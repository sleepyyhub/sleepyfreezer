--!nocheck
-- LIVEBOARD SNIPER
-- Hooks RE/Liveboard/NewEntry + RE/Liveboard/ClaimEntry and fires
-- TradeService/Invite at the entry owner.
--
-- Hot path is fully pre-resolved at load: the Invite RemoteFunction is cached
-- from TradeController.SendInvite's upvalues, the call-site GUID is a constant,
-- and OwnerUserId arrives already numeric. On event we do three type checks and
-- dispatch -- no lookup, no GetUserIdFromNameAsync.

local Players     = game:GetService("Players")
local UIS         = game:GetService("UserInputService")
local TS          = game:GetService("TweenService")
local RepS        = game:GetService("ReplicatedStorage")
local LP          = Players.LocalPlayer
local PG          = LP:WaitForChild("PlayerGui")
local IS_MOBILE   = UIS.TouchEnabled and not UIS.KeyboardEnabled and not UIS.MouseEnabled

local L = {}
local genv = (type(getgenv) == "function") and select(2, pcall(getgenv)) or nil
if genv then genv.LiveSniper = L end

----------------------------------------------------------------
-- state
----------------------------------------------------------------

L.InviteGUID   = "afb005f9-6e81-4e0a-8bb0-3555938a9658"
L.AutoOn       = false
L.Cooldown     = 30          -- per-user resend cooldown, seconds
L.Scope        = "ALL"       -- ALL | GLOBAL | SERVER
L.MinTier      = 1           -- index into L.Tiers
L.Sent         = {}          -- userId -> os.clock()
L.Blacklist    = {}          -- userId -> true
L.Stats        = {seen = 0, fired = 0, ok = 0, fail = 0, skipped = 0}
L.BestDispatch = nil
L.Feed         = {}
L.MaxRows      = 60

L.Tiers = {
    "Any", "Common", "Uncommon", "Rare", "Epic", "Legendary",
    "Mythic", "Brainrot God", "Secret", "Divine", "OG",
}
L.TierIndex = {}
for i, n in ipairs(L.Tiers) do L.TierIndex[n:lower()] = i end

L.TierColor = {
    ["common"]        = Color3.fromRGB(159, 173, 189),
    ["uncommon"]      = Color3.fromRGB( 87, 199, 133),
    ["rare"]          = Color3.fromRGB( 52, 152, 219),
    ["epic"]          = Color3.fromRGB(155, 110, 200),
    ["legendary"]     = Color3.fromRGB(241, 196,  15),
    ["mythic"]        = Color3.fromRGB(233, 121, 163),
    ["brainrot god"]  = Color3.fromRGB(231,  76,  60),
    ["secret"]        = Color3.fromRGB( 44, 40,  99),
    ["divine"]        = Color3.fromRGB(255, 215,   0),
    ["og"]            = Color3.fromRGB(255, 255, 255),
}

local T = {
    VOID     = Color3.fromRGB(6, 9, 18),
    BG       = Color3.fromRGB(10, 15, 28),
    SURFACE  = Color3.fromRGB(16, 24, 44),
    RAISED   = Color3.fromRGB(24, 34, 58),
    LINE     = Color3.fromRGB(38, 54, 88),
    ACCENT   = Color3.fromRGB(120, 180, 255),
    HIGH     = Color3.fromRGB(180, 220, 255),
    DEEP     = Color3.fromRGB(72, 130, 210),
    TEXT     = Color3.fromRGB(230, 240, 255),
    MUTED    = Color3.fromRGB(120, 145, 185),
    RED      = Color3.fromRGB(255, 130, 155),
    GREEN    = Color3.fromRGB(146, 255, 103),
    ORANGE   = Color3.fromRGB(255, 190, 120),
    WHITE    = Color3.fromRGB(255, 255, 255),
}

local function safe(fn) local ok, r = pcall(fn); return ok and r or nil end
local function alive(i) return i and typeof(i) == "Instance" and i.Parent ~= nil end

local function fmt(ms)
    if ms < 1  then return ("%.2fms"):format(ms) end
    if ms < 10 then return ("%.1fms"):format(ms) end
    return ("%.0fms"):format(ms)
end

local function New(cls, props, kids)
    local i = Instance.new(cls)
    for k, v in pairs(props or {}) do i[k] = v end
    for _, c in ipairs(kids or {}) do c.Parent = i end
    return i
end
local function Corner(p, r) return New("UICorner", {CornerRadius = UDim.new(0, r or 10), Parent = p}) end
local function Pad(p, a, b, c, d) return New("UIPadding", {
    PaddingTop    = UDim.new(0, a or 0), PaddingBottom = UDim.new(0, b or a or 0),
    PaddingLeft   = UDim.new(0, c or a or 0), PaddingRight = UDim.new(0, d or c or a or 0), Parent = p}) end
local function Stroke(p, col, th, tr)
    return New("UIStroke", {Color = col or T.LINE, Thickness = th or 1, Transparency = tr or 0.4,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = p})
end
local function tw(obj, time, style, dir, goal)
    return TS:Create(obj, TweenInfo.new(time, style or Enum.EasingStyle.Quart, dir or Enum.EasingDirection.Out), goal)
end

----------------------------------------------------------------
-- remotes: resolved ONCE so the event path stays hot
----------------------------------------------------------------

L.Net = safe(function() return RepS:WaitForChild("Packages", 10):WaitForChild("Net", 10) end)

L.NewEntry   = L.Net and L.Net:FindFirstChild("RE/Liveboard/NewEntry")
L.ClaimEntry = L.Net and L.Net:FindFirstChild("RE/Liveboard/ClaimEntry")
L.GetEntries = L.Net and L.Net:FindFirstChild("RF/Liveboard/GetEntries")

L.InviteRF = nil
do
    local ok, TC = pcall(require, RepS.Controllers.TradeController)
    if ok and type(TC) == "table" and typeof(TC.SendInvite) == "function" then
        L.TC = TC
        local oku, ups = pcall(debug.getupvalues, TC.SendInvite)
        if oku then
            for _, v in pairs(ups) do
                if typeof(v) == "Instance" and v:IsA("RemoteFunction") then L.InviteRF = v break end
            end
        end
    end
end

L.Animals = safe(function() return require(RepS.Datas.Animals) end)

