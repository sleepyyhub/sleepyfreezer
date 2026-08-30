#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
analyze.py  —  validate an unpacked RobloxPlayerBeta.exe and mine it

Runs anywhere Python does (macOS included). Roblox does not need to be
installed or running. Give it an unpacked/dumped client image and, if you
have one, an existing offsets header, and it will:

  1. VERIFY the unpack is usable — are sections present, is .text real code,
     do the RVAs line up? If this fails, nothing downstream is worth doing.

  2. CLASSIFY every offset in your header — function / string / data /
     garbage. This is how you check the claim that much of a dumped header
     is string data rather than callable code.

  3. GENERATE byte signatures for the entries that are real functions, in
     the exact format dumper.py's SIGNATURES table wants, uniqueness-tested
     against the whole image.

  4. DISCOVER offsets in a build you have NO header for. String contents
     survive Roblox updates even though addresses move, so a string scan
     yields a fresh, real offset table for the image in front of you.

USAGE
    python analyze.py client.exe
    python analyze.py client.bin --discover new_offsets.h
    python analyze.py client.exe old_offsets.h
    python analyze.py client.exe old_offsets.h --sigs signatures.py

FLAGS
    --discover [out.h]   scan for known strings, write an offsets header
    --sigs [out.py]      emit AOB signatures for dumper.py
    --raw                force flat-image mode (skip PE parsing)

