--!nocheck
-- LIVEBOARD SNIPER
-- Watches the Liveboard feed and fires TradeService/Invite at entry owners.
--
-- Remote resolution never relies on names: the Liveboard remotes are hashed
-- and rotate per server. Three strategies, cheapest first -- controller
-- upvalues, identity-by-listener, then plaintext.

local Players   = game:GetService("Players")
local UIS       = game:GetService("UserInputService")
local TS        = game:GetService("TweenService")
local RepS      = game:GetService("ReplicatedStorage")
local Lighting  = game:GetService("Lighting")
local LP        = Players.LocalPlayer
local PG        = LP:WaitForChild("PlayerGui")
local IS_MOBILE = UIS.TouchEnabled and not UIS.KeyboardEnabled and not UIS.MouseEnabled

local L = {}
local genv = (type(getgenv) == "function") and select(2, pcall(getgenv)) or nil
if genv then genv.LiveSniper = L end

----------------------------------------------------------------
-- state
----------------------------------------------------------------

L.InviteGUID    = "afb005f9-6e81-4e0a-8bb0-3555938a9658"
L.SearchGUID    = "792baf13-54a1-4663-92c4-1edd9da1e3e2"
L.AutoOn        = false
L.Cooldown      = 30
L.TradeCooldown = 90
L.LastTradeAt   = nil
L.SearchFirst   = true
L.MaxPerMin     = 6
L.MinGap        = 4.0
L.Jitter        = 1.5
L.FireLog       = {}
L.IgnoreServer  = true
L.Sent          = {}
L.Blacklist     = {}
L.Stats         = {seen = 0, fired = 0, ok = 0, fail = 0, skipped = 0}
L.BestDispatch  = nil
L.MaxRows       = 40
L.Debug         = false

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

local T = {
    VOID    = Color3.fromRGB(  4,  10,   7),
    BG      = Color3.fromRGB(  8,  17,  11),
    SURFACE = Color3.fromRGB( 12,  25,  16),
    RAISED  = Color3.fromRGB( 17,  36,  23),
    LINE    = Color3.fromRGB( 31,  60,  41),
    ACCENT  = Color3.fromRGB( 74, 222, 128),
    HIGH    = Color3.fromRGB(165, 255, 198),
    DEEP    = Color3.fromRGB( 22, 163,  74),
    TEXT    = Color3.fromRGB(228, 246, 233),
    MUTED   = Color3.fromRGB(108, 148, 120),
    RED     = Color3.fromRGB(255, 130, 155),
    GREEN   = Color3.fromRGB(146, 255, 103),
    ORANGE  = Color3.fromRGB(255, 190, 120),
    WHITE   = Color3.fromRGB(255, 255, 255),
}

local function safe(fn) local ok, r = pcall(fn); return ok and r or nil end
local function fmt(ms)
    if ms < 1  then return ("%.2fms"):format(ms) end
    if ms < 10 then return ("%.1fms"):format(ms) end
    return ("%.0fms"):format(ms)
end

----------------------------------------------------------------
-- game modules
----------------------------------------------------------------

L.Net           = safe(function() return RepS:WaitForChild("Packages", 10):WaitForChild("Net", 10) end)
L.Animals       = safe(function() return require(RepS.Datas.Animals) end)
L.SharedAnimals = safe(function() return require(RepS.Shared.Animals) end)
L.RichText      = safe(function() return require(RepS.Controllers.CustomRichTextController) end)
L.Gradients     = safe(function() return require(RepS.Packages.Gradients) end)
L.MutationText  = safe(function() return require(RepS.Shared.MutationText) end)
L.MutationData  = safe(function() return require(RepS.Datas.Mutations) end)

L.RarityEffect = {
    ["og"] = "OG", ["secret"] = "Zebra", ["divine"] = "Rainbow",
    ["brainrot god"] = "YellowRed", ["mythic"] = "GreenRed",
}

function L.RarityOf(name)
    if not L.Animals or type(name) ~= "string" then return nil end
    local rec = L.Animals[name]
    if type(rec) ~= "table" then return nil end
    local r = rec.Rarity or rec.RarityName or rec.Tier
    if type(r) == "string" then return r end
    if type(r) == "table" then return r.DisplayName or r.Name or r.Id end
    return nil
end

-- GetRarityStringFormat returns a FORMAT STRING containing %s
function L.PaintRarity(label, rarity)
    if not rarity then return false end
    label.RichText = true
    if L.SharedAnimals and typeof(L.SharedAnimals.GetRarityStringFormat) == "function" then
        local ok, fmtStr = pcall(function() return L.SharedAnimals:GetRarityStringFormat(rarity) end)
        if ok and type(fmtStr) == "string" and fmtStr ~= "" then
            local okF, markup = pcall(string.format, fmtStr, rarity:upper())
            if okF and type(markup) == "string" then
                if markup:find("<%a+>") and L.RichText then
                    if pcall(function()
                        L.RichText.apply(label, markup, {attachToInstance = true})
                    end) then return true end
                end
                if markup:find("<") then label.Text = markup return true end
            end
        end
    end
    local effect = L.RarityEffect[rarity:lower()]
    if effect and L.Gradients then
        if pcall(function() L.Gradients.apply(label, effect) end) then return true end
    end
    return false
end

function L.PaintMutation(label, mutation)
    if not mutation then return false end
    label.RichText = true
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

----------------------------------------------------------------
-- resolving the Liveboard remotes (names are hashed and rotate)
----------------------------------------------------------------

local getinfo = debug and (debug.getinfo or debug.info)

local function paramCount(fn)
    if not getinfo then return nil end
    local ok, a = pcall(getinfo, fn, "a")
    if ok and type(a) == "number" then return a end
    local ok2, info = pcall(getinfo, fn)
    if ok2 and type(info) == "table" then return info.numparams or info.nparams end
    return nil
end

local function sourceOf(fn)
    if not getinfo then return "" end
    local ok, a = pcall(getinfo, fn, "s")
    if ok and type(a) == "string" then return a end
    local ok2, info = pcall(getinfo, fn)
    if ok2 and type(info) == "table" then return tostring(info.short_src or info.source or "") end
    return ""
end