L.RarityOf = function(brainrotName)
    if not L.Animals or type(brainrotName) ~= "string" then return nil end
    local rec = L.Animals[brainrotName]
    if type(rec) ~= "table" then return nil end
    local r = rec.Rarity or rec.RarityName or rec.Tier
    if type(r) == "string" then return r end
    if type(r) == "table" then return r.DisplayName or r.Name or r.Id end
    return nil
end

L.Ready = (L.NewEntry ~= nil) and (L.InviteRF ~= nil)

----------------------------------------------------------------
-- gui root + loader
----------------------------------------------------------------

local old = PG:FindFirstChild("LiveSniperUI")
if old then old:Destroy() end

local Gui = New("ScreenGui", {
    Name = "LiveSniperUI", ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling, IgnoreGuiInset = true,
    DisplayOrder = 9999, Parent = PG,
})

local Loader = New("Frame", {
    Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
    BorderSizePixel = 0, ZIndex = 100, Parent = Gui,
})
local RainRoot = New("Frame", {
    Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
    ClipsDescendants = false, ZIndex = 100, Parent = Loader,
})

L.RainActive = true
task.spawn(function()
    while L.RainActive and Loader.Parent do
        local size = math.random(14, 34)
        local col  = ({T.ACCENT, T.HIGH, T.DEEP})[math.random(1, 3)]
        local vx   = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize.X or 1200
        local vy   = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize.Y or 800
        local x    = math.random(0, vx)
        local rot0 = math.random(-40, 40)
        local moon = New("TextLabel", {
            Size = UDim2.fromOffset(size, size),
            Position = UDim2.new(0, x, 0, -size - 20),
            BackgroundTransparency = 1, Text = "\u{263E}",
            TextColor3 = col, Font = Enum.Font.GothamBold, TextSize = size,
            TextTransparency = math.random(30, 65) / 100,
            Rotation = rot0, ZIndex = 100, Parent = RainRoot,
        })
        New("UIStroke", {Color = col, Thickness = 0.5, Transparency = 0.6, Parent = moon})
        local dur   = math.random(24, 44) / 10
        local drift = math.random(-60, 60)
        task.spawn(function()
            TS:Create(moon, TweenInfo.new(dur, Enum.EasingStyle.Linear), {
                Position = UDim2.new(0, x + drift, 0, vy + 40),
                Rotation = rot0 + math.random(-90, 90),
            }):Play()
            TS:Create(moon, TweenInfo.new(dur * 0.9, Enum.EasingStyle.Quad), {TextTransparency = 1}):Play()
            task.wait(dur)
            moon:Destroy()
        end)
        task.wait(0.11)
    end
end)

local LoaderCard = New("Frame", {
    Size = UDim2.fromOffset(560, 150),
    Position = UDim2.new(0.5, -280, 0.5, -75),
    BackgroundTransparency = 1, ZIndex = 101, Parent = Loader,
})

local BRAND     = "LIVEBOARD"
local BIG_SIZE  = IS_MOBILE and 46 or 62
local Mark = New("Frame", {
    Size = UDim2.new(1, 0, 0, BIG_SIZE + 8),
    BackgroundTransparency = 1, ZIndex = 102, Parent = LoaderCard,
})
New("UIListLayout", {
    FillDirection = Enum.FillDirection.Horizontal,
    HorizontalAlignment = Enum.HorizontalAlignment.Center,
    VerticalAlignment = Enum.VerticalAlignment.Center,
    Padding = UDim.new(0, 1), Parent = Mark,
})

local Letters = {}
for i = 1, #BRAND do
    local ch = BRAND:sub(i, i)
    local w  = BIG_SIZE * (ch == "I" and 0.35 or 0.62)
    local wrap = New("Frame", {
        Size = UDim2.fromOffset(w, BIG_SIZE), BackgroundTransparency = 1,
        LayoutOrder = i, ZIndex = 102, Parent = Mark,
    })
    local lbl = New("TextLabel", {
        Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
        Text = ch, TextColor3 = T.HIGH, Font = Enum.Font.GothamBold,
        TextSize = BIG_SIZE, TextTransparency = 1,
        Rotation = math.random(-60, 60), ZIndex = 103, Parent = wrap,
    })
    lbl.Position = UDim2.fromOffset(math.random(-140, 140), math.random(-90, 90))
    New("UIStroke", {Color = Color3.fromRGB(0, 0, 0), Thickness = 2, Transparency = 0.1,
        LineJoinMode = Enum.LineJoinMode.Round, Parent = lbl})
    Letters[i] = lbl
end

local Underline = New("Frame", {
    Size = UDim2.new(0, 0, 0, 2),
    Position = UDim2.new(0.5, 0, 0, BIG_SIZE + 12),
    AnchorPoint = Vector2.new(0.5, 0),
    BackgroundColor3 = T.ACCENT, BackgroundTransparency = 0.15,
    BorderSizePixel = 0, ZIndex = 102, Parent = LoaderCard,
})
Corner(Underline, 1)
New("UIGradient", {
    Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, T.DEEP),
        ColorSequenceKeypoint.new(0.5, T.HIGH),
        ColorSequenceKeypoint.new(1, T.DEEP),
    }), Parent = Underline,
})

local Sub = New("TextLabel", {
    Size = UDim2.new(1, 0, 0, 18),
    Position = UDim2.new(0, 0, 0, BIG_SIZE + 22),
    BackgroundTransparency = 1, Text = "initializing",
    TextColor3 = T.MUTED, Font = Enum.Font.Gotham, TextSize = 12,
    TextTransparency = 1, ZIndex = 102, Parent = LoaderCard,
})

----------------------------------------------------------------
-- panel
----------------------------------------------------------------

local PANEL_W = IS_MOBILE and 300 or 340
local Panel = New("Frame", {
    Size = UDim2.fromOffset(PANEL_W, 320),
    Position = UDim2.new(0.5, -(PANEL_W / 2), 0.5, -160 + 40),
    BackgroundColor3 = T.SURFACE, BackgroundTransparency = 1,
    BorderSizePixel = 0, Parent = Gui,
})
Corner(Panel, 16); Pad(Panel, 16)
local PanelStroke = Stroke(Panel, T.LINE, 1, 1)