Accepts a .exe or a headerless .bin memory dump. The file is memory-mapped,
so size is not a concern.
"""

import os
import re
import sys
import mmap
import struct

# ─────────────────────────────────────────────────────────────────────────
#  Minimal PE reader
# ─────────────────────────────────────────────────────────────────────────


class PE:
    """Just enough PE parsing to map RVA -> file bytes and name sections."""

    def __init__(self, data):
        self.data = data
        if data[:2] != b"MZ":
            raise ValueError("not a PE file (no MZ header)")
        e_lfanew = struct.unpack_from("<I", data, 0x3C)[0]
        if data[e_lfanew:e_lfanew + 4] != b"PE\0\0":
            raise ValueError("not a PE file (no PE signature)")

        coff = e_lfanew + 4
        self.machine = struct.unpack_from("<H", data, coff)[0]
        n_sections = struct.unpack_from("<H", data, coff + 2)[0]
        opt_size = struct.unpack_from("<H", data, coff + 16)[0]
        opt = coff + 20

        magic = struct.unpack_from("<H", data, opt)[0]
        self.is_64 = (magic == 0x20B)
        self.entry_rva = struct.unpack_from("<I", data, opt + 16)[0]
        if self.is_64:
            self.image_base = struct.unpack_from("<Q", data, opt + 24)[0]
        else:
            self.image_base = struct.unpack_from("<I", data, opt + 28)[0]
        self.size_of_image = struct.unpack_from("<I", data, opt + 56)[0]

        self.sections = []
        sec = opt + opt_size
        for i in range(n_sections):
            o = sec + i * 40
            name = data[o:o + 8].rstrip(b"\0").decode("ascii", "replace")
            vsize = struct.unpack_from("<I", data, o + 8)[0]
            vaddr = struct.unpack_from("<I", data, o + 12)[0]
            rsize = struct.unpack_from("<I", data, o + 16)[0]
            roff = struct.unpack_from("<I", data, o + 20)[0]
            chars = struct.unpack_from("<I", data, o + 36)[0]
            self.sections.append({
                "name": name, "vaddr": vaddr, "vsize": vsize,
                "roff": roff, "rsize": rsize, "chars": chars,
                "exec": bool(chars & 0x20000000),
                "read": bool(chars & 0x40000000),
                "write": bool(chars & 0x80000000),
            })

    def section_of(self, rva):
        for s in self.sections:
            if s["vaddr"] <= rva < s["vaddr"] + max(s["vsize"], s["rsize"]):
                return s
        return None

    def rva_to_off(self, rva):
        """File offset for an RVA, or None if unmapped.

        A dumped-from-memory image is usually already flat (roff == vaddr).
        Both layouts are handled.
        """
        s = self.section_of(rva)
        if not s:
            return None
        delta = rva - s["vaddr"]
        if delta >= s["rsize"]:
            return None          # in virtual padding, no file bytes
        return s["roff"] + delta

    def read(self, rva, n):
        off = self.rva_to_off(rva)
        if off is None or off + n > len(self.data):
            return None
        return self.data[off:off + n]

    def is_flat(self):
        """True if the image looks dumped-from-memory (raw == virtual)."""
        hits = sum(1 for s in self.sections
                   if s["rsize"] and s["roff"] == s["vaddr"])
        return hits >= max(1, len(self.sections) // 2)


class RawImage:
    """Fallback for a headerless blob (a .bin 'decrypt dump', typically the
    module copied straight out of memory).

    With no section table we cannot say what is code and what is data, so the
    whole file is treated as one readable+executable span and RVA == file
    offset. Classification gets less precise; string finding is unaffected,
    which is the part that matters for cross-version work.
    """

    def __init__(self, data):
        self.data = data
        self.machine = 0x8664
        self.is_64 = True
        self.entry_rva = 0
        self.image_base = 0
        self.size_of_image = len(data)
        self.sections = [{
            "name": "<raw>", "vaddr": 0, "vsize": len(data),
            "roff": 0, "rsize": len(data), "chars": 0,
            "exec": True, "read": True, "write": False,
        }]

    def section_of(self, rva):
        return self.sections[0] if 0 <= rva < len(self.data) else None

    def rva_to_off(self, rva):
        return rva if 0 <= rva < len(self.data) else None

    def read(self, rva, n):
        if rva < 0 or rva + n > len(self.data):
            return None
        return self.data[rva:rva + n]

    def is_flat(self):
        return True


def load_image(data, force_raw=False):
    """Return (image, kind). Falls back to RawImage for headerless dumps."""
    if not force_raw:
        try:
            return PE(data), "pe"
        except ValueError:
            pass
    return RawImage(data), "raw"


# ─────────────────────────────────────────────────────────────────────────
#  Classification
# ─────────────────────────────────────────────────────────────────────────

# Common x64 function-prologue openings. Not exhaustive — a miss here does
# not prove something isn't a function, it just lowers confidence.
PROLOGUES = [
    b"\x48\x89\x5C\x24",      # mov [rsp+x], rbx
    b"\x48\x89\x54\x24",      # mov [rsp+x], rdx
    b"\x48\x89\x4C\x24",      # mov [rsp+x], rcx
    b"\x48\x89\x74\x24",      # mov [rsp+x], rsi
    b"\x48\x89\x7C\x24",      # mov [rsp+x], rdi
    b"\x48\x83\xEC",          # sub rsp, imm8
    b"\x48\x81\xEC",          # sub rsp, imm32
    b"\x4C\x8B\xDC",          # mov r11, rsp
    b"\x40\x53",              # push rbx
    b"\x40\x55",              # push rbp
    b"\x40\x56",              # push rsi
    b"\x40\x57",              # push rdi
    b"\x55\x48\x8B\xEC",      # push rbp; mov rbp, rsp
    b"\x53\x48\x83\xEC",      # push rbx; sub rsp
    b"\x56\x48\x83\xEC",
    b"\x57\x48\x83\xEC",
    b"\xE9", b"\xEB",         # thunk / jmp stub
]


def looks_like_code(b):
    if not b:
        return False
    return any(b.startswith(p) for p in PROLOGUES)


def looks_like_cstring(b):
    """Printable ASCII run terminated by NUL, at least 2 chars."""
    if not b:
        return False
    end = b.find(b"\x00")
    if end < 2:
        return False
    s = b[:end]
    return all(32 <= c < 127 for c in s)


def entropy_ok(b):
    """Crude check that a code region isn't still packed/zeroed."""
    if not b:
        return False
    if b.count(0) > len(b) * 0.9:
        return False
    return len(set(b)) > 16


