do
-- The cooldown readout learns its length from replies. These drive the exact reply
-- sequence a real server produces and check what it concluded.
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

print("REDEEM COOLDOWN")
print("================================================================")

-- reset to a clean slate
L.CooldownSecs, L.CooldownKnown = 15, false
L.CooldownEnds, L.CooldownAt, L.CooldownMin, L.CooldownRejects = 0, nil, 0, 0

check("classifies the real rejection text",
    L.IsCooldownReply("Please wait before trying to redeem another Code") == true)
check("classifies an invalid code as an answer",
    L.IsCooldownReply("Invalid Code") == false)
check("classifies a success as an answer",
    L.IsCooldownReply("You received a Meowl!") == false)
check("a nil reply is not a cooldown", L.IsCooldownReply(nil) == false)

-- a redeem gets an answer: the window opens
local t = 1000
check("free before anything happened", L.CooldownEnds == 0)
L.NoteRedeemReply(false, "Invalid Code", t)
check("a real answer starts the window", L.CooldownAt == t)
check("the countdown runs off the estimate", L.CooldownEnds == t + 15)

-- rejected 4s in: still inside, and that is a lower bound
L.NoteRedeemReply(false, "Please wait before trying to redeem another Code", t + 4)
check("a rejection is not treated as an answer", L.CooldownAt == t,
    "CooldownAt moved to " .. tostring(L.CooldownAt))
check("the lower bound learned 4s", math.abs(L.CooldownMin - 4) < 0.001,
    tostring(L.CooldownMin))
check("still counting down", L.CooldownEnds == t + 15)

-- answered 12s in: the window was over, so 12s is an upper bound
L.NoteRedeemReply(false, "Invalid Code", t + 12)
check("a real answer bounds it from above", L.CooldownKnown == true)
check("the length is now the measured 12s", math.abs(L.CooldownSecs - 12) < 0.001,
    tostring(L.CooldownSecs))
check("and a fresh window started", L.CooldownAt == t + 12)
check("running off the measured length now", L.CooldownEnds == t + 24)

-- a rejection past the current estimate stretches it rather than reading zero
L.CooldownSecs, L.CooldownKnown = 15, false
L.CooldownEnds, L.CooldownAt, L.CooldownMin, L.CooldownRejects = 0, nil, 0, 0
L.NoteRedeemReply(false, "Invalid Code", t)
L.NoteRedeemReply(false, "Please wait", t + 20)
check("a rejection past the guess stretches it", L.CooldownSecs > 20,
    tostring(L.CooldownSecs))
check("and never shows ready while being told to wait", L.CooldownEnds > t + 20,
    tostring(L.CooldownEnds - t))
check("it is still marked an estimate", L.CooldownKnown == false)

-- an idle stretch with no rejection in it must not be mistaken for a measurement
L.CooldownSecs, L.CooldownKnown = 15, false
L.CooldownEnds, L.CooldownAt, L.CooldownMin, L.CooldownRejects = 0, nil, 0, 0
L.NoteRedeemReply(false, "Invalid Code", t)
L.NoteRedeemReply(false, "Invalid Code", t + 300)
check("an idle gap is not a measurement", L.CooldownKnown == false,
    "learned " .. tostring(L.CooldownSecs))

-- a timeout says nothing either way
L.CooldownSecs, L.CooldownKnown = 15, false
L.CooldownEnds, L.CooldownAt, L.CooldownMin, L.CooldownRejects = 0, nil, 0, 0
check("a no-result timeout is ignored", L.NoteRedeemReply(nil, "no result", t) == nil)
check("and leaves the window untouched", L.CooldownAt == nil)

-- end to end: announce a code, the server rejects it, the readout is counting
R.setInvokeBehaviour(function() return false, "Invalid Code" end)
L.CooldownSecs, L.CooldownKnown = 15, false
L.CooldownEnds, L.CooldownAt, L.CooldownMin, L.CooldownRejects = 0, nil, 0, 0
R.notifyRemote.OnClientEvent:FireAll("COOLCODE1", 5.5, "Sounds.Sfx.Blop", "Top")
H.pump(40000, H.virtualNow())
check("a redeem starts the countdown with no clock advance", L.CooldownLeft() > 0,
    "left=" .. tostring(L.CooldownLeft()))

local gui
for _, d in ipairs((L.GuiParent or R.RepS):GetChildren()) do
    if d:IsA("ScreenGui") and tostring(d.Name):match("^LUCK_%d+$") then gui = d end
end
local shown
if gui then
    for _, d in ipairs(gui:GetDescendants()) do
        if d:IsA("TextLabel") and tostring(d.Text):find("before the next redeem", 1, true) then
            shown = d.Text
        end
    end
end
check("the panel is showing it", shown ~= nil, "no cooldown label found")
if shown then print("     panel reads: " .. tostring(shown)) end

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