local PanelGrad = New("UIGradient", {
    Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, T.SURFACE),
        ColorSequenceKeypoint.new(0.5, T.SURFACE:Lerp(T.DEEP, 0.35)),
        ColorSequenceKeypoint.new(1, T.SURFACE),
    }), Rotation = 20, Parent = Panel,
})
task.spawn(function()
    while Panel.Parent do
        TS:Create(PanelGrad, TweenInfo.new(6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {Rotation = 200}):Play()
        task.wait(6)
        TS:Create(PanelGrad, TweenInfo.new(6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {Rotation = 20}):Play()
        task.wait(6)
    end
end)

local Header = New("Frame", {Size = UDim2.new(1, 0, 0, 20), BackgroundTransparency = 1, Parent = Panel})
local Handle = New("TextButton", {Size = UDim2.new(1, -52, 1, 0), BackgroundTransparency = 1,
    AutoButtonColor = false, Text = "", Parent = Header})

local Brand = New("TextLabel", {
    Size = UDim2.new(1, -18, 1, 0), Position = UDim2.fromOffset(16, 0),
    BackgroundTransparency = 1, Text = "LIVEBOARD SNIPER", TextColor3 = T.HIGH,
    Font = Enum.Font.GothamBold, TextSize = 12,
    TextXAlignment = Enum.TextXAlignment.Left, TextTransparency = 1, Parent = Handle,
})
local BrandGrad = New("UIGradient", {
    Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0,    T.HIGH),
        ColorSequenceKeypoint.new(0.45, T.HIGH),
        ColorSequenceKeypoint.new(0.5,  T.WHITE),
        ColorSequenceKeypoint.new(0.55, T.HIGH),
        ColorSequenceKeypoint.new(1,    T.HIGH),
    }), Offset = Vector2.new(-1, 0), Parent = Brand,
})
task.spawn(function()
    while Brand.Parent do
        task.wait(4)
        BrandGrad.Offset = Vector2.new(-1, 0)
        TS:Create(BrandGrad, TweenInfo.new(1.1, Enum.EasingStyle.Sine), {Offset = Vector2.new(1, 0)}):Play()
    end
end)

local Dot = New("Frame", {
    Size = UDim2.fromOffset(8, 8), Position = UDim2.new(0, 0, 0.5, -4),
    BackgroundColor3 = Color3.fromRGB(30, 40, 60), BackgroundTransparency = 1,
    BorderSizePixel = 0, Parent = Handle,
})
Corner(Dot, 4)
local DotStroke = New("UIStroke", {Color = Color3.fromRGB(0, 0, 0), Thickness = 1, Transparency = 0.4, Parent = Dot})
local Ring = New("Frame", {
    Size = UDim2.fromOffset(8, 8), Position = UDim2.new(0, 0, 0.5, -4),
    BackgroundTransparency = 1, BorderSizePixel = 0, Parent = Handle,
})
Corner(Ring, 8)
local RingStroke = New("UIStroke", {Color = T.ACCENT, Thickness = 1, Transparency = 1, Parent = Ring})

L.DotReady = false
L.Linked   = false
task.spawn(function()
    while true do
        if L.DotReady then
            local linked = alive(L.InviteRF) and alive(L.NewEntry)
            if linked ~= L.Linked then
                L.Linked = linked
                tw(Dot, 0.35, nil, nil, {
                    BackgroundColor3 = linked and T.HIGH or Color3.fromRGB(30, 40, 60),
                    BackgroundTransparency = 0}):Play()
                tw(DotStroke, 0.35, nil, nil, {
                    Color = linked and T.ACCENT or Color3.fromRGB(0, 0, 0),
                    Transparency = linked and 0.15 or 0.4}):Play()
            end
            if linked then
                Ring.Size = UDim2.fromOffset(8, 8)
                Ring.Position = UDim2.new(0, 0, 0.5, -4)
                RingStroke.Transparency = 0.35
                tw(Ring, 1.1, Enum.EasingStyle.Quad, nil, {
                    Size = UDim2.fromOffset(22, 22),
                    Position = UDim2.new(0, -7, 0.5, -11)}):Play()
                tw(RingStroke, 1.1, Enum.EasingStyle.Quad, nil, {Transparency = 1}):Play()
            end
        end
        task.wait(1.2)
    end
end)

local MinBtn = New("TextButton", {
    Size = UDim2.fromOffset(20, 20), Position = UDim2.new(1, -46, 0.5, -10),
    BackgroundColor3 = T.RAISED, AutoButtonColor = false,
    Text = "\u{2014}", TextColor3 = T.MUTED, Font = Enum.Font.GothamBold, TextSize = 11,
    BackgroundTransparency = 1, TextTransparency = 1, Parent = Header,
})
Corner(MinBtn, 6)
local CloseBtn = New("TextButton", {
    Size = UDim2.fromOffset(20, 20), Position = UDim2.new(1, -22, 0.5, -10),
    BackgroundColor3 = T.RAISED, AutoButtonColor = false,
    Text = "\u{00D7}", TextColor3 = T.MUTED, Font = Enum.Font.GothamBold, TextSize = 13,
    BackgroundTransparency = 1, TextTransparency = 1, Parent = Header,
})
Corner(CloseBtn, 6)

local Content = New("Frame", {
    Size = UDim2.new(1, 0, 1, -32), Position = UDim2.new(0, 0, 0, 32),
    BackgroundTransparency = 1, Parent = Panel,
})
local ContentList = New("UIListLayout", {Padding = UDim.new(0, 10),
    SortOrder = Enum.SortOrder.LayoutOrder, Parent = Content})

----------------------------------------------------------------
-- notifications
----------------------------------------------------------------

local NOTIF_W = IS_MOBILE and 270 or 320
local NotifRoot = New("Frame", {
    AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 14),
    Size = UDim2.fromOffset(NOTIF_W, 0), AutomaticSize = Enum.AutomaticSize.Y,
    BackgroundTransparency = 1, Parent = Gui,
})
New("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder,
    HorizontalAlignment = Enum.HorizontalAlignment.Right, Padding = UDim.new(0, 8), Parent = NotifRoot})

L.Notifs = {}
L.NotifOrder = 0

local function destroyNotif(state)
    if state.dead then return end
    state.dead = true
    L.Notifs[state.key] = nil
    tw(state.frame, 0.26, Enum.EasingStyle.Quart, nil, {
        Position = UDim2.fromOffset(NOTIF_W + 40, 0), BackgroundTransparency = 1}):Play()
    for _, o in ipairs(state.fade) do
        tw(o, 0.22, nil, nil, o:IsA("UIStroke") and {Transparency = 1}
            or (o:IsA("Frame") and {BackgroundTransparency = 1} or {TextTransparency = 1})):Play()
    end
    task.delay(0.3, function() if state.frame then state.frame:Destroy() end end)
