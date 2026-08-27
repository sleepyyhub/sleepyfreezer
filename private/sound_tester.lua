-- LUCK sound tester
--
-- Click a row to play it and copy its id. Rows that fail to load go red, so a
-- dead id tells you immediately instead of just staying silent.
--
-- rbxasset:// entries ship with the Roblox client itself -- no asset lookup, no
-- moderation, they cannot 404. rbxassetid:// entries are uploaded assets and can.

local Players = game:GetService("Players")
local PG = Players.LocalPlayer:WaitForChild("PlayerGui")
local SoundService = game:GetService("SoundService")

local SOUNDS = {
    {"Ping",        "rbxasset://sounds/electronicpingshort.wav", "clean, short, the classic UI ping"},
    {"Snap",        "rbxasset://sounds/snap.wav",                "dry click, very short"},
    {"Pop",         "rbxasset://sounds/pop_mid_up.wav",          "soft rising pop"},
    {"Button",      "rbxasset://sounds/button.wav",              "flat menu click"},
    {"Switch",      "rbxasset://sounds/switch.wav",              "mechanical toggle"},
    {"Click fast",  "rbxasset://sounds/clickfast.wav",           "tiny tick"},
    {"Bass",        "rbxasset://sounds/bass.wav",                "low thud, heavier"},
    {"Swoosh",      "rbxasset://sounds/swoosh.wav",              "airy sweep"},
    {"Water",       "rbxasset://sounds/impact_water.mp3",        "soft plop"},
    {"Blop",        "rbxassetid://138213892284919",              "from your test sender"},
}

local old = PG:FindFirstChild("LuckSoundTester")
if old then old:Destroy() end

local SG = Instance.new("ScreenGui")
SG.Name = "LuckSoundTester"
SG.ResetOnSpawn = false
SG.DisplayOrder = 300
SG.Parent = PG

local W = Instance.new("Frame")
W.Size = UDim2.new(0, 320, 0, 60 + #SOUNDS * 34)
W.Position = UDim2.new(0.5, -160, 0.5, -(60 + #SOUNDS * 34) / 2)
W.BackgroundColor3 = Color3.fromRGB(10, 12, 14)
W.BorderSizePixel = 0
W.Parent = SG
Instance.new("UICorner", W).CornerRadius = UDim.new(0, 12)

local head = Instance.new("TextLabel")
head.Size = UDim2.new(1, -24, 0, 34)
head.Position = UDim2.new(0, 12, 0, 4)
head.BackgroundTransparency = 1
head.Text = "SOUND TESTER  ·  click to play + copy id"
head.TextColor3 = Color3.fromRGB(150, 255, 190)
head.Font = Enum.Font.GothamBold
head.TextSize = 11
head.TextXAlignment = Enum.TextXAlignment.Left
head.Parent = W

local close = Instance.new("TextButton")
close.Size = UDim2.new(0, 22, 0, 22)
close.Position = UDim2.new(1, -30, 0, 10)
close.BackgroundColor3 = Color3.fromRGB(40, 20, 24)
close.Text = "X"
close.TextColor3 = Color3.fromRGB(255, 130, 150)
close.Font = Enum.Font.GothamBold
close.TextSize = 11
close.BorderSizePixel = 0
close.Parent = W
Instance.new("UICorner", close).CornerRadius = UDim.new(0, 7)
close.MouseButton1Click:Connect(function() SG:Destroy() end)

-- drag
do
    local dragging, startAt, startPos
    head.InputBegan = nil
    W.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging, startAt, startPos = true, i.Position, W.Position
            i.Changed:Connect(function()
                if i.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    game:GetService("UserInputService").InputChanged:Connect(function(i)
        if dragging and i.UserInputType == Enum.UserInputType.MouseMovement then
            local d = i.Position - startAt
            W.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
                                   startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
end

local function makeSound(id)
    local s = Instance.new("Sound")
    s.SoundId = id
    s.Volume = 0.6
    s.Parent = SoundService
    return s
end

print("[sounds] testing " .. #SOUNDS .. " candidates")

for i, entry in ipairs(SOUNDS) do
    local name, id, note = entry[1], entry[2], entry[3]
    local sound = makeSound(id)

    local row = Instance.new("TextButton")
    row.Size = UDim2.new(1, -24, 0, 28)
    row.Position = UDim2.new(0, 12, 0, 42 + (i - 1) * 34)
    row.BackgroundColor3 = Color3.fromRGB(20, 24, 28)
    row.Text = ""
    row.AutoButtonColor = false
    row.BorderSizePixel = 0
    row.Parent = W
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 8)

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -16, 1, 0)
    lbl.Position = UDim2.new(0, 10, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = ("%-11s  %s"):format(name, note)
    lbl.TextColor3 = Color3.fromRGB(225, 235, 240)
    lbl.Font = Enum.Font.GothamSemibold
    lbl.TextSize = 10
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = row

    row.MouseButton1Click:Connect(function()
        sound:Play()
        if type(setclipboard) == "function" then setclipboard(id) end
        print(("[sounds] %s  ->  %s"):format(name, id))
    end)

    -- A dead id never loads. Give it a moment, then mark it so a silent row is
    -- distinguishable from a broken one.
    task.spawn(function()
        local ok = false
        for _ = 1, 25 do
            if sound.IsLoaded or (sound.TimeLength or 0) > 0 then ok = true break end
            task.wait(0.2)
        end
        if not ok then
            row.BackgroundColor3 = Color3.fromRGB(45, 20, 24)
            lbl.TextColor3 = Color3.fromRGB(255, 130, 150)
            lbl.Text = ("%-11s  FAILED TO LOAD"):format(name)
            warn("[sounds] dead: " .. name .. "  " .. id)
        end
    end)
end

print("[sounds] red rows are dead ids. Tell me the name of the one you want.")
