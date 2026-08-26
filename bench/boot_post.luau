do
local R = RIG
local H = R.H
local fails, checks = {}, 0
local function check(n, c, d)
    checks += 1
    if not c then fails[#fails + 1] = n .. (d and ("  -- " .. d) or "") end
end

print("BOOT ORDER")
print("================================================================")

-- nothing of ours should exist yet: the gate has not opened, only discovery has run
local beforeReady = BOOT.created()
local L = R.genvTable.LUCK
print(("  at load:      ready=%s  ui instances=%d")
    :format(tostring(L and L.Ready), beforeReady))
check("no UI is built before the gate opens", BOOT.snapshot() == nil,
    "a ScreenGui already exists at instance " .. tostring(BOOT.snapshot() and BOOT.snapshot().at))

H.pump(200000)

local s = BOOT.snapshot()
print(("  at first UI:  ready=%s (%s)  detect=%s  redeem=%s  tested=%s  pole=%s")
    :format(tostring(s and s.ready), tostring(s and s.readyBy),
            tostring(s and s.detectOn), tostring(s and s.redeem),
            tostring(s and s.redeemTested), tostring(s and s.pole)))
print(("  after:        ui built=%s  up in %s")
    :format(tostring(L.UIBuilt), L.UpIn and ("%.3fs"):format(L.UpIn) or "?"))

check("the UI does get built", s ~= nil and L.UIBuilt == true)
if s then
    check("readiness had fired first", s.ready == true, "ready=" .. tostring(s.ready))
        check("it fired for the expected reason", s.readyBy == (BOOT_EXPECT or "discovery"),
        "got " .. tostring(s.readyBy) .. ", wanted " .. tostring(BOOT_EXPECT or "discovery"))
    check("detection was already live", s.detectOn == true)
    check("the redeem remote was already resolved", s.redeem == true)
    check("the notify remote was already resolved", s.notify == true)
    check("pole was already taken", s.pole == true, "pole=" .. tostring(s.pole))
    if not BOOT_EXPECT then
        check("the redeem had already been tested", s.redeemTested ~= nil,
            "tested=" .. tostring(s.redeemTested))
    end
end
check("no UI build error", L.UIError == nil, tostring(L.UIError))

-- and the thing all of that is for: detection works
local before = R.invokeCount()
-- on a coroutine: with a realistic server the send parks for the round trip
task.spawn(function()
    R.notifyRemote.OnClientEvent:FireAll("BOOTCODE1", 5.5, "Sounds.Sfx.Blop", "Top")
end)
H.pump(200000)
check("a code announced after boot still redeems once",
    R.invokeCount() - before == 1, "sends=" .. tostring(R.invokeCount() - before))

print("")
print(("checks: %d   failures: %d"):format(checks, #fails))
for _, f in ipairs(fails) do print("  FAIL  " .. f) end
print(("runtime errors: %d"):format(H.errors and #H.errors or 0))
end