def classify(pe, rva):
    """-> (kind, detail)"""
    s = pe.section_of(rva)
    if not s:
        return "unmapped", "RVA outside every section"
    raw = pe.read(rva, 64)
    if raw is None:
        return "novalue", f"in {s['name']} but no file bytes (virtual padding)"

    if looks_like_cstring(raw):
        text = raw[:raw.find(b"\x00")].decode("ascii", "replace")
        if len(text) > 48:
            text = text[:48] + "..."
        return "string", f'"{text}"'

    if s["exec"]:
        if looks_like_code(raw):
            return "function", raw[:8].hex(" ")
        if entropy_ok(raw):
            return "code?", raw[:8].hex(" ") + "  (exec, no known prologue)"
        return "empty", "executable section but looks blank/packed"

    return "data", raw[:8].hex(" ")


# ─────────────────────────────────────────────────────────────────────────
#  Signature generation
# ─────────────────────────────────────────────────────────────────────────
#
#  Take bytes at the function start and wildcard anything that looks like it
#  encodes an address (RIP-relative operands, call/jmp displacements), since
#  those shift between builds. Then verify the result matches exactly once.

def make_signature(pe, rva, length=32):
    raw = pe.read(rva, length)
    if not raw:
        return None
    b = bytearray(raw)
    mask = [True] * len(b)   # True = keep concrete byte

    i = 0
    while i < len(b) - 6:
        op = b[i]
        # E8/E9 rel32 call/jmp -> wildcard the displacement
        if op in (0xE8, 0xE9):
            for j in range(i + 1, min(i + 5, len(b))):
                mask[j] = False
            i += 5
            continue
        # 48 8B 05 / 48 8D 05 etc: REX.W + opcode + modrm with RIP base
        if op in (0x48, 0x4C) and i + 2 < len(b):
            modrm = b[i + 2]
            if (modrm & 0xC7) == 0x05:       # mod=00 rm=101 -> RIP-relative
                for j in range(i + 3, min(i + 7, len(b))):
                    mask[j] = False
                i += 7
                continue
        i += 1

    parts = []
    for j, keep in enumerate(mask):
        parts.append(f"{b[j]:02X}" if keep else "??")
    # trim trailing wildcards, they add nothing
    while parts and parts[-1] == "??":
        parts.pop()
    return " ".join(parts) if len(parts) >= 8 else None


def _to_pattern(sig):
    return [None if t == "??" else int(t, 16) for t in sig.split()]


def count_matches(pe, sig, limit=3):
    """How many times this signature occurs across executable sections."""
    pat = _to_pattern(sig)
    n = len(pat)
    first = pat[0]
    total = 0
    for s in pe.sections:
        if not s["exec"] or not s["rsize"]:
            continue
        blob = pe.data[s["roff"]:s["roff"] + s["rsize"]]
        i = 0
        while True:
            i = blob.find(first, i)
            if i < 0 or i + n > len(blob):
                break
            if all(pat[j] is None or blob[i + j] == pat[j] for j in range(n)):
                total += 1
                if total >= limit:
                    return total
            i += 1
    return total


# ─────────────────────────────────────────────────────────────────────────
#  Header parsing
# ─────────────────────────────────────────────────────────────────────────

RE_OFFSET = re.compile(
    r"(?:inline\s+const\s+)?(?:std::)?uintptr_t\s+(\w+)\s*=\s*REBASE\(\s*(0[xX][0-9a-fA-F]+)\s*\)")


def parse_header(path):
    out = {}
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.split("//")[0]
            m = RE_OFFSET.search(line)
            if m:
                out[m.group(1)] = int(m.group(2), 16)
    return out


# ─────────────────────────────────────────────────────────────────────────
#  Report
# ─────────────────────────────────────────────────────────────────────────