-- 1. LiveboardController.Start closes over all three remotes
function L.ResolveFromController()
    local ok, LC = pcall(require, RepS.Controllers.LiveboardController)
    if not ok or type(LC) ~= "table" or typeof(LC.Start) ~= "function" then return end
    local oku, ups = pcall(debug.getupvalues, LC.Start)
    if not oku then return end
    local events, funcs = {}, {}
    for i = 1, 60 do
        local v = ups[i]
        if typeof(v) == "Instance" then
            if v:IsA("RemoteEvent") then events[#events + 1] = v
            elseif v:IsA("RemoteFunction") then funcs[#funcs + 1] = v end
        end
    end
    return events[1], events[2], funcs[1]
end

-- 2. identity by listener: whose OnClientEvent handler lives in LiveboardController?
--    both handlers do, so tell them apart by parameter count
function L.ResolveByListener()
    if not (getconnections and getinfo and L.Net) then return end
    local newEntry, claimEntry
    for _, d in ipairs(L.Net:GetDescendants()) do
        if d:IsA("RemoteEvent") then
            local ok, conns = pcall(getconnections, d.OnClientEvent)
            if ok then
                for _, c in ipairs(conns) do
                    local okf, fn = pcall(function() return c.Function end)
                    if okf and type(fn) == "function"
                       and sourceOf(fn):find("LiveboardController", 1, true) then
                        local n = paramCount(fn)
                        if n == 1 and not newEntry then newEntry = d
                        elseif n == 3 and not claimEntry then claimEntry = d end
                    end
                end
            end
        end
    end
    return newEntry, claimEntry
end

do
    local a, b, c = L.ResolveFromController()
    L.NewEntry, L.ClaimEntry, L.GetEntries = a, b, c
    L.ResolvedVia = a and "controller" or nil
    if not L.NewEntry then
        local n, cl = L.ResolveByListener()
        if n then
            L.NewEntry, L.ClaimEntry, L.ResolvedVia = n, L.ClaimEntry or cl, "listener"
        end
    end
    if not L.NewEntry and L.Net then
        L.NewEntry   = L.Net:FindFirstChild("RE/Liveboard/NewEntry")
        L.ClaimEntry = L.ClaimEntry or L.Net:FindFirstChild("RE/Liveboard/ClaimEntry")
        L.GetEntries = L.GetEntries or L.Net:FindFirstChild("RF/Liveboard/GetEntries")
        if L.NewEntry then L.ResolvedVia = "plaintext" end
    end
end

-- trade remotes, from TradeController's own closures
L.InviteRF, L.SearchRF = nil, nil
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
        local oks, sv = pcall(debug.getupvalue, TC._createPlayerList, 12)
        if oks and typeof(sv) == "Instance" and sv:IsA("RemoteFunction") then L.SearchRF = sv end
    end
end

L.Ready = (L.NewEntry ~= nil) and (L.InviteRF ~= nil)

----------------------------------------------------------------
-- user-facing text: nothing raw from the server reaches the UI
----------------------------------------------------------------

function L.Friendly(raw)
    local w = tostring(raw or ""):lower()
    if w == "" then return "Couldn't send that invite" end
    if w:find("cooldown") or w:find("wait") or w:find("too fast") or w:find("spam") then
        return "Please wait before trading again" end
    if w:find("busy") or w:find("already") or w:find("in a trade") or w:find("trading") then
        return "They're busy right now" end
    if w:find("offline") or w:find("not found") or w:find("left") or w:find("no longer") then
        return "That player isn't available" end
    if w:find("disabled") or w:find("setting") or w:find("not accepting") or w:find("privacy") then
        return "They aren't accepting trades" end
    if w:find("full") or w:find("limit") or w:find("max") then return "Their trades are full" end
    if w:find("friend") then return "They only trade with friends" end
    if w:find("level") or w:find("requirement") or w:find("locked") then
        return "You don't meet their requirements" end
    return "Couldn't send that invite"
end

function L.Detail(...)
    if not L.Debug then return nil end
    local parts = {}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if v ~= nil and v ~= "" then parts[#parts + 1] = tostring(v) end
    end
    return #parts > 0 and table.concat(parts, "  \u{00B7}  ") or nil
end

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
    if #keep >= L.MaxPerMin then return "Slowing down for a moment" end
    local last = keep[#keep]
    if last and (now - last) < L.MinGap then
        return ("Please wait %ds"):format(math.ceil(L.MinGap - (now - last)))
    end
    return nil
end

----------------------------------------------------------------
-- player status
----------------------------------------------------------------

L.Status, L.StatusDots = {}, {}
L.StateColor = {online = T.ACCENT, busy = Color3.fromRGB(255, 205, 90),
                offline = T.RED, unknown = T.MUTED}
L.StateLabel = {online = "Online", busy = "Busy", offline = "Offline", unknown = "Unknown"}

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
            TS:Create(dot, TweenInfo.new(0.25), {
                BackgroundColor3 = L.StateColor[state] or T.MUTED}):Play()
            if lbl and lbl.Parent then
                lbl.Text = L.StateLabel[state] or "Unknown"
                lbl.TextColor3 = L.StateColor[state] or T.MUTED
            end
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

task.spawn(function()
    while true do
        local b = (math.sin(tick() * 2.2) + 1) / 2
        for _, dots in pairs(L.StatusDots) do
            for dot in pairs(dots) do
                if dot.Parent then dot.BackgroundTransparency = 0.12 + b * 0.45
                else dots[dot] = nil end
            end
        end
        task.wait(0.05)
    end
end)

function L.ObtainMethod(entry)
    if entry.IsFuse then return "Fuse Machine" end
    if entry.IsCodes then return "Code Redeem" end
    if entry.IsTrader then return "Los Traders" end
    if entry.IsBeeMerchant then return "Queen Bee" end
    if entry.IsRNGMachine then return "RNG Machine" end
    return nil
end

----------------------------------------------------------------
-- event cleaner
----------------------------------------------------------------

L.EventsHidden, L.EventRestore, L.HideEventSky = false, {}, true

local function remember(inst, prop)
    local ok, v = pcall(function() return inst[prop] end)
    if ok then table.insert(L.EventRestore, {inst = inst, prop = prop, value = v}) end
end
local function setProp(inst, prop, value)
    remember(inst, prop)
    pcall(function() inst[prop] = value end)
end
local function conceal(i)
    if i:IsA("BasePart") then setProp(i, "Transparency", 1) setProp(i, "CastShadow", false)
    elseif i:IsA("Decal") or i:IsA("Texture") then setProp(i, "Transparency", 1)
    elseif i:IsA("ParticleEmitter") or i:IsA("Beam") or i:IsA("Trail")
        or i:IsA("Smoke") or i:IsA("Fire") or i:IsA("Sparkles") then setProp(i, "Enabled", false)
    elseif i:IsA("Light") then setProp(i, "Enabled", false)
    elseif i:IsA("Sound") then setProp(i, "Volume", 0)
    elseif i:IsA("SurfaceAppearance") then setProp(i, "Parent", nil) end
end
local function concealTree(root)
    if not root then return 0 end
    local n = 1
    conceal(root)
    for _, d in ipairs(root:GetDescendants()) do conceal(d) n += 1 end
    return n
end

function L.EventTargets()
    local t = {}
    local events = workspace:FindFirstChild("Events")
    if events then for _, m in ipairs(events:GetChildren()) do t[#t + 1] = m end end
    for _, c in ipairs(workspace:GetChildren()) do
        if c.Name:match("Map$") and c.Name ~= "Map" then t[#t + 1] = c end
    end
    local sounds = workspace:FindFirstChild("Sounds")
    if sounds then
        for _, sd in ipairs(sounds:GetDescendants()) do
            if sd:IsA("Sound") and sd.Name:find("Ambience") then t[#t + 1] = sd end
        end
    end
    for _, plr in ipairs(Players:GetPlayers()) do
        local ch = plr.Character
        if ch then
            for _, d in ipairs(ch:GetDescendants()) do
                if d:IsA("Attachment") and d.Name:match("Attachment$")
                   and d.Name ~= "RootAttachment" and #d:GetChildren() > 0 then
                    t[#t + 1] = d
                end
            end
        end
    end
    return t
end

function L.SetEventsHidden(on)
    if on == L.EventsHidden then return end
    if not on then
        -- the lighting controller inserts a replacement sky while ours is gone;
        -- drop anything new before restoring or two skies fight and the wrong one wins
        if L.SkySnapshot then
            for _, c in ipairs(Lighting:GetChildren()) do
                if (c:IsA("Sky") or c:IsA("Atmosphere")) and not L.SkySnapshot[c] then
                    pcall(function() c:Destroy() end)
                end
            end
        end
        for i = #L.EventRestore, 1, -1 do
            local r = L.EventRestore[i]
            if r.inst then pcall(function() r.inst[r.prop] = r.value end) end
        end
        L.EventRestore, L.SkySnapshot, L.EventsHidden = {}, nil, false
        if L.Notify then L.Notify("Event visuals restored", T.MUTED) end
        return
    end
    L.EventRestore = {}
    local touched = 0
    for _, target in ipairs(L.EventTargets()) do touched += concealTree(target) end
    if L.HideEventSky then
        L.SkySnapshot = {}
        for _, c in ipairs(Lighting:GetChildren()) do
            if c:IsA("Sky") or c:IsA("Atmosphere") then L.SkySnapshot[c] = true end
        end
        for _, c in ipairs(Lighting:GetChildren()) do
            if c:IsA("Sky") or c:IsA("Atmosphere") then setProp(c, "Parent", nil) touched += 1 end
        end
    end
    L.EventsHidden = true
    if L.Notify then
        L.Notify("Event visuals hidden", T.HIGH, L.Detail(("%d objects"):format(touched)))
    end
end

----------------------------------------------------------------
-- UI
----------------------------------------------------------------

local old = PG:FindFirstChild("LiveSniperUI")
if old then old:Destroy() end

local function New(cls, props)
    local i = Instance.new(cls)
    for k, v in pairs(props or {}) do i[k] = v end
    return i
end
local function Corner(p, r) return New("UICorner", {CornerRadius = UDim.new(0, r or 10), Parent = p}) end
local function Stroke(p, c, t)
    return New("UIStroke", {Color = c or T.LINE, Thickness = t or 1, Transparency = 1,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = p})
end
local function tw(inst, t, goal, style)
    TS:Create(inst, TweenInfo.new(t or 0.22, style or Enum.EasingStyle.Quad,
        Enum.EasingDirection.Out), goal):Play()
end
local function hover(btn, base, stroke)
    local over = base:Lerp(T.WHITE, 0.08)
    btn.MouseEnter:Connect(function()
        tw(btn, 0.15, {BackgroundColor3 = over})
        if stroke then tw(stroke, 0.15, {Transparency = 0.25}) end
    end)
    btn.MouseLeave:Connect(function()
        tw(btn, 0.15, {BackgroundColor3 = base})
        if stroke then tw(stroke, 0.15, {Transparency = 0.45}) end
    end)
end

local reveal = {}
local function rev(inst, prop, target) reveal[#reveal + 1] = {inst, prop, target} end

local Gui = New("ScreenGui", {
    Name = "LiveSniperUI", ResetOnSpawn = false, IgnoreGuiInset = true,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 9999, Parent = PG,
})

-- one drag connection, alive only while a drag is in progress
local dragActive, dragConn = nil, nil
local function endDrag(drag)
    if drag and dragActive ~= drag then return end
    dragActive = nil
    if dragConn then pcall(function() dragConn:Disconnect() end) dragConn = nil end
end
local function beginDrag(drag)
    dragActive = drag
    if dragConn then return end
    dragConn = UIS.InputChanged:Connect(function(input)
        local d = dragActive
        if not d then return end
        local kind = input.UserInputType
        if kind ~= Enum.UserInputType.MouseMovement and kind ~= Enum.UserInputType.Touch then return end
        local delta = input.Position - d.start
        local o = d.origin
        d.frame.Position = UDim2.new(o.X.Scale, o.X.Offset + delta.X,
                                     o.Y.Scale, o.Y.Offset + delta.Y)
    end)
end

local panels = {}
local function createPanel(name, w, h, pos, display)
    local frame = New("Frame", {Size = UDim2.new(0, w, 0, h), Position = pos,
        BackgroundColor3 = T.BG, BackgroundTransparency = 1, BorderSizePixel = 0,
        ClipsDescendants = true, Parent = Gui})
    Corner(frame, 14)
    local stroke = Stroke(frame, T.ACCENT, 1)
    rev(frame, "BackgroundTransparency", 0.15)
    rev(stroke, "Transparency", 0.55)
    New("UIGradient", {Rotation = 90, Parent = frame,
        Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, T.SURFACE),
            ColorSequenceKeypoint.new(1, T.BG)}),
        Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.35),
            NumberSequenceKeypoint.new(1, 0.1)})})

    local header = New("TextButton", {Size = UDim2.new(1, 0, 0, 30),
        BackgroundTransparency = 1, Text = "", AutoButtonColor = false, Parent = frame})
    local dot = New("Frame", {Size = UDim2.new(0, 7, 0, 7), Position = UDim2.new(0, 12, 0.5, -3),
        BackgroundColor3 = T.ACCENT, BackgroundTransparency = 1, BorderSizePixel = 0,
        Parent = header})
    Corner(dot, 4)
    rev(dot, "BackgroundTransparency", 0)
    local title = New("TextLabel", {Size = UDim2.new(1, -110, 1, 0),
        Position = UDim2.new(0, 26, 0, 0), BackgroundTransparency = 1, Text = display or name,
        TextColor3 = T.HIGH, Font = Enum.Font.GothamBold, TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left, TextTransparency = 1, Parent = header})
    rev(title, "TextTransparency", 0)

    local function hBtn(txt, xoff, col)
        local b = New("TextButton", {Size = UDim2.new(0, 20, 0, 20),
            Position = UDim2.new(1, xoff, 0.5, -10), BackgroundColor3 = T.RAISED,
            BackgroundTransparency = 1, Text = txt, TextColor3 = col,
            Font = Enum.Font.GothamBold, TextSize = 11, TextTransparency = 1,
            AutoButtonColor = false, Parent = header})
        Corner(b, 6)
        rev(b, "BackgroundTransparency", 0)
        rev(b, "TextTransparency", 0)
        return b
    end
    local closeBtn = hBtn("\u{00D7}", -26, T.RED)
    local minBtn   = hBtn("\u{2013}", -50, T.ACCENT)

    local content = New("Frame", {Size = UDim2.new(1, 0, 1, -30),
        Position = UDim2.new(0, 0, 0, 30), BackgroundTransparency = 1, Parent = frame})

    local p = {frame = frame, content = content, header = header, normalH = h, minimized = false}
    panels[name] = p

    minBtn.MouseButton1Click:Connect(function()
        p.minimized = not p.minimized
        minBtn.Text = p.minimized and "+" or "\u{2013}"
        if p.minimized then
            content.Visible = false
            tw(frame, 0.2, {Size = UDim2.new(0, w, 0, 30)})
        else
            tw(frame, 0.2, {Size = UDim2.new(0, w, 0, p.normalH)})
            task.delay(0.12, function() if not p.minimized then content.Visible = true end end)
        end
    end)
    closeBtn.MouseButton1Click:Connect(function()
        tw(frame, 0.18, {BackgroundTransparency = 1})
        task.delay(0.18, function() frame.Visible = false end)
    end)

    header.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
            or i.UserInputType == Enum.UserInputType.Touch then
            local drag = {frame = frame, start = i.Position, origin = frame.Position}
            beginDrag(drag)
            i.Changed:Connect(function()
                if i.UserInputState == Enum.UserInputState.End then endDrag(drag) end
            end)
        end
    end)

    return frame, content, header, p
end

local function smallTag(parent, text, x, y)
    local l = New("TextLabel", {Size = UDim2.new(1, -x - 8, 0, 11),
        Position = UDim2.new(0, x, 0, y), BackgroundTransparency = 1, Text = text,
        TextColor3 = T.MUTED, Font = Enum.Font.GothamSemibold, TextSize = 8,
        TextXAlignment = Enum.TextXAlignment.Left, TextTransparency = 1, Parent = parent})
    rev(l, "TextTransparency", 0)
    return l
end

local function makeSwitch(parent, x, y, label)
    local l = New("TextLabel", {Size = UDim2.new(1, -x - 56, 0, 22),
        Position = UDim2.new(0, x, 0, y), BackgroundTransparency = 1, Text = label,
        TextColor3 = T.MUTED, Font = Enum.Font.GothamSemibold, TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left, TextTransparency = 1, Parent = parent})
    rev(l, "TextTransparency", 0)
    local sw = New("TextButton", {Size = UDim2.new(0, 38, 0, 20),
        Position = UDim2.new(1, -x - 38, 0, y + 1), BackgroundColor3 = T.RAISED,
        BackgroundTransparency = 1, Text = "", AutoButtonColor = false, Parent = parent})
    Corner(sw, 10)
    local swStroke = Stroke(sw)
    rev(sw, "BackgroundTransparency", 0)
    rev(swStroke, "Transparency", 0.5)
    local knob = New("Frame", {Size = UDim2.new(0, 14, 0, 14),
        Position = UDim2.new(0, 3, 0.5, -7), BackgroundColor3 = T.MUTED,
        BackgroundTransparency = 1, BorderSizePixel = 0, Parent = sw})
    Corner(knob, 7)
    rev(knob, "BackgroundTransparency", 0)
    return l, sw, swStroke, knob
end

local function paintSwitch(lbl, sw, swStroke, knob, on)
    tw(sw, 0.18, {BackgroundColor3 = on and T.ACCENT or T.RAISED})
    tw(swStroke, 0.18, {Color = on and T.HIGH or T.LINE})
    TS:Create(knob, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
        Position = on and UDim2.new(1, -17, 0.5, -7) or UDim2.new(0, 3, 0.5, -7),
        BackgroundColor3 = on and T.WHITE or T.MUTED}):Play()
    tw(lbl, 0.18, {TextColor3 = on and T.TEXT or T.MUTED})
end

local function makeBox(parent, x, y, w, placeholder)
    local box = New("TextBox", {Size = UDim2.new(0, w, 0, 26), Position = UDim2.new(0, x, 0, y),
        BackgroundColor3 = T.SURFACE, BackgroundTransparency = 1, Text = "",
        PlaceholderText = placeholder, PlaceholderColor3 = T.MUTED, TextColor3 = T.TEXT,
        Font = Enum.Font.GothamSemibold, TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left, ClearTextOnFocus = false,
        TextTransparency = 1, Parent = parent})
    Corner(box, 8)
    New("UIPadding", {PaddingLeft = UDim.new(0, 8), Parent = box})
    local st = Stroke(box)
    rev(box, "BackgroundTransparency", 0)
    rev(box, "TextTransparency", 0)
    rev(st, "Transparency", 0.5)
    box.Focused:Connect(function() tw(st, 0.15, {Color = T.ACCENT, Transparency = 0.25}) end)
    box.FocusLost:Connect(function() tw(st, 0.2, {Color = T.LINE, Transparency = 0.5}) end)
    return box
end

local function makeButton(parent, x, y, w, h, text, fill)
    local b = New("TextButton", {Size = UDim2.new(0, w, 0, h), Position = UDim2.new(0, x, 0, y),
        BackgroundColor3 = fill and T.ACCENT or T.RAISED, BackgroundTransparency = 1,
        Text = text, TextColor3 = fill and T.VOID or T.TEXT, Font = Enum.Font.GothamBold,
        TextSize = 11, TextTransparency = 1, AutoButtonColor = false, Parent = parent})
    Corner(b, 8)
    local st = Stroke(b)
    rev(b, "BackgroundTransparency", 0)
    rev(b, "TextTransparency", 0)
    rev(st, "Transparency", 0.45)
    hover(b, fill and T.ACCENT or T.RAISED, st)
    return b
end

----------------------------------------------------------------
-- panels
----------------------------------------------------------------

local P_Main, C_Main = createPanel("Main", 300, 210,
    UDim2.new(1, -320, 0.5, -260), "\u{1F3AF} SNIPER")

smallTag(C_Main, "TARGETING", 12, 4)
local aLbl, aSw, aSwS, aKnob = makeSwitch(C_Main, 12, 18, "Auto snipe")
local hLbl, hSw, hSwS, hKnob = makeSwitch(C_Main, 12, 46, "Hide event visuals")

smallTag(C_Main, "PACING", 12, 78)
local PaceLbl = New("TextLabel", {Size = UDim2.new(1, -24, 0, 14),
    Position = UDim2.new(0, 12, 0, 92), BackgroundTransparency = 1,
    Text = "", TextColor3 = T.MUTED, Font = Enum.Font.Gotham, TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left, TextTransparency = 1, Parent = C_Main})
rev(PaceLbl, "TextTransparency", 0)

smallTag(C_Main, "SESSION", 12, 114)
local StatsLbl = New("TextLabel", {Size = UDim2.new(1, -24, 0, 14),
    Position = UDim2.new(0, 12, 0, 128), BackgroundTransparency = 1,
    Text = "0 seen   0 sent   0 skipped", TextColor3 = T.TEXT,
    Font = Enum.Font.GothamSemibold, TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Left, TextTransparency = 1, Parent = C_Main})
rev(StatsLbl, "TextTransparency", 0)

local ClearBtn = makeButton(C_Main, 12, 150, 276, 26, "CLEAR FEED", false)

local P_Feed, C_Feed = createPanel("Feed", 360, 300,
    UDim2.new(1, -380, 0.5, -30), "\u{1F4E1} LIVE FEED")

local FeedFrame = New("ScrollingFrame", {Size = UDim2.new(1, -20, 1, -16),
    Position = UDim2.new(0, 10, 0, 6), BackgroundTransparency = 1, BorderSizePixel = 0,
    ScrollBarThickness = 3, ScrollBarImageColor3 = T.LINE, CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = C_Feed})
New("UIListLayout", {Padding = UDim.new(0, 7), SortOrder = Enum.SortOrder.LayoutOrder,
    Parent = FeedFrame})

local P_Send, C_Send = createPanel("Sender", 300, 214,
    UDim2.new(1, -320, 0.5, 130), "\u{1F9EA} FAKE ENTRY")

smallTag(C_Send, "BRAINROT", 12, 4)
local FE_Name = makeBox(C_Send, 12, 16, 276, "brainrot name, e.g. John Pork")
smallTag(C_Send, "MUTATION", 12, 46)
local FE_Mut = makeBox(C_Send, 12, 58, 276, "mutation, e.g. Radioactive (optional)")
smallTag(C_Send, "OWNER", 12, 88)
local FE_Id = makeBox(C_Send, 12, 100, 134, "userId")
local FE_Who = makeBox(C_Send, 154, 100, 134, "display name")
local FE_Fire = makeButton(C_Send, 12, 136, 180, 28, "FIRE ENTRY", true)
local FE_Self = makeButton(C_Send, 200, 136, 88, 28, "LOCAL", false)
local FE_Note = New("TextLabel", {Size = UDim2.new(1, -24, 0, 30),
    Position = UDim2.new(0, 12, 0, 170), BackgroundTransparency = 1, Text = "",
    TextColor3 = T.MUTED, Font = Enum.Font.Gotham, TextSize = 9, TextWrapped = true,
    TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
    TextTransparency = 1, Parent = C_Send})
rev(FE_Note, "TextTransparency", 0)

----------------------------------------------------------------
-- notifications
----------------------------------------------------------------

local NOTIF_W = IS_MOBILE and 260 or 300
local NotifRoot = New("Frame", {AnchorPoint = Vector2.new(0.5, 1),
    Position = UDim2.new(0.5, 0, 1, -16), Size = UDim2.new(0, NOTIF_W, 0, 0),
    AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, Parent = Gui})
New("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder,
    HorizontalAlignment = Enum.HorizontalAlignment.Center,
    VerticalAlignment = Enum.VerticalAlignment.Bottom,
    Padding = UDim.new(0, 6), Parent = NotifRoot})

