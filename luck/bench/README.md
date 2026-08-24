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

## Side toasts

The Top-only loop is half the workload. Side toasts -- joins, purchases,
quest popups -- are the majority of what the notify remote carries, and
every one is work the handler does for nothing, so `bench.luau` times that
rejection separately.

That column caught a modelling bug worth more than the numbers it printed.
`V.solo` used to just `return` on a non-Top message while the shipped
handler called a side function that checks for a pending verdict. Measured
against that fiction, `solo_inline` looked like an 8ns regression. Once the
variant modelled what actually ships, `solo_inline` came out 35% cheaper on
side toasts at identical code latency, and it is what the script now binds.

## Result

| variant | ns/call | vs current | side toast |
|---|---|---|---|
| floorcall (reference) | 49.5 | -56% | — |
| **solo_inline** | **57.4** | **-49%** | **24.7** |
| solo | 57.3 | -49% | 37.8 |
| solo_typelast | 59.9 | -47% | 24.9 |
| swapgate_cold | 102.8 | -6.9% | 17.0 |
| minimal | 105.1 | -4.8% | 17.5 |
| current | 113.0 | — | 17.1 |
| rawdedup | 111.1 | +0.6% | 17.0 |
| lastslot | 115.6 | +4.7% | 17.1 |

Everything from `swapgate` down is inside the noise floor: reordering
branches around the send buys nothing measurable.

`solo` is the only variant that beats it, by dropping the dedup lookup
entirely — 21 of 21 duel rounds, -44% median. It is sound only while one
surface is armed, where the same announcement cannot arrive twice, so
`L.ApplyBinding` binds it then and swaps the deduping handler back in the
moment the race is armed or a second surface is promoted.