end

L.Notify = function(msg, color, timing)
    msg = tostring(msg or "")
    if msg == "" then return end
    color = color or T.HIGH

    local existing = L.Notifs[msg]
    if existing and not existing.dead then
        existing.count += 1
        existing.badge.Text = "\u{00D7}" .. existing.count
        existing.badge.Visible = true
        if timing then existing.timing.Text = timing end
        existing.token += 1
        local tok = existing.token
        existing.frame.Size = UDim2.new(1, 0, 0, existing.height)
        tw(existing.badge, 0.12, Enum.EasingStyle.Back, nil, {TextSize = 17}):Play()
        task.delay(0.12, function()
            if existing.dead then return end
            tw(existing.badge, 0.16, Enum.EasingStyle.Back, nil, {TextSize = 13}):Play()
        end)
        task.delay(3.2, function()
            if existing.dead or existing.token ~= tok then return end
            destroyNotif(existing)
        end)
        return
    end

    L.NotifOrder += 1
    local height = timing and 72 or 52
    local frame = New("Frame", {
        Size = UDim2.new(1, 0, 0, height), Position = UDim2.fromOffset(NOTIF_W + 40, 0),
        BackgroundColor3 = T.SURFACE, BackgroundTransparency = 1, BorderSizePixel = 0,
        ClipsDescendants = true, LayoutOrder = L.NotifOrder, Parent = NotifRoot,
    })
    Corner(frame, 12)
    local stroke = Stroke(frame, T.LINE, 1, 1)
    local bar = New("Frame", {
        Size = UDim2.new(0, 4, 1, -16), Position = UDim2.new(0, 8, 0, 8),
        BackgroundColor3 = color, BackgroundTransparency = 1,
        BorderSizePixel = 0, Parent = frame,
    })
    Corner(bar, 2)
    local body = New("TextLabel", {
        Size = UDim2.new(1, -58, 0, timing and 22 or 52),
        Position = UDim2.new(0, 20, 0, timing and 11 or 0),
        BackgroundTransparency = 1, Text = msg, TextColor3 = color,
        Font = Enum.Font.GothamBold, TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = timing and Enum.TextYAlignment.Top or Enum.TextYAlignment.Center,
        TextTruncate = Enum.TextTruncate.AtEnd, TextTransparency = 1, Parent = frame,
    })
    local timingLbl = New("TextLabel", {
        Size = UDim2.new(1, -58, 0, 30), Position = UDim2.new(0, 20, 0, 35),
        BackgroundTransparency = 1, Text = timing or "", TextColor3 = T.MUTED,
        Font = Enum.Font.Gotham, TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
        TextWrapped = true, Visible = timing ~= nil, TextTransparency = 1, Parent = frame,
    })
    local badge = New("TextLabel", {
        Size = UDim2.fromOffset(32, 20), Position = UDim2.new(1, -40, 0, 9),
        BackgroundTransparency = 1, Text = "", TextColor3 = T.WHITE,
        Font = Enum.Font.GothamBold, TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Right, Visible = false,
        TextTransparency = 1, Parent = frame,
    })

    local state = {key = msg, frame = frame, badge = badge, timing = timingLbl,
        count = 1, token = 0, height = height, dead = false,
        fade = {body, timingLbl, badge, bar, stroke}}
    L.Notifs[msg] = state

    tw(frame, 0.3, Enum.EasingStyle.Quint, nil, {
        Position = UDim2.fromOffset(0, 0), BackgroundTransparency = 0.08}):Play()
    tw(stroke, 0.3, nil, nil, {Transparency = 0.45}):Play()
    tw(bar, 0.3, nil, nil, {BackgroundTransparency = 0}):Play()
    tw(body, 0.3, nil, nil, {TextTransparency = 0}):Play()
    if timing then tw(timingLbl, 0.3, nil, nil, {TextTransparency = 0.15}):Play() end
    tw(badge, 0.3, nil, nil, {TextTransparency = 0.1}):Play()

    local tok = state.token
    task.delay(3.2, function()
        if state.dead or state.token ~= tok then return end
        destroyNotif(state)
    end)
end

----------------------------------------------------------------
-- controls: auto switch, rarity tier, scope
----------------------------------------------------------------

local AutoBox = New("Frame", {
    Size = UDim2.new(1, 0, 0, 44), BackgroundColor3 = T.RAISED,
    BackgroundTransparency = 1, LayoutOrder = 1, Parent = Content,
})
Corner(AutoBox, 12); Pad(AutoBox, 0, 0, 12, 12)
local AutoStroke = Stroke(AutoBox, T.LINE, 1, 1)
New("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal,
    VerticalAlignment = Enum.VerticalAlignment.Center,
    HorizontalAlignment = Enum.HorizontalAlignment.Left, Parent = AutoBox})

local AutoTag = New("TextLabel", {
    Size = UDim2.new(1, -60, 1, 0), BackgroundTransparency = 1,
    Text = "Auto snipe", TextColor3 = T.MUTED,
    Font = Enum.Font.GothamSemibold, TextSize = 12,
    TextXAlignment = Enum.TextXAlignment.Left, TextTransparency = 1,
    LayoutOrder = 1, Parent = AutoBox,
})
local Switch = New("TextButton", {
    Size = UDim2.fromOffset(38, 20), BackgroundColor3 = T.SURFACE,
    AutoButtonColor = false, Text = "", BackgroundTransparency = 1,
    LayoutOrder = 2, Parent = AutoBox,
})
Corner(Switch, 10)
local SwitchStroke = Stroke(Switch, T.LINE, 1, 1)
local Knob = New("Frame", {
    Size = UDim2.fromOffset(14, 14), Position = UDim2.new(0, 3, 0.5, -7),
    BackgroundColor3 = T.MUTED, BackgroundTransparency = 1,
    BorderSizePixel = 0, Parent = Switch,
})
Corner(Knob, 7)

-- rarity threshold row
local TierBox = New("Frame", {
    Size = UDim2.new(1, 0, 0, 44), BackgroundColor3 = T.RAISED,
    BackgroundTransparency = 1, LayoutOrder = 2, Parent = Content,
})
Corner(TierBox, 12); Pad(TierBox, 0, 0, 12, 12)
local TierStroke = Stroke(TierBox, T.LINE, 1, 1)
New("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal,
    VerticalAlignment = Enum.VerticalAlignment.Center,
    HorizontalAlignment = Enum.HorizontalAlignment.Left, Parent = TierBox})

