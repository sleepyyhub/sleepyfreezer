# What was changed, and what it bought

`LUCK_fast.txt` is `LUCK.txt` with two edits to the hot handler. Your original
is untouched. Everything below is measured, paired and interleaved, on real
Luau at `-O2`.

## The two edits

**1. The flag test is answered at bind time, not per packet.**

`solo` tested `if fastTime or not fastRaw` on every single announcement. Those
flags only change inside `SyncFast`, which calls `ApplyBinding` immediately
afterwards — so the answer is already known when the handler is bound. A new
`soloRaw` handler drops the test entirely, and `ApplyBinding` selects it when
`fastRaw and not fastTime`.

**2. The `Top` branch comes first.**

`if position ~= "Top" then … end` makes the hot path take a jump. Inverting it
to `if position == "Top" then … end` lets the hot path fall through.
Semantically identical.

## What it bought

Paired ABBA interleaving, 21 rounds, 1.05M calls per measurement, both handlers
extracted verbatim from their own source file:

| | median | p10 | p90 |
|---|---:|---:|---:|
| original `solo` | 127.41 ns | 126.38 | 128.73 |
| patched `soloRaw` | 115.96 ns | 114.37 | 118.60 |
| **difference** | **11.22 ns** | 9.59 | 12.97 |

Faster in **21 of 21 rounds**. 8.8% of the whole handler — and because all of
it sits before the send, **~17% of everything that actually delays the packet**
(the pre-send path went from ~67 ns to ~56 ns).

`soloRaw`'s entry→send is now **1.6–3.3 ns above a bare `InvokeServer` call**.
There is nothing left to remove.

## What was tried and rejected, because it was measured

| idea | result |
|---|---|
| pre-bound `fire = function(msg) return inv(rem, msg) end` | **+17.56 ns — much worse.** The extra call frame costs more than the two `GETUPVAL`s it saves |
| compare `position` against a hoisted local instead of a constant | +0.24 ns, no better |
| drop the `position` check entirely (unsafe) | only −3.17 ns, and the inverted branch already recovers 2 of those |
| move `guarded`'s dedup after the send | rejected: on a RemoteFunction the code after `InvokeServer` runs post-yield, so the dedup would stop working entirely |

## A correction to my own earlier numbers

An earlier version of `bench/driver.luau` declared the flags as
`local fastTime, fastRaw = false, true`. The compiler constant-folded the test
away, and the driver reported *"solo, work before the send: −3.02 ns"* — that
is, nothing. That was wrong. With the flags assigned through a function so they
cannot fold, the same measurement reads **+9.14 ns**, and the flag test alone is
**10.70 ns**. `bench/extract.py` also replaced the fixed line numbers in
`build.sh`, which would have silently extracted the wrong region from an edited
script.

## What this does NOT do

It does not change whether you win a race. From `env/results_race.txt`: a head
start of one microsecond ties 40 of 40, and a head start of a **full
millisecond** still ties 37 of 40. The outgoing replication step is a
rendezvous — everything queued before it leaves at the same instant — so the
observed gap is only ever 0 ms, 16.67 ms, or 33.34 ms. Never anything between.

11 nanoseconds is 0.00007% of one frame at 60 fps. It is real, it is measured,
and it will not move a single race.

The thing that does move races is the frame rate, because it changes the size
of the step: 16.67 ms at 60 fps, 4.17 ms at 240.