L.Notifs, L.NotifOrder = {}, 0

function L.Notify(msg, color, detail)
    msg = tostring(msg or "")
    if msg == "" then return end
    color = color or T.HIGH

    local ex = L.Notifs[msg]
    if ex and not ex.dead then
        ex.count += 1
        ex.badge.Text = "\u{00D7}" .. ex.count
        ex.badge.Visible = true
        ex.token += 1
        local tok = ex.token
        tw(ex.badge, 0.12, {TextSize = 16}, Enum.EasingStyle.Back)
        task.delay(0.12, function()
            if not ex.dead then tw(ex.badge, 0.16, {TextSize = 12}, Enum.EasingStyle.Back) end
        end)
        task.delay(3.2, function()
            if not ex.dead and ex.token == tok then ex.kill() end
        end)
        return
    end

    L.NotifOrder += 1
    local h = detail and 46 or 32
    local f = New("Frame", {Size = UDim2.new(1, 0, 0, h), BackgroundColor3 = T.SURFACE,
        BackgroundTransparency = 1, BorderSizePixel = 0, ClipsDescendants = true,
        LayoutOrder = L.NotifOrder, Parent = NotifRoot})
    Corner(f, 10)
    local st = Stroke(f, color, 1)
    local bar = New("Frame", {Size = UDim2.new(0, 3, 1, -12), Position = UDim2.new(0, 8, 0, 6),
        BackgroundColor3 = color, BackgroundTransparency = 1, BorderSizePixel = 0, Parent = f})
    Corner(bar, 2)
    local body = New("TextLabel", {Size = UDim2.new(1, -60, 0, detail and 16 or 32),
        Position = UDim2.new(0, 18, 0, detail and 7 or 0), BackgroundTransparency = 1,
        Text = msg, TextColor3 = color, Font = Enum.Font.GothamBold, TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = detail and Enum.TextYAlignment.Top or Enum.TextYAlignment.Center,
        TextTruncate = Enum.TextTruncate.AtEnd, TextTransparency = 1, Parent = f})
    local det = New("TextLabel", {Size = UDim2.new(1, -60, 0, 14),
        Position = UDim2.new(0, 18, 0, 24), BackgroundTransparency = 1, Text = detail or "",
        TextColor3 = T.MUTED, Font = Enum.Font.Gotham, TextSize = 9,
        TextXAlignment = Enum.TextXAlignment.Left, Visible = detail ~= nil,
        TextTruncate = Enum.TextTruncate.AtEnd, TextTransparency = 1, Parent = f})
    local badge = New("TextLabel", {Size = UDim2.new(0, 30, 0, 18),
        Position = UDim2.new(1, -38, 0, 7), BackgroundTransparency = 1, Text = "",
        TextColor3 = T.WHITE, Font = Enum.Font.GothamBold, TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Right, Visible = false,
        TextTransparency = 1, Parent = f})

    local state = {count = 1, token = 0, dead = false, badge = badge}
    state.kill = function()
        if state.dead then return end
        state.dead = true
        L.Notifs[msg] = nil
        tw(f, 0.22, {BackgroundTransparency = 1})
        for _, o in ipairs({body, det, badge}) do tw(o, 0.2, {TextTransparency = 1}) end
        tw(bar, 0.2, {BackgroundTransparency = 1})
        tw(st, 0.2, {Transparency = 1})
        task.delay(0.28, function() f:Destroy() end)
    end
    L.Notifs[msg] = state

    tw(f, 0.25, {BackgroundTransparency = 0.08})
    tw(st, 0.25, {Transparency = 0.5})
    tw(bar, 0.25, {BackgroundTransparency = 0})
    tw(body, 0.25, {TextTransparency = 0})
    if detail then tw(det, 0.25, {TextTransparency = 0.15}) end
    tw(badge, 0.25, {TextTransparency = 0.1})

    local tok = state.token
    task.delay(3.2, function() if state.token == tok then state.kill() end end)