local TierTag = New("TextLabel", {
    Size = UDim2.new(1, -124, 1, 0), BackgroundTransparency = 1,
    Text = "Min rarity", TextColor3 = T.MUTED,
    Font = Enum.Font.GothamSemibold, TextSize = 12,
    TextXAlignment = Enum.TextXAlignment.Left, TextTransparency = 1,
    LayoutOrder = 1, Parent = TierBox,
})
local Minus = New("TextButton", {
    Size = UDim2.fromOffset(26, 26), BackgroundColor3 = T.SURFACE, AutoButtonColor = false,
    Text = "\u{2212}", TextColor3 = T.HIGH, Font = Enum.Font.GothamBold, TextSize = 16,
    BackgroundTransparency = 1, TextTransparency = 1, LayoutOrder = 2, Parent = TierBox,
})
Corner(Minus, 8)
local TierLbl = New("TextLabel", {
    Size = UDim2.fromOffset(72, 26), BackgroundTransparency = 1,
    Text = "Any", TextColor3 = T.TEXT, Font = Enum.Font.GothamBold, TextSize = 11,
    TextTransparency = 1, LayoutOrder = 3, Parent = TierBox,
})
local Plus = New("TextButton", {
    Size = UDim2.fromOffset(26, 26), BackgroundColor3 = T.SURFACE, AutoButtonColor = false,
    Text = "+", TextColor3 = T.HIGH, Font = Enum.Font.GothamBold, TextSize = 16,
    BackgroundTransparency = 1, TextTransparency = 1, LayoutOrder = 4, Parent = TierBox,
})
Corner(Plus, 8)

-- scope + test row
local RowBtns = New("Frame", {
    Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1,
    LayoutOrder = 3, Parent = Content,
})
New("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal,
    Padding = UDim.new(0, 6), VerticalAlignment = Enum.VerticalAlignment.Center, Parent = RowBtns})

local function smallBtn(text, order, width)
    local b = New("TextButton", {
        Size = UDim2.fromOffset(width, 30), BackgroundColor3 = T.RAISED,
        AutoButtonColor = false, ClipsDescendants = true, Text = text,
        TextColor3 = T.MUTED, Font = Enum.Font.GothamSemibold, TextSize = 11,
        BackgroundTransparency = 1, TextTransparency = 1,
        LayoutOrder = order, Parent = RowBtns,
    })
    Corner(b, 10)
    return b
end
local W = (PANEL_W - 32 - 12) / 3
local ScopeBtn = smallBtn("Scope: ALL", 1, W)
local TestBtn  = smallBtn("Fake log",   2, W)
local ClearBtn = smallBtn("Clear",      3, W)

local StatsLbl = New("TextLabel", {
    Size = UDim2.new(1, 0, 0, 14), BackgroundTransparency = 1,
    Text = "seen 0  fired 0  ok 0  fail 0", TextColor3 = T.MUTED,
    Font = Enum.Font.Gotham, TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left, TextTransparency = 1,
    LayoutOrder = 4, Parent = Content,
})

local FeedFrame = New("ScrollingFrame", {
    Size = UDim2.new(1, 0, 0, 150), BackgroundColor3 = T.BG,
    BackgroundTransparency = 1, BorderSizePixel = 0,
    ScrollBarThickness = 3, ScrollBarImageColor3 = T.LINE,
    CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
    LayoutOrder = 5, Parent = Content,
})
Corner(FeedFrame, 10)
local FeedStroke = Stroke(FeedFrame, T.LINE, 1, 1)
New("UIListLayout", {Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = FeedFrame})
Pad(FeedFrame, 6)

----------------------------------------------------------------
-- feed rows
----------------------------------------------------------------

local rowOrder = 0
local function addRow(title, color, sub, userId)
    rowOrder += 1
    local row = New("TextButton", {
        Size = UDim2.new(1, 0, 0, sub and 34 or 22),
        BackgroundColor3 = T.SURFACE, BackgroundTransparency = 0.35,
        AutoButtonColor = false, Text = "", BorderSizePixel = 0,
        LayoutOrder = -rowOrder, Parent = FeedFrame,
    })
    Corner(row, 6)
    New("TextLabel", {
        Size = UDim2.new(1, -10, 0, sub and 16 or 22), Position = UDim2.fromOffset(6, 0),
        BackgroundTransparency = 1, Text = title, TextColor3 = color or T.TEXT,
        Font = Enum.Font.GothamSemibold, TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd, Parent = row,
    })
    if sub then
        New("TextLabel", {
            Size = UDim2.new(1, -10, 0, 14), Position = UDim2.fromOffset(6, 16),
            BackgroundTransparency = 1, Text = sub, TextColor3 = T.MUTED,
            Font = Enum.Font.Gotham, TextSize = 10,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd, Parent = row,
        })
    end

    row.MouseEnter:Connect(function() tw(row, 0.12, nil, nil, {BackgroundTransparency = 0.15}):Play() end)
    row.MouseLeave:Connect(function() tw(row, 0.18, nil, nil, {BackgroundTransparency = 0.35}):Play() end)

    -- QOL: click a row to manually invite that owner, copy id on the notification
    if userId then
        row.MouseButton1Click:Connect(function()
            if setclipboard then pcall(setclipboard, tostring(userId)) end
            L.Sent[userId] = nil
            L.Fire(userId, tostring(userId), os.clock(), true)
        end)
    end

    local kids = FeedFrame:GetChildren()
    local count = 0
    for _, c in ipairs(kids) do if c:IsA("GuiButton") then count += 1 end end
    if count > L.MaxRows then
        local oldest, ord = nil, math.huge
        for _, c in ipairs(kids) do
            if c:IsA("GuiButton") and c.LayoutOrder < ord then ord, oldest = c.LayoutOrder, c end
        end
        if oldest then oldest:Destroy() end
    end
end

local function refreshStats()
    StatsLbl.Text = ("seen %d  fired %d  ok %d  fail %d  skip %d%s"):format(
        L.Stats.seen, L.Stats.fired, L.Stats.ok, L.Stats.fail, L.Stats.skipped,
        L.BestDispatch and ("   best " .. fmt(L.BestDispatch)) or "")
