#!/usr/bin/env python3
"""Test harness for the Luau obfuscator.

For each sample .luau file:
  1. Run it directly through the luau interpreter  -> reference output
  2. Transform it (roundtrip or obfuscate) via a generated driver -> new source
  3. Run the new source through luau                -> test output
  4. Compare. PASS iff outputs are byte-identical.

Usage: run.py [roundtrip|obfuscate] [sample ...]
"""
import os, sys, subprocess, tempfile, glob

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
LUAU = os.environ.get("LUAU",
    "/tmp/claude-0/-home-user-sleepyfreezer/6b321802-9070-5c91-b2f5-536294776d13/scratchpad/luau")

def luau_string(data: bytes) -> str:
    out = ['"']
    for b in data:
        c = chr(b)
        if c == '"': out.append('\\"')
        elif c == '\\': out.append('\\\\')
        elif b == 10: out.append('\\n')
        elif b == 13: out.append('\\r')
        elif b == 9: out.append('\\t')
        elif b < 32 or b >= 127: out.append('\\%d' % b)
        else: out.append(c)
    out.append('"')
    return ''.join(out)

def run_luau(path: str):
    # Capture bytes: obfuscated source and program output may contain arbitrary bytes.
    p = subprocess.run([LUAU, path], capture_output=True, timeout=60)
    return p.returncode, p.stdout, p.stderr

def make_driver(mode: str, src_bytes: bytes, seed: int) -> str:
    """Write a driver .luau in tests/ that emits transformed source to stdout."""
    lit = luau_string(src_bytes)
    if mode == "roundtrip":
        body = """
local Parser = require("../src/Parser")
local Serializer = require("../src/Serializer")
local ast = Parser.parse(SRC)
io_write(Serializer.serialize(ast))
"""
    elif mode == "clovyre":
        protect = "true" if os.environ.get("CLOVYRE_PROTECT") else "false"
        mod = "../dist/Clovyre" if os.environ.get("CLOVYRE_BUNDLE") else "../src/Clovyre"
        body = """
local Clovyre = require("{mod}")
io_write(Clovyre.obfuscate(SRC, {{ seed = {seed}, protect = {protect}, fallbackOnUnsupported = false }}))
""".format(mod=mod, seed=seed, protect=protect)
    else:
        mod = "../dist/Clovexx" if os.environ.get("CLOVEXX_BUNDLE") else "../src/Obfuscator"
        body = """
local Obfuscator = require("{mod}")
io_write(Obfuscator.obfuscate(SRC, {{ seed = {seed} }}))
""".format(mod=mod, seed=seed)
    driver = "local SRC = " + lit + "\n"
    # luau CLI has no io; collect output into a table and print once at the end.
    driver += "local __out = {}\n"
    driver += "local function io_write(s) table.insert(__out, s) end\n"
    driver += body
    driver += "\nprint(table.concat(__out))\n"
    path = os.path.join(HERE, "_driver.luau")
    with open(path, "w") as f:
        f.write(driver)
    return path

def transform(mode, src_bytes, seed):
    drv = make_driver(mode, src_bytes, seed)
    rc, out, err = run_luau(drv)
    if rc != 0:
        return None, err.decode("utf-8", "replace")
    # print() adds a trailing newline byte; strip exactly one.
    if out.endswith(b"\n"):
        out = out[:-1]
    return out, None

def main():
    args = sys.argv[1:]
    mode = "roundtrip"
    if args and args[0] in ("roundtrip", "obfuscate", "clovyre"):
        mode = args.pop(0)
    samples = args or sorted(glob.glob(os.path.join(HERE, "samples", "*.luau")))

    npass = nfail = 0
    for s in samples:
        name = os.path.basename(s)
        rc0, out0, err0 = run_luau(s)
        if rc0 != 0:
            print(f"SKIP {name}: reference failed to run:\n{err0.decode('utf-8','replace')}")
            continue
        with open(s, "rb") as f:
            src_bytes = f.read()
        gen, err = transform(mode, src_bytes, seed=1337)
        if gen is None:
            print(f"FAIL {name}: transform error:\n{err}")
            nfail += 1
            continue
        # write generated source (bytes) and run it
        with tempfile.NamedTemporaryFile("wb", suffix=".luau", delete=False, dir=HERE) as tf:
            tf.write(gen)
            genpath = tf.name
        try:
            rc1, out1, err1 = run_luau(genpath)
        finally:
            os.unlink(genpath)
        if rc1 != 0:
            preview = gen[:2000].decode("utf-8", "replace")
            print(f"FAIL {name}: generated code failed to run:\n{err1.decode('utf-8','replace')}\n--- generated ---\n{preview}")
            nfail += 1
            continue
        if out0 == out1:
            print(f"PASS {name}  ({mode})")
            npass += 1
        else:
            print(f"FAIL {name}: output mismatch")
            print(f"  reference: {out0!r}")
            print(f"  got:       {out1!r}")
            nfail += 1
    print(f"\n{npass} passed, {nfail} failed")
    sys.exit(1 if nfail else 0)

if __name__ == "__main__":
    main()
