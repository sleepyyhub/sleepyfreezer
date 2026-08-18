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
L.SearchFirst  = true        -- mimic the real UI: SearchUser before Invite
L.MaxPerMin    = 6           -- hard ceiling on invites per rolling minute
L.MinGap       = 4.0         -- minimum seconds between any two invites
L.TradeCooldown = 90         -- after a trade lands, wait this long before the next
L.LastTradeAt  = nil         -- os.clock() of the last accepted/sent trade
L.Jitter       = 1.5         -- extra random delay, up to this many seconds
L.FireLog      = {}          -- timestamps of recent invites

-- rarity accent colours, used for the obtainment/rarity text on a card
L.TierColor = {
    ["common"]       = Color3.fromRGB(159, 173, 189),
    ["uncommon"]     = Color3.fromRGB( 87, 199, 133),
    ["rare"]         = Color3.fromRGB( 52, 152, 219),
    ["epic"]         = Color3.fromRGB(155, 110, 200),
    ["legendary"]    = Color3.fromRGB(241, 196,  15),
    ["mythic"]       = Color3.fromRGB(233, 121, 163),
    ["brainrot god"] = Color3.fromRGB(231,  76,  60),
    ["secret"]       = Color3.fromRGB(120, 110, 235),
    ["divine"]       = Color3.fromRGB(255, 215,   0),
    ["og"]           = Color3.fromRGB(255, 255, 255),
}
L.IgnoreServer = true        -- [SERVER] entries are ignored; global feed only
L.Sent         = {}          -- userId -> os.clock()
L.Blacklist    = {}          -- userId -> true
L.Stats        = {seen = 0, fired = 0, ok = 0, fail = 0, skipped = 0}
L.BestDispatch = nil
L.MaxRows      = 40

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

L.InviteRF   = nil
L.SearchRF   = nil
L.SearchGUID = "792baf13-54a1-4663-92c4-1edd9da1e3e2"
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
        -- SearchUser sits at upvalue 12 of _createPlayerList
        local oks, sv = pcall(debug.getupvalue, TC._createPlayerList, 12)
        if oks and typeof(sv) == "Instance" and sv:IsA("RemoteFunction") then L.SearchRF = sv end
    end
end

L.Animals      = safe(function() return require(RepS.Datas.Animals) end)
L.SharedAnimals = safe(function() return require(RepS.Shared.Animals) end)
L.RichText     = safe(function() return require(RepS.Controllers.CustomRichTextController) end)
L.Gradients    = safe(function() return require(RepS.Packages.Gradients) end)

L.MutationText = safe(function() return require(RepS.Shared.MutationText) end)
L.MutationData = safe(function() return require(RepS.Datas.Mutations) end)

-- The game owns the rarity -> style mapping. GetRarityStringFormat returns a
-- FORMAT STRING containing %s -- "<zebra>%s</zebra>" for Secret, "<og>%s</og>"
-- for OG, "<font color=\"#ff0000\">%s</font>" for Mythic -- so it must be
-- formatted before rendering. This table is only a fallback.
L.RarityEffect = {
    ["og"]           = "OG",
    ["secret"]       = "Zebra",
    ["divine"]       = "Rainbow",
    ["brainrot god"] = "YellowRed",
    ["mythic"]       = "GreenRed",
}

