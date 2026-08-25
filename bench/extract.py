#!/usr/bin/env python3
"""Pull the hot-path fragments out of a LUCK source, by content not line number.

Line numbers shift the moment the script is edited, and a benchmark that
silently extracts the wrong region is worse than no benchmark. Everything here
is located by an anchor that only appears once, and it fails loudly otherwise.

  extract.py SOURCE OUTDIR
"""
import re
import sys


def find_unique(lines, pattern, what):
    rx = re.compile(pattern)
    hits = [i for i, l in enumerate(lines) if rx.match(l)]
    if len(hits) != 1:
        sys.exit(f"extract: expected exactly one {what}, found {len(hits)}")
    return hits[0]


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, outdir = sys.argv[1], sys.argv[2]
    lines = open(src, encoding="utf-8").read().splitlines()

    # PayloadText: from `local TEXT_KEYS = {` through `L.PayloadText = ...`
    a = find_unique(lines, r"^local TEXT_KEYS = \{", "TEXT_KEYS table")
    b = find_unique(lines, r"^L\.PayloadText = ", "L.PayloadText assignment")
    payload = lines[a:b]

    # CodeFrom: `L.IsNotifyMetadata = function` through the line before
    # `local codeFrom, payloadText, selectArg`
    c = find_unique(lines, r"^L\.IsNotifyMetadata = function", "IsNotifyMetadata")
    d = find_unique(lines, r"^local codeFrom, payloadText, selectArg",
                    "codeFrom/payloadText locals")
    codefrom = lines[c:d]

    # The hot block: the bare `do` immediately above `local dispatch = L.Dispatch`,
    # through the `end` that closes it. Found by brace-free depth counting on the
    # block's own `do`/`end` keywords would be fragile, so anchor on the block's
    # last statement instead -- it is distinctive and appears once.
    e = find_unique(lines, r"^    local dispatch = L\.Dispatch$", "hot block head")
    if lines[e - 1].strip() != "do":
        sys.exit("extract: line above `local dispatch` is not a bare `do`")
    start = e - 1
    f = find_unique(lines, r"^    if L\.RemoteDetectOn then L\.BindFast\(\) end$",
                    "hot block tail")
    if lines[f + 1].strip() != "end":
        sys.exit("extract: line after BindFast is not the block's `end`")
    hot = lines[start:f + 2]

    for name, body in (("_payloadtext", payload), ("_codefrom", codefrom),
                       ("_hotpath", hot)):
        with open(f"{outdir}/{name}.luau", "w", encoding="utf-8") as fh:
            fh.write("\n".join(body) + "\n")

    sys.stderr.write(
        f"extract: payload {len(payload)} lines, codeFrom {len(codefrom)} lines, "
        f"hot block {len(hot)} lines (source lines {start + 1}-{f + 2})\n")


if __name__ == "__main__":
    main()
