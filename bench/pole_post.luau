do
-- Pole has to be HELD, not taken once.
--
-- The game can attach a notification handler at any time -- a respawn, a UI
-- module reloading, its own script rebinding. Under Immediate signals anything
-- we failed to take runs its GUI and sound work synchronously ahead of our
-- invoke. Nothing announces that: PoleOn stays true, it is just no longer
-- holding everything.
local R = RIG
local H = R.H
local notifyRemote = R.notifyRemote
H.pump(300000)
local L = R.genvTable.LUCK
local fails, checks = {}, 0
local function check(name, cond, detail)
    checks += 1
    if not cond then fails[#fails + 1] = name .. (detail and ("  -- " .. detail) or "") end
end

check("pole is held at boot", L.PoleOn == true)
local heldAtBoot = #(L.PoleTaken or {})
check("it took the game's handler", heldAtBoot >= 1, tostring(heldAtBoot))

-- Everything the game had is disabled, and ours is not.
local function enabledCount()
    local n = 0
    for _, c in ipairs(getconnections(notifyRemote.OnClientEvent)) do
        if c._enabled ~= false then n += 1 end
    end
    return n
end
check("only our own connection is live", enabledCount() == 1, tostring(enabledCount()))

-- The game comes back and reconnects, exactly as it would after a respawn.
local lateCalls = 0
local lateConn = notifyRemote.OnClientEvent:Connect(function() lateCalls += 1 end)
check("the newcomer is live before the sweep", enabledCount() == 2, tostring(enabledCount()))

-- One announcement while pole is stale: the newcomer runs ahead of us, which is
-- the whole problem.
local beforeStale = R.invokeCount()
notifyRemote.OnClientEvent:FireAll("POLESTALE", 5.5, nil, "Top")
H.pump(40000)
check("we still send while pole is stale", R.invokeCount() > beforeStale)
check("but the newcomer ran too", lateCalls >= 1, tostring(lateCalls))

-- Now let the janitor come round. It runs every 30s and re-sweeps.
H.pump(200000, H.virtualNow() + 65)
check("the sweep took the newcomer", enabledCount() == 1, tostring(enabledCount()) .. " live")
check("and it is on the held list", #(L.PoleTaken or {}) > heldAtBoot,
    tostring(#(L.PoleTaken or {})))

-- Taken does not mean dropped: pole re-dispatches what it holds, so the game's
-- own popup still happens -- just behind our send instead of in front of it.
local before = lateCalls
notifyRemote.OnClientEvent:FireAll("POLEHELD", 5.5, nil, "Top")
H.pump(40000)
check("the newcomer still gets its announcement", lateCalls > before,
    tostring(lateCalls - before))

-- The risk a repeating sweep introduces that a one-shot did not: by the time it
-- runs we may have rebound, and a stale connection of OUR OWN is still on the
-- list. Pole disables what it captures and then calls it again by hand, so
-- capturing one of ours would send the same code twice with the exactly-once
-- guard unable to see it -- the second call comes from us.
L.SetDetectMode("ui"); H.pump(40000)
L.SetDetectMode("remote"); H.pump(40000)
L.SyncFast(); H.pump(40000)
H.pump(200000, H.virtualNow() + 65)

local n0 = R.invokeCount()
notifyRemote.OnClientEvent:FireAll("POLEONCE", 5.5, nil, "Top")
H.pump(60000)
check("one announcement is still exactly one send", R.invokeCount() - n0 == 1,
    tostring(R.invokeCount() - n0) .. " sends")

local ours = 0
for _, c in ipairs(L.PoleTaken or {}) do
    if L.IsOurHandler and L.IsOurHandler(c) then ours += 1 end
end
check("the sweep never took one of ours", ours == 0, tostring(ours))

-- And dropping pole hands everything back, including the one taken late.
-- AutoPole off first: rebinding re-takes pole the moment we reconnect, which is
-- what you want in play and would hide the handback here.
L.AutoPole = false
L.DropPole()
check("dropping pole re-enables everything", enabledCount() >= 2, tostring(enabledCount()))
L.AutoPole = nil
pcall(function() lateConn:Disconnect() end)

print(("checks: %d   failures: %d"):format(checks, #fails))
for _, f in ipairs(fails) do print("  FAIL  " .. f) end
print("runtime errors: " .. #(H.errors or {}))
end