end

----------------------------------------------------------------
-- hot path
----------------------------------------------------------------

function L.Fire(userId, label, t0, manual)
    if not L.InviteRF then
        L.Notify("Invite remote unavailable", T.RED)
        return
    end
    L.Stats.fired += 1
    local dispatch = (os.clock() - t0) * 1000
    if not L.BestDispatch or dispatch < L.BestDispatch then L.BestDispatch = dispatch end

    task.spawn(function()
        local tCall = os.clock()
        local ok, a, b = pcall(L.InviteRF.InvokeServer, L.InviteRF, L.InviteGUID, userId)
        local rtt = (os.clock() - tCall) * 1000
        local line = ("dispatch %s \u{00B7} server %s"):format(fmt(dispatch), fmt(rtt))
        if ok and a then
            L.Stats.ok += 1
            addRow(("SENT \u{2192} %s"):format(label), T.GREEN, line, nil)
            L.Notify((manual and "Manual invite \u{2192} " or "Sniped \u{2192} ") .. label, T.GREEN, line)
        else
            L.Stats.fail += 1
            local why = tostring(ok and b or a)
            addRow(("FAIL \u{2192} %s"):format(label), T.RED, line .. " \u{00B7} " .. why, nil)
            L.Notify("Invite failed: " .. why, T.RED, line)
        end
        refreshStats()
    end)
    refreshStats()
end

function L.OnEntry(entry, faked)
    local t0 = os.clock()
    if type(entry) ~= "table" then return end
    if type(entry.BrainrotName) ~= "string" then return end

    L.Stats.seen += 1
    local uid    = entry.OwnerUserId
    local name   = entry.OwnerDisplayName
    local scope  = entry.IsLocalServer and "[SERVER]" or "[GLOBAL]"
    local rarity = L.RarityOf(entry.BrainrotName)
    local mut    = entry.Mutation and (" <" .. tostring(entry.Mutation) .. ">") or ""

    local tag = ""
    if entry.IsFuse then tag = " [FUSE]"
    elseif entry.IsCodes then tag = " [CODES]"
    elseif entry.IsTrader then tag = " [TRADERS]"
    elseif entry.IsBeeMerchant then tag = " [QUEEN BEE]"
    elseif entry.IsRNGMachine then tag = " [RNG]" end

    local col = rarity and L.TierColor[rarity:lower()] or (faked and T.ORANGE or T.TEXT)
    addRow(("%s%s %s%s"):format(scope, mut, entry.BrainrotName, tag), col,
        uid and ("%s  \u{00B7}  %s (%s)"):format(rarity or "?", tostring(name or "?"), tostring(uid))
             or ((rarity or "?") .. "  \u{00B7}  UNCLAIMED"),
        uid)

    -- filters
    if not L.AutoOn then refreshStats() return end
    if type(uid) ~= "number" or uid == LP.UserId then L.Stats.skipped += 1 refreshStats() return end
    if L.Blacklist[uid] then L.Stats.skipped += 1 refreshStats() return end
    if L.Scope == "GLOBAL" and entry.IsLocalServer then L.Stats.skipped += 1 refreshStats() return end
    if L.Scope == "SERVER" and not entry.IsLocalServer then L.Stats.skipped += 1 refreshStats() return end
    if L.MinTier > 1 then
        local ti = rarity and L.TierIndex[rarity:lower()]
        if not ti or ti < L.MinTier then L.Stats.skipped += 1 refreshStats() return end
    end
    local last = L.Sent[uid]
    if last and (os.clock() - last) < L.Cooldown then L.Stats.skipped += 1 refreshStats() return end
    L.Sent[uid] = os.clock()

    L.Fire(uid, ("%s (%s)"):format(tostring(name or uid), tostring(uid)), t0, false)
end

if L.NewEntry then
    L.NewEntry.OnClientEvent:Connect(function(entry) L.OnEntry(entry, false) end)
end
if L.ClaimEntry then
    L.ClaimEntry.OnClientEvent:Connect(function(_, ownerUserId, ownerDisplayName)
        if type(ownerUserId) == "number" then
            L.OnEntry({UID = "claim", BrainrotName = "(claimed)", OwnerUserId = ownerUserId,
                OwnerDisplayName = ownerDisplayName, IsLocalServer = false}, false)
        end
    end)
end

----------------------------------------------------------------
-- interactions
----------------------------------------------------------------

local function ripple(btn, tint)
    btn.MouseButton1Down:Connect(function(x, y)
        local abs = btn.AbsolutePosition
        local size = math.max(btn.AbsoluteSize.X, btn.AbsoluteSize.Y) * 2
        local r = New("Frame", {
            Size = UDim2.fromOffset(0, 0),
            Position = UDim2.fromOffset(x - abs.X, y - abs.Y),
            AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = tint or T.WHITE,
            BackgroundTransparency = 0.75, BorderSizePixel = 0, ZIndex = 10, Parent = btn,
        })
        Corner(r, 999)
        tw(r, 0.45, Enum.EasingStyle.Quad, nil, {
            Size = UDim2.fromOffset(size, size), BackgroundTransparency = 1}):Play()
        task.delay(0.5, function() r:Destroy() end)
    end)
end
local function press(btn, sink)
    btn.MouseButton1Down:Connect(function()
        tw(btn, 0.08, Enum.EasingStyle.Quad, nil, {Size = btn.Size - UDim2.fromOffset(0, 2)}):Play()
    end)
    local function up() tw(btn, 0.16, Enum.EasingStyle.Back, nil, {Size = sink}):Play() end
    btn.MouseButton1Up:Connect(up); btn.MouseLeave:Connect(up)
end
local function hoverFill(btn, base, hover)
    btn.MouseEnter:Connect(function() tw(btn, 0.15, nil, nil, {BackgroundColor3 = hover}):Play() end)
    btn.MouseLeave:Connect(function() tw(btn, 0.2, nil, nil, {BackgroundColor3 = base}):Play() end)
end

