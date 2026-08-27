do
-- Two sound slots: announce (replaces the game's chime) and redeem (the game
-- has none). Each with its own list, volume, switch, and a box for your own ids.
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

print("SOUNDS")
print("================================================================")

check("there are two slots", L.SoundSlots and #L.SoundSlots == 2,
    tostring(L.SoundSlots and #L.SoundSlots))
check("one is announce", L.CurrentSound("Announce") ~= nil)
check("one is redeem", L.CurrentSound("Redeem") ~= nil)
check("the library is bigger than before", L.SoundLibrary and #L.SoundLibrary >= 20,
    tostring(L.SoundLibrary and #L.SoundLibrary))
print(("     %d sounds: %s"):format(#L.SoundLibrary, (function()
    local out = {}
    for _, e in ipairs(L.SoundLibrary) do out[#out + 1] = e.name end
    return table.concat(out, ", ")
end)()))

-- the two slots are independent
L.PickSound("Announce", "Ping")
L.PickSound("Redeem", "Bass")
check("announce holds its own pick", L.CurrentSound("Announce").name == "Ping",
    L.CurrentSound("Announce").name)
check("redeem holds a different one", L.CurrentSound("Redeem").name == "Bass",
    L.CurrentSound("Redeem").name)
L.PickSound("Announce", "Snap")
check("changing one does not move the other",
    L.CurrentSound("Redeem").name == "Bass", L.CurrentSound("Redeem").name)

-- picking by name, and rejecting nonsense
check("picking by name works", L.PickSound("Redeem", "Pop") == true)
check("an unknown name is refused", L.PickSound("Redeem", "NotASound") == false)
check("and leaves the pick alone", L.CurrentSound("Redeem").name == "Pop")

-- your own ids, both shapes
check("a raw rbxasset id is accepted",
    L.PickSound("Redeem", "rbxasset://sounds/switch.wav") == true)
check("and becomes the pick", L.CurrentSound("Redeem").id == "rbxasset://sounds/switch.wav",
    L.CurrentSound("Redeem").id)
check("a bare asset number is accepted", L.PickSound("Redeem", "9046863579") == true)
check("and is turned into a real id",
    L.CurrentSound("Redeem").id == "rbxassetid://9046863579",
    L.CurrentSound("Redeem").id)

-- one Sound instance per slot, not one per play
local SoundService = game:GetService("SoundService")
local function soundsNamed(n)
    local out = 0
    for _, d in ipairs(SoundService:GetDescendants()) do
        if d.Name == n then out += 1 end
    end
    return out
end
L.PickSound("Redeem", "Bass")
for _ = 1, 8 do L.TestSound("Redeem") end
H.pump(40000)
check("eight tests make one Sound instance", soundsNamed("LuckSoundRedeem") == 1,
    tostring(soundsNamed("LuckSoundRedeem")))

local function playCount(n)
    for _, d in ipairs(SoundService:GetDescendants()) do
        if d.Name == n then return d.PlayCount or 0 end
    end
    return -1
end

-- the switches
check("a slot can be switched off", L.SetSoundOn("Redeem", false) == false)
local before = playCount("LuckSoundRedeem")
L.PlayRedeemSound()
check("and then does not play", playCount("LuckSoundRedeem") == before)
check("TEST still plays with the switch off", L.TestSound("Redeem") == true)
L.SetSoundOn("Redeem", true)

-- volume
check("volume can be set", L.SetSoundVolume("Announce", 0.25) == 0.25)
check("and is clamped", L.SetSoundVolume("Announce", 5) == 1)
L.SetSoundVolume("Announce", 0.55)

-- the redeem sound fires on a win and not on a loss
L.SetSoundOn("Redeem", true)
R.setInvokeBehaviour(function() return false, "Invalid Code" end)
before = playCount("LuckSoundRedeem")
R.notifyRemote.OnClientEvent:FireAll("SNDLOSE1", 5.5, "Sounds.Sfx.Blop", "Top")
H.pump(200000)
check("a rejected code makes no redeem sound",
    playCount("LuckSoundRedeem") == before,
    ("%d -> %d"):format(before, playCount("LuckSoundRedeem")))

R.setInvokeBehaviour(function() return true, "You received a Meowl!" end)
before = playCount("LuckSoundRedeem")
R.notifyRemote.OnClientEvent:FireAll("SNDWIN1", 5.5, "Sounds.Sfx.Blop", "Top")
H.pump(200000)
check("a win makes a redeem sound", playCount("LuckSoundRedeem") > before,
    ("%d -> %d"):format(before, playCount("LuckSoundRedeem")))

-- the announce sound fires on detection, win or lose
L.SetSoundOn("Announce", true)
R.setInvokeBehaviour(function() return false, "Invalid Code" end)
before = playCount("LuckSoundAnnounce")
R.notifyRemote.OnClientEvent:FireAll("SNDANN1", 5.5, "Sounds.Sfx.Blop", "Top")
H.pump(200000)
check("a spotted code makes an announce sound even when it loses",
    playCount("LuckSoundAnnounce") > before,
    ("%d -> %d"):format(before, playCount("LuckSoundAnnounce")))

-- muting the game's chime drops the sound argument to its handler
check("mute is off by default unless changed", type(L.MuteGameSound) == "boolean")
-- Wrapped in a table on purpose. `heard[#heard + 1] = sound` stores nothing at
-- all when sound is nil, so the array never grows and the muted case reads back
-- as whatever the unmuted one left behind -- which is exactly the value the test
-- is trying to prove is gone.
local heard = {}
local taken = L.PoleTaken
if taken and #taken > 0 then
    L.PoleTaken = {function(msg, dur, sound, position)
        heard[#heard + 1] = {sound = sound}
    end}
    L.MuteGameSound = false
    R.notifyRemote.OnClientEvent:FireAll("SNDMUTE1", 5.5, "Sounds.Sfx.Blop", "Top")
    H.pump(200000)
    check("unmuted, the game still gets its sound",
        heard[#heard] and heard[#heard].sound == "Sounds.Sfx.Blop",
        tostring(heard[#heard] and heard[#heard].sound))
    L.MuteGameSound = true
    R.notifyRemote.OnClientEvent:FireAll("SNDMUTE2", 5.5, "Sounds.Sfx.Blop", "Top")
    H.pump(200000)
    check("muted, the sound argument is dropped",
        heard[#heard] and heard[#heard].sound == nil,
        tostring(heard[#heard] and heard[#heard].sound))
    check("but the notification itself still goes through", #heard >= 2,
        tostring(#heard))
    L.MuteGameSound = false
    L.PoleTaken = taken
else
    check("pole was held so the mute could be tested", false, "no PoleTaken")
end

-- the panel
local gui
for _, d in ipairs((L.GuiParent or R.RepS):GetChildren()) do
    if d:IsA("ScreenGui") and tostring(d.Name):match("^LUCK_%d+$") then gui = d end
end
local panel = gui and gui:FindFirstChild("LuckSoundPanel")
check("the panel exists", panel ~= nil)
if panel then
    local rows, tabs = 0, 0
    for _, d in ipairs(panel:GetDescendants()) do
        if d:IsA("TextLabel") then
            for _, e in ipairs(L.SoundLibrary) do
                if d.Text == e.name then rows += 1 break end
            end
        end
        if d:IsA("TextButton") and (d.Text == "ANNOUNCE" or d.Text == "REDEEM") then
            tabs += 1
        end
    end
    check("it lists the sounds to click", rows >= 15, "found " .. tostring(rows))
    check("with a tab per slot", tabs == 2, "found " .. tostring(tabs))
    check("it minimizes", L.MinimizeSoundPanel(true) == true
        and panel:FindFirstChild("Body").Visible == false)
    check("and restores", L.MinimizeSoundPanel(false) == false)
end

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
