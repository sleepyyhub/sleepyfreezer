# A simulated Roblox client, so the script can actually be run

No live client was reachable, so this is one built here. It loads `LUCK.txt`
unmodified — `loadstring` + `setfenv` against a synthetic global table — boots it,
lets it resolve its own remotes, and then drops codes at it and measures when the
server got the redeem.

```sh
./run.sh /path/to/LUCK.txt          # full sweep
```

It fetches the Luau binary on first run. Takes about 30 seconds.

## What it actually is

| file | what it does |
|---|---|
| `roblox.luau` | Instances, signals, datatypes, Enum, and a real cooperative scheduler |
| `place.luau` | the fake place: remotes, `Net` package, `NotificationController`, the Codes UI, and a server that validates codes and timestamps every packet |
| `sandbox.luau` | the global table the script runs under, including the executor surface |
| `run.luau` | boots the script, drops codes, measures |
| `run.sh` | materialises the target script as a module (the Luau CLI has no `io`) and runs it |

The script is not patched, wrapped, or special-cased. It arms through its own
`netFallback` path (`redeem=net notify=net`), tests its own remote, binds its own
`solo` handler, and reports `fastReady=true` — the same state as a live client
whose executor lacks `debug.getupvalue`.

## The clock, which is the part that matters

`os.clock()` inside the sandbox returns **real CPU burned + simulated delay**.

Real work the script does counts against the frame budget exactly as it would on
a device; only the wire delay and the frame cadence are synthetic. So when a run
says LUCK cost 0.000329 ms, that is measured Luau execution, not a constant
someone typed in. When it says the wire cost 20 ms, that is a parameter.

Replication is frame-aligned in both directions with a configurable one-way
delay. Announcements are placed at an **exact, evenly swept offset inside the
client's frame** — 40 samples across one whole frame — so every configuration
sees the identical set of arrival phases. Random phase was tried first and
thrown out: the real CPU each pass burns shifts the grid, and a few ms of luck
showed up as a difference between configs that were in fact identical.

## Results

40 ms ping, 60 fps, Immediate signals, unless stated. All figures are
**announce → the server holds your redeem**, in ms.

### The floor test

Same place, same wire, same frame grid, same phases — but the notify signal is
served by four lines that read the message and invoke the redeem remote, nothing
else. LUCK is switched off for that pass so the two never race.

| | min | p10 | med | p90 | max |
|---|---:|---:|---:|---:|---:|
| LUCK (solo, raw) | 40.02 | 41.25 | 47.92 | 54.59 | 56.27 |
| bare forwarding handler | 40.02 | 41.26 | 48.01 | 54.60 | 56.26 |

**Gap: +0.004 ms at the minimum, −0.088 ms at the median.** LUCK is sitting on
the floor. There is no version of this script that is meaningfully faster,
because there is nothing left to remove.

### Ping

| | min | med | max |
|---|---:|---:|---:|
| 10 ms | 10.42 | 18.35 | 26.67 |
| 25 ms | 25.01 | 32.93 | 41.26 |
| 40 ms | 40.43 | 48.34 | 56.68 |
| 80 ms | 80.43 | 88.34 | 96.68 |
| 150 ms | 150.01 | 157.94 | 166.26 |

Minimum tracks ping exactly; maximum is ping + one frame. Ping is the floor and
nothing on the client moves it.

### Frame rate — the one dial that does anything

| | min | med | max |
|---|---:|---:|---:|
| 30 fps | 40.01 | 55.84 | 72.51 |
| 60 fps | 40.01 | 47.94 | 56.26 |
| 120 fps | 40.01 | 44.00 | 48.16 |
| 240 fps | 40.01 | 41.99 | 44.07 |

**13.85 ms** between 30 and 240 fps at fixed ping. That is roughly 42 000 times
the script's entire CPU cost, and it is the only lever with a number worth
reading.

### Every switch inside the script