end

----------------------------------------------------------------
-- feed rows
----------------------------------------------------------------

local rowOrder = 0
local function trimFeed()
    local n = 0
    for _, c in ipairs(FeedFrame:GetChildren()) do if c:IsA("GuiObject") then n += 1 end end
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

local function addLine(text, color, sub)
    rowOrder += 1
    local row = New("Frame", {Size = UDim2.new(1, 0, 0, sub and 34 or 22),
        BackgroundColor3 = T.SURFACE, BackgroundTransparency = 0.45, BorderSizePixel = 0,
        LayoutOrder = -rowOrder, Parent = FeedFrame})
    Corner(row, 7)
    New("Frame", {Size = UDim2.new(0, 2, 1, -8), Position = UDim2.new(0, 7, 0, 4),
        BackgroundColor3 = color or T.MUTED, BorderSizePixel = 0, Parent = row})
    New("TextLabel", {Size = UDim2.new(1, -24, 0, sub and 15 or 22),
        Position = UDim2.new(0, 16, 0, sub and 3 or 0), BackgroundTransparency = 1,
        Text = text, TextColor3 = color or T.TEXT, Font = Enum.Font.GothamSemibold,
        TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd, Parent = row})
    if sub then
        New("TextLabel", {Size = UDim2.new(1, -24, 0, 13), Position = UDim2.new(0, 16, 0, 18),
            BackgroundTransparency = 1, Text = sub, TextColor3 = T.MUTED,
            Font = Enum.Font.Gotham, TextSize = 9,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd, Parent = row})
    end
    trimFeed()