function L.PaintRarity(label, rarity)
    if not rarity then return false end
    label.RichText = true

    if L.SharedAnimals and typeof(L.SharedAnimals.GetRarityStringFormat) == "function" then
        local ok, fmtStr = pcall(function()
            return L.SharedAnimals:GetRarityStringFormat(rarity)
        end)
        if ok and type(fmtStr) == "string" and fmtStr ~= "" then
            local okF, markup = pcall(string.format, fmtStr, rarity:upper())
            if okF and type(markup) == "string" then
                -- gradient tags (<og>, <zebra>) need the rich-text controller;
                -- plain <font> markup renders on its own
                if markup:find("<%a+>") and L.RichText then
                    local applied = pcall(function()
                        L.RichText.apply(label, markup, {attachToInstance = true})
                    end)
                    if applied then return true end
                end
                -- plain <font> markup renders on its own
                if markup:find("<") then
                    label.Text = markup
                    return true
                end
                -- the game styles some rarities (Divine) not at all; fall
                -- through to our own effect table rather than leaving it flat
            end
        end
    end

    local effect = L.RarityEffect[rarity:lower()]
    if effect and L.Gradients then
        if pcall(function() L.Gradients.apply(label, effect) end) then return true end
    end
    return false
end

-- paint a label as a mutation; the game handles colour, bold and any
-- gradient (Crystal, Phantom, Rainbow, Christmas) itself
function L.PaintMutation(label, mutation)
    if not mutation then return false end
    label.RichText = true      -- Phantom writes <b>..</b> straight into Text

    if L.MutationText and typeof(L.MutationText.apply) == "function" then
        if pcall(function() L.MutationText.apply(label, mutation) end) then return true end
    end

    local rec = L.MutationData and L.MutationData[mutation]
    if type(rec) == "table" and typeof(rec.MainColor) == "Color3" then
        label.Text = tostring(rec.DisplayText or mutation)
        label.TextColor3 = rec.MainColor
        return true
    end
    return false
end

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

local Letters, LetterStrokes = {}, {}
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
    local st = New("UIStroke", {Color = Color3.fromRGB(0, 0, 0), Thickness = 2, Transparency = 0.1,
        LineJoinMode = Enum.LineJoinMode.Round, Parent = lbl})
    Letters[i] = lbl
    LetterStrokes[i] = st
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

