
--[[ ====================================================================
     LUCK PRIVATE  ·  win sound

     Plays when a redeem comes back a win. Cycle the picker to hear each
     one, TEST to replay the current one, and the name is on screen so
     there is something to point at.

     rbxasset:// ids are files inside the Roblox client -- no lookup, no
     moderation, they cannot 404. Anything uploaded can, so the picker
     marks a sound that never loads instead of just going quiet.
     ==================================================================== }]]

do

local L = (getgenv and getgenv().LUCK) or LUCK
if not L then return end

local UIS = game:GetService("UserInputService")
local rgb = Color3.fromRGB
local floor = math.floor

L.WinSounds = {
    {name = "Ping",       id = "rbxasset://sounds/electronicpingshort.wav"},
    {name = "Snap",       id = "rbxasset://sounds/snap.wav"},
    {name = "Pop",        id = "rbxasset://sounds/pop_mid_up.wav"},
    {name = "Button",     id = "rbxasset://sounds/button.wav"},
    {name = "Switch",     id = "rbxasset://sounds/switch.wav"},
    {name = "Click",      id = "rbxasset://sounds/clickfast.wav"},
    {name = "Bass",       id = "rbxasset://sounds/bass.wav"},
    {name = "Swoosh",     id = "rbxasset://sounds/swoosh.wav"},
    {name = "Water",      id = "rbxasset://sounds/impact_water.mp3"},
    {name = "Blop",       id = "rbxassetid://138213892284919"},
}

L.WinSoundOn     = true
L.WinSoundVolume = 0.55
L.WinSoundIndex  = 1
L.WinSoundDead   = {}      -- names that never loaded

local SOUND_FILE = "LUCK/private_sound.txt"
local VOL_FILE   = "LUCK/private_sound_vol.txt"

local function save()
    pcall(function()
        if type(makefolder) == "function"
            and (type(isfolder) ~= "function" or not isfolder("LUCK")) then
            makefolder("LUCK")
        end
        local cur = L.WinSounds[L.WinSoundIndex]
        writefile(SOUND_FILE, (L.WinSoundOn and "" or "off:")
            .. (cur and cur.name or "Ping"))
        writefile(VOL_FILE, tostring(L.WinSoundVolume))
    end)
end

local function load()
    pcall(function()
        if type(isfile) == "function" and not isfile(SOUND_FILE) then return end
        local raw = readfile(SOUND_FILE)
        if type(raw) ~= "string" then return end
        if raw:sub(1, 4) == "off:" then
            L.WinSoundOn, raw = false, raw:sub(5)
        end
        for i, e in ipairs(L.WinSounds) do
            if e.name == raw then L.WinSoundIndex = i break end
        end
    end)
    pcall(function()
        if type(isfile) == "function" and not isfile(VOL_FILE) then return end
        local v = tonumber(readfile(VOL_FILE))
        if v then L.WinSoundVolume = math.clamp(v, 0, 1) end
    end)
end
load()

-- One Sound instance, reused. A fresh one per win is an Instance allocation on
-- the result path for something that only ever plays one clip at a time.
local player
local function ensure()
    if player and player.Parent then return player end
    local ok = pcall(function()
        local s = Instance.new("Sound")
        s.Name = "LuckWinSound"
        s.Volume = L.WinSoundVolume
        local parent
        pcall(function() parent = game:GetService("SoundService") end)
        s.Parent = parent or L.GuiParent
        player = s
    end)
    return ok and player or nil
end

local refreshSoundUI

L.CurrentWinSound = function()
    return L.WinSounds[L.WinSoundIndex] or L.WinSounds[1]
end

L.PlayWinSound = function()
    if not L.WinSoundOn then return false end
    local s = ensure()
    local entry = L.CurrentWinSound()
    if not s or not entry then return false end
    pcall(function()
        s.SoundId = entry.id
        s.Volume = L.WinSoundVolume
        s:Play()
    end)
    return true
end

