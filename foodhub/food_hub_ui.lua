--[[
    Food Hub — Redeemer UI (redesign)
    Roblox / Luau — executor-side LocalScript
    Run: paste into your executor and execute, or loadstring this file.

    Exposes getgenv().FoodHub_API for your backend script:
        :SetStatus(text, color)
        :Log(text, color)          -- appends a line to the console
        :GetSettings()             -- live settings table
        :OnToggle(name, fn)        -- fires fn(state) when a switch flips
        :SetToggle(name, state)    -- flip a switch from code (no callback loop)
--]]

local Players            = game:GetService("Players")
local UserInputService   = game:GetService("UserInputService")
local TweenService       = game:GetService("TweenService")
local RunService         = game:GetService("RunService")
local Lighting           = game:GetService("Lighting")
local Terrain            = workspace:FindFirstChildOfClass("Terrain")

local setClip = (setclipboard or toclipboard or (syn and syn.clipboard))
local LP      = Players.LocalPlayer
local PGui    = LP:WaitForChild("PlayerGui")

-- ==================================================================
-- THEME
-- ==================================================================
local T = {
    Black    = Color3.fromRGB(11, 11, 13),
    Panel    = Color3.fromRGB(17, 17, 20),
    Raised   = Color3.fromRGB(25, 25, 29),
    Line     = Color3.fromRGB(38, 38, 43),
    Gold     = Color3.fromRGB(255, 205, 0),
    GoldDeep = Color3.fromRGB(196, 148, 0),
    GoldSoft = Color3.fromRGB(255, 231, 138),
    Text     = Color3.fromRGB(236, 236, 240),
    Dim      = Color3.fromRGB(122, 122, 132),
    Off      = Color3.fromRGB(46, 46, 52),
}

local FONT      = Enum.Font.GothamBold
local FONT_MED  = Enum.Font.GothamMedium
local FONT_MONO = Enum.Font.Code

local EASE  = TweenInfo.new(0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local SNAP  = TweenInfo.new(0.30, Enum.EasingStyle.Back,  Enum.EasingDirection.Out)
local SLOW  = TweenInfo.new(0.45, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

local function tw(obj, info, props) local t = TweenService:Create(obj, info, props) t:Play() return t end
local function corner(p, r) local c = Instance.new("UICorner") c.CornerRadius = UDim.new(0, r) c.Parent = p return c end
local function pad(p, l, r, t, b)
    local u = Instance.new("UIPadding")
    u.PaddingLeft, u.PaddingRight = UDim.new(0, l), UDim.new(0, r)
    u.PaddingTop,  u.PaddingBottom = UDim.new(0, t), UDim.new(0, b)
    u.Parent = p return u
end
local function stroke(p, color, thick, trans)
    local s = Instance.new("UIStroke")
    s.Color = color or T.Line
    s.Thickness = thick or 1
    s.Transparency = trans or 0
    s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    s.Parent = p return s
end

-- ==================================================================
-- SETTINGS
-- ==================================================================
local S = {
    sniper       = true,
    autoSubmit   = true,
    retryInvalid = false,
    autoRedeem   = false,
    redeemAmount = 1,
    sendDelay    = 3,
    antiLag      = false,
    fpsBoost     = false,
    autoBuy      = false,
}

local toggleHandles = {}   -- name -> {set = fn, get = fn}
local userHooks     = {}   -- name -> fn

-- ==================================================================
-- CLEANUP OLD INSTANCE
-- ==================================================================
pcall(function()
    for _, root in ipairs({ (gethui and gethui()) or game:GetService("CoreGui"), PGui }) do
        local old = root and root:FindFirstChild("FoodHubInterface")
        if old then old:Destroy() end
    end
end)

-- ==================================================================
-- ROOT
-- ==================================================================
local Gui = Instance.new("ScreenGui")
Gui.Name = "FoodHubInterface"
Gui.ResetOnSpawn = false
Gui.IgnoreGuiInset = true
Gui.DisplayOrder = 9999
Gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
if gethui then
    pcall(function() Gui.Parent = gethui() end)
end
if not Gui.Parent then
    if not pcall(function() Gui.Parent = game:GetService("CoreGui") end) then Gui.Parent = PGui end
end

local W, H = 306, 560

-- soft drop shadow behind everything
local Shadow = Instance.new("ImageLabel")
Shadow.Name = "Shadow"
Shadow.AnchorPoint = Vector2.new(0.5, 0.5)
Shadow.BackgroundTransparency = 1
Shadow.Image = "rbxassetid://6014261993"
Shadow.ImageColor3 = Color3.new(0, 0, 0)
Shadow.ImageTransparency = 0.45
Shadow.ScaleType = Enum.ScaleType.Slice
Shadow.SliceCenter = Rect.new(49, 49, 450, 450)
Shadow.ZIndex = 0

local Window = Instance.new("Frame")
Window.Name = "Window"
Window.Size = UDim2.new(0, W, 0, H)
Window.Position = UDim2.new(1, -(W + 28), 0.5, -(H / 2))
Window.BackgroundColor3 = T.Black
Window.BorderSizePixel = 0
Window.Active = true
Window.ClipsDescendants = false
Window.Parent = Gui
corner(Window, 14)

Shadow.Size = UDim2.new(1, 60, 1, 60)
Shadow.Position = UDim2.new(0.5, 0, 0.5, 4)
Shadow.Parent = Window

-- animated gold hairline border
local Border = stroke(Window, T.Gold, 1.4, 0.15)
local BorderGrad = Instance.new("UIGradient")
BorderGrad.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0.00, T.GoldDeep),
    ColorSequenceKeypoint.new(0.35, T.GoldSoft),
    ColorSequenceKeypoint.new(0.50, T.Gold),
    ColorSequenceKeypoint.new(0.75, T.GoldDeep),
    ColorSequenceKeypoint.new(1.00, T.GoldSoft),
})
BorderGrad.Parent = Border

task.spawn(function()
    while Border.Parent do
        BorderGrad.Rotation = (BorderGrad.Rotation + 1) % 360
        RunService.RenderStepped:Wait()
    end
end)

-- open animation
local scale = Instance.new("UIScale")
scale.Scale = 0.9
scale.Parent = Window
Window.BackgroundTransparency = 1
tw(scale, SNAP, { Scale = 1 })
tw(Window, SLOW, { BackgroundTransparency = 0 })

-- ==================================================================
-- HEADER
-- ==================================================================
local Header = Instance.new("Frame")
Header.Name = "Header"
Header.Size = UDim2.new(1, 0, 0, 44)
Header.BackgroundColor3 = T.Panel
Header.BorderSizePixel = 0
Header.Active = true
Header.Parent = Window
corner(Header, 14)

