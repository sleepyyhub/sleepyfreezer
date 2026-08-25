#!/usr/bin/env bash
# Run a Roblox client script inside the simulated client and speed-test it.
#
#   ./run.sh /path/to/LUCK.txt [scenario]
#
# The Luau CLI ships without an io library, so the target script is
# materialised as a generated module (_source.luau) that returns it verbatim
# inside a long-bracket string. Nothing in the script is altered.
set -euo pipefail

SRC="${1:?usage: run.sh /path/to/script.txt [scenario]}"
SCENARIO="${2:-sweep}"
DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -x "$DIR/luau" ]; then
  echo "fetching luau ..." >&2
  curl -sSL -o "$DIR/luau.zip" \
    https://github.com/luau-lang/luau/releases/latest/download/luau-ubuntu.zip
  unzip -oq "$DIR/luau.zip" -d "$DIR"
  chmod +x "$DIR"/luau*
fi

# pick a long-bracket level the source cannot possibly close
LEVEL=""
for n in "" = == === ==== =====; do
  if ! grep -qF "]$n]" "$SRC"; then LEVEL="$n"; break; fi
done
if [ -z "$LEVEL" ] && grep -qF "]]" "$SRC"; then
  echo "could not find a safe long-bracket level for $SRC" >&2
  exit 1
fi

{
  printf 'return {\n'
  printf '\tpath = [%s[%s]%s],\n' "$LEVEL" "$SRC" "$LEVEL"
  printf '\tscenario = [%s[%s]%s],\n' "$LEVEL" "$SCENARIO" "$LEVEL"
  printf '\tsource = [%s[\n' "$LEVEL"
  cat "$SRC"
  printf ']%s],\n}\n' "$LEVEL"
} > "$DIR/_source.luau"

# the diagnostic gets materialised the same way, for scenario "diag"
DIAG="$DIR/../LUCK_racediag.lua"
if [ -f "$DIAG" ]; then
  DLEVEL=""
  for n in "" = == === ==== =====; do
    if ! grep -qF "]$n]" "$DIAG"; then DLEVEL="$n"; break; fi
  done
  {
    printf 'return {\n\tsource = [%s[\n' "$DLEVEL"
    cat "$DIAG"
    printf ']%s],\n}\n' "$DLEVEL"
  } > "$DIR/_diag.luau"
fi

cd "$DIR"
case "$SCENARIO" in
  race) exec ./luau race.luau ;;
  diag) exec ./luau diagtest.luau ;;
  yourcase) exec ./luau yourcase.luau ;;
  notify) exec ./luau notifytest.luau ;;
esac
exec ./luau run.luau
