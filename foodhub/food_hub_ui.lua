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

local W, H = 306, 392

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
Header.Size = UDim2.new(1, 0, 0, 58)
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
Mark.Size = UDim2.new(0, 4, 0, 26)
Mark.Position = UDim2.new(0, 16, 0, 12)
Mark.BackgroundColor3 = T.Gold
Mark.BorderSizePixel = 0
Mark.Parent = Header
corner(Mark, 2)

local Title = Instance.new("TextLabel")
Title.Name = "Title"
Title.Size = UDim2.new(0, 200, 0, 22)
Title.Position = UDim2.new(0, 28, 0, 11)
Title.BackgroundTransparency = 1
Title.Text = "FOOD HUB"
Title.TextColor3 = Color3.new(1, 1, 1)
Title.Font = Enum.Font.GothamBlack
Title.TextSize = 19
Title.TextXAlignment = Enum.TextXAlignment.Left
Title.Parent = Header

-- gold gradient across the wordmark + slow shimmer sweep
local TitleGrad = Instance.new("UIGradient")
TitleGrad.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0.00, T.GoldDeep),
    ColorSequenceKeypoint.new(0.45, T.Gold),
    ColorSequenceKeypoint.new(0.55, Color3.fromRGB(255, 250, 214)),
    ColorSequenceKeypoint.new(1.00, T.GoldDeep),
})
TitleGrad.Parent = Title

task.spawn(function()
    while Title.Parent do
        TitleGrad.Offset = Vector2.new(-1, 0)
        tw(TitleGrad, TweenInfo.new(1.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), { Offset = Vector2.new(1, 0) })
        task.wait(3.2)
    end
end)

local Sub = Instance.new("TextLabel")
Sub.Size = UDim2.new(0, 200, 0, 12)
Sub.Position = UDim2.new(0, 29, 0, 32)
Sub.BackgroundTransparency = 1
Sub.Text = "C O D E   R E D E E M E R"
Sub.TextColor3 = T.Dim
Sub.Font = FONT_MED
Sub.TextSize = 9
Sub.TextXAlignment = Enum.TextXAlignment.Left
Sub.Parent = Header

-- live pulse dot
local Pulse = Instance.new("Frame")
Pulse.Size = UDim2.new(0, 7, 0, 7)
Pulse.Position = UDim2.new(1, -62, 0, 26)
Pulse.BackgroundColor3 = T.Gold
Pulse.BorderSizePixel = 0
Pulse.Parent = Header
corner(Pulse, 4)

task.spawn(function()
    while Pulse.Parent do
        tw(Pulse, TweenInfo.new(0.8, Enum.EasingStyle.Sine), { BackgroundTransparency = 0.75 })
        task.wait(0.85)
        tw(Pulse, TweenInfo.new(0.8, Enum.EasingStyle.Sine), { BackgroundTransparency = 0 })
        task.wait(0.85)
    end
end)

-- window buttons
local function headerButton(text, xOff, onClick)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0, 22, 0, 22)
    b.Position = UDim2.new(1, xOff, 0, 18)
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
Body.Size = UDim2.new(1, 0, 1, -58)
Body.Position = UDim2.new(0, 0, 0, 58)
Body.BackgroundTransparency = 1
Body.ClipsDescendants = true
Body.Parent = Window