local HeaderFoot = Instance.new("Frame")   -- squares off the bottom corners
HeaderFoot.Size = UDim2.new(1, 0, 0, 14)
HeaderFoot.Position = UDim2.new(0, 0, 1, -14)
HeaderFoot.BackgroundColor3 = T.Panel
HeaderFoot.BorderSizePixel = 0
HeaderFoot.Parent = Header

local HeaderLine = Instance.new("Frame")
HeaderLine.Size = UDim2.new(1, 0, 0, 1)
HeaderLine.Position = UDim2.new(0, 0, 1, -1)
HeaderLine.BackgroundColor3 = T.Gold
HeaderLine.BackgroundTransparency = 0.55
HeaderLine.BorderSizePixel = 0
HeaderLine.ZIndex = 3
HeaderLine.Parent = Header

-- gold accent block on the left of the title
local Mark = Instance.new("Frame")
Mark.Size = UDim2.new(0, 3, 0, 16)
Mark.Position = UDim2.new(0, 16, 0, 14)
Mark.BackgroundColor3 = T.Gold
Mark.BorderSizePixel = 0
Mark.Parent = Header
corner(Mark, 2)

local Title = Instance.new("TextLabel")
Title.Name = "Title"
Title.Size = UDim2.new(0, 200, 0, 18)
Title.Position = UDim2.new(0, 28, 0, 13)
Title.BackgroundTransparency = 1
Title.Text = "Food Hub"
Title.TextColor3 = T.Gold
Title.Font = Enum.Font.GothamBold
Title.TextSize = 15
Title.TextXAlignment = Enum.TextXAlignment.Left
Title.Parent = Header

local Version = Instance.new("TextLabel")
Version.Size = UDim2.new(0, 60, 0, 12)
Version.Position = UDim2.new(0, 100, 0, 16)
Version.BackgroundTransparency = 1
Version.Text = "v2"
Version.TextColor3 = T.Dim
Version.Font = FONT_MED
Version.TextSize = 10
Version.TextXAlignment = Enum.TextXAlignment.Left
Version.Parent = Header

-- window buttons
local function headerButton(text, xOff, onClick)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0, 22, 0, 22)
    b.Position = UDim2.new(1, xOff, 0, 11)
    b.BackgroundColor3 = T.Raised
    b.BorderSizePixel = 0
    b.Text = text
    b.TextColor3 = T.Dim
    b.Font = FONT
    b.TextSize = 13
    b.AutoButtonColor = false
    b.Parent = Header
    corner(b, 6)
    b.MouseEnter:Connect(function()
        tw(b, EASE, { BackgroundColor3 = T.Gold })
        tw(b, EASE, { TextColor3 = T.Black })
    end)
    b.MouseLeave:Connect(function()
        tw(b, EASE, { BackgroundColor3 = T.Raised })
        tw(b, EASE, { TextColor3 = T.Dim })
    end)
    b.MouseButton1Click:Connect(onClick)
    return b
end

local Body = Instance.new("Frame")
Body.Name = "Body"
Body.Size = UDim2.new(1, 0, 1, -44)
Body.Position = UDim2.new(0, 0, 0, 44)
Body.BackgroundTransparency = 1
Body.ClipsDescendants = true
Body.Parent = Window

local minimized = false
headerButton("–", -48, function()
    minimized = not minimized
    Body.Visible = true
    if minimized then
        tw(Window, EASE, { Size = UDim2.new(0, W, 0, 44) })
        task.delay(0.22, function() if minimized then Body.Visible = false end end)
    else
        tw(Window, EASE, { Size = UDim2.new(0, W, 0, H) })
    end
end)

headerButton("✕", -22, function()
    tw(scale, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Scale = 0.9 })
    tw(Window, TweenInfo.new(0.18), { BackgroundTransparency = 1 })
    task.delay(0.2, function() Gui:Destroy() end)
end)

-- ==================================================================
-- TABS
-- ==================================================================
local TabBar = Instance.new("Frame")
TabBar.Size = UDim2.new(1, -24, 0, 30)
TabBar.Position = UDim2.new(0, 12, 0, 10)
TabBar.BackgroundColor3 = T.Panel
TabBar.BorderSizePixel = 0
TabBar.Parent = Body
corner(TabBar, 8)

local TabGlider = Instance.new("Frame")
local TAB_COUNT = 3
local TAB_W = 1 / TAB_COUNT
TabGlider.Size = UDim2.new(TAB_W, -6, 1, -6)
TabGlider.Position = UDim2.new(0, 3, 0, 3)
TabGlider.BackgroundColor3 = T.Gold
TabGlider.BorderSizePixel = 0
TabGlider.Parent = TabBar
corner(TabGlider, 6)

local Pages = Instance.new("Frame")
Pages.Size = UDim2.new(1, 0, 1, -50)
Pages.Position = UDim2.new(0, 0, 0, 48)
Pages.BackgroundTransparency = 1
Pages.ClipsDescendants = true
Pages.Parent = Body

local pageList, tabButtons, activeTab = {}, {}, 1

local function selectTab(index)
    if index == activeTab then return end
    local dir = index > activeTab and 1 or -1
    local old = pageList[activeTab]
    local new = pageList[index]

    tw(TabGlider, EASE, { Position = UDim2.new(TAB_W * (index - 1), 3, 0, 3) })
    for i, b in ipairs(tabButtons) do
        tw(b, EASE, { TextColor3 = (i == index) and T.Black or T.Dim })
    end

    new.Position = UDim2.new(0, dir * 26, 0, 0)
    new.Visible = true
    tw(new, EASE, { Position = UDim2.new(0, 0, 0, 0) })
    tw(old, EASE, { Position = UDim2.new(0, -dir * 26, 0, 0) })
    task.delay(0.22, function()
        if activeTab ~= index then return end
        old.Visible = false
    end)

    activeTab = index
end

local function makeTab(name, index)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(TAB_W, -6, 1, -6)
    b.Position = UDim2.new(TAB_W * (index - 1), 3, 0, 3)
    b.BackgroundTransparency = 1
    b.Text = name
    b.TextColor3 = (index == 1) and T.Black or T.Dim
    b.Font = FONT_MED
    b.TextSize = 11
    b.AutoButtonColor = false
    b.ZIndex = 2
    b.Parent = TabBar
    b.MouseButton1Click:Connect(function() selectTab(index) end)
    tabButtons[index] = b

    local page = Instance.new("Frame")
    page.Name = name .. "Page"
    page.Size = UDim2.new(1, 0, 1, 0)
    page.BackgroundTransparency = 1
    page.Visible = (index == 1)
    page.Parent = Pages
    pad(page, 12, 12, 0, 0)
    pageList[index] = page
    return page
