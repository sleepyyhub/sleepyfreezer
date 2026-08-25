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

---

# The remote's result as a notification

The redeem RemoteFunction answers with two values. The second one is the
message ("Meowl spawned!"); the first is the verdict.

`L.ResultNotify(code, ok, reply)` puts that second value on screen and colours
it by the first:

| first return | colour |
|---|---|
| `true` | green — `T.GREEN` rgb(146,255,103) |
| `false` | red — `T.RED` rgb(255,130,155) |
| `nil` / no answer | amber — `T.ORANGE` |

The message reads first and the code follows it as a footnote, in both LUCK's
own feed and the game's notification popup:

```
» Meowl spawned!   ·   MEOWLCODE
» Invalid code   ·   NOTACODE
```

Three details that were not free:

- **A fire-and-forget remote has no reply.** It learns its result from a
  follow-up announcement, which `claimOurs` already shows. `L.ResultShown`
  marks that code so `PostRedeem` does not print the same line twice.
- **`"sent"` is a placeholder, not an answer.** It is suppressed.
- **A non-string reply** is run through `L.PayloadText` first, so a table
  payload still yields its message.

Turn it off with `LUCK.ResultNotifyOn = false`.

## Verified

`./run.sh LUCK_fast.txt notify` — the server is made to answer with real prize
strings and both `L.Notify` and `L.Toast` are wrapped to capture what actually
reaches the screen. 11 checks, all passing, including the colour mapping in
both directions.

The first version of that test failed the two colour checks while printing the
correct colours: it guarded with `typeof(a) ~= "Color3"`, but `typeof` inside
the test file is the host's, not the sandbox's, so it reports `"table"` and
rejected colours that were right. The test compared components after that.

The notification runs inside `PostRedeem`, which is downstream of the send, so
it costs the hot path nothing: the A/B still reads 127.32 ns original against
115.99 ns patched, faster in 21 of 21 rounds.

---

# Correction: pole position, and the 11x I had missed

The 200 ns / 3000 ns figure was real, and I had been measuring the wrong axis.
It is not one build against the other — it is **pole held against pole not
held**, and both builds have the mechanism.

Connecting to `OnClientEvent` puts you at the BACK of the handler list. Until
pole is taken, every redeem goes out behind the game's own notification
handler, which builds its popup and starts a sound before it yields.

Measured here, detect → send, with the game's handler given real work to do:

| | min | med | p90 |
|---|---:|---:|---:|
| pole held | 1977 ns | **2735 ns** | 4232 ns |
| pole dropped | 17376 ns | **20158 ns** | 31467 ns |

**7.4x.** The largest single number left in this script, and far larger than
the 11 ns the handler rewrite bought.

## The bug this exposed in my build

`TakePole()` was only ever called from inside `L.Boost`, and only under:

```lua
if L.SignalMode == "Immediate" then
```

On an executor that refuses to write `workspace.SignalBehavior` — common — that
test never passes, `TakePole` never runs, and the 7.4x penalty is permanent and
silent. The gate was wrong on its own terms too: connection order decides who
runs first in deferred dispatch as well, so "not needed while signals are
deferred" was simply false.

Proven by forcing the executor to refuse Immediate:

| | pole held | taken at |
|---|---|---|
| before | `false` | **never** |
| after | `true` | 0.173 s |

## The fix

Pole is now taken in `ConnectNotifyRemote`, the moment the listener is live,
guarded by `L.AutoPole ~= false`, plus one re-sweep at +3 s for handlers that
attach later.

`L.RetakePole` was added to make that re-sweep work: `TakePole` returns early
when `PoleOn` is already true, so on its own it cannot capture a handler that
connected after position was taken — which is exactly what happens when the
game reconnects its notification handler. `RetakePole` drops and retakes.

Verified after the change: notification suite 11/11, functional sweep intact
across every mode, `Auto off` still the control, no thread errors. The handler
now binds as `pole`, whose ordering is `poleInner(...)` first and the game's
handlers after — we send, their popup follows.

## Why this still does not change the duel

Against the uploaded build the score is unchanged at **0 - 0, 20 tied**, medians
22.095 vs 22.097 ms. Both hold pole, so neither is paying the 7.4x. And 20 µs
is still well inside one frame at 240 fps (4.17 ms), so even the full penalty
would land as a tie in a race — consistent with the quantisation sweep, where a
one-millisecond head start still tied 37 of 40.

Pole is worth taking because it is free and it is the difference between 2.7 µs
and 20 µs of your own latency. It is not worth expecting a different scoreboard
from.
