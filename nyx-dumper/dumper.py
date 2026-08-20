#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
nyx-dumper  —  Roblox offset extractor (Windows, external, read-only)

WHAT IT DOES
    Attaches to a running RobloxPlayerBeta.exe, reads its memory (does NOT
    write anything, does NOT touch your account or files), scans for known
    byte-signatures and string references, resolves them to RVAs, and writes
    an offsets.h next to this script. Then it opens the folder for you.

WHAT IT DOES NOT DO
    - No writing to Roblox. Read-only. It cannot ban you for reading.
    - No network. It never phones home. (Check: there is no `socket`,
      `urllib`, or `requests` anywhere in this file.)
    - No admin needed for the read itself, though Roblox's anti-cheat
      (Hyperion) may refuse the handle regardless — see the note it prints.

HONEST LIMITS
    * Hyperion strips read handles to the Roblox process on current builds.
      If OpenProcess fails, that's why — the script falls back to scanning a
      Task Manager memory dump (.DMP) instead. That path always works.
    * Signatures drift every Roblox update. The set below is a STARTER set
      and marked accordingly. Anything that doesn't resolve, send the report
      back and we fix the signature — it's a two-minute job per function.

HOW TO RUN
    1. Install Python 3 from python.org (tick "Add Python to PATH").
    2. Join a Roblox game and wait until you're fully loaded in.
    3. Double-click this file. A console window opens and does the work.
       If double-click just flashes, open a terminal here and run:
           python dumper.py
    4. To scan a dump instead of live memory:
           python dumper.py path\to\RobloxPlayerBeta.DMP