end

local RedeemPage   = makeTab("Redeemer",  1)
local MechanicPage = makeTab("Mechanics", 2)
local RiddlePage   = makeTab("AI Riddle", 3)

-- ==================================================================
-- WIDGETS
-- ==================================================================
-- flat button with hover fill and gold border
local function flatButton(parent, text, size, pos, onClick)
    local b = Instance.new("TextButton")
    b.Size = size
    b.Position = pos
    b.BackgroundColor3 = T.Panel
    b.BorderSizePixel = 0
    b.Text = text
    b.TextColor3 = T.Gold
    b.Font = FONT_MED
    b.TextSize = 11
    b.AutoButtonColor = false
    b.ClipsDescendants = true
    b.Parent = parent
    corner(b, 6)
    local line = stroke(b, T.GoldDeep, 1, 0.55)
    b.MouseEnter:Connect(function()
        tw(b, EASE, { BackgroundColor3 = T.Raised })
        tw(line, EASE, { Transparency = 0.15 })
    end)
    b.MouseLeave:Connect(function()
        tw(b, EASE, { BackgroundColor3 = T.Panel })
        tw(line, EASE, { Transparency = 0.55 })
    end)
    if onClick then b.MouseButton1Click:Connect(onClick) end
    return b, line
end
local function sectionLabel(parent, text, y)
    local l = Instance.new("TextLabel")
    l.Size = UDim2.new(1, 0, 0, 12)
    l.Position = UDim2.new(0, 2, 0, y)
    l.BackgroundTransparency = 1
    l.Text = text
    l.TextColor3 = T.Dim
    l.Font = FONT_MED
    l.TextSize = 10
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Parent = parent
    return l
end

-- one settings row: label + sliding switch, with hover lift
local function switchRow(parent, key, label, y)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 32)
    row.Position = UDim2.new(0, 0, 0, y)
    row.BackgroundColor3 = T.Panel
    row.BackgroundTransparency = 0.25
    row.BorderSizePixel = 0
    row.Parent = parent
    corner(row, 8)
    local rowLine = stroke(row, T.Line, 1, 0.25)

    local name = Instance.new("TextLabel")
    name.Size = UDim2.new(1, -68, 0, 13)
    name.Position = UDim2.new(0, 12, 0, 9)
    name.BackgroundTransparency = 1
    name.Text = label
    name.TextColor3 = T.Text
    name.Font = FONT_MED
    name.TextSize = 12
    name.TextXAlignment = Enum.TextXAlignment.Left
    name.Parent = row

    local track = Instance.new("TextButton")
    track.Size = UDim2.new(0, 34, 0, 18)
    track.Position = UDim2.new(1, -46, 0.5, -9)
    track.BackgroundColor3 = S[key] and T.Gold or T.Off
    track.BorderSizePixel = 0
    track.Text = ""
    track.AutoButtonColor = false
    track.Parent = row
    corner(track, 9)

    local knob = Instance.new("Frame")
    knob.Size = UDim2.new(0, 12, 0, 12)
    knob.Position = S[key] and UDim2.new(1, -15, 0.5, -6) or UDim2.new(0, 3, 0.5, -6)
    knob.BackgroundColor3 = S[key] and T.Black or Color3.fromRGB(150, 150, 158)
    knob.BorderSizePixel = 0
    knob.Parent = track
    corner(knob, 6)

    -- gold bloom that fades in when the switch is on
    local glow = stroke(row, T.Gold, 1, S[key] and 0.55 or 1)

    local function apply(state, fire)
        S[key] = state
        tw(track, EASE, { BackgroundColor3 = state and T.Gold or T.Off })
        tw(knob, SNAP, {
            Position = state and UDim2.new(1, -15, 0.5, -6) or UDim2.new(0, 3, 0.5, -6),
            BackgroundColor3 = state and T.Black or Color3.fromRGB(150, 150, 158),
        })
        tw(glow, EASE, { Transparency = state and 0.55 or 1 })
        if fire and userHooks[key] then task.spawn(userHooks[key], state) end
    end

    track.MouseButton1Click:Connect(function() apply(not S[key], true) end)

    row.MouseEnter:Connect(function()
        tw(row, EASE, { BackgroundTransparency = 0.05 })
        tw(rowLine, EASE, { Color = T.GoldDeep, Transparency = 0.4 })
    end)
    row.MouseLeave:Connect(function()
        tw(row, EASE, { BackgroundTransparency = 0.25 })
        tw(rowLine, EASE, { Color = T.Line, Transparency = 0.25 })
    end)

    toggleHandles[key] = { set = apply }
    return row
end

-- ==================================================================
-- REDEEMER PAGE
-- ==================================================================
local StatusCard = Instance.new("Frame")
StatusCard.Size = UDim2.new(1, 0, 0, 32)
StatusCard.Position = UDim2.new(0, 0, 0, 0)
StatusCard.BackgroundColor3 = T.Panel
StatusCard.BorderSizePixel = 0
StatusCard.Parent = RedeemPage
corner(StatusCard, 8)
stroke(StatusCard, T.Line, 1, 0.3)

local StatusDot = Instance.new("Frame")
StatusDot.Size = UDim2.new(0, 6, 0, 6)
StatusDot.Position = UDim2.new(0, 12, 0.5, -3)
StatusDot.BackgroundColor3 = T.Gold
StatusDot.BorderSizePixel = 0
StatusDot.Parent = StatusCard
corner(StatusDot, 3)

local StatusText = Instance.new("TextLabel")
StatusText.Size = UDim2.new(1, -80, 1, 0)
StatusText.Position = UDim2.new(0, 26, 0, 0)
StatusText.BackgroundTransparency = 1
StatusText.Text = S.sniper and "Active" or "Idle"
StatusText.TextColor3 = S.sniper and T.Gold or T.Dim
StatusText.Font = FONT
StatusText.TextSize = 11
StatusText.TextXAlignment = Enum.TextXAlignment.Left
StatusText.Parent = StatusCard

local CodeCount = Instance.new("TextLabel")
CodeCount.Size = UDim2.new(0, 70, 1, 0)
CodeCount.Position = UDim2.new(1, -82, 0, 0)
CodeCount.BackgroundTransparency = 1
CodeCount.Text = "0 codes"
CodeCount.TextColor3 = T.Dim
CodeCount.Font = FONT_MONO
CodeCount.TextSize = 10
CodeCount.TextXAlignment = Enum.TextXAlignment.Right
CodeCount.Parent = StatusCard

