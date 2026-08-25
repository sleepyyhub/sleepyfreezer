#!/usr/bin/env bash
# Rebuild and run the offline LUCK hot-path benchmark.
#
#   ./build.sh /path/to/LUCK.txt
#
# Pulls the hot-path block (and PayloadText / CodeFrom) VERBATIM out of the
# script, bolts on the stubs in prelude.luau + glue.luau, and runs it under
# the real Luau interpreter. Nothing in the measured path is rewritten.
set -euo pipefail
SRC="${1:?usage: build.sh /path/to/LUCK.txt}"
DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -x "$DIR/luau" ]; then
  curl -sSL -o "$DIR/luau.zip" \
    https://github.com/luau-lang/luau/releases/latest/download/luau-ubuntu.zip
  unzip -oq "$DIR/luau.zip" -d "$DIR"
  chmod +x "$DIR"/luau*
fi

# located by content, not line number -- the moment the script is edited the
# numbers move, and silently benchmarking the wrong region is worse than not
# benchmarking at all. extract.py fails loudly instead.
python3 "$DIR/extract.py" "$SRC" "$DIR"

cat "$DIR/prelude.luau" "$DIR/_payloadtext.luau" "$DIR/_codefrom.luau" \
    "$DIR/glue.luau" "$DIR/_hotpath.luau" "$DIR/driver.luau" > "$DIR/bench.luau"

exec "$DIR/luau" -O2 "$DIR/bench.luau"
