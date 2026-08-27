do
-- Win sound: cycles, tests, names itself, plays on a win and not on a loss.
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

print("WIN SOUND")
print("================================================================")

check("there is a list to cycle", L.WinSounds and #L.WinSounds >= 10,
    "got " .. tostring(L.WinSounds and #L.WinSounds))
check("it starts on one of them", L.CurrentWinSound() ~= nil)
print("     " .. (function()
    local out = {}
    for _, e in ipairs(L.WinSounds) do out[#out + 1] = e.name end
    return table.concat(out, ", ")
end)())

-- The Sound is parented to SoundService, not the gui. Looking anywhere else
-- finds nothing and every count check passes for the wrong reason.
local SoundService = game:GetService("SoundService")
local function allSounds()
    local out = {}
    for _, d in ipairs(SoundService:GetDescendants()) do
        if d.Name == "LuckWinSound" then out[#out + 1] = d end
    end
    return out
end

L.TestWinSound()
H.pump(40000)
check("the sound instance exists where it says it does", #allSounds() == 1,
    "found " .. tostring(#allSounds()))
for _ = 1, 5 do L.TestWinSound() end
H.pump(40000)
check("six tests do not make six Sound instances", #allSounds() == 1,
    "found " .. tostring(#allSounds()))

-- cycling walks the list and wraps
L.SetWinSound("Ping")
local first = L.CurrentWinSound().name
check("SetWinSound by name works", first == "Ping", first)
local seen = {}
for _ = 1, #L.WinSounds do
    seen[L.CurrentWinSound().name] = true
    L.NextWinSound()
    H.pump(20000)
end
check("cycling reaches every sound", (function()
    local n = 0
    for _ in pairs(seen) do n += 1 end
    return n == #L.WinSounds
end)(), "reached " .. tostring((function() local n = 0 for _ in pairs(seen) do n += 1 end return n end)()))
check("and wraps back to where it started", L.CurrentWinSound().name == first,
    L.CurrentWinSound().name)

check("stepping backwards works", (function()
    L.SetWinSound("Ping")
    L.NextWinSound(-1)
    return L.CurrentWinSound().name == L.WinSounds[#L.WinSounds].name
end)(), L.CurrentWinSound().name)

-- the on/off switch
L.SetWinSound("Ping")
check("it can be switched off", L.SetWinSoundOn(false) == false)
check("and PlayWinSound respects that", L.PlayWinSound() == false)
check("and back on", L.SetWinSoundOn(true) == true)
check("and plays again", L.PlayWinSound() == true)

-- TEST ignores the switch, because you press it to hear the sound
L.SetWinSoundOn(false)
check("TEST plays even with the switch off", L.TestWinSound() == true)
L.SetWinSoundOn(true)

-- it fires on a win and not on a loss
local function playCount()
    local s = allSounds()[1]
    return s and (s.PlayCount or 0) or -1
end
check("play counting is actually reading a sound", playCount() >= 0,
    "no LuckWinSound in SoundService")
local before = playCount()
R.setInvokeBehaviour(function() return false, "Invalid Code" end)
R.notifyRemote.OnClientEvent:FireAll("SOUNDLOSE1", 5.5, "Sounds.Sfx.Blop", "Top")
H.pump(200000)
check("a rejected code makes no sound", playCount() == before,
    ("%d -> %d"):format(before, playCount()))

before = playCount()
R.setInvokeBehaviour(function() return true, "You received a Meowl!" end)
R.notifyRemote.OnClientEvent:FireAll("SOUNDWIN1", 5.5, "Sounds.Sfx.Blop", "Top")
H.pump(200000)
check("a win makes a sound", playCount() > before,
    ("%d -> %d"):format(before, playCount()))

-- the panel shows the name
local gui
for _, d in ipairs((L.GuiParent or R.RepS):GetChildren()) do
    if d:IsA("ScreenGui") and tostring(d.Name):match("^LUCK_%d+$") then gui = d end
end
local panel = gui and gui:FindFirstChild("LuckSoundPanel")
check("the panel exists", panel ~= nil)
if panel then
    L.SetWinSound("Snap")
    local shown
    for _, d in ipairs(panel:GetDescendants()) do
        if d:IsA("TextLabel") and tostring(d.Text):find("Snap", 1, true) then
            shown = d.Text
        end
    end
    check("and names the current sound", shown ~= nil, "no name label showing Snap")
    if shown then print("     panel reads: " .. shown) end
    check("it minimizes", L.MinimizeSoundPanel(true) == true
        and panel:FindFirstChild("Body").Visible == false)
    check("and restores", L.MinimizeSoundPanel(false) == false
        and panel:FindFirstChild("Body").Visible == true)
end

print("")
print(("checks: %d   failures: %d"):format(checks, #fails))
for _, f in ipairs(fails) do print("  FAIL  " .. f) end
print(("runtime errors: %d"):format(H.errors and #H.errors or 0))
if H.errors then
    local seen2 = {}
    for _, e in ipairs(H.errors) do
        local k = tostring(e)
        if not seen2[k] then seen2[k] = true; print("  ERR  " .. k) end
    end
end
end