sectionLabel(RedeemPage, "Sniper", 42)
switchRow(RedeemPage, "sniper",       "Code Sniper",     58)
switchRow(RedeemPage, "autoSubmit",   "Auto Submit",     94)
switchRow(RedeemPage, "retryInvalid", "Retype Invalid", 130)
switchRow(RedeemPage, "autoRedeem",   "Auto Redeem on", 166)

-- redeem amount: 1-5 presets plus a custom stepper
sectionLabel(RedeemPage, "Amount", 206)

local AMOUNT_PRESETS = { 1, 2, 3, 4, 5 }
local chipButtons, CustomChip = {}, nil

local AmountRow = Instance.new("Frame")
AmountRow.Size = UDim2.new(1, 0, 0, 24)
AmountRow.Position = UDim2.new(0, 0, 0, 222)
AmountRow.BackgroundTransparency = 1
AmountRow.Parent = RedeemPage

local AmountBar = Instance.new("Frame")
AmountBar.Size = UDim2.new(1, 0, 0, 30)
AmountBar.Position = UDim2.new(0, 0, 0, 252)
AmountBar.BackgroundColor3 = T.Panel
AmountBar.BackgroundTransparency = 0.25
AmountBar.BorderSizePixel = 0
AmountBar.Parent = RedeemPage
corner(AmountBar, 8)
stroke(AmountBar, T.Line, 1, 0.25)

local AmountCaption = Instance.new("TextLabel")
AmountCaption.Size = UDim2.new(1, -100, 1, 0)
AmountCaption.Position = UDim2.new(0, 12, 0, 0)
AmountCaption.BackgroundTransparency = 1
AmountCaption.Text = "Codes per drop"
AmountCaption.TextColor3 = T.Text
AmountCaption.Font = FONT_MED
AmountCaption.TextSize = 12
AmountCaption.TextXAlignment = Enum.TextXAlignment.Left
AmountCaption.Parent = AmountBar

local AmountStepper = Instance.new("Frame")
AmountStepper.Size = UDim2.new(0, 82, 0, 20)
AmountStepper.Position = UDim2.new(1, -94, 0.5, -10)
AmountStepper.BackgroundColor3 = T.Raised
AmountStepper.BorderSizePixel = 0
AmountStepper.Parent = AmountBar
corner(AmountStepper, 6)

local AmountValue = Instance.new("TextLabel")
AmountValue.Size = UDim2.new(0, 40, 1, 0)
AmountValue.Position = UDim2.new(0, 21, 0, 0)
AmountValue.BackgroundTransparency = 1
AmountValue.Text = tostring(S.redeemAmount)
AmountValue.TextColor3 = T.Gold
AmountValue.Font = FONT
AmountValue.TextSize = 11
AmountValue.Parent = AmountStepper

local function refreshAmount()
    AmountValue.Text = tostring(S.redeemAmount)
    AmountValue.TextTransparency = 0.6
    tw(AmountValue, EASE, { TextTransparency = 0 })

    local matched
    for i, v in ipairs(AMOUNT_PRESETS) do
        if v == S.redeemAmount then matched = i end
    end
    for i, b in ipairs(chipButtons) do
        local on = (i == matched)
        tw(b, EASE, { BackgroundColor3 = on and T.Gold or T.Panel, TextColor3 = on and T.Black or T.Dim })
    end
    if CustomChip then
        local on = (matched == nil)
        tw(CustomChip, EASE, { BackgroundColor3 = on and T.Gold or T.Panel, TextColor3 = on and T.Black or T.Dim })
    end
end

local function amountButton(text, posX, delta)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0, 21, 1, 0)
    b.Position = UDim2.new(0, posX, 0, 0)
    b.BackgroundTransparency = 1
    b.Text = text
    b.TextColor3 = T.Gold
    b.Font = FONT
    b.TextSize = 14
    b.AutoButtonColor = false
    b.Parent = AmountStepper
    b.MouseButton1Click:Connect(function()
        S.redeemAmount = math.clamp(S.redeemAmount + delta, 1, 999)
        refreshAmount()
    end)
    b.MouseEnter:Connect(function() tw(b, EASE, { TextColor3 = T.GoldSoft }) end)
    b.MouseLeave:Connect(function() tw(b, EASE, { TextColor3 = T.Gold }) end)
end
amountButton("−", 0, -1)
amountButton("+", 61, 1)

-- chips: 1 2 3 4 5 Custom
local CHIP_N = #AMOUNT_PRESETS + 1
local CHIP_W = 1 / CHIP_N

local function makeChip(text, index)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(CHIP_W, -3, 1, 0)
    b.Position = UDim2.new(CHIP_W * (index - 1), 0, 0, 0)
    b.BackgroundColor3 = T.Panel
    b.BorderSizePixel = 0
    b.Text = text
    b.TextColor3 = T.Dim
    b.Font = FONT_MED
    b.TextSize = 10
    b.AutoButtonColor = false
    b.Parent = AmountRow
    corner(b, 6)
    stroke(b, T.Line, 1, 0.35)
    return b
end

for i, v in ipairs(AMOUNT_PRESETS) do
    local b = makeChip(tostring(v), i)
    b.MouseButton1Click:Connect(function()
        S.redeemAmount = v
        refreshAmount()
    end)
    chipButtons[i] = b
end

CustomChip = makeChip("Custom", CHIP_N)
CustomChip.MouseButton1Click:Connect(function()
    -- step off the presets so the stepper owns the value
    if S.redeemAmount <= 5 then S.redeemAmount = 6 end
    refreshAmount()
end)

refreshAmount()

-- delay stepper
local DelayRow = Instance.new("Frame")
DelayRow.Size = UDim2.new(1, 0, 0, 32)
DelayRow.Position = UDim2.new(0, 0, 0, 292)
DelayRow.BackgroundColor3 = T.Panel
DelayRow.BackgroundTransparency = 0.25
DelayRow.BorderSizePixel = 0
DelayRow.Parent = RedeemPage
corner(DelayRow, 8)
stroke(DelayRow, T.Line, 1, 0.25)

local DelayLabel = Instance.new("TextLabel")
DelayLabel.Size = UDim2.new(1, -100, 1, 0)
DelayLabel.Position = UDim2.new(0, 12, 0, 0)
DelayLabel.BackgroundTransparency = 1
DelayLabel.Text = "Wait before send"
DelayLabel.TextColor3 = T.Text
DelayLabel.Font = FONT_MED
DelayLabel.TextSize = 12
DelayLabel.TextXAlignment = Enum.TextXAlignment.Left
DelayLabel.Parent = DelayRow

