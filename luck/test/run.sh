#!/bin/sh
# Runs LUCK.lua against a stubbed Roblox API and checks the fast lane.
# Needs the standalone luau binary on PATH (github.com/luau-lang/luau releases).
set -e
here=$(dirname "$0")
cat "$here/prelude.luau" "$here/../LUCK.lua" "$here/epilogue.luau" > "$here/combined.luau"
luau "$here/combined.luau"
