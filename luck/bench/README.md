# Redeem hot-path bench

Measures the work between the notify handler being entered and the redeem
call going out — the only part of the announce-to-redeem delay the script
controls.

```sh
luau luck/bench/bench.luau     # rank every variant
luau luck/bench/duel.luau      # two variants head to head
luau luck/test/run.sh          # 37 behaviour checks against a stubbed Roblox
```

Needs the standalone `luau` binary on PATH (luau-lang/luau releases).

## Reading the numbers

**Rank once, then duel.** The ranking takes the best of seven rounds per
variant, which flatters whichever variant happened to run on a quiet core.
Two variants that looked 10% apart in the ranking turned out to be inside
the noise when duelled — `minimal` "won" by 9.7% and then lost the duel,
and `swapgate_cold` "won" by 5.0% and then took 7 of 21 rounds. Only a
duel that wins nearly every round is a real difference.

`duel.luau` alternates the two variants round by round so CPU drift cannot
land on one of them, and reports medians rather than a best round.

## Reference points

`floorcall` does nothing but the send. It is not a candidate — it is the
irreducible cost of the benchmark itself, two closure calls. Anything close
to it has essentially no logic left to remove.

## Working set

The dedup set is cleared every 32 calls. An earlier version let it grow to
60,000 entries, and the resulting hash rehashing was larger than every
difference being measured. A real session holds a handful of codes, so the
table is kept session-sized.

## Result

| variant | ns/call | vs current |
|---|---|---|
| floorcall (reference) | 61.6 | -54% |
| **solo** | **73.7** | **-45%** |
| swapgate | 129.0 | -4.5% |
| minimal | 130.7 | -3.3% |
| current | 135.2 | — |
| rawdedup | 138.1 | +2.2% |
| lastslot | 143.7 | +6.3% |

Everything from `swapgate` down is inside the noise floor: reordering
branches around the send buys nothing measurable.

`solo` is the only variant that beats it, by dropping the dedup lookup
entirely — 21 of 21 duel rounds, -44% median. It is sound only while one
surface is armed, where the same announcement cannot arrive twice, so
`L.ApplyBinding` binds it then and swaps the deduping handler back in the
moment the race is armed or a second surface is promoted.
