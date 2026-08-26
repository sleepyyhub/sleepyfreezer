do
-- Five seconds between redeems that count. An attempt made inside that window is
-- discarded by the server and must not move the clock in either direction.
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
local function near(a, b) return math.abs(a - b) < 0.001 end
local function reset()
    L.CooldownSecs, L.CooldownKnown = 5, true
    L.CooldownEnds, L.CooldownAt = 0, nil
    L.CooldownMin, L.CooldownRejects, L.CooldownWasted = 0, 0, 0
end

print("REDEEM COOLDOWN")
print("================================================================")

check("the length is the measured 5s, not a guess",
    near(L.CooldownSecs, 5) and L.CooldownKnown == true,
    tostring(L.CooldownSecs) .. " known=" .. tostring(L.CooldownKnown))

check("classifies the real rejection text",
    L.IsCooldownReply("Please wait before trying to redeem another Code") == true)
check("classifies an invalid code as an answer",
    L.IsCooldownReply("Invalid Code") == false)
check("classifies a success as an answer",
    L.IsCooldownReply("You received a Meowl!") == false)
check("a nil reply is not a cooldown", L.IsCooldownReply(nil) == false)

-- an invalid code counts, and starts the five seconds
reset()
local t = 1000
L.NoteRedeemReply(false, "Invalid Code", t)
check("an invalid redeem counts and opens the window", L.CooldownAt == t)
check("it runs five seconds", near(L.CooldownEnds, t + 5),
    tostring(L.CooldownEnds - t))

-- three attempts inside the window: all discarded, clock untouched
for _, offset in ipairs({0.5, 1.0, 4.9}) do
    L.NoteRedeemReply(false, "Please wait before trying to redeem another Code", t + offset)
end
check("attempts inside the window do not restart it", L.CooldownAt == t,
    "start moved to " .. tostring(L.CooldownAt))
check("and do not extend it either", near(L.CooldownEnds, t + 5),
    ("ends at +%.2f"):format(L.CooldownEnds - t))
check("and do not shorten it", L.CooldownEnds >= t + 5)
check("they are counted as discarded", L.CooldownRejects == 3,
    tostring(L.CooldownRejects))
check("and tallied for the session", L.CooldownWasted == 3,
    tostring(L.CooldownWasted))

-- the next one that counts starts a fresh five
L.NoteRedeemReply(false, "Invalid Code", t + 5.2)
check("the next real answer opens a new window", L.CooldownAt == t + 5.2)
check("five seconds again", near(L.CooldownEnds, t + 10.2),
    tostring(L.CooldownEnds - t))
check("the discard counter resets with it", L.CooldownRejects == 0)
check("the session tally does not reset", L.CooldownWasted == 3,
    tostring(L.CooldownWasted))

-- a success counts the same way
reset()
L.NoteRedeemReply(true, "You received a Meowl!", t)
check("a successful redeem opens the window too", near(L.CooldownEnds, t + 5),
    tostring(L.CooldownEnds - t))

-- the safety valve: told to wait after the window should already have closed
reset()
L.NoteRedeemReply(false, "Invalid Code", t)
L.NoteRedeemReply(false, "Please wait", t + 8)
check("being told to wait past 5s lengthens it", L.CooldownSecs > 5,
    tostring(L.CooldownSecs))
check("it never reads ready while the server says no", L.CooldownEnds >= t + 8,
    ("ends at +%.2f"):format(L.CooldownEnds - t))

-- and it must never shorten
reset()
L.NoteRedeemReply(false, "Invalid Code", t)
L.NoteRedeemReply(false, "Please wait", t + 1)
check("an early rejection does not shorten it", near(L.CooldownSecs, 5),
    tostring(L.CooldownSecs))
check("nor pull the end in", near(L.CooldownEnds, t + 5),
    tostring(L.CooldownEnds - t))

-- a timeout says nothing either way
reset()
check("a no-result timeout is ignored", L.NoteRedeemReply(nil, "no result", t) == nil)
check("and leaves the window untouched", L.CooldownAt == nil)

-- end to end through a real announcement
reset()
R.setInvokeBehaviour(function() return false, "Invalid Code" end)
R.notifyRemote.OnClientEvent:FireAll("COOLCODE1", 5.5, "Sounds.Sfx.Blop", "Top")
H.pump(40000, H.virtualNow())
check("a redeem starts the countdown with no clock advance", L.CooldownLeft() > 0,
    "left=" .. tostring(L.CooldownLeft()))
check("and it is about five seconds", L.CooldownLeft() > 4 and L.CooldownLeft() <= 5,
    ("%.2f"):format(L.CooldownLeft()))

local gui
for _, d in ipairs((L.GuiParent or R.RepS):GetChildren()) do
    if d:IsA("ScreenGui") and tostring(d.Name):match("^LUCK_%d+$") then gui = d end
end
local function readPanel()
    if not gui then return nil end
    for _, d in ipairs(gui:GetDescendants()) do
        local txt = tostring(d.Text or "")
        if d:IsA("TextLabel") and (txt:find("next redeem", 1, true)
            or txt:find("discarded", 1, true)) then return txt end
    end
end
local shown = readPanel()
check("the panel is showing the countdown", shown ~= nil, "no cooldown label found")
if shown then print("     panel reads: " .. tostring(shown)) end

-- and it reports the wasted attempts once some pile up
R.setInvokeBehaviour(function() return false, "Please wait before trying to redeem another Code" end)
for i = 1, 3 do
    R.notifyRemote.OnClientEvent:FireAll("COOLBURN" .. i, 5.5, "Sounds.Sfx.Blop", "Top")
end
H.pump(40000, H.virtualNow())
if L.PaintCooldown then L.PaintCooldown() end
local burned = readPanel()
check("the panel says how many were thrown away",
    burned ~= nil and burned:find("discarded", 1, true) ~= nil, tostring(burned))
if burned then print("     panel reads: " .. tostring(burned)) end

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