end

local function addCard(entry, rarity, faked)
    rowOrder += 1
    local uid, name = entry.OwnerUserId, entry.OwnerDisplayName
    local obtain = L.ObtainMethod(entry)
    local CARD_H, RIGHT_W, LEFT_X, OWNER_Y = 96, 88, 88, 62

    local card = New("TextButton", {Size = UDim2.new(1, 0, 0, CARD_H),
        BackgroundColor3 = T.SURFACE, BackgroundTransparency = 0.4, AutoButtonColor = false,
        Text = "", BorderSizePixel = 0, LayoutOrder = -rowOrder, Parent = FeedFrame})
    Corner(card, 10)
    local cs = Stroke(card, faked and T.ORANGE or T.LINE, 1)
    cs.Transparency = faked and 0.4 or 0.7

    local box = New("Frame", {Size = UDim2.new(0, 64, 0, 64),
        Position = UDim2.new(0, 12, 0, (CARD_H - 64) / 2), BackgroundColor3 = T.VOID,
        BackgroundTransparency = 0.25, BorderSizePixel = 0, ClipsDescendants = true,
        Parent = card})
    Corner(box, 9)
    local vp = New("ViewportFrame", {Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1,
        Ambient = Color3.fromRGB(200, 214, 235), LightColor = T.WHITE,
        LightDirection = Vector3.new(-0.4, -1, -0.6), Parent = box})
    if L.SharedAnimals then
        task.spawn(function()
            pcall(function()
                L.SharedAnimals:AttachOnViewport(entry.BrainrotName, vp, nil, entry.Mutation)
            end)
        end)
    end

    local title = New("TextLabel", {Size = UDim2.new(1, -(LEFT_X + RIGHT_W), 0, 22),
        Position = UDim2.new(0, LEFT_X, 0, 10), BackgroundTransparency = 1,
        Text = entry.BrainrotName, TextColor3 = T.TEXT, Font = Enum.Font.GothamBold,
        TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd, Parent = card})
    if L.RichText and L.SharedAnimals then
        pcall(function()
            L.RichText.apply(title, L.SharedAnimals:ColorBrainrotName(entry.BrainrotName),
                {attachToInstance = true})
        end)
    end

    if rarity or entry.Mutation or obtain then
        local meta = New("Frame", {Size = UDim2.new(1, -(LEFT_X + RIGHT_W), 0, 18),
            Position = UDim2.new(0, LEFT_X, 0, 38), BackgroundTransparency = 1, Parent = card})
        New("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal,
            VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 10),
            SortOrder = Enum.SortOrder.LayoutOrder, Parent = meta})
        if rarity then
            local rl = New("TextLabel", {AutomaticSize = Enum.AutomaticSize.X,
                Size = UDim2.new(0, 0, 0, 18), BackgroundTransparency = 1,
                Text = rarity:upper(), TextColor3 = L.TierColor[rarity:lower()] or T.TEXT,
                Font = Enum.Font.GothamBlack, TextSize = 13,
                TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = 1, Parent = meta})
            New("UIStroke", {Color = Color3.fromRGB(0, 0, 0), Thickness = 1,
                Transparency = 0.55, Parent = rl})
            L.PaintRarity(rl, rarity)
        end
        if entry.Mutation then
            local ml = New("TextLabel", {AutomaticSize = Enum.AutomaticSize.X,
                Size = UDim2.new(0, 0, 0, 17), BackgroundTransparency = 1,
                Text = tostring(entry.Mutation), TextColor3 = T.TEXT,
                Font = Enum.Font.GothamBold, TextSize = 12,
                TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = 2, Parent = meta})
            New("UIStroke", {Color = Color3.fromRGB(0, 0, 0), Thickness = 1,
                Transparency = 0.65, Parent = ml})
            L.PaintMutation(ml, entry.Mutation)
        end
        if obtain then
            New("TextLabel", {AutomaticSize = Enum.AutomaticSize.X,
                Size = UDim2.new(0, 0, 0, 16), BackgroundTransparency = 1, Text = obtain,
                TextColor3 = T.MUTED, Font = Enum.Font.GothamSemibold, TextSize = 11,
                TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = 3, Parent = meta})
        end
    end

    if uid then
        local head = New("ImageLabel", {Size = UDim2.new(0, 24, 0, 24),
            Position = UDim2.new(0, LEFT_X, 0, OWNER_Y), BackgroundColor3 = T.VOID,
            BackgroundTransparency = 0.3, BorderSizePixel = 0,
            Image = ("rbxthumb://type=AvatarHeadShot&id=%d&w=48&h=48"):format(uid),
            Parent = card})
        Corner(head, 12)
        local state = L.GetStatus(uid)
        local dot = New("Frame", {Size = UDim2.new(0, 10, 0, 10),
            Position = UDim2.new(0, LEFT_X + 17, 0, OWNER_Y + 16),
            BackgroundColor3 = L.StateColor[state] or T.MUTED, BackgroundTransparency = 0.15,
            BorderSizePixel = 0, ZIndex = 3, Parent = card})
        Corner(dot, 5)
        New("UIStroke", {Color = T.SURFACE, Thickness = 2, Transparency = 0.1, Parent = dot})

        local TEXT_X = LEFT_X + 34
        New("TextLabel", {Size = UDim2.new(1, -(TEXT_X + RIGHT_W), 0, 13),
            Position = UDim2.new(0, TEXT_X, 0, OWNER_Y - 1), BackgroundTransparency = 1,
            Text = tostring(name or uid), TextColor3 = T.TEXT,
            Font = Enum.Font.GothamSemibold, TextSize = 11,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd, Parent = card})
        local stateLbl = New("TextLabel", {Size = UDim2.new(1, -(TEXT_X + RIGHT_W), 0, 12),
            Position = UDim2.new(0, TEXT_X, 0, OWNER_Y + 13), BackgroundTransparency = 1,
            Text = L.StateLabel[state] or "Unknown", TextColor3 = L.StateColor[state] or T.MUTED,
            Font = Enum.Font.Gotham, TextSize = 10,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd, Parent = card})

        L.StatusDots[uid] = L.StatusDots[uid] or {}
        L.StatusDots[uid][dot] = stateLbl
        card.Destroying:Connect(function()
            if L.StatusDots[uid] then L.StatusDots[uid][dot] = nil end
        end)

        local trade = New("TextButton", {Size = UDim2.new(0, 62, 0, 30),
            Position = UDim2.new(1, -74, 0, (CARD_H - 30) / 2), BackgroundColor3 = T.RAISED,
            AutoButtonColor = false, ClipsDescendants = true, Text = "Trade",
            TextColor3 = T.HIGH, Font = Enum.Font.GothamBold, TextSize = 11, Parent = card})
        Corner(trade, 9)
        local ts = Stroke(trade)
        ts.Transparency = 0.5
        hover(trade, T.RAISED, ts)
        trade.MouseButton1Click:Connect(function()
            if setclipboard then pcall(setclipboard, tostring(uid)) end
            L.Sent[uid] = nil
            trade.Text = "..."
            L.Fire(uid, tostring(name or uid), os.clock(), true)
            task.delay(1.2, function() if trade.Parent then trade.Text = "Trade" end end)
        end)
    else
        New("TextLabel", {Size = UDim2.new(1, -(LEFT_X + RIGHT_W), 0, 14),
            Position = UDim2.new(0, LEFT_X, 0, OWNER_Y + 5), BackgroundTransparency = 1,
            Text = "UNCLAIMED", TextColor3 = T.RED, Font = Enum.Font.GothamSemibold,
            TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left, Parent = card})
    end

    card.MouseEnter:Connect(function()
        tw(card, 0.12, {BackgroundTransparency = 0.2})
        tw(cs, 0.12, {Transparency = 0.3, Color = T.ACCENT})
    end)
    card.MouseLeave:Connect(function()
        tw(card, 0.18, {BackgroundTransparency = 0.4})
        tw(cs, 0.18, {Transparency = faked and 0.4 or 0.7, Color = faked and T.ORANGE or T.LINE})
    end)

    trimFeed()
