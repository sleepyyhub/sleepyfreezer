
--[[ ====================================================================
     LUCK PRIVATE  ·  sounds

     Two independent slots:

       ANNOUNCE  fires when a code is detected. The game plays
                 Sounds.Sfx.Blop there; this is yours instead, and it can
                 mute the game's.
       REDEEM    fires when a redeem comes back a win. The game has no
                 sound for this at all.

     Each has its own list, its own volume, its own on/off, and a box to
     paste any id you find. Click a row to pick it -- clicking also plays
     it, so choosing and auditioning are the same action.

     rbxasset:// ids are files inside the Roblox client: no lookup, no
     moderation, they cannot 404. Uploaded ids can, so anything that never
     loads is marked instead of just going quiet.
     ==================================================================== ]]

do

local L = (getgenv and getgenv().LUCK) or LUCK
if not L then return end

local UIS = game:GetService("UserInputService")
local rgb = Color3.fromRGB

-- --------------------------------------------------------------------
-- The library
--
-- Everything here is engine-bundled except where marked. If one of these
-- filenames is wrong it shows up red in the list rather than silently doing
-- nothing, which is the only way to tell from inside the game.
-- --------------------------------------------------------------------
local LIBRARY = {
    {name = "Ping",        id = "rbxasset://sounds/electronicpingshort.wav"},
    {name = "Snap",        id = "rbxasset://sounds/snap.wav"},
    {name = "Pop",         id = "rbxasset://sounds/pop_mid_up.wav"},
    {name = "Click",       id = "rbxasset://sounds/clickfast.wav"},
    {name = "Button",      id = "rbxasset://sounds/button.wav"},
    {name = "Switch",      id = "rbxasset://sounds/switch.wav"},
    {name = "Bass",        id = "rbxasset://sounds/bass.wav"},
    {name = "Swoosh",      id = "rbxasset://sounds/swoosh.wav"},
    {name = "Water",       id = "rbxasset://sounds/impact_water.mp3"},
    {name = "Splash",      id = "rbxasset://sounds/splash.wav"},
    {name = "Metal",       id = "rbxasset://sounds/metal.ogg"},
    {name = "Glass",       id = "rbxasset://sounds/glassbreak.wav"},
    {name = "Unsheath",    id = "rbxasset://sounds/unsheath.wav"},
    {name = "Slash",       id = "rbxasset://sounds/swordslash.wav"},
    {name = "Rocket",      id = "rbxasset://sounds/Rocket whoosh 01.wav"},
    {name = "Launch",      id = "rbxasset://sounds/Launching rocket.wav"},
    {name = "Hmm",         id = "rbxasset://sounds/uuhhh.mp3"},
    {name = "Getting up",  id = "rbxasset://sounds/action_get_up.mp3"},
    {name = "Jump",        id = "rbxasset://sounds/action_jump.mp3"},
    {name = "Footstep",    id = "rbxasset://sounds/action_footsteps_plastic.mp3"},
    {name = "Blop",        id = "rbxassetid://138213892284919"},  -- your test sender
    {name = "Silent",      id = ""},
}
L.SoundLibrary = LIBRARY
L.SoundDead = {}

-- --------------------------------------------------------------------
-- The two slots
-- --------------------------------------------------------------------
local SLOTS = {
    {key = "Announce", title = "ANNOUNCE", note = "when a code is spotted",
     default = "Ping",   file = "LUCK/private_snd_announce.txt"},
    {key = "Redeem",   title = "REDEEM",   note = "when a redeem wins",
     default = "Bass",   file = "LUCK/private_snd_redeem.txt"},
}

for _, slot in ipairs(SLOTS) do
    slot.on = true
    slot.volume = 0.55
    slot.index = 1
    for i, e in ipairs(LIBRARY) do
        if e.name == slot.default then slot.index = i break end
    end
end

-- The game plays its own sound on an announcement. Off by default -- silencing
-- the game is a thing to ask for, not something to discover.
L.MuteGameSound = false

local function slotFor(key)
    for _, s in ipairs(SLOTS) do
        if s.key:lower() == tostring(key):lower() then return s end
    end
    return nil