press(Minus, UDim2.fromOffset(26, 26)); press(Plus, UDim2.fromOffset(26, 26))
press(ScopeBtn, UDim2.fromOffset(W, 30)); press(TestBtn, UDim2.fromOffset(W, 30)); press(ClearBtn, UDim2.fromOffset(W, 30))
ripple(ScopeBtn, T.ACCENT); ripple(TestBtn, T.ACCENT); ripple(ClearBtn, T.ACCENT)
hoverFill(Minus, T.SURFACE, T.RAISED); hoverFill(Plus, T.SURFACE, T.RAISED)
hoverFill(ScopeBtn, T.RAISED, T.RAISED:Lerp(T.ACCENT, 0.12))
hoverFill(TestBtn,  T.RAISED, T.RAISED:Lerp(T.ACCENT, 0.12))
hoverFill(ClearBtn, T.RAISED, Color3.fromRGB(50, 22, 34))
hoverFill(MinBtn,   T.RAISED, T.RAISED:Lerp(T.ACCENT, 0.2))
hoverFill(CloseBtn, T.RAISED, Color3.fromRGB(50, 22, 34))

L.SetAuto = function(on)
    L.AutoOn = on
    tw(Switch, 0.18, nil, nil, {BackgroundColor3 = on and T.ACCENT or T.SURFACE}):Play()
    tw(SwitchStroke, 0.18, nil, nil, {Color = on and T.HIGH or T.LINE, Transparency = on and 0.3 or 0.5}):Play()
    TS:Create(Knob, TweenInfo.new(0.26, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
        Position = on and UDim2.new(1, -17, 0.5, -7) or UDim2.new(0, 3, 0.5, -7),
        BackgroundColor3 = on and T.WHITE or T.MUTED}):Play()
    tw(AutoTag, 0.18, nil, nil, {TextColor3 = on and T.TEXT or T.MUTED}):Play()
    tw(AutoStroke, 0.18, nil, nil, {Color = on and T.ACCENT or T.LINE, Transparency = on and 0.35 or 0.5}):Play()
    L.Notify(on and "Auto snipe enabled" or "Auto snipe disabled", on and T.GREEN or T.MUTED)
end
Switch.MouseButton1Click:Connect(function() L.SetAuto(not L.AutoOn) end)

local function refreshTier()
    local name = L.Tiers[L.MinTier]
    TierLbl.Text = name
    TierLbl.TextColor3 = (L.MinTier == 1) and T.MUTED or (L.TierColor[name:lower()] or T.TEXT)
