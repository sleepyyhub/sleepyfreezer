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

## What the ns/call number is made of

Three references decompose it, so no part of the total is charged to the
handler by accident:

| reference | what it adds | measured |
|---|---|---|
| `noop` | the timing loop and an empty handler call | 22.0 |
| `floorcall_c` | + the send as a C builtin (FASTCALL) | 27.3 |
| `floorcall` | + the send as a Lua closure | 47.6 |
| `solo_bare` | + the script's own logic | 49.9 |

The send in the live client is `InvokeServer`, a generic C function. That is
cheaper than the Lua closure `floorcall` uses and dearer than the FASTCALL
`floorcall_c` gets, so the send call costs between **5.3 and 25.6 ns** and
the handler's total, net of the benchmark's own loop, is **7.7 to 28 ns**.
The script's share of that is 2.4 ns and does not move.

Two scaffolding costs used to sit inside that number and were removed: the
fake send incremented a table field (`ctx.n += 1`, a GETTABLEKS + ADD +
SETTABLEKS on every call), and the timed loop ran an integer modulo per
iteration to decide when to clear the dedup set. Both were charged to every
variant. The counter is now an upvalue and the loop is chunked.

## The logic column

Total ns/call is dominated by two calls that are not the script's to remove:
the signal dispatch that enters the handler, and the send itself. `floorcall`
is exactly that pair and nothing else, so subtracting it leaves the work the
script controls -- the same quantity `L.FloorUs` reports on a live client.
Judge variants on that column, not the total.

## Result

| variant | ns/call | side toast | logic |
|---|---|---|---|
| floorcall (reference) | 50.0 | — | 0.0 |
| **solo_bare** | **53.1** | **24.6** | **3.1** |
| solo | 57.9 | 38.3 | 7.9 |
| solo_inline | 59.4 | 25.1 | 9.3 |
| solo_typelast | 60.5 | 24.8 | 10.5 |
| swapgate_cold | ~104 | 17.1 | ~54 |
| current (three rounds ago) | ~112 | 17.3 | ~62 |

`solo_bare` won its duel against `solo_inline` 21 of 21 rounds at -7.6%.
It drops the type check as well: a table payload goes out as-is, the server
rejects it, and the tail extracts the real code and resends -- the same
contract the string path already runs under. The tail hands `rawFire` the
value that was actually sent rather than the unwrapped one, or the resend
compares equal to itself and never fires.

Everything from `swapgate` down is inside the noise floor: reordering
branches around the send buys nothing measurable.

`solo` is the only variant that beats it, by dropping the dedup lookup
entirely — 21 of 21 duel rounds, -44% median. It is sound only while one
surface is armed, where the same announcement cannot arrive twice, so
`L.ApplyBinding` binds it then and swaps the deduping handler back in the
moment the race is armed or a second surface is promoted.
