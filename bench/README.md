# LUCK — real speed measurements

Two things live here.

- **`../LUCK_speedtest.lua`** — run this in your executor, in game, after LUCK is loaded.
  It measures the actual device: signal behaviour, frame times, ping, real server
  round trip, handler CPU, and (optionally) the entry→send floor on live announcements.
  That is the only number that is *your* client's speed.
- **`build.sh`** — an offline benchmark. It pulls the hot-path block out of `LUCK.txt`
  **verbatim** (lines 1435–1826, plus `PayloadText` and `CodeFrom`), stubs only the
  engine boundary, and runs it under the real Luau interpreter.

```sh
./build.sh /path/to/LUCK.txt
```

Nothing inside the measured path is rewritten. The stubs replace `InvokeServer`
with a counter, `task.defer` with a no-op, and `task.spawn`/`task.wait` with
no-ops so the housekeeping loops never fire mid-measurement — exactly the
substitutions the script's own `L.Bench` makes.

## Method

`N = 2.62M` calls per trial (40 passes over 65 536 distinct code strings),
`sent[]` cleared every 32 sends the way `L.Bench` does it, **min of 11 trials**.
Min, not mean — the fastest trial is the one least polluted by scheduler noise.
Every figure is then reported net of a harness floor (an empty function with the
same signature, called through the same loop), so the loop and call overhead is
subtracted out rather than smuggled into the result.

## Results

Intel Xeon @ 2.80 GHz, Luau `-O2`. `-O1` lands within 4%, so the hot path is not
optimisation-sensitive.

| path | min ns | cycles |
|---|---:|---:|
| empty fn (harness floor) | 26.03 | 73 |
| send call alone (reference) | 58.92 | 165 |
| `solo` entry → send | 56.54 | 158 |
| `solo` full handler | 143.48 | 402 |
| `guarded` entry → send | 127.70 | 358 |
| `guarded` full handler | 238.26 | 667 |
| `solo` with `Instrument` on (`soloSlow`) | 336.57 | 942 |
| non-raw, `codeFrom()` parses first | 9381.23 | 26 269 |

Net of the floor:

| | ns |
|---|---:|
| the send call itself | 32.89 |
| `solo`, work **before** the send — *delays the packet* | ~0 (below noise) |
| `solo`, work **after** the send — packet already gone | 86.95 |
| `guarded`, work **before** the send | 68.78 |
| `codeFrom()` on a full sentence | 9 237.74 |

**`solo` handler end to end: 117 ns = 0.000117 ms.**

## What the numbers say

1. In `solo` + raw mode the script adds **nothing measurable** before the send.
   The two branch tests (`position ~= "Top"`, `fastTime or not fastRaw`) sit inside
   measurement noise of a bare `InvokeServer` call. The ~87 ns of `sent[msg] = true`
   and `defer(tail, …)` all runs *after* the packet is handed to the network.
2. `guarded` costs **~69 ns before the send** — the `sent[code]` dedup lookup and
   store are on the latency path. That is the price of the duplicate guard.
3. `Instrument` / race mode roughly doubles the handler (143 → 337 ns) because
   `solo` delegates to `soloSlow` and takes two `os.clock()` samples. Fine for
   diagnosis, not something to leave on.
4. `RawFire = false` is the one real cliff: **~9.2 µs** to run `codeFrom()`
   (`gsub` for tags, `gmatch` word scan, the STOP-word scoring pass) on a full
   announcement, and all of it lands *before* the send. That is ~65× the entire
   raw handler — still only 0.009 ms, but it is the only dial in the script that
   moves the pre-send number at all.
5. The Normal / Medium / Fast / Lucky buttons **do not touch this path**.
   `L.Mode.raw` is only read at `L.Dispatch` (line 1393), the slow worker path.
   Once remote detect is live and `solo` is bound, all four modes run the same
   handler. `RawFire`, `Instrument` and `Solo`-vs-`guarded` are the switches that
   actually change the hot path.

## Caveats, stated plainly

- This is a 2.80 GHz x86 server core, not the device you play on. Cycle counts
  transfer, nanoseconds do not — scale by clock speed and IPC.
- It measures the script's CPU cost, not the network. `InvokeServer` is a counter
  here; in game it yields on the wire.
- Roblox compiles at a comparable optimisation level, but an executor's own
  compiler and the client's Luau build are not bit-identical to upstream Luau.

Which is the point of `LUCK_speedtest.lua`: none of the above is your client.
Run that one in game.