"""

import os
import sys
import mmap
import struct
import ctypes
from ctypes import wintypes

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
OUT_PATH   = os.path.join(SCRIPT_DIR, "offsets.h")
PROC_NAME  = "RobloxPlayerBeta.exe"


# ─────────────────────────────────────────────────────────────────────────
#  Signature table
# ─────────────────────────────────────────────────────────────────────────
#
#  Each entry finds ONE offset. Two finder kinds:
#
#   ("aob",  "48 8B 05 ?? ?? ?? ??", adjust)
#       Scan for the byte pattern. `??` is a wildcard byte. The RVA is the
#       match position + `adjust`. Use adjust to skip a prologue, or set
#       ("aob_rip", ...) below to resolve a RIP-relative reference.
#
#   ("aob_rip", "48 8B 05 ?? ?? ?? ??", rip_operand_offset, instr_len)
#       Same scan, but the target is a RIP-relative DATA pointer. Reads the
#       int32 at (match + rip_operand_offset) and computes:
#           target_rva = match + instr_len + int32
#       This is how FakeDataModelPointer / IdentityPointer etc. are found.
#
#   ("string", "some unique ascii text")
#       Find the literal string in memory, report its RVA. This is the most
#       stable finder — string contents don't change between builds even when
#       code around them is recompiled. Great for the S_*, JobName_*, TM___*
#       family, which are all just strings.
#
#  STATUS TAGS in the comment column:
#       [stable]   string finders — reliable across builds
#       [starter]  provisional code sigs — VERIFY against your build
#
SIGNATURES = {
    # ---- string-based (reliable) ---------------------------------------
    "TM___namecall":   ("string", "__namecall"),
    "TM___index":      ("string", "__index"),
    "TM___newindex":   ("string", "__newindex"),
    "TM___tostring":   ("string", "__tostring"),
    "TM___metatable":  ("string", "__metatable"),
    "T_boolean":       ("string", "boolean"),
    "T_number":        ("string", "number"),
    "T_vector":        ("string", "vector"),
    "JobName_Heartbeat":       ("string", "Heartbeat"),
    "JobName_RBX_Main":        ("string", "RunPartitionJob"),  # verify literal
    "LBCVersionString":        ("string", "Unsupported bytecode version"),
    "BytecodeCorrupted":       ("string", "Bytecode corrupted"),
    "S_ReadonlyTable":         ("string", "Attempt to modify a readonly table"),
    "S_StackOverflow":         ("string", "stack overflow"),

    # ---- code signatures (STARTER — verify before trusting) ------------
    # These byte patterns are illustrative placeholders showing the format.
    # Replace the bytes with ones pulled from YOUR build (see README).
    # "Luau_execute": ("aob", "4C 8B DC 55 41 56 48 81 EC ?? ?? ?? ??", 0),
    # "lua_pushcclosure": ("aob", "48 89 5C 24 ?? 57 48 83 EC ?? 48 8B ?? ?? 41 8B F8", 0),

    # ---- RIP-relative data pointers (STARTER — verify) -----------------
    # "FakeDataModelPointer": ("aob_rip", "48 8B 05 ?? ?? ?? ?? 48 8B 88", 3, 7),
    # "TaskSchedulerPointer": ("aob_rip", "48 8B 0D ?? ?? ?? ?? E8", 3, 7),
}


# ─────────────────────────────────────────────────────────────────────────
#  Pattern parsing + scanning
# ─────────────────────────────────────────────────────────────────────────

def parse_pattern(text):
    """'48 8B ?? C3' -> (bytes_or_None list). None means wildcard."""
    out = []
    for tok in text.split():
        out.append(None if tok in ("??", "?") else int(tok, 16))
    return out


def find_pattern(buf, pat, start=0):
    """Return index of first match of `pat` (list from parse_pattern) or -1."""
    first = pat[0]
    n = len(pat)
    blen = len(buf)
    i = start
    # fast-path anchor on the first concrete byte
    if first is not None:
        while True:
            i = buf.find(first, i)
            if i < 0 or i + n > blen:
                return -1
            if _match_at(buf, pat, i, n):
                return i
            i += 1
    else:
        while i + n <= blen:
            if _match_at(buf, pat, i, n):
                return i
            i += 1
        return -1


def _match_at(buf, pat, i, n):
    for j in range(n):
        b = pat[j]
        if b is not None and buf[i + j] != b:
            return False
    return True


def find_string(buf, s, start=0):
    """First occurrence of a NUL-terminated ascii string, -1 if absent."""
    needle = s.encode("ascii") + b"\x00"
    idx = buf.find(needle, start)
    return idx


# ─────────────────────────────────────────────────────────────────────────
#  Resolve one signature against a memory image (base-relative bytes buffer)
# ─────────────────────────────────────────────────────────────────────────

def resolve(name, spec, buf):
    """Return RVA (int) or None. `buf` is the module image; index == RVA."""
    kind = spec[0]

    if kind == "string":
        idx = find_string(buf, spec[1])
        return idx if idx >= 0 else None

    if kind == "aob":
        pat = parse_pattern(spec[1])
        adjust = spec[2] if len(spec) > 2 else 0
        idx = find_pattern(buf, pat)
        return (idx + adjust) if idx >= 0 else None

    if kind == "aob_rip":
        pat = parse_pattern(spec[1])
        op_off  = spec[2]      # where the int32 operand starts inside the match
        instr_len = spec[3]    # full instruction length (for RIP base)
        idx = find_pattern(buf, pat)
        if idx < 0:
            return None
        rel = struct.unpack_from("<i", buf, idx + op_off)[0]
        return idx + instr_len + rel

    raise ValueError(f"unknown finder kind {kind!r} for {name}")


# ─────────────────────────────────────────────────────────────────────────
#  Live process reader (Windows)
# ─────────────────────────────────────────────────────────────────────────

def _win():
    return ctypes.windll  # only touched on Windows, at call time


def find_pid(name):
    TH32CS_SNAPPROCESS = 0x02
    k32 = _win().kernel32

    class PROCESSENTRY32(ctypes.Structure):
        _fields_ = [
            ("dwSize", wintypes.DWORD),
            ("cntUsage", wintypes.DWORD),
            ("th32ProcessID", wintypes.DWORD),
            ("th32DefaultHeapID", ctypes.POINTER(ctypes.c_ulong)),
            ("th32ModuleID", wintypes.DWORD),
            ("cntThreads", wintypes.DWORD),
            ("th32ParentProcessID", wintypes.DWORD),
            ("pcPriClassBase", ctypes.c_long),
            ("dwFlags", wintypes.DWORD),
            ("szExeFile", ctypes.c_char * 260),
        ]

    snap = k32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
    if snap == -1:
        return None
    entry = PROCESSENTRY32()
    entry.dwSize = ctypes.sizeof(PROCESSENTRY32)
    pid = None
    if k32.Process32First(snap, ctypes.byref(entry)):
        while True:
            if entry.szExeFile.decode(errors="ignore").lower() == name.lower():
                pid = entry.th32ProcessID
                break
            if not k32.Process32Next(snap, ctypes.byref(entry)):
                break
    k32.CloseHandle(snap)
    return pid


def module_base_and_size(pid, name):
    TH32CS_SNAPMODULE = 0x08
    TH32CS_SNAPMODULE32 = 0x10
    k32 = _win().kernel32

    class MODULEENTRY32(ctypes.Structure):
        _fields_ = [
            ("dwSize", wintypes.DWORD),
            ("th32ModuleID", wintypes.DWORD),
            ("th32ProcessID", wintypes.DWORD),
            ("GlblcntUsage", wintypes.DWORD),
            ("ProccntUsage", wintypes.DWORD),
            ("modBaseAddr", ctypes.POINTER(ctypes.c_byte)),
            ("modBaseSize", wintypes.DWORD),
            ("hModule", wintypes.HMODULE),
            ("szModule", ctypes.c_char * 256),
            ("szExePath", ctypes.c_char * 260),
        ]

    snap = k32.CreateToolhelp32Snapshot(
        TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid)
    if snap == -1:
        return None, None
    me = MODULEENTRY32()
    me.dwSize = ctypes.sizeof(MODULEENTRY32)
    base = size = None
    if k32.Module32First(snap, ctypes.byref(me)):
        while True:
            if me.szModule.decode(errors="ignore").lower() == name.lower():
                base = ctypes.cast(me.modBaseAddr, ctypes.c_void_p).value
                size = me.modBaseSize
                break
            if not k32.Module32Next(snap, ctypes.byref(me)):
                break
    k32.CloseHandle(snap)
    return base, size


def read_module_live(pid, base, size):
    PROCESS_VM_READ = 0x0010
    PROCESS_QUERY_INFORMATION = 0x0400
    k32 = _win().kernel32
    h = k32.OpenProcess(PROCESS_VM_READ | PROCESS_QUERY_INFORMATION, False, pid)
    if not h:
        return None
    buf = (ctypes.c_char * size)()
    read = ctypes.c_size_t(0)
    ok = k32.ReadProcessMemory(h, ctypes.c_void_p(base), buf,
                               size, ctypes.byref(read))
    k32.CloseHandle(h)
    if not ok or read.value == 0:
        return None
    return bytearray(buf.raw[:read.value])


# ─────────────────────────────────────────────────────────────────────────
#  Minidump reader (fallback path — always works)
# ─────────────────────────────────────────────────────────────────────────
#
#  Parses a full-memory .DMP: finds the RobloxPlayerBeta.exe module base from
#  the ModuleList stream, then walks Memory64List and stitches the module's
#  image back together so index == RVA, same as the live path.

MINIDUMP_SIG = b"MDMP"
STREAM_MODULE_LIST = 4
STREAM_MEMORY64_LIST = 9


def _read_u32(b, o):  return struct.unpack_from("<I", b, o)[0]
def _read_u64(b, o):  return struct.unpack_from("<Q", b, o)[0]


def _dump_directory(data):
    if data[:4] != MINIDUMP_SIG:
        raise ValueError("not a minidump (bad MDMP signature)")
    n_streams = _read_u32(data, 8)
    dir_rva   = _read_u32(data, 12)
    streams = {}
    for i in range(n_streams):
        off = dir_rva + i * 12
        stype = _read_u32(data, off)
        size  = _read_u32(data, off + 4)
        rva   = _read_u32(data, off + 8)
        streams[stype] = (rva, size)
    return streams


def _dump_module_base(data, streams, name):
    if STREAM_MODULE_LIST not in streams:
        return None
    rva, _ = streams[STREAM_MODULE_LIST]
    count = _read_u32(data, rva)
    p = rva + 4
    for _ in range(count):
        base = _read_u64(data, p)
        # MINIDUMP_MODULE: BaseOfImage(u64) SizeOfImage(u32) CheckSum(u32)
        # TimeDateStamp(u32) ModuleNameRva(u32) -> name rva at struct offset 20
        name_rva = _read_u32(data, p + 20)
        # MINIDUMP_MODULE is 108 bytes; name string is a MINIDUMP_STRING
        slen = _read_u32(data, name_rva)
        raw = data[name_rva + 4: name_rva + 4 + slen]
        modname = raw.decode("utf-16-le", errors="ignore")
        if modname.lower().endswith(name.lower()):
            return base
        p += 108
    return None


def _dump_read_module(data, streams, base, name):
    """Return a bytearray where index == RVA for the module image."""
    if STREAM_MEMORY64_LIST not in streams:
        return None
    rva, _ = streams[STREAM_MEMORY64_LIST]
    count = _read_u64(data, rva)
    base_rva = _read_u64(data, rva + 8)  # file offset of first memory blob
    # Each descriptor: StartOfMemoryRange (u64), DataSize (u64)
    descs = []
    p = rva + 16
    file_off = base_rva
    for _ in range(count):
        start = _read_u64(data, p)
        dsize = _read_u64(data, p + 8)
        descs.append((start, dsize, file_off))
        file_off += dsize
        p += 16

    # Determine module image span from PE headers at base.
    # Find the descriptor covering `base`, read SizeOfImage from the PE.
    img = None
    for (start, dsize, foff) in descs:
        if start <= base < start + dsize:
            hdr = data[foff + (base - start): foff + (base - start) + 0x400]
            if hdr[:2] == b"MZ":
                e_lfanew = _read_u32(hdr, 0x3C)
                size_of_image = _read_u32(hdr, e_lfanew + 0x18 + 0x38)
                img = bytearray(size_of_image)
            break
    if img is None:
        return None

    # Copy every descriptor that falls inside [base, base+len(img)) into img.
    end = base + len(img)
    for (start, dsize, foff) in descs:
        if start + dsize <= base or start >= end:
            continue
        seg_start = max(start, base)
        seg_end = min(start + dsize, end)
        dst = seg_start - base
        src = foff + (seg_start - start)
        img[dst:dst + (seg_end - seg_start)] = data[src:src + (seg_end - seg_start)]
    return img


# ─────────────────────────────────────────────────────────────────────────
#  Output
# ─────────────────────────────────────────────────────────────────────────

def write_header(results, source_desc):
    lines = []
    lines.append("/*")
    lines.append(" *  offsets.h  —  generated by nyx-dumper")
    lines.append(f" *  source: {source_desc}")
    lines.append(" *  NOTE: entries marked (unresolved) were not found — the")
    lines.append(" *        signature needs updating for this build.")
    lines.append(" */")
    lines.append("#pragma once")
    lines.append("#include <cstdint>")
    lines.append("#include <Windows.h>")
    lines.append("")
    lines.append("inline std::uintptr_t rbx_rebase(std::uintptr_t rva) {")
    lines.append("    static std::uintptr_t base ="
                 " reinterpret_cast<std::uintptr_t>(GetModuleHandleA(nullptr));")
    lines.append("    return rva ? (rva + base) : 0;")
    lines.append("}")
    lines.append("#define REBASE(x) (rbx_rebase(x))")
    lines.append("")
    lines.append("namespace Offsets {")
    width = max((len(k) for k in results), default=1)
    for name, rva in results.items():
        if rva is None:
            lines.append(f"    // {name:<{width}} = (unresolved)")
        else:
            lines.append(
                f"    inline const uintptr_t {name:<{width}} = REBASE(0x{rva:X});")
    lines.append("}")
    lines.append("")
    with open(OUT_PATH, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


def open_folder():
    try:
        os.startfile(SCRIPT_DIR)  # noqa: this is Windows-only, intended
    except Exception:
        pass


# ─────────────────────────────────────────────────────────────────────────
#  Main
# ─────────────────────────────────────────────────────────────────────────

def scan_dump(path):
    """Rebuild the module image from a minidump on disk.

    The file is memory-mapped rather than read into RAM: these dumps run
    2-6 GB and loading one outright can fail on an 8 GB machine that still
    has Roblox open. mmap lets the OS page in only what we touch, so peak
    usage is roughly the size of the module image (~150 MB), not the dump.
    """
    size_mb = os.path.getsize(path) / (1024 * 1024)
    print(f"[*] Scanning dump file: {path}  ({size_mb:.0f} MB)")
    print("[*] Memory-mapping (no need to load it all) ...")
    with open(path, "rb") as f:
        with mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as data:
            streams = _dump_directory(data)
            base = _dump_module_base(data, streams, PROC_NAME)
            if base is None:
                return None, "module not found in dump"
            print(f"[*] Module base 0x{base:X} — rebuilding image ...")
            img = _dump_read_module(data, streams, base, PROC_NAME)
            if img is None:
                return None, "could not rebuild module image from dump"
            return img, f"dump {os.path.basename(path)} (base 0x{base:X})"


def find_local_dumps():
    """Look where Task Manager actually puts dumps. Newest first."""
    candidates = []
    roots = [
        os.environ.get("TEMP", ""),
        os.path.join(os.path.expanduser("~"), "Desktop"),
        os.path.join(os.path.expanduser("~"), "Downloads"),
        SCRIPT_DIR,
    ]
    for root in roots:
        if not root or not os.path.isdir(root):
            continue
        try:
            for fn in os.listdir(root):
                if fn.lower().endswith(".dmp") and "roblox" in fn.lower():
                    full = os.path.join(root, fn)
                    try:
                        candidates.append((os.path.getmtime(full), full))
                    except OSError:
                        pass
        except OSError:
            pass
    candidates.sort(reverse=True)
    return [p for _, p in candidates]


def acquire_image():
    """Return (image_bytes, source_description) or (None, reason)."""
    if len(sys.argv) > 1:
        return scan_dump(sys.argv[1])

    print(f"[*] Looking for {PROC_NAME} ...")
    pid = find_pid(PROC_NAME)
    if not pid:
        return None, f"{PROC_NAME} is not running — join a game first"
    print(f"[*] Found pid {pid}")
    base, size = module_base_and_size(pid, PROC_NAME)
    if not base:
        return None, "could not read module base (Hyperion may be blocking)"
    print(f"[*] Module base 0x{base:X}, size 0x{size:X}, reading ...")
    img = read_module_live(pid, base, size)
    if img is None:
        return None, ("OpenProcess/ReadProcessMemory denied — this is "
                      "Hyperion. Use the dump route instead (see README).")
    return img, f"live pid {pid} (base 0x{base:X})"


def main():
    print("=" * 60)
    print("  nyx-dumper — Roblox offset extractor (read-only)")
    print("=" * 60)

    if sys.platform != "win32":
        print("[!] This must run on Windows (it reads a Windows process).")
        input("\nPress Enter to close...")
        return

    try:
        img, desc = acquire_image()
    except Exception as e:
        print(f"[!] {e}")
        input("\nPress Enter to close...")
        return

    if img is None:
        print(f"[!] {desc}\n")

        # Anti-cheat blocking the live read is the NORMAL outcome, not a
        # failure. Look for a dump the user may already have made.
        dumps = find_local_dumps()
        if dumps:
            print("[*] Found a Roblox dump already on this PC:")
            for i, p in enumerate(dumps[:5], 1):
                mb = os.path.getsize(p) / (1024 * 1024)
                print(f"      {i}. {p}  ({mb:.0f} MB)")
            pick = input("\n    Use #1? [Y/n, or type a number]: ").strip().lower()
            chosen = None
            if pick in ("", "y", "yes"):
                chosen = dumps[0]
            elif pick.isdigit() and 1 <= int(pick) <= min(5, len(dumps)):
                chosen = dumps[int(pick) - 1]
            if chosen:
                try:
                    img, desc = scan_dump(chosen)
                except Exception as e:
                    img, desc = None, str(e)
                if img is not None:
                    return _finish(img, desc)
                print(f"[!] {desc}")

        print("\n    Next step — make a memory dump (takes ~1 minute):")
        print("      1. Ctrl+Shift+Esc  ->  'Details' tab")
        print("      2. Right-click RobloxPlayerBeta.exe -> 'Create dump file'")
        print("      3. Leave Roblox running until it finishes")
        print("      4. Run this script again — it will find the dump itself.")
        print("\n    (Or pass the path directly:  python dumper.py C:\\path\\to\\that.DMP)")
        input("\nPress Enter to close...")
        return

    _finish(img, desc)


def _finish(img, desc):
    """Resolve every signature against the image, write offsets.h, open it."""
    print(f"\n[*] Image ready ({len(img)} bytes). Resolving signatures ...\n")
    results = {}
    found = 0
    for name, spec in SIGNATURES.items():
        try:
            rva = resolve(name, spec, img)
        except Exception as e:
            rva = None
            print(f"    {name}: error {e}")
        results[name] = rva
        if rva is not None:
            found += 1
            print(f"    [ok]   {name} = 0x{rva:X}")
        else:
            print(f"    [MISS] {name}")

    write_header(results, desc)
    print(f"\n[*] Wrote {found}/{len(SIGNATURES)} resolved to:")
    print(f"    {OUT_PATH}")
    if found < len(SIGNATURES):
        print("\n[*] The [MISS] entries just need their signature updated for")
        print("    this build. Send the offsets.h back and they get fixed.")
    print("\n[*] Opening the folder ...")
    open_folder()
    input("\nDone — send offsets.h back. Press Enter to close...")


if __name__ == "__main__":
    main()