def verify_image(pe):
    print("=" * 68)
    print("  1. IMAGE VERIFICATION")
    print("=" * 68)
    arch = "x64" if pe.is_64 else "x86"
    print(f"  architecture   : {arch} (machine 0x{pe.machine:X})")
    print(f"  image base     : 0x{pe.image_base:X}")
    print(f"  size of image  : 0x{pe.size_of_image:X}")
    print(f"  entry point    : 0x{pe.entry_rva:X}")
    print(f"  layout         : {'flat / dumped-from-memory' if pe.is_flat() else 'on-disk (raw != virtual)'}")
    print(f"  sections       : {len(pe.sections)}")
    print()
    print(f"    {'name':<10} {'vaddr':>10} {'vsize':>10} {'rsize':>10}  flags  state")
    ok_text = False
    for s in pe.sections:
        flags = ("R" if s["read"] else "-") + ("W" if s["write"] else "-") + \
                ("X" if s["exec"] else "-")
        state = ""
        if s["exec"]:
            blob = pe.data[s["roff"]:s["roff"] + min(s["rsize"], 0x4000)]
            if not s["rsize"]:
                state = "NO RAW DATA - still packed?"
            elif not entropy_ok(blob):
                state = "blank/low-entropy - still packed?"
            else:
                state = "looks like real code"
                ok_text = True
        print(f"    {s['name']:<10} 0x{s['vaddr']:>8X} 0x{s['vsize']:>8X} "
              f"0x{s['rsize']:>8X}  {flags}    {state}")
    print()
    if ok_text:
        print("  [OK]   At least one executable section holds real code.")
    else:
        print("  [BAD]  No executable section looks like real code.")
        print("         This image is still packed. Nothing below is reliable.")
    return ok_text


def check_offsets(pe, offsets):
    print()
    print("=" * 68)
    print("  2. OFFSET CLASSIFICATION")
    print("=" * 68)
    print("  What each labelled offset actually points at.\n")

    buckets = {}
    rows = []
    for name, rva in sorted(offsets.items(), key=lambda kv: kv[1]):
        kind, detail = classify(pe, rva)
        buckets.setdefault(kind, []).append(name)
        rows.append((name, rva, kind, detail))

    width = max((len(n) for n in offsets), default=10)
    for name, rva, kind, detail in rows:
        print(f"    {name:<{width}} 0x{rva:<9X} [{kind:<8}] {detail}")

    print()
    print("  Summary:")
    for kind in sorted(buckets, key=lambda k: -len(buckets[k])):
        print(f"    {kind:<10} {len(buckets[kind]):>4}")

    unmapped = len(buckets.get("unmapped", [])) + len(buckets.get("novalue", []))
    total = len(offsets)
    if total:
        bad_pct = 100.0 * unmapped / total
        print()
        if bad_pct > 50:
            print(f"  [BAD]  {bad_pct:.0f}% of offsets do not resolve. Either this")
            print("         image is a different build, or RVAs are shifted.")
        elif bad_pct > 10:
            print(f"  [WARN] {bad_pct:.0f}% unresolved — likely a version mismatch.")
        else:
            print(f"  [OK]   {100 - bad_pct:.0f}% of offsets land on real content.")
            print("         RVAs line up. This image matches these offsets.")
    return buckets