end
L.SoundSlots = SLOTS

local function save(slot)
    pcall(function()
        if type(makefolder) == "function"
            and (type(isfolder) ~= "function" or not isfolder("LUCK")) then
            makefolder("LUCK")
        end
        local e = LIBRARY[slot.index]
        writefile(slot.file, table.concat({
            slot.on and "on" or "off",
            tostring(slot.volume),
            e and e.name or slot.default,
            e and e.id or "",
        }, "\n"))
    end)
end

local function load(slot)
    pcall(function()
        if type(isfile) == "function" and not isfile(slot.file) then return end
        local raw = readfile(slot.file)
        if type(raw) ~= "string" then return end
        local parts = {}
        for line in raw:gmatch("[^\n]*") do parts[#parts + 1] = line end
        if parts[1] then slot.on = parts[1] ~= "off" end
        local v = tonumber(parts[2])
        if v then slot.volume = math.clamp(v, 0, 1) end
        local wantName, wantId = parts[3], parts[4]
        for i, e in ipairs(LIBRARY) do
            if e.name == wantName and e.id == wantId then slot.index = i return end
        end
        -- A custom id saved last session is not in the library yet.
        if wantId and wantId ~= "" and wantName then
            LIBRARY[#LIBRARY + 1] = {name = wantName, id = wantId}
            slot.index = #LIBRARY
        end
    end)
end
for _, slot in ipairs(SLOTS) do load(slot) end

-- One Sound per slot, made once and reused. A fresh Instance per play is an
-- allocation on the result path for something that only plays one clip at a time.
local function ensure(slot)
    if slot.player and slot.player.Parent then return slot.player end
    pcall(function()
        local s = Instance.new("Sound")
        s.Name = "LuckSound" .. slot.key
        s.Volume = slot.volume
        local parent
        pcall(function() parent = game:GetService("SoundService") end)
        s.Parent = parent or L.GuiParent
        slot.player = s
    end)
    return slot.player
end

local refreshUI

local function playSlot(slot, force)
    if not slot then return false end
    if not force and not slot.on then return false end
    local e = LIBRARY[slot.index]
    if not e or e.id == "" then return false end
    local s = ensure(slot)
    if not s then return false end
    pcall(function()
        s.SoundId = e.id
        s.Volume = slot.volume
        s:Play()
    end)
    if force then
        -- A dead id plays nothing and says nothing, which is indistinguishable
        -- from a quiet one. Give it a moment, then mark it.
        task.spawn(function()
            local name = e.name
            for _ = 1, 20 do
                local ok, loaded = pcall(function()
                    return s.IsLoaded or (s.TimeLength or 0) > 0
                end)
                if ok and loaded then
                    if L.SoundDead[name] then
                        L.SoundDead[name] = nil
                        if refreshUI then refreshUI() end
                    end
                    return
                end
                task.wait(0.15)
            end
            L.SoundDead[name] = true
            if refreshUI then refreshUI() end
            warn(("[LUCK] sound '%s' did not load: %s"):format(name, e.id))
        end)
    end
    return true
end

-- --------------------------------------------------------------------
-- API
-- --------------------------------------------------------------------
L.CurrentSound = function(key)
    local slot = slotFor(key)
    return slot and LIBRARY[slot.index] or nil
end

L.TestSound = function(key)
    local slot = slotFor(key)
    if not slot then return false end
    local e = LIBRARY[slot.index]
    print(("[LUCK] %s  ->  %s  %s"):format(slot.title, e and e.name or "?",
        e and e.id or ""))
    -- Ignores the on/off switch: you press test to hear it, not to find out
    -- whether the switch is on.
    return playSlot(slot, true)
end

L.PickSound = function(key, nameOrId)
    local slot = slotFor(key)
    if not slot then return false end
    local want = tostring(nameOrId)
    for i, e in ipairs(LIBRARY) do
        if e.name:lower() == want:lower() then
            slot.index = i
            save(slot)
            if refreshUI then refreshUI() end
            return true
        end
    end
    if want:match("^rbxasset") then
        LIBRARY[#LIBRARY + 1] = {name = "Custom", id = want}
        slot.index = #LIBRARY
        save(slot)
        if refreshUI then refreshUI() end
        return true
    end
    -- A bare number is an uploaded asset.
    if want:match("^%d+$") then
        LIBRARY[#LIBRARY + 1] = {name = "Custom", id = "rbxassetid://" .. want}
        slot.index = #LIBRARY
        save(slot)
        if refreshUI then refreshUI() end
        return true
    end
    local names = {}
    for _, e in ipairs(LIBRARY) do names[#names + 1] = e.name end
    print("[LUCK] sounds: " .. table.concat(names, ", "))
    return false
end

L.NextSound = function(key, step)
    local slot = slotFor(key)
    if not slot then return nil end
    slot.index = ((slot.index - 1 + (step or 1)) % #LIBRARY) + 1
    save(slot)
    if refreshUI then refreshUI() end
    L.TestSound(key)
    return LIBRARY[slot.index].name
end

L.SetSoundOn = function(key, on)
    local slot = slotFor(key)
    if not slot then return nil end
    if on == nil then on = not slot.on end
    slot.on = on and true or false
    save(slot)
    if refreshUI then refreshUI() end
    return slot.on
end

L.SetSoundVolume = function(key, v)
    local slot = slotFor(key)
    if not slot then return nil end
    slot.volume = math.clamp(tonumber(v) or 0, 0, 1)
    save(slot)
    if refreshUI then refreshUI() end
    return slot.volume
end

L.PlayAnnounceSound = function() return playSlot(slotFor("Announce")) end
L.PlayRedeemSound   = function() return playSlot(slotFor("Redeem")) end

L.SoundPrint = function()
    for _, slot in ipairs(SLOTS) do
        local e = LIBRARY[slot.index]
        print(("[LUCK] %-8s  %s  vol %.2f  %s"):format(
            slot.title, slot.on and "on " or "off", slot.volume,
            e and (e.name .. "  " .. e.id) or "?"))
    end
    print("[LUCK] LUCK.PickSound(\"Redeem\", \"Ping\")  ·  LUCK.TestSound(\"Announce\")")
end

-- --------------------------------------------------------------------
-- Hooks
--
-- Both post-send. The announce sound rides L.Note, which the script already
-- calls once a code has gone out; the redeem sound rides L.OnResult. Nothing
-- here runs before a packet leaves.
-- --------------------------------------------------------------------
do
    local prevNote = L.Note
    L.Note = function(name, code, at)
        if prevNote then pcall(prevNote, name, code, at) end
        L.PlayAnnounceSound()
    end

    local prevResult = L.OnResult
    L.OnResult = function(code, ok, reply, timing)
        if prevResult then pcall(prevResult, code, ok, reply, timing) end
        if ok == true then L.PlayRedeemSound() end
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
    local W, H = 250, 336

    local root = Instance.new("Frame")
    root.Name = "LuckSoundPanel"
    root.Size = UDim2.new(0, W, 0, H)
    root.Position = UDim2.new(0, 250, 0, 200)
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
    title.Text = "SOUNDS"
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
    local function headBtn(x, txt, colour)
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(0, 18, 0, 18)
        b.Position = UDim2.new(1, x, 0.5, -9)
        b.BackgroundColor3 = P.RAISED or rgb(17, 36, 23)
        b.Text = txt
        b.TextColor3 = colour
        b.Font = Enum.Font.GothamBold
        b.TextSize = 11
        b.AutoButtonColor = false
        b.BorderSizePixel = 0
        b.Parent = header
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
        return b
    end
    local minBtn  = headBtn(-46, "-", P.ACCENT or rgb(74, 222, 128))
    local hideBtn = headBtn(-24, "x", P.RED or rgb(255, 130, 155))

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

    -- Which slot the list below is editing. Two tabs rather than two lists,
    -- because two copies of twenty-odd rows is forty rows of instances to build
    -- and keep painted for something only one of which is ever looked at.
    local active = SLOTS[1]
    local tabs, rows = {}, {}

    for i, slot in ipairs(SLOTS) do
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(0.5, -16, 0, 26)
        b.Position = UDim2.new(0.5 * (i - 1), i == 1 and 12 or 4, 0, 4)
        b.BackgroundColor3 = P.RAISED or rgb(17, 36, 23)
        b.Text = slot.title
        b.TextColor3 = P.MUTED or rgb(108, 148, 120)
        b.Font = Enum.Font.GothamBold
        b.TextSize = 10
        b.AutoButtonColor = false
        b.BorderSizePixel = 0
        b.Parent = body
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 7)
        b.MouseButton1Click:Connect(function()
            active = slot
            if refreshUI then refreshUI() end
        end)
        tabs[i] = {button = b, slot = slot}
    end

    local noteLbl = Instance.new("TextLabel")
    noteLbl.Size = UDim2.new(1, -24, 0, 11)
    noteLbl.Position = UDim2.new(0, 12, 0, 32)
    noteLbl.BackgroundTransparency = 1
    noteLbl.Text = ""
    noteLbl.TextColor3 = P.MUTED or rgb(108, 148, 120)
    noteLbl.Font = Enum.Font.GothamSemibold
    noteLbl.TextSize = 8
    noteLbl.TextXAlignment = Enum.TextXAlignment.Left
    noteLbl.Parent = body

    -- The list. Scrolling, one row per sound, click to pick AND hear it --
    -- choosing and auditioning are the same action.
    local list = Instance.new("ScrollingFrame")
    list.Size = UDim2.new(1, -24, 0, 160)
    list.Position = UDim2.new(0, 12, 0, 46)
    list.BackgroundColor3 = P.SURFACE or rgb(12, 25, 16)
    list.BackgroundTransparency = 0.35
    list.BorderSizePixel = 0
    list.ScrollBarThickness = 3
    list.CanvasSize = UDim2.new(0, 0, 0, #LIBRARY * 22 + 8)
    list.Parent = body
    Instance.new("UICorner", list).CornerRadius = UDim.new(0, 8)

    for i, entry in ipairs(LIBRARY) do
        local r = Instance.new("TextButton")
        r.Size = UDim2.new(1, -8, 0, 20)
        r.Position = UDim2.new(0, 4, 0, 4 + (i - 1) * 22)
        r.BackgroundColor3 = P.RAISED or rgb(17, 36, 23)
        r.BackgroundTransparency = 1
        r.Text = ""
        r.AutoButtonColor = false
        r.BorderSizePixel = 0
        r.Parent = list
        Instance.new("UICorner", r).CornerRadius = UDim.new(0, 6)

        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(1, -16, 1, 0)
        lbl.Position = UDim2.new(0, 8, 0, 0)
        lbl.BackgroundTransparency = 1
        lbl.Text = entry.name
        lbl.TextColor3 = P.TEXT or rgb(228, 246, 233)
        lbl.Font = Enum.Font.GothamSemibold
        lbl.TextSize = 10
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.Parent = r

        r.MouseButton1Click:Connect(function()
            active.index = i
            save(active)
            if refreshUI then refreshUI() end
            L.TestSound(active.key)
        end)
        rows[i] = {button = r, label = lbl, entry = entry}
    end

    local box = Instance.new("TextBox")
    box.Size = UDim2.new(1, -80, 0, 24)
    box.Position = UDim2.new(0, 12, 0, 214)
    box.BackgroundColor3 = P.SURFACE or rgb(12, 25, 16)
    box.BorderSizePixel = 0
    box.PlaceholderText = "paste an id or asset number…"
    box.PlaceholderColor3 = P.MUTED or rgb(108, 148, 120)
    box.Text = ""
    box.TextColor3 = P.TEXT or rgb(228, 246, 233)
    box.ClearTextOnFocus = false
    box.Font = Enum.Font.GothamSemibold
    box.TextSize = 10
    box.TextXAlignment = Enum.TextXAlignment.Left
    box.Parent = body
    Instance.new("UICorner", box).CornerRadius = UDim.new(0, 7)
    Instance.new("UIPadding", box).PaddingLeft = UDim.new(0, 8)

    local addBtn = Instance.new("TextButton")
    addBtn.Size = UDim2.new(0, 56, 0, 24)
    addBtn.Position = UDim2.new(1, -68, 0, 214)
    addBtn.BackgroundColor3 = P.RAISED or rgb(17, 36, 23)
    addBtn.Text = "ADD"
    addBtn.TextColor3 = P.ACCENT or rgb(74, 222, 128)
    addBtn.Font = Enum.Font.GothamBold
    addBtn.TextSize = 10
    addBtn.AutoButtonColor = false
    addBtn.BorderSizePixel = 0
    addBtn.Parent = body
    Instance.new("UICorner", addBtn).CornerRadius = UDim.new(0, 7)

    local function addFromBox()
        local t = (box.Text or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if t == "" then return end
        box.Text = ""
        if not L.PickSound(active.key, t) then return end
        -- The row for it did not exist when the list was built.
        local i = #LIBRARY
        local entry = LIBRARY[i]
        local r = Instance.new("TextButton")
        r.Size = UDim2.new(1, -8, 0, 20)
        r.Position = UDim2.new(0, 4, 0, 4 + (i - 1) * 22)
        r.BackgroundColor3 = P.RAISED or rgb(17, 36, 23)
        r.Text = ""
        r.AutoButtonColor = false
        r.BorderSizePixel = 0
        r.Parent = list
        Instance.new("UICorner", r).CornerRadius = UDim.new(0, 6)
        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(1, -16, 1, 0)
        lbl.Position = UDim2.new(0, 8, 0, 0)
        lbl.BackgroundTransparency = 1
        lbl.Text = entry.name
        lbl.TextColor3 = P.TEXT or rgb(228, 246, 233)
        lbl.Font = Enum.Font.GothamSemibold
        lbl.TextSize = 10
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.Parent = r
        r.MouseButton1Click:Connect(function()
            active.index = i
            save(active)
            if refreshUI then refreshUI() end
            L.TestSound(active.key)
        end)
        rows[i] = {button = r, label = lbl, entry = entry}
        list.CanvasSize = UDim2.new(0, 0, 0, #LIBRARY * 22 + 8)
        if refreshUI then refreshUI() end
        L.TestSound(active.key)
    end
    addBtn.MouseButton1Click:Connect(addFromBox)
    box.FocusLost:Connect(function(enter) if enter then addFromBox() end end)

    local testBtn = Instance.new("TextButton")
    testBtn.Size = UDim2.new(0, 108, 0, 24)
    testBtn.Position = UDim2.new(0, 12, 0, 244)
    testBtn.BackgroundColor3 = P.RAISED or rgb(17, 36, 23)
    testBtn.Text = "TEST"
    testBtn.TextColor3 = P.HIGH or rgb(165, 255, 198)
    testBtn.Font = Enum.Font.GothamBold
    testBtn.TextSize = 11
    testBtn.AutoButtonColor = false
    testBtn.BorderSizePixel = 0
    testBtn.Parent = body
    Instance.new("UICorner", testBtn).CornerRadius = UDim.new(0, 7)
    testBtn.MouseButton1Click:Connect(function() L.TestSound(active.key) end)

    local onBtn = Instance.new("TextButton")
    onBtn.Size = UDim2.new(0, 108, 0, 24)
    onBtn.Position = UDim2.new(1, -120, 0, 244)
    onBtn.BackgroundColor3 = P.RAISED or rgb(17, 36, 23)
    onBtn.Text = "ON"
    onBtn.TextColor3 = P.ACCENT or rgb(74, 222, 128)
    onBtn.Font = Enum.Font.GothamBold
    onBtn.TextSize = 11
    onBtn.AutoButtonColor = false
    onBtn.BorderSizePixel = 0
    onBtn.Parent = body
    Instance.new("UICorner", onBtn).CornerRadius = UDim.new(0, 7)
    onBtn.MouseButton1Click:Connect(function() L.SetSoundOn(active.key) end)

    local volTag = Instance.new("TextLabel")
    volTag.Size = UDim2.new(0, 26, 0, 12)
    volTag.Position = UDim2.new(0, 12, 0, 274)
    volTag.BackgroundTransparency = 1
    volTag.Text = "VOL"
    volTag.TextColor3 = P.MUTED or rgb(108, 148, 120)
    volTag.Font = Enum.Font.GothamBold
    volTag.TextSize = 8
    volTag.Parent = body

    local volTrack = Instance.new("Frame")
    volTrack.Size = UDim2.new(1, -60, 0, 6)
    volTrack.Position = UDim2.new(0, 40, 0, 277)
    volTrack.BackgroundColor3 = P.RAISED or rgb(17, 36, 23)
    volTrack.BorderSizePixel = 0
    volTrack.Parent = body
    Instance.new("UICorner", volTrack).CornerRadius = UDim.new(0, 3)

    local volFill = Instance.new("Frame")
    volFill.Size = UDim2.new(active.volume, 0, 1, 0)
    volFill.BackgroundColor3 = P.ACCENT or rgb(74, 222, 128)
    volFill.BorderSizePixel = 0
    volFill.Parent = volTrack
    Instance.new("UICorner", volFill).CornerRadius = UDim.new(0, 3)

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
            L.SetSoundVolume(active.key, (x - origin) / width)
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

    local muteBtn = Instance.new("TextButton")
    muteBtn.Size = UDim2.new(1, -24, 0, 22)
    muteBtn.Position = UDim2.new(0, 12, 0, 296)
    muteBtn.BackgroundColor3 = P.RAISED or rgb(17, 36, 23)
    muteBtn.Text = "MUTE THE GAME'S ANNOUNCE SOUND:  OFF"
    muteBtn.TextColor3 = P.MUTED or rgb(108, 148, 120)
    muteBtn.Font = Enum.Font.GothamBold
    muteBtn.TextSize = 9
    muteBtn.AutoButtonColor = false
    muteBtn.BorderSizePixel = 0
    muteBtn.Parent = body
    Instance.new("UICorner", muteBtn).CornerRadius = UDim.new(0, 7)
    muteBtn.MouseButton1Click:Connect(function()
        L.MuteGameSound = not L.MuteGameSound
        if refreshUI then refreshUI() end
    end)

    refreshUI = function()
        for _, t in ipairs(tabs) do
            local on = t.slot == active
            t.button.BackgroundColor3 = on and (P.DEEP or rgb(22, 163, 74))
                or (P.RAISED or rgb(17, 36, 23))
            t.button.TextColor3 = on and (P.HIGH or rgb(165, 255, 198))
                or (P.MUTED or rgb(108, 148, 120))
        end
        noteLbl.Text = active.note
        for i, r in ipairs(rows) do
            local picked = (i == active.index)
            local dead = L.SoundDead[r.entry.name]
            r.button.BackgroundTransparency = picked and 0 or 1
            r.label.TextColor3 = dead and (P.RED or rgb(255, 130, 155))
                or (picked and (P.HIGH or rgb(165, 255, 198)))
                or (P.TEXT or rgb(228, 246, 233))
            r.label.Text = dead and (r.entry.name .. "   (did not load)")
                or r.entry.name
        end
        onBtn.Text = active.on and "ON" or "OFF"
        onBtn.TextColor3 = active.on and (P.ACCENT or rgb(74, 222, 128))
            or (P.MUTED or rgb(108, 148, 120))
        volFill.Size = UDim2.new(active.volume, 0, 1, 0)
        muteBtn.Text = "MUTE THE GAME'S ANNOUNCE SOUND:  "
            .. (L.MuteGameSound and "ON" or "OFF")
        muteBtn.TextColor3 = L.MuteGameSound and (P.ACCENT or rgb(74, 222, 128))
            or (P.MUTED or rgb(108, 148, 120))
    end
    refreshUI()
    applyMin()
    L.SoundPanel = root
end

local function boot()
    buildPanel()
    print(("[LUCK] sounds  ·  %d in the list  ·  announce %s, redeem %s"):format(
        #LIBRARY,
        (L.CurrentSound("Announce") or {}).name or "?",
        (L.CurrentSound("Redeem") or {}).name or "?"))
end

if L.WhenReady then
    L.WhenReady(function()
        local ok, err = pcall(boot)
        if not ok then
            L.SoundError = tostring(err)
            warn("[LUCK] sound panel failed: " .. tostring(err))
        end
    end)
else
    task.defer(function() pcall(boot) end)
end

end