end

local function refreshStats()
    StatsLbl.Text = ("%d seen   %d sent   %d skipped"):format(
        L.Stats.seen, L.Stats.ok, L.Stats.skipped + L.Stats.fail)
    local hold = L.ThrottleReason()
    PaceLbl.Text = hold or ("ready \u{00B7} max %d/min"):format(L.MaxPerMin)
    PaceLbl.TextColor3 = hold and T.ORANGE or T.MUTED
end

----------------------------------------------------------------
-- firing
----------------------------------------------------------------

function L.Fire(userId, label, t0, manual)
    if not L.InviteRF then
        L.Notify("Trading isn't available right now", T.RED)
        return
    end
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
        local searchNote
        if L.SearchFirst and L.SearchRF then
            local okS, sOk, sFound = pcall(L.SearchRF.InvokeServer, L.SearchRF, L.SearchGUID, userId)
            searchNote = L.Detail(okS and ("search ok=%s found=%s"):format(tostring(sOk), tostring(sFound)) or "search errored")
            if okS and sOk and sFound == false then
                L.SetStatus(userId, "busy")
                L.Stats.skipped += 1
                addLine("Not available to trade", T.MUTED, label)
                refreshStats()
                return
            end
            if okS and sOk and sFound then L.SetStatus(userId, "online") end
            task.wait(0.35 + math.random() * L.Jitter)
        end

        local tCall = os.clock()
        local ok, a, b = pcall(L.InviteRF.InvokeServer, L.InviteRF, L.InviteGUID, userId)
        local rtt = (os.clock() - tCall) * 1000
        local detail = L.Detail(("dispatch %s"):format(fmt(dispatch)),
                                ("server %s"):format(fmt(rtt)), searchNote)
        if ok and a then
            L.Stats.ok += 1
            L.LastTradeAt = os.clock()
            L.SetStatus(userId, "busy")
            addLine("Trade sent \u{2192} " .. label, T.ACCENT, detail)
            L.Notify("Trade sent to " .. label, T.ACCENT, detail)
        else
            L.Stats.fail += 1
            local raw = tostring(ok and b or a):lower()
            if raw:find("trad") or raw:find("busy") or raw:find("already") then
                L.SetStatus(userId, "busy")
            elseif raw:find("offline") or raw:find("not found") or raw:find("left") then
                L.SetStatus(userId, "offline")
            end
            local msg = L.Friendly(raw)
            addLine(msg, T.ORANGE, label)
            L.Notify(msg, T.ORANGE, detail)
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
    local rarity = L.RarityOf(entry.BrainrotName)

    addCard(entry, rarity, faked)

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
-- fake entry
--
-- firesignal fires EVERY listener on the signal, so one call reaches both
-- LiveboardController's renderer (the entry appears on the real in-game
-- board) and this script's handler (it counts in the feed and stats).
-- Purely local: nothing is sent to the server, nobody else sees it.
----------------------------------------------------------------