local PANEL_W = IS_MOBILE and 340 or 400
local Panel = New("Frame", {
    Size = UDim2.fromOffset(PANEL_W, 380),
    Position = UDim2.new(0.5, -(PANEL_W / 2), 0.5, -190 + 40),
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
local ContentList = New("UIListLayout", {Padding = UDim.new(0, 12),
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
    Size = UDim2.new(1, 0, 0, 48), BackgroundColor3 = T.RAISED,
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

-- action row
local RowBtns = New("Frame", {
    Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1,
    LayoutOrder = 3, Parent = Content,
})
New("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal,
    Padding = UDim.new(0, 8), VerticalAlignment = Enum.VerticalAlignment.Center, Parent = RowBtns})

local function smallBtn(text, order, width)
    local b = New("TextButton", {
        Size = UDim2.fromOffset(width, 34), BackgroundColor3 = T.RAISED,
        AutoButtonColor = false, ClipsDescendants = true, Text = text,
        TextColor3 = T.MUTED, Font = Enum.Font.GothamSemibold, TextSize = 11,
        BackgroundTransparency = 1, TextTransparency = 1,
        LayoutOrder = order, Parent = RowBtns,
    })
    Corner(b, 10)
    return b
end
local W = PANEL_W - 32
local ClearBtn = smallBtn("Clear feed", 1, W)

local StatsLbl = New("TextLabel", {
    Size = UDim2.new(1, 0, 0, 14), BackgroundTransparency = 1,
    Text = "seen 0  fired 0  ok 0  fail 0", TextColor3 = T.MUTED,
    Font = Enum.Font.Gotham, TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left, TextTransparency = 1,
    LayoutOrder = 4, Parent = Content,
})

local FeedFrame = New("ScrollingFrame", {
    Size = UDim2.new(1, 0, 0, 250), BackgroundColor3 = T.BG,
    BackgroundTransparency = 1, BorderSizePixel = 0,
    ScrollBarThickness = 3, ScrollBarImageColor3 = T.LINE,
    CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
    LayoutOrder = 5, Parent = Content,
})
Corner(FeedFrame, 12)
local FeedStroke = Stroke(FeedFrame, T.LINE, 1, 1)
New("UIListLayout", {Padding = UDim.new(0, 7), SortOrder = Enum.SortOrder.LayoutOrder, Parent = FeedFrame})
Pad(FeedFrame, 8)

----------------------------------------------------------------
-- feed rows
----------------------------------------------------------------

----------------------------------------------------------------
-- live player status
--   green  online   - present in this server
--   yellow busy     - server told us they are mid-trade / not available
--   red    offline  - seen here and then left
-- Players in other servers are unknowable from a client, so they stay
-- unknown (grey) until an invite or search tells us something concrete.
----------------------------------------------------------------

L.Status = {}          -- userId -> {state, at}
L.StatusDots = {}      -- userId -> { dot, ... } live indicators to repaint

L.StateColor = {
    online  = T.GREEN,
    busy    = Color3.fromRGB(255, 205, 90),
    offline = T.RED,
    unknown = T.MUTED,
}
L.StateLabel = {
    online  = "Online",
    busy    = "Busy",
    offline = "Offline",
    unknown = "Unknown",
}

function L.GetStatus(userId)
    if type(userId) ~= "number" then return "unknown" end
    if Players:GetPlayerByUserId(userId) then return "online" end
    local rec = L.Status[userId]
    return rec and rec.state or "unknown"
end

function L.SetStatus(userId, state)
    if type(userId) ~= "number" then return end
    L.Status[userId] = {state = state, at = os.clock()}
    local dots = L.StatusDots[userId]
    if not dots then return end
    for dot, lbl in pairs(dots) do
        if dot.Parent then
            tw(dot, 0.25, nil, nil, {BackgroundColor3 = L.StateColor[state] or T.MUTED}):Play()
            if lbl and lbl.Parent then lbl.Text = L.StateLabel[state] or "Unknown" end
        else
            dots[dot] = nil
        end
    end
end

Players.PlayerRemoving:Connect(function(p)
    if p ~= LP then L.SetStatus(p.UserId, "offline") end
end)
Players.PlayerAdded:Connect(function(p)
    if p ~= LP then L.SetStatus(p.UserId, "online") end
end)

-- one breathing loop drives every dot on screen, rather than one per row
L.Breath = 0
task.spawn(function()
    while true do
        local t = tick()
        L.Breath = (math.sin(t * 2.2) + 1) / 2      -- 0..1
        for uid, dots in pairs(L.StatusDots) do
            for dot in pairs(dots) do
                if dot.Parent then
                    dot.BackgroundTransparency = 0.12 + L.Breath * 0.45
                else
                    dots[dot] = nil
                end
            end
        end
        task.wait(0.05)
    end
end)

-- obtainment method, from the entry's source flags
function L.ObtainMethod(entry)
    if entry.IsFuse then return "Fuse Machine" end
    if entry.IsCodes then return "Code Redeem" end
    if entry.IsTrader then return "Los Traders" end
    if entry.IsBeeMerchant then return "Queen Bee" end
    if entry.IsRNGMachine then return "RNG Machine" end
    return nil                    -- ordinary spawn: say nothing
end

local rowOrder = 0

local function trimFeed()
    local kids = FeedFrame:GetChildren()
    local n = 0
    for _, c in ipairs(kids) do if c:IsA("GuiObject") then n += 1 end end
    while n > L.MaxRows do
        local oldest, ord = nil, math.huge
        for _, c in ipairs(FeedFrame:GetChildren()) do
            if c:IsA("GuiObject") and c.LayoutOrder < ord then ord, oldest = c.LayoutOrder, c end
        end
        if not oldest then break end
        oldest:Destroy()
        n -= 1
    end
end

-- slim status line (SENT / FAIL / notices)
local function addLine(text, color, sub)
    rowOrder += 1
    local row = New("Frame", {
        Size = UDim2.new(1, 0, 0, sub and 36 or 24),
        BackgroundColor3 = T.SURFACE, BackgroundTransparency = 0.45,
        BorderSizePixel = 0, LayoutOrder = -rowOrder, Parent = FeedFrame,
    })
    Corner(row, 6)
    New("Frame", {Size = UDim2.new(0, 2, 1, -8), Position = UDim2.fromOffset(6, 4),
        BackgroundColor3 = color or T.MUTED, BorderSizePixel = 0, Parent = row})
    New("TextLabel", {
        Size = UDim2.new(1, -24, 0, sub and 16 or 24), Position = UDim2.fromOffset(16, sub and 4 or 0),
        BackgroundTransparency = 1, Text = text, TextColor3 = color or T.TEXT,
        Font = Enum.Font.GothamSemibold, TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd, Parent = row,
    })
    if sub then
        New("TextLabel", {
            Size = UDim2.new(1, -24, 0, 13), Position = UDim2.fromOffset(16, 20),
            BackgroundTransparency = 1, Text = sub, TextColor3 = T.MUTED,
            Font = Enum.Font.Gotham, TextSize = 10,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd, Parent = row,
        })
    end
    trimFeed()
end

-- full entry card
--   [ model ]  Name
--              Obtainment      (o) Player      [ Trade ]
local function addCard(entry, rarity)
    rowOrder += 1
    local uid    = entry.OwnerUserId
    local name   = entry.OwnerDisplayName
    local obtain = L.ObtainMethod(entry)

    local CARD_H   = 96
    local RIGHT_W  = 88          -- reserved column for the Trade button, plus clearance
    local LEFT_X   = 88          -- text column starts after the model box

    local card = New("TextButton", {
        Size = UDim2.new(1, 0, 0, CARD_H),
        BackgroundColor3 = T.SURFACE, BackgroundTransparency = 0.4,
        AutoButtonColor = false, Text = "", BorderSizePixel = 0,
        LayoutOrder = -rowOrder, Parent = FeedFrame,
    })
    Corner(card, 10)
    local cardStroke = Stroke(card, T.LINE, 1, 0.7)

    -- model, vertically centred
    local box = New("Frame", {
        Size = UDim2.fromOffset(64, 64), Position = UDim2.fromOffset(12, (CARD_H - 64) / 2),
        BackgroundColor3 = T.BG, BackgroundTransparency = 0.25,
        BorderSizePixel = 0, ClipsDescendants = true, Parent = card,
    })
    Corner(box, 9)
    local vp = New("ViewportFrame", {
        Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
        Ambient = Color3.fromRGB(200, 214, 235),
        LightColor = Color3.fromRGB(255, 255, 255),
        LightDirection = Vector3.new(-0.4, -1, -0.6), Parent = box,
    })
    if L.SharedAnimals then
        task.spawn(function()
            pcall(function()
                L.SharedAnimals:AttachOnViewport(entry.BrainrotName, vp, nil, entry.Mutation)
            end)
        end)
    end

    -- row 1: name
    local title = New("TextLabel", {
        Size = UDim2.new(1, -(LEFT_X + RIGHT_W), 0, 22),
        Position = UDim2.fromOffset(LEFT_X, 10),
        BackgroundTransparency = 1, Text = entry.BrainrotName,
        TextColor3 = T.TEXT, Font = Enum.Font.GothamBold, TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd, Parent = card,
    })
    if L.RichText and L.SharedAnimals then
        pcall(function()
            L.RichText.apply(title, L.SharedAnimals:ColorBrainrotName(entry.BrainrotName),
                {attachToInstance = true})
        end)
    end

    -- row 2: rarity (fat, gradient-painted) then source, laid out inline
    if rarity or entry.Mutation or obtain then
        local metaRow = New("Frame", {
            Size = UDim2.new(1, -(LEFT_X + RIGHT_W), 0, 18),
            Position = UDim2.fromOffset(LEFT_X, 38),
            BackgroundTransparency = 1, Parent = card,
        })
        New("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            VerticalAlignment = Enum.VerticalAlignment.Center,
            Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder,
            Parent = metaRow,
        })
        if rarity then
            local rl = New("TextLabel", {
                AutomaticSize = Enum.AutomaticSize.X,
                Size = UDim2.fromOffset(0, 18), BackgroundTransparency = 1,
                Text = rarity:upper(),
                TextColor3 = L.TierColor[rarity:lower()] or T.TEXT,
                Font = Enum.Font.GothamBlack, TextSize = 13,
                TextXAlignment = Enum.TextXAlignment.Left,
                LayoutOrder = 1, Parent = metaRow,
            })
            New("UIStroke", {Color = Color3.fromRGB(0, 0, 0), Thickness = 1,
                Transparency = 0.55, Parent = rl})
            L.PaintRarity(rl, rarity)
        end
        if entry.Mutation then
            local ml = New("TextLabel", {
                AutomaticSize = Enum.AutomaticSize.X,
                Size = UDim2.fromOffset(0, 17), BackgroundTransparency = 1,
                Text = tostring(entry.Mutation), TextColor3 = T.TEXT,
                Font = Enum.Font.GothamBold, TextSize = 12,
                TextXAlignment = Enum.TextXAlignment.Left,
                LayoutOrder = 2, Parent = metaRow,
            })
            New("UIStroke", {Color = Color3.fromRGB(0, 0, 0), Thickness = 1,
                Transparency = 0.65, Parent = ml})
            L.PaintMutation(ml, entry.Mutation)
        end
        if obtain then
            New("TextLabel", {
                AutomaticSize = Enum.AutomaticSize.X,
                Size = UDim2.fromOffset(0, 16), BackgroundTransparency = 1,
                Text = obtain, TextColor3 = T.MUTED,
                Font = Enum.Font.GothamSemibold, TextSize = 11,
                TextXAlignment = Enum.TextXAlignment.Left,
                LayoutOrder = 3, Parent = metaRow,
            })
        end
    end

    -- row 3: owner
    local OWNER_Y = 62
    if uid then
        local head = New("ImageLabel", {
            Size = UDim2.fromOffset(24, 24), Position = UDim2.fromOffset(LEFT_X, OWNER_Y),
            BackgroundColor3 = T.BG, BackgroundTransparency = 0.3, BorderSizePixel = 0,
            Image = ("rbxthumb://type=AvatarHeadShot&id=%d&w=48&h=48"):format(uid),
            Parent = card,
        })
        Corner(head, 12)

        local state = L.GetStatus(uid)
        local dot = New("Frame", {
            Size = UDim2.fromOffset(10, 10),
            Position = UDim2.fromOffset(LEFT_X + 17, OWNER_Y + 16),
            BackgroundColor3 = L.StateColor[state] or T.MUTED,
            BackgroundTransparency = 0.15, BorderSizePixel = 0,
            ZIndex = 3, Parent = card,
        })
        Corner(dot, 5)
        New("UIStroke", {Color = T.SURFACE, Thickness = 2, Transparency = 0.1, Parent = dot})

        local TEXT_X = LEFT_X + 34
        New("TextLabel", {
            Size = UDim2.new(1, -(TEXT_X + RIGHT_W), 0, 13),
            Position = UDim2.fromOffset(TEXT_X, OWNER_Y - 1),
            BackgroundTransparency = 1, Text = tostring(name or uid),
            TextColor3 = T.TEXT, Font = Enum.Font.GothamSemibold, TextSize = 11,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd, Parent = card,
        })
        local stateLbl = New("TextLabel", {
            Size = UDim2.new(1, -(TEXT_X + RIGHT_W), 0, 12),
            Position = UDim2.fromOffset(TEXT_X, OWNER_Y + 13),
            BackgroundTransparency = 1, Text = L.StateLabel[state] or "Unknown",
            TextColor3 = L.StateColor[state] or T.MUTED,
            Font = Enum.Font.Gotham, TextSize = 10,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd, Parent = card,
        })

        L.StatusDots[uid] = L.StatusDots[uid] or {}
        L.StatusDots[uid][dot] = stateLbl
        card.Destroying:Connect(function()
            if L.StatusDots[uid] then L.StatusDots[uid][dot] = nil end
        end)

        local trade = New("TextButton", {
            Size = UDim2.fromOffset(62, 30),
            Position = UDim2.new(1, -74, 0, (CARD_H - 30) / 2),
            BackgroundColor3 = T.RAISED, AutoButtonColor = false, ClipsDescendants = true,
            Text = "Trade", TextColor3 = T.HIGH,
            Font = Enum.Font.GothamBold, TextSize = 11, Parent = card,
        })
        Corner(trade, 9)
        local tradeStroke = Stroke(trade, T.LINE, 1, 0.5)
        trade.MouseEnter:Connect(function()
            tw(trade, 0.12, nil, nil, {BackgroundColor3 = T.RAISED:Lerp(T.ACCENT, 0.25)}):Play()
            tw(tradeStroke, 0.12, nil, nil, {Color = T.ACCENT, Transparency = 0.25}):Play()
        end)
        trade.MouseLeave:Connect(function()
            tw(trade, 0.18, nil, nil, {BackgroundColor3 = T.RAISED}):Play()
            tw(tradeStroke, 0.18, nil, nil, {Color = T.LINE, Transparency = 0.5}):Play()
        end)
        trade.MouseButton1Click:Connect(function()
            if setclipboard then pcall(setclipboard, tostring(uid)) end
            L.Sent[uid] = nil
            trade.Text = "..."
            L.Fire(uid, tostring(name or uid), os.clock(), true)
            task.delay(1.2, function() if trade.Parent then trade.Text = "Trade" end end)
        end)
    else
        New("TextLabel", {
            Size = UDim2.new(1, -(LEFT_X + RIGHT_W), 0, 14),
            Position = UDim2.fromOffset(LEFT_X, OWNER_Y + 5),
            BackgroundTransparency = 1, Text = "UNCLAIMED", TextColor3 = T.RED,
            Font = Enum.Font.GothamSemibold, TextSize = 11,
            TextXAlignment = Enum.TextXAlignment.Left, Parent = card,
        })
    end

    card.MouseEnter:Connect(function()
        tw(card, 0.12, nil, nil, {BackgroundTransparency = 0.2}):Play()
        tw(cardStroke, 0.12, nil, nil, {Transparency = 0.3, Color = T.ACCENT}):Play()
    end)
    card.MouseLeave:Connect(function()
        tw(card, 0.18, nil, nil, {BackgroundTransparency = 0.4}):Play()
        tw(cardStroke, 0.18, nil, nil, {Transparency = 0.7, Color = T.LINE}):Play()
    end)

    trimFeed()
end

local function refreshStats()
    local base = ("%d seen   %d sent   %d skipped"):format(
        L.Stats.seen, L.Stats.ok, L.Stats.skipped + L.Stats.fail)
    if L.Debug and L.BestDispatch then
        base = base .. ("   best %s"):format(fmt(L.BestDispatch))
    end
    StatsLbl.Text = base
end

----------------------------------------------------------------
-- hot path
----------------------------------------------------------------

----------------------------------------------------------------
-- user-facing messages
-- Nothing raw from the server reaches the UI: no remote names, no return
-- values, no error strings, no timings. Everything is mapped to plain
-- language. Flip L.Debug for the underlying detail while developing.
----------------------------------------------------------------

L.Debug = false

function L.Friendly(raw)
    local w = tostring(raw or ""):lower()
    if w == "" then return "Couldn't send that invite" end
    if w:find("cooldown") or w:find("wait") or w:find("too fast") or w:find("spam") then
        return "Please wait before trading again"
    end
    if w:find("busy") or w:find("already") or w:find("in a trade") or w:find("trading") then
        return "They're busy right now"
    end
    if w:find("offline") or w:find("not found") or w:find("left") or w:find("no longer") then
        return "That player isn't available"
    end
    if w:find("disabled") or w:find("setting") or w:find("not accepting") or w:find("privacy") then
        return "They aren't accepting trades"
    end
    if w:find("full") or w:find("limit") or w:find("max") then
        return "Their trades are full"
    end
    if w:find("friend") then return "They only trade with friends" end
    if w:find("level") or w:find("requirement") or w:find("locked") then
        return "You don't meet their requirements"
    end
    return "Couldn't send that invite"
end

-- detail line: empty unless debugging
function L.Detail(...)
    if not L.Debug then return nil end
    local parts = {}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if v ~= nil and v ~= "" then parts[#parts + 1] = tostring(v) end
    end
    return #parts > 0 and table.concat(parts, "  \u{00B7}  ") or nil
end

-- rolling-window throttle: returns nil if allowed, else the reason
function L.ThrottleReason()
    local now = os.clock()
    local keep = {}
    for _, t in ipairs(L.FireLog) do
        if now - t < 60 then keep[#keep + 1] = t end
    end
    L.FireLog = keep
    if L.LastTradeAt and (now - L.LastTradeAt) < L.TradeCooldown then
        return ("Please wait %ds before trading again"):format(
            math.ceil(L.TradeCooldown - (now - L.LastTradeAt)))
    end
    if #keep >= L.MaxPerMin then
        return "Slowing down for a moment"
    end
    local last = keep[#keep]
    if last and (now - last) < L.MinGap then
        return ("Please wait %ds"):format(math.ceil(L.MinGap - (now - last)))
    end
    return nil
end

function L.Fire(userId, label, t0, manual)
    if not L.InviteRF then
        L.Notify("Trading isn't available right now", T.RED)
        return
    end

    -- manual clicks bypass the throttle; automated ones never do
    if not manual then
        local why = L.ThrottleReason()
        if why then
            L.Stats.skipped += 1
            addLine(why, T.ORANGE, label)
            refreshStats()
            return
        end
    end

    L.Stats.fired += 1
    L.FireLog[#L.FireLog + 1] = os.clock()
    local dispatch = (os.clock() - t0) * 1000
    if not L.BestDispatch or dispatch < L.BestDispatch then L.BestDispatch = dispatch end

    task.spawn(function()
        -- walk the same path the real UI walks: search, pause, then invite.
        -- inviting a userId the server never saw you search is the clearest
        -- automation tell there is, so we don't do that.
        local searchNote
        if L.SearchFirst and L.SearchRF then
            local okS, sOk, sFound = pcall(L.SearchRF.InvokeServer, L.SearchRF, L.SearchGUID, userId)
            searchNote = L.Detail(okS and ("search ok=%s found=%s"):format(tostring(sOk), tostring(sFound))
                                      or "search errored")
            if okS and sOk and sFound == false then
                L.SetStatus(userId, "busy")
                L.Stats.skipped += 1
                addLine(("SKIPPED \u{2192} %s"):format(label), T.MUTED, "Not available to trade")
                refreshStats()
                return
            end
            if okS and sOk and sFound then L.SetStatus(userId, "online") end
            -- human-ish beat between reading a result and clicking invite
            task.wait(0.35 + math.random() * L.Jitter)
        end

        local tCall = os.clock()
        local ok, a, b = pcall(L.InviteRF.InvokeServer, L.InviteRF, L.InviteGUID, userId)
        local rtt = (os.clock() - tCall) * 1000
        local detail = L.Detail(("dispatch %s"):format(fmt(dispatch)),
                                ("server %s"):format(fmt(rtt)), searchNote)
        if ok and a then
            L.Stats.ok += 1
            L.LastTradeAt = os.clock()          -- start the trade cooldown
            L.SetStatus(userId, "busy")         -- they now have our invite open
            addLine(("SENT \u{2192} %s"):format(label), T.GREEN, detail)
            L.Notify("Trade sent to " .. label, T.GREEN, detail)
        else
            L.Stats.fail += 1
            -- raw reason is used only to classify status; never shown
            local raw = tostring(ok and b or a):lower()
            if raw:find("trad") or raw:find("busy") or raw:find("already") then
                L.SetStatus(userId, "busy")
            elseif raw:find("offline") or raw:find("not found") or raw:find("left") then
                L.SetStatus(userId, "offline")
            end
            local msg = L.Friendly(raw)
            addLine(("%s \u{2192} %s"):format(msg, label), T.ORANGE,
                L.Detail(detail, "raw: " .. tostring(ok and b or a)))
            L.Notify(msg, T.ORANGE, detail)
        end
        refreshStats()
    end)
    refreshStats()
end

function L.OnEntry(entry)
    local t0 = os.clock()
    if type(entry) ~= "table" then return end
    if type(entry.BrainrotName) ~= "string" then return end

    L.Stats.seen += 1
    local uid    = entry.OwnerUserId
    local name   = entry.OwnerDisplayName
    local rarity = L.RarityOf(entry.BrainrotName)

    addCard(entry, rarity)

    -- filters
    if not L.AutoOn then refreshStats() return end
    if L.IgnoreServer and entry.IsLocalServer then L.Stats.skipped += 1 refreshStats() return end
    if type(uid) ~= "number" or uid == LP.UserId then L.Stats.skipped += 1 refreshStats() return end
    if L.Blacklist[uid] then L.Stats.skipped += 1 refreshStats() return end
    local last = L.Sent[uid]
    if last and (os.clock() - last) < L.Cooldown then L.Stats.skipped += 1 refreshStats() return end
    L.Sent[uid] = os.clock()

    L.Fire(uid, tostring(name or uid), t0, false)
end

if L.NewEntry then
    L.NewEntry.OnClientEvent:Connect(function(entry) L.OnEntry(entry) end)
end
if L.ClaimEntry then
    L.ClaimEntry.OnClientEvent:Connect(function(_, ownerUserId, ownerDisplayName)
        if type(ownerUserId) == "number" then
            L.OnEntry({UID = "claim", BrainrotName = "(claimed)", OwnerUserId = ownerUserId,
                OwnerDisplayName = ownerDisplayName, IsLocalServer = false})
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

press(ClearBtn, UDim2.fromOffset(W, 34))
ripple(ClearBtn, T.ACCENT)
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

ClearBtn.MouseButton1Click:Connect(function()
    for _, c in ipairs(FeedFrame:GetChildren()) do if c:IsA("GuiObject") then c:Destroy() end end
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
        L.NewEntry and "connecting to feed" or "feed unavailable",
        L.InviteRF and "preparing trades" or "trading unavailable",
        "arming filters",
        "ready",
    }
    for _, s in ipairs(steps) do Sub.Text = s task.wait(0.26) end
    task.wait(0.18)

    for i, lbl in ipairs(Letters) do
        TS:Create(lbl, TweenInfo.new(0.35), {TextTransparency = 1}):Play()
        if LetterStrokes[i] then
            TS:Create(LetterStrokes[i], TweenInfo.new(0.35), {Transparency = 1}):Play()
        end
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
    task.delay(0.19, function()
        for _, b in ipairs({ClearBtn}) do
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
            L.Notify("Ready", T.HIGH)
        else
            L.Notify("Some features are unavailable", T.ORANGE,
                L.Detail(("NewEntry %s"):format(L.NewEntry and "ok" or "missing"),
                         ("Invite %s"):format(L.InviteRF and "ok" or "missing")))
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
                if type(e) == "table" then n += 1 L.OnEntry(e) end
            end
            if n > 0 then L.Notify(("Loaded %d recent drops"):format(n), T.MUTED) end
        end
    end)
end

return L