| | min | med | max |
|---|---:|---:|---:|
| RawFire on (default) | 40.01 | 47.92 | 56.26 |
| RawFire off (parses the text) | 40.02 | 47.92 | 56.26 |
| Instrument on | 40.01 | 47.93 | 56.26 |
| guarded handler | 40.11 | 47.93 | 56.31 |
| Auto off | *no redeem reached the server* |

Identical to 0.01 ms. The 9.2 µs that `codeFrom()` costs with `RawFire` off —
a 65× difference in the microbenchmark — does not survive contact with a frame.
`Auto off` producing nothing is the control: the pipeline is real, not scripted.

### Where the time goes

| | ms | share |
|---|---:|---:|
| announcement over the wire | 20.000 | 41.7% |
| waiting for the client frame | 7.922 | 16.5% |
| **LUCK's own code** | **0.000329** | **0.0007%** |
| redeem over the wire | 20.000 | 41.7% |
| total | 47.923 | |

## Can it be made faster? The levers, measured

The stage breakdown at 40 ms ping / 60 fps says where the time is:

| stage | ms | share |
|---|---:|---:|
| 1. announcement over the wire (incl. waiting for the client's replication step) | 28.124 | 58.4% |
| 2. LUCK's handler | 0.005 | 0.01% |
| 3. waiting for the outgoing flush | 0.004 | 0.01% |
| 4. redeem over the wire | 20.000 | 41.6% |

Stage 3 is the surprise: **the outgoing side is already free.** The handler runs
during the client's replication step, and the outgoing flush is later in the same
frame, so the packet never waits. The entire frame tax is inbound — waiting for
the client to pick the announcement up.

### Lever 1 — frame rate. The only one that moves anything.

| fps | inbound wait | script | flush wait | total |
|---|---:|---:|---:|---:|
| 30 | 16.250 | 0.0035 | 0.0029 | 55.84 |
| 60 | 8.125 | 0.0044 | 0.0037 | 47.92 |
| 120 | 4.062 | 0.0047 | 0.0031 | 43.97 |
| 240 | 2.032 | 0.0040 | 0.0030 | 41.98 |
| 480 | 1.016 | 0.0042 | 0.0031 | 41.00 |

The inbound wait is exactly half a frame and halves every time the frame rate
doubles. **14.85 ms between 30 and 480 fps**, at fixed ping.

### Lever 2 — connection order

| | min | med | max |
|---|---:|---:|---:|
| LUCK alone on the signal | 40.01 | 47.92 | 56.25 |
| a heavy listener ahead of it | 40.61 | 48.55 | 56.84 |

A listener registered ahead of yours costs you exactly its own CPU time, 0.6 ms
here, and nothing more. It does not make you miss the flush.

### Lever 3 — firing more than once

| | min | med | max |
|---|---:|---:|---:|
| one fire | 40.00 | 47.93 | 56.25 |
| five fires | 40.01 | 47.92 | 56.27 |

Identical. Every copy rides the same replication step, so the first one lands at
the same instant. Spamming buys nothing and costs bandwidth.

### What that leaves

Ping is 40 of the 48 ms and no client-side code touches it. Frame rate is worth
up to ~7 ms from 60 fps. The script's own code is 0.005 ms and is already at the
floor. There is no fourth lever hiding in the source.

## What this does not model, stated plainly

- **Rendering, physics, input.** Absent. On a real client they are what makes
  frames long, and frame length is the thing that matters most here — so a real
  device under load will look worse than this, never better.
- **Engine-side property writes.** Here they are Lua table stores; on a client
  they cross into C++. This affects the script's boot and UI cost, not the hot path.
- **Deferred vs Immediate signals came out identical** (47.97 vs 47.94), and that
  is a limitation, not a finding. In this frame model the receive step and the
  deferred flush both land before the same outgoing network flush, so switching
  costs nothing. On a real client a busy frame can push a deferred callback past
  that flush and cost a full frame. Treat the script's `SetImmediateSignals(true)`
  as worth something this harness cannot see.
- **Server behaviour** is a table lookup plus a fixed think time. Real games
  queue, rate-limit, and validate.
- **One client, no rivals.** Whether you beat another sniper depends on their
  ping and frame rate against yours, and this measures only your side.