end
Minus.MouseButton1Click:Connect(function() L.MinTier = math.max(1, L.MinTier - 1) refreshTier() end)
Plus.MouseButton1Click:Connect(function() L.MinTier = math.min(#L.Tiers, L.MinTier + 1) refreshTier() end)

local scopes = {"ALL", "GLOBAL", "SERVER"}
ScopeBtn.MouseButton1Click:Connect(function()
    local i = table.find(scopes, L.Scope) or 1
    L.Scope = scopes[(i % #scopes) + 1]
    ScopeBtn.Text = "Scope: " .. L.Scope
end)

TestBtn.MouseButton1Click:Connect(function()
    L.OnEntry({
        UID              = "FAKE-" .. tostring(math.random(1e6)),
        BrainrotName     = "Test Brainrot",
        Mutation         = "Gold",
        OwnerUserId      = 902460523,
        OwnerDisplayName = "kasthmz",
        Timestamp        = workspace:GetServerTimeNow(),
        DisplayDuration  = 30,
        IsLocalServer    = false,
    }, true)
end)

ClearBtn.MouseButton1Click:Connect(function()
    for _, c in ipairs(FeedFrame:GetChildren()) do if c:IsA("GuiButton") then c:Destroy() end end
    L.Sent = {}
    L.Stats = {seen = 0, fired = 0, ok = 0, fail = 0, skipped = 0}
    L.BestDispatch = nil
    refreshStats()
    L.Notify("Feed cleared", T.MUTED)
end)

-- FAB + minimize / close
local Fab = New("TextButton", {
    Size = UDim2.fromOffset(48, 48), Position = UDim2.new(0, 20, 1, -90),
    BackgroundColor3 = T.SURFACE, AutoButtonColor = false,
    Text = "L", TextColor3 = T.HIGH, Font = Enum.Font.GothamBold, TextSize = 18,
    Visible = false, Parent = Gui,
})
Corner(Fab, 14)
local FabStroke = Stroke(Fab, T.ACCENT, 1, 0.5)
hoverFill(Fab, T.SURFACE, T.RAISED)
task.spawn(function()
    while Fab.Parent do
        if Fab.Visible then
            tw(FabStroke, 1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, {Transparency = 0.85, Thickness = 2}):Play()
            task.wait(1.1)
            tw(FabStroke, 1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, {Transparency = 0.35, Thickness = 1}):Play()
            task.wait(1.1)
        else
            task.wait(0.4)
        end
    end
end)

local minimized = false
local function fit(instant)
    if minimized then return end
    local h = ContentList.AbsoluteContentSize.Y + 64
    if instant then Panel.Size = UDim2.fromOffset(PANEL_W, h)
    else tw(Panel, 0.28, Enum.EasingStyle.Quart, nil, {Size = UDim2.fromOffset(PANEL_W, h)}):Play() end
end
ContentList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function() fit(false) end)

MinBtn.MouseButton1Click:Connect(function()
    minimized = not minimized
    if minimized then
        Content.Visible = false
        tw(Panel, 0.26, Enum.EasingStyle.Quart, nil, {Size = UDim2.fromOffset(PANEL_W, 44)}):Play()
        MinBtn.Text = "+"
    else
        MinBtn.Text = "\u{2014}"
        fit(false)
        task.delay(0.1, function() if not minimized then Content.Visible = true end end)
    end
end)
CloseBtn.MouseButton1Click:Connect(function()
    tw(Panel, 0.2, Enum.EasingStyle.Quart, nil, {
        BackgroundTransparency = 1,
        Size = UDim2.fromOffset(PANEL_W * 0.9, Panel.Size.Y.Offset * 0.9)}):Play()
    task.delay(0.2, function()
        Panel.Visible = false
        Panel.BackgroundTransparency = 0.7
        fit(true)
        Fab.Visible = true
        Fab.Rotation = -90
        Fab.Size = UDim2.fromOffset(0, 0)
        tw(Fab, 0.3, Enum.EasingStyle.Back, nil, {Rotation = 0, Size = UDim2.fromOffset(48, 48)}):Play()
    end)
end)
Fab.MouseButton1Click:Connect(function()
    tw(Fab, 0.18, Enum.EasingStyle.Quart, nil, {Rotation = 90, Size = UDim2.fromOffset(0, 0)}):Play()
    task.delay(0.18, function()
        Fab.Visible = false; Fab.Rotation = 0; Fab.Size = UDim2.fromOffset(48, 48)
        Panel.Visible = true
    end)
end)

-- drag
local function draggable(frame, handle)
    handle = handle or frame
    local dragging, start, spos
    handle.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging = true; start = i.Position; spos = frame.Position
            i.Changed:Connect(function()
                if i.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    UIS.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
            local d = i.Position - start
            frame.Position = UDim2.new(spos.X.Scale, spos.X.Offset + d.X, spos.Y.Scale, spos.Y.Offset + d.Y)
        end
    end)
end
draggable(Panel, Handle); draggable(Fab, Fab)

-- QOL: RightShift hides/shows the whole UI
UIS.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == Enum.KeyCode.RightShift then
        Gui.Enabled = not Gui.Enabled
    end
end)

----------------------------------------------------------------
-- boot sequence
----------------------------------------------------------------

refreshTier()
refreshStats()

task.spawn(function()
    for i, lbl in ipairs(Letters) do
        task.delay((i - 1) * 0.055, function()
            TS:Create(lbl, TweenInfo.new(0.7, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
                Position = UDim2.fromOffset(0, 0), Rotation = 0, TextTransparency = 0}):Play()
        end)
    end
    task.wait(0.055 * #Letters + 0.35)

    tw(Underline, 0.55, Enum.EasingStyle.Quart, nil, {Size = UDim2.new(0.72, 0, 0, 2)}):Play()
    task.wait(0.15)
    tw(Sub, 0.4, nil, nil, {TextTransparency = 0}):Play()

    local steps = {
        "loading modules",
        L.NewEntry and "liveboard hooked" or "liveboard MISSING",
        L.InviteRF and "invite remote resolved" or "invite remote MISSING",
        "arming filters",
        "ready",
    }
    for _, s in ipairs(steps) do Sub.Text = s task.wait(0.26) end
    task.wait(0.18)

    for _, lbl in ipairs(Letters) do
        TS:Create(lbl, TweenInfo.new(0.35), {TextTransparency = 1}):Play()
    end
    tw(Sub, 0.3, nil, nil, {TextTransparency = 1}):Play()
    tw(Underline, 0.35, nil, nil, {Size = UDim2.new(0, 0, 0, 2), BackgroundTransparency = 1}):Play()
    task.wait(0.4)

    L.RainActive = false
    task.delay(2.5, function() if Loader.Parent then Loader:Destroy() end end)

    fit(true)
    local target = Panel.Size
    Panel.Size = UDim2.fromOffset(PANEL_W, math.floor(target.Y.Offset * 0.86))
    Panel.Position = UDim2.new(Panel.Position.X.Scale, Panel.Position.X.Offset,
                               Panel.Position.Y.Scale, Panel.Position.Y.Offset + 24)
    TS:Create(Panel, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
        BackgroundTransparency = 0.7, Size = target,
        Position = UDim2.new(Panel.Position.X.Scale, Panel.Position.X.Offset,
                             Panel.Position.Y.Scale, Panel.Position.Y.Offset - 24)}):Play()
    tw(PanelStroke, 0.42, nil, nil, {Transparency = 0.35}):Play()
    tw(Brand, 0.4, nil, nil, {TextTransparency = 0}):Play()
    tw(Dot, 0.4, nil, nil, {BackgroundTransparency = 0}):Play()
    tw(MinBtn, 0.4, nil, nil, {BackgroundTransparency = 0, TextTransparency = 0}):Play()
    tw(CloseBtn, 0.4, nil, nil, {BackgroundTransparency = 0, TextTransparency = 0}):Play()

    task.delay(0.05, function()
        tw(AutoBox, 0.4, nil, nil, {BackgroundTransparency = 0}):Play()
        tw(AutoStroke, 0.4, nil, nil, {Transparency = 0.5}):Play()
        tw(SwitchStroke, 0.4, nil, nil, {Transparency = 0.5}):Play()
        tw(AutoTag, 0.3, nil, nil, {TextTransparency = 0}):Play()
        tw(Switch, 0.3, nil, nil, {BackgroundTransparency = 0}):Play()
        tw(Knob, 0.3, nil, nil, {BackgroundTransparency = 0}):Play()
    end)
    task.delay(0.12, function()
        tw(TierBox, 0.4, nil, nil, {BackgroundTransparency = 0}):Play()
        tw(TierStroke, 0.4, nil, nil, {Transparency = 0.5}):Play()
        tw(TierTag, 0.3, nil, nil, {TextTransparency = 0}):Play()
        tw(TierLbl, 0.3, nil, nil, {TextTransparency = 0}):Play()
        tw(Minus, 0.3, nil, nil, {BackgroundTransparency = 0, TextTransparency = 0}):Play()
        tw(Plus,  0.3, nil, nil, {BackgroundTransparency = 0, TextTransparency = 0}):Play()
    end)
    task.delay(0.19, function()
        for _, b in ipairs({ScopeBtn, TestBtn, ClearBtn}) do
            tw(b, 0.4, nil, nil, {BackgroundTransparency = 0, TextTransparency = 0}):Play()
        end
        tw(StatsLbl, 0.4, nil, nil, {TextTransparency = 0}):Play()
    end)
    task.delay(0.26, function()
        tw(FeedFrame, 0.4, nil, nil, {BackgroundTransparency = 0.35}):Play()
        tw(FeedStroke, 0.4, nil, nil, {Transparency = 0.5}):Play()
    end)

    task.delay(0.6, function() L.DotReady = true end)
    task.delay(0.7, function()
        if L.Ready then
            L.Notify("Liveboard sniper online", T.HIGH)
        else
            L.Notify("Online, but a remote is missing", T.RED,
                ("NewEntry %s \u{00B7} Invite %s"):format(
                    L.NewEntry and "ok" or "MISSING", L.InviteRF and "ok" or "MISSING"))
        end
    end)
end)

-- backfill the board once, so you see existing entries immediately
if L.GetEntries then
    task.spawn(function()
        local ok, data = pcall(L.GetEntries.InvokeServer, L.GetEntries)
        if ok and type(data) == "table" then
            local n = 0
            for _, e in pairs(data) do
                if type(e) == "table" then n += 1 L.OnEntry(e, false) end
            end
            if n > 0 then L.Notify(("Backfilled %d entries"):format(n), T.MUTED) end
        end
    end)
end

return L
