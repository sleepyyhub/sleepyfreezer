# Luminosity — UI Path

Target: `[🐝] Sakumi Bee Game` (placeId `81639382631672`). Everything below was
read off the live client.

**UI path only, both ends.** No RemoteEvent connect, no RemoteFunction, no
`InvokeServer` anywhere in this build. Detection reads the game's own
notification labels; redeeming drives the game's own redeem handler.

## The thing that was actually costing codes

Not the network — `submitCode`, in `ReplicatedStorage.Controllers.CodesController`:

```lua
if v_u_18 or not p_u_16.Active then return end   -- returns on line 1
...
task.wait(0.5)                                    -- then re-opens the gate
p_u_16.Active = true ; v_u_18 = false
```

That is a **lockout, not a delay**. A code announced inside half a second plus a
round trip does not arrive late — it never fires at all. `submitCode` returns on
its first line and the announcement is gone. It is entirely local, and it was
the single biggest source of dropped codes.

So it gets cleared in place, before every fire. Verified on the live client:
`submitCode`'s upvalue 1 **is** that debounce boolean and it is writable
(`debug.setupvalue` → read back `false`), and upvalue 2 is the real TextBox.
Clearing it and restoring `Active` is still the button path — we drive the
game's own handler, we just refuse to let it lock itself out behind us.

## Three more wins on the same path

- **Calls `submitCode` directly**, off the `OnActivated` handler list, instead
  of the Confirm button's `Activated` connection. That connection is the
  `AnimatedButton` wrapper, which fires a sound and an Expand tween before the
  redeem ever runs. Skipping the wrapper skips both. Handle resolved once and
  cached; shape is validated before it is trusted (upvalue 1 boolean, upvalue 2
  our TextBox).
- **Pre-sanitises the code** to exactly what the game's TextBox handler would
  produce (`gsub` non-alphanumerics, `upper`, cap 50), so its
  `GetPropertyChangedSignal` finds `v29 == v26` and skips its own second write.
  Parity with the game's own routine checked across 8 cases including rich-text
  markup — identical output.
- **Four parked worker coroutines.** `submitCode` yields on the game's remote,
  so a single worker would serialise a burst behind that yield — which, together
  with the lockout, is how bursts were being lost.

Write and submit happen with nothing between them. `submitCode` reads
`box.Text` synchronously at its top, before it yields, so the capture is atomic
and two overlapping fires cannot cross codes.

## Detection

`__newindex` hook on the notification labels, so the string is caught during the
assignment rather than waiting for the deferred `GetPropertyChangedSignal` to
flush. Falls back to the signal where `hookmetamethod` is unavailable.

## Modes

All four detect on the label and redeem through `submitCode`; they differ only
in how much policy sits between the two. Luminosity (raw) removes the last of
it — no accumulator, no result-word filter. Dedup, fired-once, send.

Default is Luminosity on PC (`SpeedIndex = IS_PC and 4 or 1`).

## Verified / not verified

Verified live: `submitCode` resolves off the handler list; upvalue 1 is the
debounce and `debug.setupvalue` writes it; upvalue 2 is the real TextBox.
Verified locally: sanitiser parity, and the whole file compiles
(`luau-compile`).

**Not verified:** the assembled block running end to end in game. The client
dropped before that check could run. Load it and watch `detect->send` in the
status line, and whether a burst still loses codes.

## Build

Single file, no dependencies: `Luminosity_Instant.lua`. Needs `getconnections`
and `debug.getupvalue`/`setupvalue`; `hookmetamethod` is optional (detection
falls back to the property signal without it).
