# Luminosity — Instant Path

Target: `[🐝] Sakumi Bee Game` (placeId `81639382631672`). Everything below was
read off the live client, not guessed.

## What was slow

The `NoRemote` build detected a code by watching the notification **label**, and
redeemed it by driving the game's **Confirm button**. Both are the slowest
surface the client offers.

Detection, from `ReplicatedStorage.Controllers.NotificationController`:

```
RemoteEvent "NotificationService/Notify" arrives
  -> OnClientEvent                     (deferred: queued, flushed next resumption)
  -> NotificationController:Notify
  -> task.spawn                        (thread allocation)
  -> Template:Clone()                  (Instance clone)
  -> CustomRichTextController.apply
       -> transformRichText: 7 gsub passes over the message
  -> label.Text = <transformed>        <- the old detector woke up HERE
```

Redeeming, from `ReplicatedStorage.Controllers.CodesController.submitCode`:

```lua
if v_u_18 or not p_u_16.Active then return end   -- debounce + Active gate
...
p_u_16.Text = ""; p_u_16.Active = false; p_u_16:ReleaseFocus()
pcall(function() return Net:RemoteFunction("RequestRedemption"):InvokeServer(code) end)
...
task.wait(0.5)                                    -- lockout, not a delay
p_u_16.Active = true; v_u_18 = false
```

That trailing `task.wait(0.5)` is the real killer: a second code announced
inside half a second plus a round trip is **silently dropped**, because `Active`
is false and `submitCode` returns immediately. Writing `box.Text` also triggers
the game's own Text sanitiser signal (`gsub` + `upper` + `sub`, and a possible
second write) on top.

## What it does now

Both ends moved to the wire.

**Detect** — connect straight to `Net:RemoteEvent("NotificationService/Notify")`.
Arg 1 is the message. No clone, no gsub, no label, no render: it is the earliest
moment the string exists on this client.

**Redeem** — call `Net:RemoteFunction("RequestRedemption"):InvokeServer(code)`,
the exact call `submitCode` makes, with the debounce, the UI writes and the 0.5s
lockout removed. Both handles resolve once through the game's own `Net` package
**by name**, and `InvokeServer` is cached as a bare function, so firing is one
call with no property crossing in front of it.

Verified live: `InvokeServer("ZZQXINVALIDTEST")` returned `false, "Invalid Code"`
with no Codes UI open and no TextBox involved — the button path is not needed at
all. Round trip was 444 ms, which is the server; the client-side portion is now
a dedup read, a fired-once read, and the call.

Four parked worker coroutines handle packets, so a code announced while an
earlier redeem is still mid-round-trip takes the next free thread instead of
queueing behind it. That alone lifts the hard cap the 0.5s lockout imposed.

## Two things that fall out for free

- **Real verdicts.** `InvokeServer` returns `(ok, message)`. Outcomes are no
  longer inferred from the colour of a toast, and the 6-second "no result" hold
  is gone.
- **No self-feedback.** Codes arrive over the wire *from the server*; the game's
  own `"Code redeemed!"` / `"Invalid code"` toasts are raised **locally** by
  `NotificationController:Error/Success` and never touch the remote. The
  detector cannot hear itself, so `claimOurs` and the colour classifier stop
  being load-bearing. The label watcher is gated off while the wire is live
  precisely because it *does* see those local toasts.

## Fallback

If `Packages.Net` can't be resolved, `resolveNet()` retries in the background
for 60s and the original label-watch + Confirm-button path stays active
untouched. `L.WireLive` is the flag; `L.Instant` says the remote resolved.

## Not measured

The wire-vs-label lead time. The server was quiet for a 26-second capture
window, so no announcement landed to time head-to-head. The ordering is
structural — same signal, our handler in the same flush, the game's handler
doing a clone plus seven pattern passes plus a thread spawn before it writes the
label — but the millisecond figure is unproven. Run a capture during an actual
drop to get it.

## Build

Single file, no dependencies: `Luminosity_Instant.lua`. Executor needs
`getconnections` and `hookmetamethod` only for the fallback path; the wire path
needs neither. Compile-checked with `luau-compile`.