local Stepper = Instance.new("Frame")
Stepper.Size = UDim2.new(0, 82, 0, 22)
Stepper.Position = UDim2.new(1, -94, 0.5, -11)
Stepper.BackgroundColor3 = T.Raised
Stepper.BorderSizePixel = 0
Stepper.Parent = DelayRow
corner(Stepper, 6)

local DelayValue = Instance.new("TextLabel")
DelayValue.Size = UDim2.new(0, 40, 1, 0)
DelayValue.Position = UDim2.new(0, 21, 0, 0)
DelayValue.BackgroundTransparency = 1
DelayValue.Text = S.sendDelay .. "s"
DelayValue.TextColor3 = T.Gold
DelayValue.Font = FONT
DelayValue.TextSize = 11
DelayValue.Parent = Stepper

local function stepButton(text, posX, delta)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0, 21, 1, 0)
    b.Position = UDim2.new(0, posX, 0, 0)
    b.BackgroundTransparency = 1
    b.Text = text
    b.TextColor3 = T.Gold
    b.Font = FONT
    b.TextSize = 14
    b.AutoButtonColor = false
    b.Parent = Stepper
    b.MouseButton1Click:Connect(function()
        S.sendDelay = math.clamp(S.sendDelay + delta, 0, 60)
        DelayValue.Text = S.sendDelay .. "s"
        DelayValue.TextTransparency = 0.6
        tw(DelayValue, EASE, { TextTransparency = 0 })
    end)
    b.MouseEnter:Connect(function() tw(b, EASE, { TextColor3 = T.GoldSoft }) end)
    b.MouseLeave:Connect(function() tw(b, EASE, { TextColor3 = T.Gold }) end)
    return b
end
stepButton("−", 0, -1)
stepButton("+", 61, 1)

-- console
sectionLabel(RedeemPage, "Console", 336)

local ClearBox = flatButton(RedeemPage, "Clear Box", UDim2.new(0, 66, 0, 17), UDim2.new(1, -66, 0, 333))
ClearBox.TextSize = 10

local Console = Instance.new("Frame")
Console.Size = UDim2.new(1, 0, 0, 84)
Console.Position = UDim2.new(0, 0, 0, 352)
Console.BackgroundColor3 = Color3.fromRGB(9, 9, 11)
Console.BorderSizePixel = 0
Console.ClipsDescendants = true
Console.Parent = RedeemPage
corner(Console, 8)
stroke(Console, T.Line, 1, 0.3)

local ConsoleScroll = Instance.new("ScrollingFrame")
ConsoleScroll.Size = UDim2.new(1, 0, 1, 0)
ConsoleScroll.BackgroundTransparency = 1
ConsoleScroll.BorderSizePixel = 0
ConsoleScroll.ScrollBarThickness = 2
ConsoleScroll.ScrollBarImageColor3 = T.GoldDeep
ConsoleScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
ConsoleScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
ConsoleScroll.ScrollingDirection = Enum.ScrollingDirection.Y
ConsoleScroll.Parent = Console
pad(ConsoleScroll, 8, 8, 6, 6)

local ConsoleList = Instance.new("UIListLayout")
ConsoleList.Padding = UDim.new(0, 2)
ConsoleList.SortOrder = Enum.SortOrder.LayoutOrder
ConsoleList.Parent = ConsoleScroll

local logIndex = 0
local function pushLog(text, color)
    logIndex += 1
    local line = Instance.new("TextLabel")
    line.Size = UDim2.new(1, 0, 0, 13)
    line.BackgroundTransparency = 1
    line.Text = tostring(text)
    line.TextColor3 = color or Color3.fromRGB(178, 178, 188)
    line.Font = FONT_MONO
    line.TextSize = 11
    line.TextXAlignment = Enum.TextXAlignment.Left
    line.TextTruncate = Enum.TextTruncate.AtEnd
    line.LayoutOrder = logIndex
    line.TextTransparency = 1
    line.Parent = ConsoleScroll
    tw(line, EASE, { TextTransparency = 0 })

    -- keep it light: trim to the last 40 lines
    local kids = ConsoleScroll:GetChildren()
    if #kids > 42 then
        local oldest, order = nil, math.huge
        for _, k in ipairs(kids) do
            if k:IsA("TextLabel") and k.LayoutOrder < order then oldest, order = k, k.LayoutOrder end
        end
        if oldest then oldest:Destroy() end
    end

    task.defer(function()
        ConsoleScroll.CanvasPosition = Vector2.new(0, ConsoleScroll.AbsoluteCanvasSize.Y)
    end)
end

pushLog(S.sniper and "waiting for codes" or "sniper off", T.Dim)

ClearBox.MouseButton1Click:Connect(function()
    for _, k in ipairs(ConsoleScroll:GetChildren()) do
        if k:IsA("TextLabel") then k:Destroy() end
    end
    logIndex = 0
    ConsoleScroll.CanvasPosition = Vector2.new(0, 0)
end)

-- discord
local Discord = Instance.new("TextButton")
Discord.Size = UDim2.new(1, 0, 0, 28)
Discord.Position = UDim2.new(0, 0, 0, 444)
Discord.BackgroundColor3 = T.Panel
Discord.BorderSizePixel = 0
Discord.Text = "discord.gg/zYgRUCVv7D"
Discord.TextColor3 = T.Gold
Discord.Font = FONT
Discord.TextSize = 11
Discord.AutoButtonColor = false
Discord.ClipsDescendants = true
Discord.Parent = RedeemPage
corner(Discord, 8)
local DiscordLine = stroke(Discord, T.GoldDeep, 1, 0.5)

Discord.MouseEnter:Connect(function()
    tw(Discord, EASE, { BackgroundColor3 = T.Raised })
    tw(DiscordLine, EASE, { Transparency = 0.1 })
end)
Discord.MouseLeave:Connect(function()
    tw(Discord, EASE, { BackgroundColor3 = T.Panel })
    tw(DiscordLine, EASE, { Transparency = 0.5 })
end)

-- click ripple
local function ripple(button, x, y)
    local r = Instance.new("Frame")
    r.AnchorPoint = Vector2.new(0.5, 0.5)
    r.Position = UDim2.new(0, x - button.AbsolutePosition.X, 0, y - button.AbsolutePosition.Y)
    r.Size = UDim2.new(0, 0, 0, 0)
    r.BackgroundColor3 = T.Gold
    r.BackgroundTransparency = 0.7
    r.BorderSizePixel = 0
    r.ZIndex = 0
    r.Parent = button
    corner(r, 100)
    tw(r, TweenInfo.new(0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
        Size = UDim2.new(0, 340, 0, 340), BackgroundTransparency = 1,
    })
    task.delay(0.55, function() r:Destroy() end)
