#!/usr/bin/env bash
# Race two builds over the same code drops and score it round by round.
#
#   ./duel.sh A.txt B.txt ["Name A"] ["Name B"]
#
# Each build runs the identical round schedule -- same frame phases, same ping,
# same fps -- and reports when its redeem reached the server. The round goes to
# whichever packet landed first. Nothing is shared between the two runs except
# the schedule, so neither can interfere with the other.
set -euo pipefail

A="${1:?usage: duel.sh A.txt B.txt [nameA] [nameB]}"
B="${2:?usage: duel.sh A.txt B.txt [nameA] [nameB]}"
NA="${3:-Fast}"
NB="${4:-Current}"
DIR="$(cd "$(dirname "$0")" && pwd)"

"$DIR/run.sh" "$A" "${MODE:-duelrun}" > /tmp/duel_a.txt 2>&1
"$DIR/run.sh" "$B" "${MODE:-duelrun}" > /tmp/duel_b.txt 2>&1

python3 - "$NA" "$NB" <<'PY'
import re, sys

na, nb = sys.argv[1], sys.argv[2]

def load(path):
    rounds, meta = {}, ""
    for line in open(path):
        line = line.strip()
        if line.startswith("META"):
            meta += line[5:] + " "
        m = re.match(r"^ROUND (\d+) (.+)$", line)
        if m:
            n = int(m.group(1))
            v = m.group(2)
            rounds[n] = None if v == "MISS" else float(v)
    return rounds, meta.strip()

ra, ma = load("/tmp/duel_a.txt")
rb, mb = load("/tmp/duel_b.txt")

if not ra or not rb:
    print("one of the builds produced no rounds:")
    print(f"  {na}: {len(ra)} rounds   {nb}: {len(rb)} rounds")
    sys.exit(1)

print()
print(f"  {na:<24} {ma}")
print(f"  {nb:<24} {mb}")
print()

# A tie is a tie. Below this the two packets land in the same server tick and
# the order is decided by the NIC, not by either script.
TIE = 0.05
sa = sb = ties = 0

for n in sorted(set(ra) | set(rb)):
    a, b = ra.get(n), rb.get(n)
    print(f"Round {n}")
    print()
    print(f"{na} / {nb}")
    print()

    if a is None and b is None:
        note = "neither reached the server"
    elif a is None:
        sb += 1; note = f"{na} never sent"
    elif b is None:
        sa += 1; note = f"{nb} never sent"
    else:
        d = a - b
        if abs(d) < TIE:
            ties += 1
            note = f"tie  ({a:.3f} vs {b:.3f} ms, {abs(d)*1000:.0f} ns apart)"
        elif d < 0:
            sa += 1
            note = f"{na} by {abs(d):.3f} ms  ({a:.3f} vs {b:.3f} ms)"
        else:
            sb += 1
            note = f"{nb} by {abs(d):.3f} ms  ({a:.3f} vs {b:.3f} ms)"

    print(f"{sa} - {sb}")
    print(f"    {note}")
    print()

print("=" * 46)
print(f"FINAL   {na} {sa} - {sb} {nb}    ({ties} tied)")
print("=" * 46)

vals_a = [v for v in ra.values() if v is not None]
vals_b = [v for v in rb.values() if v is not None]
if vals_a and vals_b:
    ma_ = sorted(vals_a)[len(vals_a)//2]
    mb_ = sorted(vals_b)[len(vals_b)//2]
    print(f"  median {na}: {ma_:.3f} ms")
    print(f"  median {nb}: {mb_:.3f} ms")
    print(f"  difference: {ma_-mb_:+.3f} ms")
print()
PY
