#!/usr/bin/env python3
"""Load-test the Luminosity scripts off-platform.

Runs each file top to bottom against tools/stub_roblox.lua. Signals never
fire and remotes are absent, so this proves one thing only — and it is the
thing that splicing chrome between files can break: every identifier
resolves and nothing indexes a nil on the way up.

Luau's compound assignment is rewritten to plain Lua first, since the host
runtime is stock Lua.
"""

import pathlib
import re
import sys

import lupa

HERE = pathlib.Path(__file__).parent
ROOT = HERE.parent
FILES = ["luminosity.lua", "luminosity_modded.lua", "luminosity_modded_sniper.lua"]

PLACES = {
    "luminosity.lua": 109983668079237,      # main game
    "luminosity_modded.lua": 70665834402027,
    "luminosity_modded_sniper.lua": 70665834402027,
}


def to_plain_lua(src: str) -> str:
    src = re.sub(r"([\w\.\[\]]+)\s*\+=\s*([^;\n]+)", r"\1 = \1 + (\2)", src)
    src = src.replace("table.create(", "__table_create(")
    src = src.replace("table.clear(", "__table_clear(")
    return src


PRELUDE = """
__table_create = function(n) return {} end
__table_clear  = function(t) for k in pairs(t) do t[k] = nil end return t end
"""

failures = 0
for name in FILES:
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(PRELUDE)
    lua.execute((HERE / "stub_roblox.lua").read_text())
    lua.execute(f"game.PlaceId = {PLACES[name]}")

    src = to_plain_lua((ROOT / name).read_text())
    chunk = lua.eval("load")(src, name)
    if isinstance(chunk, tuple):
        print(f"FAIL  {name}: syntax: {chunk[1]}")
        failures += 1
        continue

    ok, err = lua.eval("function(f) return pcall(f) end")(chunk)
    if ok:
        print(f"ok    {name}")
    else:
        msg = str(err)
        if "__stub_wait_cap" in msg:
            print(f"ok    {name}  (boot loop reached the harness wait cap)")
        else:
            print(f"FAIL  {name}: {msg}")
            failures += 1

sys.exit(1 if failures else 0)