end

local discordBusy = false
Discord.MouseButton1Click:Connect(function()
    local m = UserInputService:GetMouseLocation()
    ripple(Discord, m.X, m.Y)
    if setClip then pcall(setClip, "https://discord.gg/zYgRUCVv7D") end
    if discordBusy then return end
    discordBusy = true
    Discord.Text = "copied"
    pushLog("copied invite", T.Gold)
    task.wait(1.2)
    Discord.Text = "discord.gg/zYgRUCVv7D"
    discordBusy = false
end)

-- ==================================================================
-- MECHANICS PAGE
-- ==================================================================
sectionLabel(MechanicPage, "Performance", 4)

-- live FPS meter
local FpsCard = Instance.new("Frame")
FpsCard.Size = UDim2.new(1, 0, 0, 46)
FpsCard.Position = UDim2.new(0, 0, 0, 20)
FpsCard.BackgroundColor3 = T.Panel
FpsCard.BorderSizePixel = 0
FpsCard.Parent = MechanicPage
corner(FpsCard, 8)
stroke(FpsCard, T.Line, 1, 0.3)

local FpsLabel = Instance.new("TextLabel")
FpsLabel.Size = UDim2.new(0, 120, 0, 12)
FpsLabel.Position = UDim2.new(0, 12, 0, 9)
FpsLabel.BackgroundTransparency = 1
FpsLabel.Text = "Framerate"
FpsLabel.TextColor3 = T.Dim
FpsLabel.Font = FONT_MED
FpsLabel.TextSize = 10
FpsLabel.TextXAlignment = Enum.TextXAlignment.Left
FpsLabel.Parent = FpsCard

local FpsValue = Instance.new("TextLabel")
FpsValue.Size = UDim2.new(0, 80, 0, 14)
FpsValue.Position = UDim2.new(1, -92, 0, 8)
FpsValue.BackgroundTransparency = 1
FpsValue.Text = "-- fps"
FpsValue.TextColor3 = T.Gold
FpsValue.Font = FONT
FpsValue.TextSize = 12
FpsValue.TextXAlignment = Enum.TextXAlignment.Right
FpsValue.Parent = FpsCard

local FpsTrack = Instance.new("Frame")
FpsTrack.Size = UDim2.new(1, -24, 0, 6)
FpsTrack.Position = UDim2.new(0, 12, 0, 28)
FpsTrack.BackgroundColor3 = T.Off
FpsTrack.BorderSizePixel = 0
FpsTrack.Parent = FpsCard
corner(FpsTrack, 3)

local FpsFill = Instance.new("Frame")
FpsFill.Size = UDim2.new(0, 0, 1, 0)
FpsFill.BackgroundColor3 = T.Gold
FpsFill.BorderSizePixel = 0
FpsFill.Parent = FpsTrack
corner(FpsFill, 3)

local FpsFillGrad = Instance.new("UIGradient")
FpsFillGrad.Color = ColorSequence.new(T.GoldDeep, T.GoldSoft)
FpsFillGrad.Parent = FpsFill

switchRow(MechanicPage, "antiLag",  "Anti Lag",  74)
switchRow(MechanicPage, "fpsBoost", "FPS Boost", 110)

sectionLabel(MechanicPage, "Automation", 154)
switchRow(MechanicPage, "autoBuy", "Auto Buy", 170)

-- session readout
local Stats = Instance.new("Frame")
Stats.Size = UDim2.new(1, 0, 0, 62)
Stats.Position = UDim2.new(0, 0, 0, 216)
Stats.BackgroundColor3 = Color3.fromRGB(9, 9, 11)
Stats.BorderSizePixel = 0
Stats.Parent = MechanicPage
corner(Stats, 8)
stroke(Stats, T.Line, 1, 0.3)
pad(Stats, 12, 12, 9, 9)

local StatsList = Instance.new("UIListLayout")
StatsList.Padding = UDim.new(0, 5)
StatsList.Parent = Stats

local function statLine(name, value)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 12)
    row.BackgroundTransparency = 1
    row.Parent = Stats

    local l = Instance.new("TextLabel")
    l.Size = UDim2.new(0.5, 0, 1, 0)
    l.BackgroundTransparency = 1
    l.Text = name
    l.TextColor3 = T.Dim
    l.Font = FONT_MONO
    l.TextSize = 10
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Parent = row

    local v = Instance.new("TextLabel")
    v.Size = UDim2.new(0.5, 0, 1, 0)
    v.Position = UDim2.new(0.5, 0, 0, 0)
    v.BackgroundTransparency = 1
    v.Text = value
    v.TextColor3 = T.Text
    v.Font = FONT_MONO
    v.TextSize = 10
    v.TextXAlignment = Enum.TextXAlignment.Right
    v.Parent = row
    return v
end

local StatUptime = statLine("uptime",  "0s")
local StatPing   = statLine("ping",    "-- ms")
local StatMem    = statLine("memory",  "-- mb")

-- ==================================================================
-- AI RIDDLE PAGE
-- ==================================================================
sectionLabel(RiddlePage, "Riddle", 4)

local RiddleBoxFrame = Instance.new("Frame")
RiddleBoxFrame.Size = UDim2.new(1, 0, 0, 56)
RiddleBoxFrame.Position = UDim2.new(0, 0, 0, 20)
RiddleBoxFrame.BackgroundColor3 = Color3.fromRGB(9, 9, 11)
RiddleBoxFrame.BorderSizePixel = 0
RiddleBoxFrame.Parent = RiddlePage
corner(RiddleBoxFrame, 8)
local RiddleLine = stroke(RiddleBoxFrame, T.Line, 1, 0.3)

local RiddleInput = Instance.new("TextBox")
RiddleInput.Size = UDim2.new(1, -16, 1, -12)
RiddleInput.Position = UDim2.new(0, 8, 0, 6)
RiddleInput.BackgroundTransparency = 1
RiddleInput.Text = ""
RiddleInput.PlaceholderText = "paste a riddle, or let it capture the announcement"
RiddleInput.PlaceholderColor3 = Color3.fromRGB(90, 90, 98)
RiddleInput.TextColor3 = T.Text
RiddleInput.Font = FONT_MED
RiddleInput.TextSize = 11
RiddleInput.TextXAlignment = Enum.TextXAlignment.Left
RiddleInput.TextYAlignment = Enum.TextYAlignment.Top
RiddleInput.TextWrapped = true
RiddleInput.ClearTextOnFocus = false
RiddleInput.MultiLine = true
RiddleInput.Parent = RiddleBoxFrame