def gen_signatures(pe, offsets, buckets, out_path=None):
    print()
    print("=" * 68)
    print("  3. SIGNATURE GENERATION")
    print("=" * 68)
    funcs = buckets.get("function", []) + buckets.get("code?", [])
    if not funcs:
        print("  No function-like offsets to sign.")
        return
    print(f"  Building patterns for {len(funcs)} function offsets ...\n")

    lines = ["# Generated by analyze.py — paste into dumper.py SIGNATURES",
             "SIGNATURES = {"]
    good = 0
    for name in sorted(funcs):
        rva = offsets[name]
        sig = make_signature(pe, rva)
        if not sig:
            print(f"    [skip]   {name}: could not read bytes")
            continue
        hits = count_matches(pe, sig)
        if hits == 1:
            print(f"    [unique] {name}")
            lines.append(f'    "{name}": ("aob", "{sig}", 0),')
            good += 1
        elif hits == 0:
            print(f"    [bug]    {name}: signature does not match itself")
        else:
            print(f"    [ambig]  {name}: {hits}+ matches — needs a longer pattern")
            lines.append(f'    # "{name}": ("aob", "{sig}", 0),  # AMBIGUOUS')
    lines.append("}")

    print(f"\n  {good}/{len(funcs)} signatures are unique and usable.")
    if out_path:
        with open(out_path, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
        print(f"  Written to {out_path}")


# ─────────────────────────────────────────────────────────────────────────
#  Discovery — find offsets with no prior header to compare against
# ─────────────────────────────────────────────────────────────────────────
#
#  String contents survive Roblox updates even though addresses move, so a
#  string scan yields a usable offset table for a build you have nothing for.
#  Anything that resolves here is real: it was found in THIS image, not
#  carried over from an older dump.

KNOWN_STRINGS = {
    # metamethods
    "TM___index":        "__index",
    "TM___newindex":     "__newindex",
    "TM___namecall":     "__namecall",
    "TM___call":         "__call",
    "TM___concat":       "__concat",
    "TM___tostring":     "__tostring",
    "TM___metatable":    "__metatable",
    "TM___mode":         "__mode",
    "TM___len":          "__len",
    "TM___eq":           "__eq",
    "TM___iter":         "__iter",
    # type names
    "T_boolean":         "boolean",
    "T_number":          "number",
    "T_vector":          "vector",
    "T_thread":          "thread",
    "T_userdata":        "userdata",
    "T_buffer":          "buffer",
    # VM error strings — high-value anchors, each referenced by one function
    "S_StackOverflow":       "stack overflow",
    "S_ReadonlyTable":       "Attempt to modify a readonly table",
    "S_TableIndexIsNil":     "table index is nil",
    "S_TableIndexIsNaN":     "table index is NaN",
    "S_CannotResumeDead":    "cannot resume dead coroutine",
    "S_AttemptYieldBoundary": "attempt to yield across metamethod/C-call boundary",
    "S_ScriptTimeout":       "script exhausted",
    # bytecode / loader
    "BytecodeVersionMismatch": "Unsupported bytecode version",
    "BytecodeCorrupted":       "Bytecode corrupted",
    # scheduler job names
    "JobName_Heartbeat":     "Heartbeat",
    "JobName_Simulation":    "Simulation",
    "JobName_FrameStart":    "FrameStart",
    "JobName_FrameEnd":      "FrameEnd",
    "JobName_PostRender":    "PostRender",
    # services / instances
    "Svc_Workspace":         "Workspace",
    "Svc_ReplicatedStorage": "ReplicatedStorage",
    "Svc_HttpService":       "HttpService",
    "Svc_UserInputService":  "UserInputService",
    "Svc_RunService":        "RunService",
    "Cls_RemoteEvent":       "RemoteEvent",
    "Cls_RemoteFunction":    "RemoteFunction",
    "Cls_ClickDetector":     "ClickDetector",
    "Cls_ProximityPrompt":   "ProximityPrompt",
    # anti-cheat surface
    "Hyperion_Untrusted":    "PlayerUntrusted",
}


def _all_string_hits(data, s, cap=8, anchored=True):
    """Every NUL-terminated occurrence of `s`, as file offsets.

    anchored=True also requires the match to START a string — the preceding
    byte must be NUL (or non-printable). Without this, "vector" matches
    inside "__vector" and "number" inside "lua_number", which buries the
    real hit in noise.
    """
    needle = s.encode("ascii") + b"\x00"
    hits = []
    i = 0
    while len(hits) < cap:
        i = data.find(needle, i)
        if i < 0:
            break
        if not anchored or i == 0 or not (32 <= data[i - 1] < 127):
            hits.append(i)
        i += 1
    return hits


def discover(img, out_path=None):
    print()
    print("=" * 68)
    print("  STRING DISCOVERY")
    print("=" * 68)
    print("  Finding known strings in THIS image. Version-independent —")
    print("  works on a build you have no offsets for.\n")

    data = img.data
    results = {}
    ambiguous = 0
    for name, text in sorted(KNOWN_STRINGS.items()):
        hits = _all_string_hits(data, text)
        if not hits:
            print(f"    [MISS]  {name:<26} \"{text}\"")
            results[name] = None
        elif len(hits) == 1:
            print(f"    [ok]    {name:<26} 0x{hits[0]:X}")
            results[name] = hits[0]
        else:
            ambiguous += 1
            locs = ", ".join(f"0x{h:X}" for h in hits[:4])
            more = "..." if len(hits) > 4 else ""
            print(f"    [multi] {name:<26} {len(hits)} hits: {locs}{more}")
            results[name] = hits[0]   # first occurrence, verify before trusting

    found = sum(1 for v in results.values() if v is not None)
    print(f"\n  Resolved {found}/{len(KNOWN_STRINGS)}"
          f"   ({ambiguous} had multiple matches — verify those)")

    if found == 0:
        print("\n  [BAD] Nothing found. Either this is not a Roblox image, or")
        print("        it is still encrypted/packed.")
        return results

    if out_path:
        lines = [
            "/*",
            " *  Discovered by analyze.py --discover",
            " *  String offsets found in this image. Entries marked (multi)",
            " *  matched more than once — confirm which occurrence you want.",
            " */",
            "#pragma once",
            "#include <cstdint>",
            "#include <Windows.h>",
            "",
            "inline std::uintptr_t rbx_rebase(std::uintptr_t rva) {",
            "    static std::uintptr_t base ="
            " reinterpret_cast<std::uintptr_t>(GetModuleHandleA(nullptr));",
            "    return rva ? (rva + base) : 0;",
            "}",
            "#define REBASE(x) (rbx_rebase(x))",
            "",
            "namespace Offsets {",
        ]
        width = max(len(k) for k in results)
        for name, rva in results.items():
            if rva is None:
                lines.append(f"    // {name:<{width}} = (not found)")
            else:
                lines.append(
                    f"    inline const uintptr_t {name:<{width}} = REBASE(0x{rva:X});")
        lines.append("}")
        with open(out_path, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
        print(f"  Written to {out_path}")
    return results


def dump_strings_at(img, rva, length=0x400, minlen=3):
    """List every printable C string in [rva, rva+length).

    Use this to inspect a literal pool — when a string you expected is
    missing, look at the neighbourhood of one that resolved and read what is
    actually there.
    """
    print()
    print("=" * 68)
    print(f"  STRINGS IN 0x{rva:X} .. 0x{rva + length:X}")
    print("=" * 68)
    blob = img.read(rva, length)
    if blob is None:
        print(f"  [!] 0x{rva:X}+0x{length:X} is not readable in this image.")
        return
    count = 0
    i = 0
    n = len(blob)
    while i < n:
        if 32 <= blob[i] < 127:
            j = i
            while j < n and 32 <= blob[j] < 127:
                j += 1
            if j - i >= minlen and j < n and blob[j] == 0:
                text = blob[i:j].decode("ascii")
                print(f"    0x{rva + i:X}  ({j - i:>3})  {text!r}")
                count += 1
            i = j + 1
        else:
            i += 1
    print(f"\n  {count} strings.")


def dump_pointers_at(img, rva, length=0x100):
    """Read a region as 64-bit pointers and resolve each into the image.

    A dumped-from-memory image stores absolute VAs, so a qword inside
    [image_base, image_base+size) is a pointer to somewhere in this same
    file. Where it lands on a string, the string is printed.

    This is how you read a pointer TABLE — e.g. Luau's metamethod name array
    hands you every entry in order, including ones a string scan missed.
    """
    print()
    print("=" * 68)
    print(f"  POINTERS IN 0x{rva:X} .. 0x{rva + length:X}")
    print("=" * 68)
    blob = img.read(rva, length)
    if blob is None:
        print(f"  [!] 0x{rva:X}+0x{length:X} is not readable in this image.")
        return

    base = getattr(img, "image_base", 0) or 0
    size = getattr(img, "size_of_image", len(img.data))
    resolved = 0
    for i in range(0, len(blob) - 7, 8):
        q = struct.unpack_from("<Q", blob, i)[0]
        here = rva + i
        if q == 0:
            print(f"    0x{here:X}  0x{q:016X}")
            continue

        target = None
        if base and base <= q < base + size:
            target = q - base
        elif 0 < q < size:
            target = q                    # stored as a plain RVA

        if target is None:
            print(f"    0x{here:X}  0x{q:016X}")
            continue

        note = f"-> 0x{target:X}"
        raw = img.read(target, 64)
        if raw:
            end = raw.find(b"\x00")
            if end > 0 and all(32 <= c < 127 for c in raw[:end]):
                note += f"  {raw[:end].decode('ascii')!r}"
                resolved += 1
        print(f"    0x{here:X}  0x{q:016X}  {note}")
    print(f"\n  {resolved} pointers landed on strings.")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1

    exe = sys.argv[1]
    header = None
    out_sigs = None
    out_disc = None
    args = sys.argv[2:]
    if args and not args[0].startswith("--"):
        header = args[0]
        args = args[1:]
    force_raw = "--raw" in args
    want_discover = "--discover" in args
    at_rva = at_len = None
    if "--at" in args:
        i = args.index("--at")
        try:
            at_rva = int(args[i + 1], 0)
            at_len = int(args[i + 2], 0) if (i + 2 < len(args)
                                             and not args[i + 2].startswith("--")) else 0x400
        except (IndexError, ValueError):
            print("[!] --at needs an address, e.g. --at 0x6D45300 0x400")
            return 1

    ptr_rva = ptr_len = None
    if "--ptrs" in args:
        i = args.index("--ptrs")
        try:
            ptr_rva = int(args[i + 1], 0)
            ptr_len = int(args[i + 2], 0) if (i + 2 < len(args)
                                              and not args[i + 2].startswith("--")) else 0x100
        except (IndexError, ValueError):
            print("[!] --ptrs needs an address, e.g. --ptrs 0x6D45420 0x100")
            return 1
    if "--sigs" in args:
        i = args.index("--sigs")
        out_sigs = args[i + 1] if i + 1 < len(args) else "signatures.py"
    if want_discover:
        i = args.index("--discover")
        nxt = args[i + 1] if i + 1 < len(args) else None
        out_disc = nxt if (nxt and not nxt.startswith("--")) else "discovered.h"

    if not os.path.isfile(exe):
        print(f"[!] no such file: {exe}")
        return 1

    size_mb = os.path.getsize(exe) / (1024 * 1024)
    print(f"[*] {os.path.basename(exe)}  ({size_mb:.1f} MB)\n")

    with open(exe, "rb") as f:
        with mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as data:
            img, kind = load_image(data, force_raw)
            if kind == "raw":
                print("[*] No usable PE header — treating as a flat memory")
                print("    image (RVA == file offset). Normal for a .bin dump.\n")

            usable = verify_image(img)

            if at_rva is not None:
                dump_strings_at(img, at_rva, at_len)

            if ptr_rva is not None:
                dump_pointers_at(img, ptr_rva, ptr_len)

            if want_discover:
                discover(img, out_disc)

            if header:
                if not os.path.isfile(header):
                    print(f"\n[!] no such header: {header}")
                    return 1
                offsets = parse_header(header)
                print(f"\n[*] Parsed {len(offsets)} offsets from "
                      f"{os.path.basename(header)}")
                if not offsets:
                    print("[!] none matched the REBASE(0x...) pattern")
                    return 1
                buckets = check_offsets(img, offsets)
                if usable:
                    gen_signatures(img, offsets, buckets, out_sigs)
            elif not want_discover:
                print("\n[*] Next: pass an offsets header to classify it, or")
                print("    --discover to find offsets in this image directly.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