L.HasFireSignal = typeof(firesignal) == "function"

function L.BuildFakeEntry(brainrot, mutation, userId, displayName)
    return {
        UID              = "FAKE-" .. tostring(math.random(100000, 999999)),
        BrainrotName     = brainrot,
        Mutation         = (mutation ~= "" and mutation) or nil,
        OwnerUserId      = userId,
        OwnerDisplayName = displayName,
        Timestamp        = workspace:GetServerTimeNow(),
        DisplayDuration  = 60,
        IsLocalServer    = false,
    }
end

-- push through the real signal: game board + this script both react
function L.FireFakeEntry(entry)
    if not L.NewEntry then return false, "feed remote unavailable" end
    if not L.HasFireSignal then return false, "executor has no firesignal" end
    local ok, err = pcall(firesignal, L.NewEntry.OnClientEvent, entry)
    if not ok then return false, tostring(err) end
    return true
end

-- render in this script only, without touching the game's board
function L.LocalFakeEntry(entry)
    L.OnEntry(entry, true)
    return true
end

local function readFakeEntry()
    local brainrot = (FE_Name.Text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if brainrot == "" then return nil, "Enter a brainrot name" end
    local mutation = (FE_Mut.Text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local idText   = (FE_Id.Text or ""):gsub("%D", "")
    local userId   = tonumber(idText)
    if not userId then return nil, "Enter a numeric userId" end
    local who = (FE_Who.Text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if who == "" then who = tostring(userId) end
    return L.BuildFakeEntry(brainrot, mutation, userId, who)
end

FE_Fire.MouseButton1Click:Connect(function()
    local entry, err = readFakeEntry()
    if not entry then FE_Note.Text = err FE_Note.TextColor3 = T.ORANGE return end
    local ok, why = L.FireFakeEntry(entry)
    if ok then
        FE_Note.Text = "Fired through the live feed \u{00B7} also shown on the in-game board"
        FE_Note.TextColor3 = T.ACCENT
    else
        FE_Note.Text = "Couldn't fire (" .. tostring(why) .. ") \u{00B7} rendered locally instead"
        FE_Note.TextColor3 = T.ORANGE
        L.LocalFakeEntry(entry)
    end
end)

FE_Self.MouseButton1Click:Connect(function()
    local entry, err = readFakeEntry()
    if not entry then FE_Note.Text = err FE_Note.TextColor3 = T.ORANGE return end
    L.LocalFakeEntry(entry)
    FE_Note.Text = "Rendered in this feed only"
    FE_Note.TextColor3 = T.MUTED
end)

----------------------------------------------------------------
-- wiring
----------------------------------------------------------------

paintSwitch(aLbl, aSw, aSwS, aKnob, false)
paintSwitch(hLbl, hSw, hSwS, hKnob, false)

aSw.MouseButton1Click:Connect(function()
    L.AutoOn = not L.AutoOn
    paintSwitch(aLbl, aSw, aSwS, aKnob, L.AutoOn)
    L.Notify(L.AutoOn and "Auto snipe enabled" or "Auto snipe disabled",
        L.AutoOn and T.ACCENT or T.MUTED)
end)
hSw.MouseButton1Click:Connect(function()
    local target = not L.EventsHidden
    paintSwitch(hLbl, hSw, hSwS, hKnob, target)
    L.SetEventsHidden(target)
end)
ClearBtn.MouseButton1Click:Connect(function()
    for _, c in ipairs(FeedFrame:GetChildren()) do
        if c:IsA("GuiObject") then c:Destroy() end
    end
    L.Sent = {}
    L.Stats = {seen = 0, fired = 0, ok = 0, fail = 0, skipped = 0}
    L.BestDispatch = nil
    refreshStats()
    L.Notify("Feed cleared", T.MUTED)
end)

UIS.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == Enum.KeyCode.RightShift then Gui.Enabled = not Gui.Enabled end
end)

task.spawn(function()
    while true do refreshStats() task.wait(1) end
end)

----------------------------------------------------------------
-- reveal
----------------------------------------------------------------

refreshStats()
FE_Note.Text = L.HasFireSignal
    and "FIRE pushes through the live feed, so the entry also lands on the real in-game board. LOCAL fills this feed only."
    or  "This executor has no firesignal, so only LOCAL is available."

task.spawn(function()
    task.wait(0.15)
    for i, r in ipairs(reveal) do
        local inst, prop, target = r[1], r[2], r[3]
        if inst and inst.Parent then
            TS:Create(inst, TweenInfo.new(0.35, Enum.EasingStyle.Quad,
                Enum.EasingDirection.Out), {[prop] = target}):Play()
        end
        if i % 6 == 0 then task.wait(0.015) end
    end
    L.IntroDone = true
    task.wait(0.4)
    if L.Ready then
        L.Notify("Ready", T.ACCENT, L.Detail("feed via " .. tostring(L.ResolvedVia)))
    else
        L.Notify("Some features are unavailable", T.ORANGE)
    end
end)

if L.GetEntries then
    task.spawn(function()
        local ok, data = pcall(L.GetEntries.InvokeServer, L.GetEntries)
        if ok and type(data) == "table" then
            local n = 0
            for _, e in pairs(data) do
                if type(e) == "table" then n += 1 L.OnEntry(e, false) end
            end
            if n > 0 then L.Notify(("Loaded %d recent drops"):format(n), T.MUTED) end
        end
    end)
end

return L