RiddleInput.Focused:Connect(function() tw(RiddleLine, EASE, { Color = T.GoldDeep, Transparency = 0.1 }) end)
RiddleInput.FocusLost:Connect(function() tw(RiddleLine, EASE, { Color = T.Line, Transparency = 0.3 }) end)

-- answer panel (declared early so the ask flow can write into it)
sectionLabel(RiddlePage, "Answer", 128)

local AnswerFrame = Instance.new("Frame")
AnswerFrame.Size = UDim2.new(1, 0, 0, 120)
AnswerFrame.Position = UDim2.new(0, 0, 0, 144)
AnswerFrame.BackgroundColor3 = Color3.fromRGB(9, 9, 11)
AnswerFrame.BorderSizePixel = 0
AnswerFrame.ClipsDescendants = true
AnswerFrame.Parent = RiddlePage
corner(AnswerFrame, 8)
local AnswerLine = stroke(AnswerFrame, T.Line, 1, 0.3)

local AnswerScroll = Instance.new("ScrollingFrame")
AnswerScroll.Size = UDim2.new(1, 0, 1, 0)
AnswerScroll.BackgroundTransparency = 1
AnswerScroll.BorderSizePixel = 0
AnswerScroll.ScrollBarThickness = 2
AnswerScroll.ScrollBarImageColor3 = T.GoldDeep
AnswerScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
AnswerScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
AnswerScroll.Parent = AnswerFrame
pad(AnswerScroll, 10, 10, 8, 8)

local AnswerText = Instance.new("TextLabel")
AnswerText.Size = UDim2.new(1, 0, 0, 0)
AnswerText.AutomaticSize = Enum.AutomaticSize.Y
AnswerText.BackgroundTransparency = 1
AnswerText.Text = "nothing asked yet"
AnswerText.TextColor3 = T.Dim
AnswerText.Font = FONT_MED
AnswerText.TextSize = 12
AnswerText.TextXAlignment = Enum.TextXAlignment.Left
AnswerText.TextYAlignment = Enum.TextYAlignment.Top
AnswerText.TextWrapped = true
AnswerText.Parent = AnswerScroll

local RiddleStatus = Instance.new("TextLabel")
RiddleStatus.Size = UDim2.new(1, 0, 0, 12)
RiddleStatus.Position = UDim2.new(0, 2, 0, 112)
RiddleStatus.BackgroundTransparency = 1
RiddleStatus.Text = "idle"
RiddleStatus.TextColor3 = T.Dim
RiddleStatus.Font = FONT_MONO
RiddleStatus.TextSize = 10
RiddleStatus.TextXAlignment = Enum.TextXAlignment.Left
RiddleStatus.Parent = RiddlePage

local lastAnswer = ""
local thinking = false

local function setStatus(text, color)
    RiddleStatus.Text = text
    tw(RiddleStatus, EASE, { TextColor3 = color or T.Dim })
end

local function setAnswer(text, color)
    lastAnswer = tostring(text)
    AnswerText.Text = lastAnswer
    AnswerText.TextTransparency = 1
    tw(AnswerText, EASE, { TextColor3 = color or T.Text })
    tw(AnswerText, SLOW, { TextTransparency = 0 })
    tw(AnswerLine, EASE, { Color = T.GoldDeep, Transparency = 0.2 })
    task.delay(1.2, function() tw(AnswerLine, EASE, { Color = T.Line, Transparency = 0.3 }) end)
end

-- backend: getgenv().FoodHub_AskAI(riddle) -> answer string
local function askAI(riddle)
    riddle = (riddle or ""):match("^%s*(.-)%s*$")
    if riddle == "" then
        setStatus("no riddle to ask", T.GoldDeep)
        return
    end
    if thinking then return end

    thinking = true
    setStatus("thinking", T.Gold)
    task.spawn(function()
        local dots = 0
        while thinking do
            dots = (dots + 1) % 4
            RiddleStatus.Text = "thinking" .. string.rep(".", dots)
            task.wait(0.35)
        end
    end)

    task.spawn(function()
        local backend = getgenv().FoodHub_AskAI
        local ok, result
        if backend then
            ok, result = pcall(backend, riddle)
        else
            ok, result = false, "no ai backend bound - set getgenv().FoodHub_AskAI = function(riddle) return answer end"
        end
        thinking = false
        if ok and result and tostring(result) ~= "" then
            setAnswer(result, T.Text)
            setStatus("answered", T.Gold)
            pushLog("riddle answered", T.Gold)
        else
            setAnswer(tostring(result or "no response"), T.Dim)
            setStatus("failed", T.Dim)
            pushLog("riddle ask failed", T.Dim)
        end
    end)
end

-- Ask + Answer-next-announcement
local AskBtn = flatButton(RiddlePage, "Ask", UDim2.new(0.5, -4, 0, 30), UDim2.new(0, 0, 0, 84), function()
    askAI(RiddleInput.Text)
end)
AskBtn.Font = FONT

local armed = false
local ArmBtn, ArmLine = flatButton(RiddlePage, "Answer Next", UDim2.new(0.5, -4, 0, 30), UDim2.new(0.5, 4, 0, 84))

local function setArmed(state)
    armed = state
    tw(ArmBtn, EASE, {
        BackgroundColor3 = armed and T.Gold or T.Panel,
        TextColor3 = armed and T.Black or T.Gold,
    })
    tw(ArmLine, EASE, { Transparency = armed and 0 or 0.55 })
    ArmBtn.Text = armed and "Listening" or "Answer Next"
    setStatus(armed and "waiting for announcement" or "idle", armed and T.Gold or T.Dim)
end

ArmBtn.MouseButton1Click:Connect(function() setArmed(not armed) end)

-- copy the answer out
flatButton(RiddlePage, "Copy Answer", UDim2.new(1, 0, 0, 28), UDim2.new(0, 0, 0, 274), function()
    if lastAnswer ~= "" and setClip then
        pcall(setClip, lastAnswer)
        setStatus("answer copied", T.Gold)
    end
end)

-- announcement intake: feed it manually with API:PushAnnouncement,
-- or let the TextChatService listener below catch system messages
local function onAnnouncement(text)
    text = tostring(text or "")
    if text == "" then return end
    RiddleInput.Text = text
    pushLog("announcement captured", T.Dim)
    if armed then
        setArmed(false)
        askAI(text)
    end
end

pcall(function()
    local TCS = game:GetService("TextChatService")
    TCS.MessageReceived:Connect(function(msg)
        if not msg.TextSource then          -- system / announcement, not a player
            onAnnouncement(msg.Text)
        end
    end)
end)