local minimized = false
headerButton("–", -48, function()
    minimized = not minimized
    Body.Visible = true
    if minimized then
        tw(Window, EASE, { Size = UDim2.new(0, W, 0, 58) })
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
TabGlider.Size = UDim2.new(0.5, -6, 1, -6)
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

    tw(TabGlider, EASE, { Position = UDim2.new(0.5 * (index - 1), 3, 0, 3) })
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
    b.Size = UDim2.new(0.5, -6, 1, -6)
    b.Position = UDim2.new(0.5 * (index - 1), 3, 0, 3)
    b.BackgroundTransparency = 1
    b.Text = name
    b.TextColor3 = (index == 1) and T.Black or T.Dim
    b.Font = FONT
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

local RedeemPage   = makeTab("REDEEMER",  1)
local MechanicPage = makeTab("MECHANICS", 2)

-- ==================================================================
-- WIDGETS
-- ==================================================================
local function sectionLabel(parent, text, y)
    local l = Instance.new("TextLabel")
    l.Size = UDim2.new(1, 0, 0, 12)
    l.Position = UDim2.new(0, 2, 0, y)
    l.BackgroundTransparency = 1
    l.Text = text
    l.TextColor3 = T.GoldDeep
    l.Font = FONT
    l.TextSize = 9
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Parent = parent
    return l
end

-- one settings row: label + sliding switch, with hover lift
local function switchRow(parent, key, label, blurb, y)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 40)
    row.Position = UDim2.new(0, 0, 0, y)
    row.BackgroundColor3 = T.Panel
    row.BackgroundTransparency = 0.25
    row.BorderSizePixel = 0
    row.Parent = parent
    corner(row, 8)
    local rowLine = stroke(row, T.Line, 1, 0.25)

    local name = Instance.new("TextLabel")
    name.Size = UDim2.new(1, -68, 0, 13)
    name.Position = UDim2.new(0, 12, 0, blurb and 8 or 13)
    name.BackgroundTransparency = 1
    name.Text = label
    name.TextColor3 = T.Text
    name.Font = FONT_MED
    name.TextSize = 12
    name.TextXAlignment = Enum.TextXAlignment.Left
    name.Parent = row

    if blurb then
        local sub = Instance.new("TextLabel")
        sub.Size = UDim2.new(1, -68, 0, 11)
        sub.Position = UDim2.new(0, 12, 0, 21)
        sub.BackgroundTransparency = 1
        sub.Text = blurb
        sub.TextColor3 = T.Dim
        sub.Font = FONT_MED
        sub.TextSize = 9
        sub.TextXAlignment = Enum.TextXAlignment.Left
        sub.Parent = row
    end

    local track = Instance.new("TextButton")
    track.Size = UDim2.new(0, 38, 0, 20)
    track.Position = UDim2.new(1, -50, 0.5, -10)
    track.BackgroundColor3 = S[key] and T.Gold or T.Off
    track.BorderSizePixel = 0
    track.Text = ""
    track.AutoButtonColor = false
    track.Parent = row
    corner(track, 10)

    local knob = Instance.new("Frame")
    knob.Size = UDim2.new(0, 14, 0, 14)
    knob.Position = S[key] and UDim2.new(1, -17, 0.5, -7) or UDim2.new(0, 3, 0.5, -7)
    knob.BackgroundColor3 = S[key] and T.Black or Color3.fromRGB(150, 150, 158)
    knob.BorderSizePixel = 0
    knob.Parent = track
    corner(knob, 7)

    -- gold bloom that fades in when the switch is on
    local glow = stroke(row, T.Gold, 1, S[key] and 0.55 or 1)

    local function apply(state, fire)
        S[key] = state
        tw(track, EASE, { BackgroundColor3 = state and T.Gold or T.Off })
        tw(knob, SNAP, {
            Position = state and UDim2.new(1, -17, 0.5, -7) or UDim2.new(0, 3, 0.5, -7),
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
StatusCard.Size = UDim2.new(1, 0, 0, 34)
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
StatusText.Text = S.sniper and "ACTIVE" or "IDLE"
StatusText.TextColor3 = S.sniper and T.Gold or T.Dim
StatusText.Font = FONT
StatusText.TextSize = 11
StatusText.TextXAlignment = Enum.TextXAlignment.Left
StatusText.Parent = StatusCard

local CodeCount = Instance.new("TextLabel")
CodeCount.Size = UDim2.new(0, 70, 1, 0)
CodeCount.Position = UDim2.new(1, -82, 0, 0)
CodeCount.BackgroundTransparency = 1
CodeCount.Text = "0 redeemed"
CodeCount.TextColor3 = T.Dim
CodeCount.Font = FONT_MONO
CodeCount.TextSize = 10
CodeCount.TextXAlignment = Enum.TextXAlignment.Right
CodeCount.Parent = StatusCard

sectionLabel(RedeemPage, "SNIPER", 44)
switchRow(RedeemPage, "sniper",       "Code Sniper",    "Watch chat for drops",     60)
switchRow(RedeemPage, "autoSubmit",   "Auto Submit",    "Fire the code on detect", 104)
switchRow(RedeemPage, "retryInvalid", "Retype Invalid", "Re-send on reject",       148)

-- delay stepper
local DelayRow = Instance.new("Frame")
DelayRow.Size = UDim2.new(1, 0, 0, 34)
DelayRow.Position = UDim2.new(0, 0, 0, 192)
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
sectionLabel(RedeemPage, "CONSOLE", 236)

local Console = Instance.new("Frame")
Console.Size = UDim2.new(1, 0, 0, 60)
Console.Position = UDim2.new(0, 0, 0, 252)
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
    line.Text = "› " .. tostring(text)
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

pushLog(S.sniper and "standing by..." or "module disabled", T.Dim)

-- discord
local Discord = Instance.new("TextButton")
Discord.Size = UDim2.new(1, 0, 0, 28)
Discord.Position = UDim2.new(0, 0, 0, 322)
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
    Discord.Text = "COPIED ✓"
    pushLog("invite copied to clipboard", T.Gold)
    task.wait(1.2)
    Discord.Text = "discord.gg/zYgRUCVv7D"
    discordBusy = false
end)

-- ==================================================================
-- MECHANICS PAGE
-- ==================================================================
sectionLabel(MechanicPage, "PERFORMANCE", 4)

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
FpsLabel.Text = "FRAMERATE"
FpsLabel.TextColor3 = T.Dim
FpsLabel.Font = FONT
FpsLabel.TextSize = 9
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

switchRow(MechanicPage, "antiLag", "Anti Lag",  "Strip particles, trails, decals", 74)
switchRow(MechanicPage, "fpsBoost", "FPS Boost", "Drop quality + lighting cost",   118)

sectionLabel(MechanicPage, "AUTOMATION", 168)
switchRow(MechanicPage, "autoBuy", "Auto Buy", "Purchase on stock refresh", 184)

-- session readout
local Stats = Instance.new("Frame")
Stats.Size = UDim2.new(1, 0, 0, 62)
Stats.Position = UDim2.new(0, 0, 0, 236)
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
        pushLog(("anti-lag on — %d effects culled"):format(#disabledEffects), T.Gold)
    else
        for _, inst in ipairs(disabledEffects) do
            pcall(function()
                if inst:IsA("Decal") or inst:IsA("Texture") then inst.Transparency = 0 else inst.Enabled = true end
            end)
        end
        disabledEffects = {}
        pushLog("anti-lag off — effects restored", T.Dim)
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
        pushLog("fps boost on — quality dropped", T.Gold)
    else
        Lighting.GlobalShadows = savedLighting.GlobalShadows
        Lighting.FogEnd = savedLighting.FogEnd
        Lighting.Brightness = savedLighting.Brightness
        pcall(function() settings().Rendering.QualityLevel = savedLighting.Quality end)
        for _, e in ipairs(Lighting:GetChildren()) do
            if e:IsA("PostEffect") then e.Enabled = true end
        end
        pushLog("fps boost off — quality restored", T.Dim)
    end
end

userHooks.antiLag  = applyAntiLag
userHooks.fpsBoost = applyFpsBoost
userHooks.autoBuy  = function(on) pushLog("auto buy " .. (on and "armed" or "disarmed"), on and T.Gold or T.Dim) end
userHooks.sniper   = function(on)
    StatusText.Text = on and "ACTIVE" or "IDLE"
    tw(StatusText, EASE, { TextColor3 = on and T.Gold or T.Dim })
    tw(StatusDot, EASE, { BackgroundColor3 = on and T.Gold or T.Off })
    pushLog(on and "sniper armed" or "sniper idle", on and T.Gold or T.Dim)
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

function API:SetCount(n) CodeCount.Text = n .. " redeemed" end

function API:GetSettings() return S end

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
