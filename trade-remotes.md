# Steal a Brainrot — TradeService remote reference

Place: `109983668079237` (RootPlaceId, main game)
Trade Plaza place: `78906538690694`
Source: `ReplicatedStorage.Controllers.TradeController` (decompiled + bytecode verified)

## What is stable vs what rotates

| Thing | Stable? | Notes |
|---|---|---|
| **Call-site GUIDs** | **Yes** | String literals in the compiled bytecode (constant table of `TradeController`). Identical across servers, sessions and rejoins. Only change when the devs republish (watch `PlaceVersion`). |
| **Hashed remote names** (`RF/<64 hex>`) | **No** | Rotate per server. Confirmed: two different servers gave two different hashes for the same logical remote. **Never hardcode these.** |
| **Index position** under `Packages.Net` | Appears stable | Same scheme Luminosity uses (`EXPECTED_INDEX = 70` for redeem, which matched on a different server). Verified once for trade — re-check after any game update. |

Observed rotation, same remote, two servers:

| Remote | server `f7b8e27f` | server `da1674c6` |
|---|---|---|
| SearchUser | `RF/dfd12b51…c4606` | `RF/fd62a578…9d1b7` |
| Invite | `RF/b42f9232…e8d434` | `RF/850c6749…50201` |

## The remotes

| Plaintext name | Class | RF index | GUID (stable) |
|---|---|---|---|
| `TradeService/SearchUser` | RemoteFunction | **12** | `792baf13-54a1-4663-92c4-1edd9da1e3e2` |
| `TradeService/Invite` | RemoteFunction | **10** | `afb005f9-6e81-4e0a-8bb0-3555938a9658` |
| `TradeService/AddBrainrot` | RemoteFunction | — | `6b5f15fb-5cb9-4d07-a031-bbff8e641eda` |
| `TradeService/RemoveBrainrot` | RemoteFunction | — | `1a5f9c76-711f-4c90-8117-2ffd3fa21c6d` |
| `TradeService/AddItem` | RemoteFunction | — | `f2c4a9d1-3b7e-4a51-9c8d-1e6f0a2b3c4d` |
| `TradeService/RemoveItem` | RemoteFunction | — | `a7e1b5c9-2d48-4f63-8a90-5c1d2e3f4a6b` |
| `TradeService/SendChatMessage` | RemoteEvent | — | `b7e3f1a2-4c89-4d5e-a6b0-9f8e7d6c5b4a` |

Also present (no GUID arg observed): `CreateInvite` (RE, server→client), `InviteResult` (RE),
`AcceptInvite` (RF), `DeclineInvite` (RE), `CancelTrade` (RE), `Accept` (RE), `Ready` (RE),
`GetTradeHistory` (RF), `HistoryUpdated` (RE).

## Arguments

```lua
SearchUser:InvokeServer(GUID, userId)   -- userId is a NUMBER, not a username
-- returns (success, found, ...)
-- the UI resolves name -> id client-side first via Players:GetUserIdFromNameAsync

Invite:InvokeServer(GUID, userId)
-- returns (ok, err, pending)
--   ok == false          -> err is the reason string
--   pending not a string -> delivered cleanly
--   pending is a string  -> parked awaiting the other side; TradeService/InviteResult keys off it

AddBrainrot:InvokeServer(GUID, podiumIndex, brainrot)
-- podiumIndex : key from the AnimalPodiums table
-- brainrot    : the WHOLE record table {UUID, Index, Mutation, Traits, OneOfOne}
-- returns (ok, err)
-- server re-validates against your real podium; forged tables are rejected
-- brainrots with .Machine set, or an Index missing from Datas.Animals, are not addable
```

## Bait / honeypot remotes

The game plants decoy RemoteFunctions with **GUID-shaped names**:

```lua
local function isBait(n)   return n:match("^RF/%x+%-%x+%-%x+%-%x+%-%x+$") ~= nil end
local function isReal(n)   return #n == 67 and n:match("^RF/%x+$") ~= nil end
```

Real remotes are `RF/` + exactly 64 hex chars. Do not touch anything matching the bait shape.

## Resolving at runtime (correct approach)

Do not hardcode hashes. Pull the live instance out of the controller's own closures:

```lua
local TC = require(game.ReplicatedStorage.Controllers.TradeController)

-- SearchUser lives at upvalue 12 of _createPlayerList
local searchUser = select(2, pcall(debug.getupvalue, TC._createPlayerList, 12))

-- Invite is an upvalue of SendInvite
local invite
for _, v in pairs(select(2, pcall(debug.getupvalues, TC.SendInvite)) or {}) do
    if typeof(v) == "Instance" and v:IsA("RemoteFunction") then invite = v break end
end
```

Or just use the game's own wrapper, which handles resolution and the GUID for you:

```lua
TC:SendInvite(userId, function(delivered, message)
    print("delivered:", delivered, "message:", message)
end)
```

## Gotcha: a wedged RemoteFunction jams the whole client

If one `InvokeServer` never returns, **every subsequent RemoteFunction from that client hangs**
— across unrelated services (confirmed against SettingsService and the code-redeem remote).
Replication, ping and server clock all stay healthy, so it looks like the server is ignoring you.
Only a rejoin clears it. Always wrap probe invokes:

```lua
local done, res = false, nil
task.spawn(function()
    local ok, a, b = pcall(function() return rf:InvokeServer(...) end)
    if not done then res = {ok, a, b}; done = true end
end)
local t0 = os.clock()
while not done and os.clock() - t0 < 20 do task.wait(0.1) end
```

## Known IDs

| Who | userId |
|---|---|
| forbiddentomove123 (clover) | 8568412616 |
| za903h | 1832933603 |