-- ==================================================================
-- PERFORMANCE ACTIONS
-- ==================================================================
local savedLighting = {
    GlobalShadows = Lighting.GlobalShadows,
    FogEnd        = Lighting.FogEnd,
    Brightness    = Lighting.Brightness,
    Quality       = settings().Rendering.QualityLevel,
}
local disabledEffects = {}

local function applyAntiLag(on)
    if on then
        for _, inst in ipairs(workspace:GetDescendants()) do
            if inst:IsA("ParticleEmitter") or inst:IsA("Trail") or inst:IsA("Smoke")
                or inst:IsA("Fire") or inst:IsA("Sparkles") or inst:IsA("Beam") then
                if inst.Enabled then
                    inst.Enabled = false
                    table.insert(disabledEffects, inst)
                end
            elseif inst:IsA("Decal") or inst:IsA("Texture") then
                if inst.Transparency < 1 then
                    table.insert(disabledEffects, inst)
                    inst.Transparency = 1
                end
            end
        end
        if Terrain then Terrain.WaterWaveSize, Terrain.WaterReflectance = 0, 0 end
        pushLog(("anti lag on (%d culled)"):format(#disabledEffects), T.Gold)
    else
        for _, inst in ipairs(disabledEffects) do
            pcall(function()
                if inst:IsA("Decal") or inst:IsA("Texture") then inst.Transparency = 0 else inst.Enabled = true end
            end)
        end
        disabledEffects = {}
        pushLog("anti lag off", T.Dim)
    end
end

local function applyFpsBoost(on)
    if on then
        Lighting.GlobalShadows = false
        Lighting.FogEnd = 1e6
        pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Level01 end)
        for _, e in ipairs(Lighting:GetChildren()) do
            if e:IsA("PostEffect") then e.Enabled = false end
        end
        pushLog("fps boost on", T.Gold)
    else
        Lighting.GlobalShadows = savedLighting.GlobalShadows
        Lighting.FogEnd = savedLighting.FogEnd
        Lighting.Brightness = savedLighting.Brightness
        pcall(function() settings().Rendering.QualityLevel = savedLighting.Quality end)
        for _, e in ipairs(Lighting:GetChildren()) do
            if e:IsA("PostEffect") then e.Enabled = true end
        end
        pushLog("fps boost off", T.Dim)
    end
end

userHooks.antiLag  = applyAntiLag
userHooks.fpsBoost = applyFpsBoost
userHooks.autoRedeem = function(on)
    pushLog("auto redeem " .. (on and ("on x" .. S.redeemAmount) or "off"), on and T.Gold or T.Dim)
end
userHooks.autoBuy  = function(on) pushLog("auto buy " .. (on and "on" or "off"), on and T.Gold or T.Dim) end
userHooks.sniper   = function(on)
    StatusText.Text = on and "Active" or "Idle"
    tw(StatusText, EASE, { TextColor3 = on and T.Gold or T.Dim })
    tw(StatusDot, EASE, { BackgroundColor3 = on and T.Gold or T.Off })
    pushLog(on and "sniper on" or "sniper off", on and T.Gold or T.Dim)
end

-- ==================================================================
-- LIVE METERS
-- ==================================================================
task.spawn(function()
    local startClock = os.clock()
    local frames, acc = 0, 0
    RunService.RenderStepped:Connect(function(dt)
        frames += 1
        acc += dt
    end)
    while Gui.Parent do
        task.wait(0.5)
        if acc > 0 then
            local fps = math.floor(frames / acc + 0.5)
            frames, acc = 0, 0
            FpsValue.Text = fps .. " fps"
            tw(FpsFill, TweenInfo.new(0.45, Enum.EasingStyle.Quint), {
                Size = UDim2.new(math.clamp(fps / 144, 0.02, 1), 0, 1, 0),
            })
        end
        local up = math.floor(os.clock() - startClock)
        StatUptime.Text = (up >= 60) and ("%dm %ds"):format(up // 60, up % 60) or (up .. "s")
        pcall(function()
            StatPing.Text = ("%d ms"):format(LP:GetNetworkPing() * 1000)
            StatMem.Text  = ("%d mb"):format(game:GetService("Stats"):GetTotalMemoryUsageMb())
        end)
    end
end)

-- ==================================================================
-- DRAGGING (mouse + touch)
-- ==================================================================
do
    local dragging, dragStart, startPos, dragInput = false, nil, nil, nil

    Header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging   = true
            dragStart  = input.Position
            startPos   = Window.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)

    Header.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch then
            dragInput = input
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if dragging and input == dragInput then
            local d = input.Position - dragStart
            Window.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + d.X,
                startPos.Y.Scale, startPos.Y.Offset + d.Y
            )
        end
    end)
end

-- right-ctrl hides / shows the whole window
UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == Enum.KeyCode.RightControl then
        Window.Visible = not Window.Visible
    end
end)

-- ==================================================================
-- PUBLIC API
-- ==================================================================
local API = {}

function API:SetStatus(text, color)
    StatusText.Text = tostring(text)
    if color then tw(StatusText, EASE, { TextColor3 = color }) end
end

function API:Log(text, color) pushLog(text, color) end

function API:SetCount(n) CodeCount.Text = n .. " codes" end

function API:GetSettings() return S end

function API:ClearBox()
    for _, k in ipairs(ConsoleScroll:GetChildren()) do
        if k:IsA("TextLabel") then k:Destroy() end
    end
    logIndex = 0
end

function API:GetAmount() return S.redeemAmount end
function API:SetAmount(n)
    S.redeemAmount = math.clamp(math.floor(tonumber(n) or 1), 1, 999)
    refreshAmount()
end

function API:SetRiddle(text) RiddleInput.Text = tostring(text or "") end
function API:PushAnnouncement(text) onAnnouncement(text) end
function API:Ask(text) askAI(text or RiddleInput.Text) end
function API:SetAnswer(text, color) setAnswer(text, color) end
function API:GetAnswer() return lastAnswer end
function API:IsArmed() return armed end
function API:SetArmed(state) setArmed(state and true or false) end

function API:OnToggle(name, fn)
    local existing = userHooks[name]
    userHooks[name] = function(state)
        if existing then pcall(existing, state) end
        pcall(fn, state)
    end
end

function API:SetToggle(name, state)
    local h = toggleHandles[name]
    if h then h.set(state, false) end
end

function API:Destroy() Gui:Destroy() end

getgenv().FoodHub_API = API
getgenv().FoodHub_CustomAPI = {                -- back-compat with the old script
    SetStateMessage  = function(_, m, c) API:SetStatus(m, c) end,
    PushConsoleLog   = function(_, m, c) API:Log(m, c) end,
    FetchActiveSettings = function() return S end,
}

return API
