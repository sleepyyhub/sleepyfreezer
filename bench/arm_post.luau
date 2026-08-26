do
-- Auto-arm: the script listens with Auto Redeem off, and an announcement saying a
-- code is coming can switch sending on by itself. Off unless asked for.
local R = RIG
local H = R.H
H.pump(200000)
local L = R.genvTable.LUCK
if not L then print("no getgenv().LUCK") return end

local fails, checks = {}, 0
local function check(n, c, d)
    checks += 1
    if not c then fails[#fails + 1] = n .. (d and ("  -- " .. d) or "") end
end
local function reset(arm)
    L.AutoArm = arm and true or false
    if L.SetAuto then L.SetAuto(false) else L.AutoOn = false; L.SyncHot() end
    L.ArmedBy, L.ArmCount = nil, 0
    H.pump(200000)
end

print("AUTO-ARM")
print("================================================================")

check("it is off by default in the settings defaults", L.Settings.AutoArm ~= true)
check("the toggle is exposed", type(L.SetAutoArm) == "function")
check("the check is exposed", type(L.CheckAutoArm) == "function")

-- off: an announcement saying a code is coming must NOT switch sending on
reset(false)
check("auto redeem starts off for this test", L.AutoOn == false)
R.notifyRemote.OnClientEvent:FireAll("Use code SUMMER for a free pet!",
    5.5, "Sounds.Sfx.Blop", "Top")
H.pump(200000)
check("with auto-arm off, nothing is switched on", L.AutoOn == false,
    "AutoOn=" .. tostring(L.AutoOn))

-- on: the same announcement arms it
reset(true)
local before = R.invokeCount()
R.notifyRemote.OnClientEvent:FireAll("Use code SUMMER for a free pet!",
    5.5, "Sounds.Sfx.Blop", "Top")
H.pump(200000)
check("with auto-arm on, auto redeem switches on", L.AutoOn == true,
    "AutoOn=" .. tostring(L.AutoOn))
check("and it records what armed it", L.ArmedBy == "use code",
    tostring(L.ArmedBy))
check("and counts it", L.ArmCount == 1, tostring(L.ArmCount))

-- the other phrasings
local phrases = {
    ["the code is MEOWL2024"] = "code is",
    ["New code: FREEPET"] = "code:",
    ["Redeem code WINTER now"] = "redeem code",
    ["new code dropping in 5"] = "new code",
    ["free code for everyone"] = "free code",
}
for text, want in pairs(phrases) do
    reset(true)
    R.notifyRemote.OnClientEvent:FireAll(text, 5.5, "Sounds.Sfx.Blop", "Top")
    H.pump(200000)
    check(("\"%s\" arms it"):format(text), L.AutoOn == true,
        "AutoOn=" .. tostring(L.AutoOn) .. " by=" .. tostring(L.ArmedBy))
end

-- ordinary chatter must not
local quiet = {"Player123 redeemed SUMMER for a Meowl",
               "Meowl spawned!", "Welcome to the server", "SUMMER2024"}
for _, text in ipairs(quiet) do
    reset(true)
    R.notifyRemote.OnClientEvent:FireAll(text, 5.5, "Sounds.Sfx.Blop", "Top")
    H.pump(200000)
    check(("\"%s\" does not arm it"):format(text), L.AutoOn == false,
        "AutoOn=" .. tostring(L.AutoOn) .. " by=" .. tostring(L.ArmedBy))
end

-- once armed, a code that follows actually redeems
reset(true)
R.notifyRemote.OnClientEvent:FireAll("Use code for a free pet!",
    5.5, "Sounds.Sfx.Blop", "Top")
H.pump(200000)
check("armed by the announcement", L.AutoOn == true)
local n0 = R.invokeCount()
R.notifyRemote.OnClientEvent:FireAll("ARMEDCODE1", 5.5, "Sounds.Sfx.Blop", "Top")
H.pump(200000)
check("the code that follows is redeemed", R.invokeCount() - n0 == 1,
    "sends=" .. tostring(R.invokeCount() - n0))

-- the toggle persists to settings
reset(false)
L.SetAutoArm(true)
check("the toggle writes through to settings", L.Settings.AutoArm == true)
L.SetAutoArm(false)
check("and back off again", L.Settings.AutoArm == false and L.AutoArm == false)

-- and arming twice does not double-fire
reset(true)
R.notifyRemote.OnClientEvent:FireAll("use code AAA", 5.5, "Sounds.Sfx.Blop", "Top")
H.pump(200000)
local armed = L.ArmCount
R.notifyRemote.OnClientEvent:FireAll("use code BBB", 5.5, "Sounds.Sfx.Blop", "Top")
H.pump(200000)
check("already-on announcements do not re-arm", L.ArmCount == armed,
    ("%d -> %d"):format(armed, L.ArmCount))

print("")
print(("checks: %d   failures: %d"):format(checks, #fails))
for _, f in ipairs(fails) do print("  FAIL  " .. f) end
print(("runtime errors: %d"):format(H.errors and #H.errors or 0))
if H.errors then
    local seen = {}
    for _, e in ipairs(H.errors) do
        local k = tostring(e)
        if not seen[k] then seen[k] = true; print("  ERR  " .. k) end
    end
end
end