-- TEST ignores the on/off switch: you press it to hear the sound, not to find
-- out whether the switch is on.
L.TestWinSound = function()
    local s = ensure()
    local entry = L.CurrentWinSound()
    if not s or not entry then return false end
    pcall(function()
        s.SoundId = entry.id
        s.Volume = L.WinSoundVolume
        s:Play()
    end)
    print(("[LUCK] sound  %s  ->  %s"):format(entry.name, entry.id))

    -- A dead id plays nothing and says nothing, which is indistinguishable from
    -- a quiet one. Give it a moment and mark it if it never loads.
    task.spawn(function()
        local name = entry.name
        for _ = 1, 20 do
            local okLoaded, loaded = pcall(function()
                return s.IsLoaded or (s.TimeLength or 0) > 0
            end)
            if okLoaded and loaded then
                if L.WinSoundDead[name] then
                    L.WinSoundDead[name] = nil
                    if refreshSoundUI then refreshSoundUI() end
                end
                return
            end
            task.wait(0.15)
        end
        L.WinSoundDead[name] = true
        if refreshSoundUI then refreshSoundUI() end
        warn(("[LUCK] sound '%s' did not load: %s"):format(name, entry.id))
    end)
    return true
end

L.NextWinSound = function(step)
    local n = #L.WinSounds
    L.WinSoundIndex = ((L.WinSoundIndex - 1 + (step or 1)) % n) + 1
    save()
    if refreshSoundUI then refreshSoundUI() end
    L.TestWinSound()
    return L.CurrentWinSound().name
end

L.SetWinSound = function(name)
    for i, e in ipairs(L.WinSounds) do
        if e.name:lower() == tostring(name):lower() then
            L.WinSoundIndex = i
            save()
            if refreshSoundUI then refreshSoundUI() end
            return true
        end
    end
    -- Anything that is not one of the names is treated as an id to add.
    local id = tostring(name)
    if id:match("^rbxasset") then
        L.WinSounds[#L.WinSounds + 1] = {name = "Custom", id = id}
        L.WinSoundIndex = #L.WinSounds
        save()
        if refreshSoundUI then refreshSoundUI() end
        return true
    end
    print("[LUCK] sounds: " .. (function()
        local out = {}
        for _, e in ipairs(L.WinSounds) do out[#out + 1] = e.name end
        return table.concat(out, ", ")
    end)())
    return false
end

L.SetWinSoundOn = function(on)
    if on == nil then on = not L.WinSoundOn end
    L.WinSoundOn = on and true or false
    save()
    if refreshSoundUI then refreshSoundUI() end
    return L.WinSoundOn
end

-- The hook the base fires once a redeem has been answered.
do
    local prev = L.OnResult
    L.OnResult = function(code, ok, reply, timing)
        if prev then pcall(prev, code, ok, reply, timing) end
        if ok == true then L.PlayWinSound() end
    end
end

-- --------------------------------------------------------------------
-- Panel
-- --------------------------------------------------------------------
local function findGui()
    local parent = L.GuiParent
    if not parent then return nil end
    for _, d in ipairs(parent:GetChildren()) do
        if d:IsA("ScreenGui") and tostring(d.Name):match("^LUCK_%d+$") then
            return d
        end
    end
    return nil
end

local function buildPanel()
    local gui = findGui()
    if not gui then return end
    local P = L.Palette or {}
    local W, H = 214, 116

    local root = Instance.new("Frame")
    root.Name = "LuckSoundPanel"
    root.Size = UDim2.new(0, W, 0, H)
    root.Position = UDim2.new(0, 240, 0, 210)
    root.BackgroundColor3 = P.BG or rgb(8, 17, 11)
    root.BackgroundTransparency = 0.12
    root.BorderSizePixel = 0
    root.Parent = gui
    Instance.new("UICorner", root).CornerRadius = UDim.new(0, 14)
    local edge = Instance.new("UIStroke", root)
    edge.Thickness = 1
    edge.Transparency = 0.5
    edge.Color = P.LINE or rgb(31, 60, 41)

    local header = Instance.new("TextButton")
    header.Size = UDim2.new(1, 0, 0, 28)
    header.BackgroundTransparency = 1
    header.Text = ""
    header.AutoButtonColor = false
    header.Parent = root

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -70, 1, 0)
    title.Position = UDim2.new(0, 12, 0, 0)
    title.BackgroundTransparency = 1
    title.Text = "WIN SOUND"
    title.TextColor3 = P.HIGH or rgb(165, 255, 198)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 11
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = header

    local body = Instance.new("Frame")
    body.Name = "Body"
    body.Size = UDim2.new(1, 0, 1, -28)
    body.Position = UDim2.new(0, 0, 0, 28)
    body.BackgroundTransparency = 1
    body.Parent = root

    local minimized = false
    local minBtn = Instance.new("TextButton")
    minBtn.Size = UDim2.new(0, 18, 0, 18)
    minBtn.Position = UDim2.new(1, -46, 0.5, -9)
    minBtn.BackgroundColor3 = P.RAISED or rgb(17, 36, 23)
    minBtn.Text = "-"
    minBtn.TextColor3 = P.ACCENT or rgb(74, 222, 128)
    minBtn.Font = Enum.Font.GothamBold
    minBtn.TextSize = 12
    minBtn.AutoButtonColor = false
    minBtn.BorderSizePixel = 0
    minBtn.Parent = header
    Instance.new("UICorner", minBtn).CornerRadius = UDim.new(0, 6)

    local hideBtn = Instance.new("TextButton")
    hideBtn.Size = UDim2.new(0, 18, 0, 18)
    hideBtn.Position = UDim2.new(1, -24, 0.5, -9)
    hideBtn.BackgroundColor3 = P.RAISED or rgb(17, 36, 23)
    hideBtn.Text = "x"
    hideBtn.TextColor3 = P.RED or rgb(255, 130, 155)
    hideBtn.Font = Enum.Font.GothamBold
    hideBtn.TextSize = 11
    hideBtn.AutoButtonColor = false
    hideBtn.BorderSizePixel = 0
    hideBtn.Parent = header
    Instance.new("UICorner", hideBtn).CornerRadius = UDim.new(0, 6)

    local function applyMin()
        minBtn.Text = minimized and "+" or "-"
        body.Visible = not minimized
        root.Size = minimized and UDim2.new(0, W, 0, 28) or UDim2.new(0, W, 0, H)
    end
    L.MinimizeSoundPanel = function(on)
        if on == nil then on = not minimized end
        minimized = on and true or false
        applyMin()
        return minimized
    end
    minBtn.MouseButton1Click:Connect(function() L.MinimizeSoundPanel() end)
    hideBtn.MouseButton1Click:Connect(function() root.Visible = false end)
    L.ToggleSoundPanel = function(on)
        if on == nil then on = not root.Visible end
        root.Visible = on and true or false
        return root.Visible
    end

    -- drag, connected only while held
    pcall(function()
        local startAt, startPos, moveConn
        local function release()
            if moveConn then
                pcall(function() moveConn:Disconnect() end)
                moveConn = nil
            end
        end
        header.InputBegan:Connect(function(i)
            if i.UserInputType ~= Enum.UserInputType.MouseButton1
                and i.UserInputType ~= Enum.UserInputType.Touch then return end
            startAt, startPos = i.Position, root.Position
            release()
            moveConn = UIS.InputChanged:Connect(function(m)
                if m.UserInputType ~= Enum.UserInputType.MouseMovement
                    and m.UserInputType ~= Enum.UserInputType.Touch then return end
                local d = m.Position - startAt
                root.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
                                          startPos.Y.Scale, startPos.Y.Offset + d.Y)
            end)
            i.Changed:Connect(function()
                if i.UserInputState == Enum.UserInputState.End then release() end
            end)
        end)
    end)

    -- The name, big enough to read across the room, because the whole point is
    -- being able to say which one you want.
    local nameLabel = Instance.new("TextLabel")
    nameLabel.Size = UDim2.new(1, -84, 0, 26)
    nameLabel.Position = UDim2.new(0, 42, 0, 4)
    nameLabel.BackgroundTransparency = 1
    nameLabel.Text = "Ping"
    nameLabel.TextColor3 = P.TEXT or rgb(228, 246, 233)
    nameLabel.Font = Enum.Font.GothamBold
    nameLabel.TextSize = 15
    nameLabel.Parent = body

    local idLabel = Instance.new("TextLabel")
    idLabel.Size = UDim2.new(1, -24, 0, 10)
    idLabel.Position = UDim2.new(0, 12, 0, 30)
    idLabel.BackgroundTransparency = 1
    idLabel.Text = ""
    idLabel.TextColor3 = P.MUTED or rgb(108, 148, 120)
    idLabel.Font = Enum.Font.GothamSemibold
    idLabel.TextSize = 8
    idLabel.TextTruncate = Enum.TextTruncate.AtEnd
    idLabel.Parent = body

    local function arrow(x, txt, step)
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(0, 26, 0, 26)
        b.Position = UDim2.new(x, x == 0 and 12 or -38, 0, 4)
        b.BackgroundColor3 = P.RAISED or rgb(17, 36, 23)
        b.Text = txt
        b.TextColor3 = P.ACCENT or rgb(74, 222, 128)
        b.Font = Enum.Font.GothamBold
        b.TextSize = 13
        b.AutoButtonColor = false
        b.BorderSizePixel = 0
        b.Parent = body
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 7)
        -- Cycling plays what it lands on, so one button is both "next" and
        -- "let me hear it".
        b.MouseButton1Click:Connect(function() L.NextWinSound(step) end)
        return b
    end
    arrow(0, "<", -1)
    arrow(1, ">", 1)

    local testBtn = Instance.new("TextButton")
    testBtn.Size = UDim2.new(0, 118, 0, 24)
    testBtn.Position = UDim2.new(0, 12, 0, 46)
    testBtn.BackgroundColor3 = P.RAISED or rgb(17, 36, 23)
    testBtn.Text = "TEST"
    testBtn.TextColor3 = P.HIGH or rgb(165, 255, 198)
    testBtn.Font = Enum.Font.GothamBold
    testBtn.TextSize = 11
    testBtn.AutoButtonColor = false
    testBtn.BorderSizePixel = 0
    testBtn.Parent = body
    Instance.new("UICorner", testBtn).CornerRadius = UDim.new(0, 7)
    testBtn.MouseButton1Click:Connect(function() L.TestWinSound() end)

    local onBtn = Instance.new("TextButton")
    onBtn.Size = UDim2.new(0, 60, 0, 24)
    onBtn.Position = UDim2.new(1, -72, 0, 46)
    onBtn.BackgroundColor3 = P.RAISED or rgb(17, 36, 23)
    onBtn.Text = "ON"
    onBtn.TextColor3 = P.ACCENT or rgb(74, 222, 128)
    onBtn.Font = Enum.Font.GothamBold
    onBtn.TextSize = 11
    onBtn.AutoButtonColor = false
    onBtn.BorderSizePixel = 0
    onBtn.Parent = body
    Instance.new("UICorner", onBtn).CornerRadius = UDim.new(0, 7)
    onBtn.MouseButton1Click:Connect(function() L.SetWinSoundOn() end)

    local volTrack = Instance.new("Frame")
    volTrack.Size = UDim2.new(1, -60, 0, 6)
    volTrack.Position = UDim2.new(0, 40, 0, 78)
    volTrack.BackgroundColor3 = P.RAISED or rgb(17, 36, 23)
    volTrack.BorderSizePixel = 0
    volTrack.Parent = body
    Instance.new("UICorner", volTrack).CornerRadius = UDim.new(0, 3)

    local volFill = Instance.new("Frame")
    volFill.Size = UDim2.new(L.WinSoundVolume, 0, 1, 0)
    volFill.BackgroundColor3 = P.ACCENT or rgb(74, 222, 128)
    volFill.BorderSizePixel = 0
    volFill.Parent = volTrack
    Instance.new("UICorner", volFill).CornerRadius = UDim.new(0, 3)

    local volTag = Instance.new("TextLabel")
    volTag.Size = UDim2.new(0, 26, 0, 12)
    volTag.Position = UDim2.new(0, 12, 0, 75)
    volTag.BackgroundTransparency = 1
    volTag.Text = "VOL"
    volTag.TextColor3 = P.MUTED or rgb(108, 148, 120)
    volTag.Font = Enum.Font.GothamBold
    volTag.TextSize = 8
    volTag.Parent = body

    local volGrab = Instance.new("TextButton")
    volGrab.Size = UDim2.new(1, 0, 0, 18)
    volGrab.Position = UDim2.new(0, 0, 0, -6)
    volGrab.BackgroundTransparency = 1
    volGrab.Text = ""
    volGrab.AutoButtonColor = false
    volGrab.Parent = volTrack

    pcall(function()
        local moveConn
        local function release()
            if moveConn then
                pcall(function() moveConn:Disconnect() end)
                moveConn = nil
            end
        end
        local function set(x)
            local origin, width = volTrack.AbsolutePosition.X, volTrack.AbsoluteSize.X
            if width <= 0 then return end
            L.WinSoundVolume = math.clamp((x - origin) / width, 0, 1)
            volFill.Size = UDim2.new(L.WinSoundVolume, 0, 1, 0)
            save()
        end
        volGrab.InputBegan:Connect(function(i)
            if i.UserInputType ~= Enum.UserInputType.MouseButton1
                and i.UserInputType ~= Enum.UserInputType.Touch then return end
            set(i.Position.X)
            release()
            moveConn = UIS.InputChanged:Connect(function(m)
                if m.UserInputType ~= Enum.UserInputType.MouseMovement
                    and m.UserInputType ~= Enum.UserInputType.Touch then return end
                set(m.Position.X)
            end)
            i.Changed:Connect(function()
                if i.UserInputState == Enum.UserInputState.End then release() end
            end)
        end)
    end)

    refreshSoundUI = function()
        local e = L.CurrentWinSound()
        if not e then return end
        local dead = L.WinSoundDead[e.name]
        nameLabel.Text = ("%d/%d  %s"):format(L.WinSoundIndex, #L.WinSounds, e.name)
        nameLabel.TextColor3 = dead and (P.RED or rgb(255, 130, 155))
            or (P.TEXT or rgb(228, 246, 233))
        idLabel.Text = dead and ("did not load  ·  " .. e.id) or e.id
        onBtn.Text = L.WinSoundOn and "ON" or "OFF"
        onBtn.TextColor3 = L.WinSoundOn and (P.ACCENT or rgb(74, 222, 128))
            or (P.MUTED or rgb(108, 148, 120))
        volFill.Size = UDim2.new(L.WinSoundVolume, 0, 1, 0)
    end
    refreshSoundUI()
    applyMin()

    L.SoundPanel = root
end

local function boot()
    buildPanel()
    print(("[LUCK] win sound  ·  %s  ·  %d to choose from")
        :format(L.CurrentWinSound().name, #L.WinSounds))
    print("[LUCK] LUCK.NextWinSound()  ·  LUCK.TestWinSound()  ·  LUCK.SetWinSound(\"Snap\")")
end

if L.WhenReady then
    L.WhenReady(function()
        local ok, err = pcall(boot)
        if not ok then
            L.SoundError = tostring(err)
            warn("[LUCK] win sound panel failed: " .. tostring(err))
        end
    end)
else
    task.defer(function() pcall(boot) end)
end

end
