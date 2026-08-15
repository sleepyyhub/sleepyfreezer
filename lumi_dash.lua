--[[  LUMINOSITY — DASH  ]]--
-- Steal A Summertino — aimed straight-line fling with obstacle routing
-- Executor: any. No dependencies. Paste whole file, execute.
--
-- Hold the bind (default E) to raise an aim arrow, release to fling.
-- The arrow is horizontal only — pitch is stripped from the camera, so you
-- travel flat and never get launched into the sky.
--
-- ROUTING
-- The path is no longer a single hop that lifts over everything. It marches
-- the line in steps and, when a step is blocked, looks for a way AROUND:
-- perpendicular offsets to the left and right at increasing distance, taking
-- the first that has clear line of sight both into the detour and back out to
-- the next point. Each detour becomes a real teleport stop, so you thread
-- past a wall instead of clipping through it:
--
--        you ---> [stop] ------> [stop] ------> base
--                    |  wall        |  wall
--
-- Vertical lift is kept, but only as the fallback when no lateral way exists.
--
-- AUTO STEAL
-- ProximityPromptService.PromptTriggered fires the moment a hold completes.
-- When the prompt's ObjectText or ActionText contains "Steal" and the trigger
-- was yours, the route home runs inside that same handler — no wait, no
-- polling, no heartbeat delay.

local Players    = game:GetService("Players")
local RepS       = game:GetService("ReplicatedStorage")
local RunS       = game:GetService("RunService")
local TS         = game:GetService("TweenService")
local UIS        = game:GetService("UserInputService")
local PPS        = game:GetService("ProximityPromptService")
local LP         = Players.LocalPlayer
local PG         = LP:WaitForChild("PlayerGui")
local Cam        = workspace.CurrentCamera
local IS_MOBILE  = UIS.TouchEnabled and not UIS.KeyboardEnabled and not UIS.MouseEnabled

local Sync = nil
pcall(function()
    Sync = require(RepS:WaitForChild("Packages", 10):WaitForChild("Synchronizer", 10))
end)

local L = {}
L.Key        = Enum.KeyCode.E
L.Range      = 260
L.Cone       = 40
L.Climb      = 40
L.Step       = 14
L.Detours    = {8, 16, 26, 38, 52, 68}
L.MaxHops    = 64
L.AutoAim    = true
L.MineOnly   = false
L.Instant    = true
L.AutoSteal  = true
L.ShowPath   = true
L.Aiming     = false
L.Target     = nil
L.Hops       = 0
L.LastRoute  = {}

local T = {
    VOID = Color3.fromRGB(6,9,18),        BG      = Color3.fromRGB(10,15,28),
    SURFACE = Color3.fromRGB(16,24,44),   RAISED  = Color3.fromRGB(24,34,58),
    LINE = Color3.fromRGB(38,54,88),      ACCENT  = Color3.fromRGB(120,180,255),
    HIGH = Color3.fromRGB(180,220,255),   DEEP    = Color3.fromRGB(72,130,210),
    TEXT = Color3.fromRGB(230,240,255),   MUTED   = Color3.fromRGB(120,145,185),
    RED  = Color3.fromRGB(255,130,155),   GREEN   = Color3.fromRGB(146,255,103),
    ORANGE = Color3.fromRGB(255,190,120), WHITE   = Color3.fromRGB(255,255,255),
    PURPLE = Color3.fromRGB(175,135,255), CYAN    = Color3.fromRGB(100,230,255),
}

local function safe(fn) local ok, r = pcall(fn); return ok and r or nil end
local function alive(i) return i and typeof(i) == "Instance" and i.Parent ~= nil end
local function char()   return LP.Character end
local function hrp()    local c = char(); return c and c:FindFirstChild("HumanoidRootPart") end
local function humanoid() local c = char(); return c and c:FindFirstChildOfClass("Humanoid") end

----------------------------------------------------------------------
-- WORLD
----------------------------------------------------------------------
local function myPlot()
    local folder = workspace:FindFirstChild("Plots")
    if not folder or not Sync then return nil end
    for _, plot in ipairs(folder:GetChildren()) do
        local ch = safe(function() return Sync:Get(plot.Name) end)
        if ch and safe(function() return ch:Get("Owner") end) == LP then return plot end
    end
    return nil
end

local function deliveryPads()
    local out = {}
    local folder = workspace:FindFirstChild("Plots")
    if not folder then return out end
    local mine = myPlot()
    for _, plot in ipairs(folder:GetChildren()) do
        local pad = plot:FindFirstChild("DeliveryHitbox")
        if pad and pad:IsA("BasePart") then
            if not L.MineOnly or plot == mine then
                table.insert(out, {part = pad, plot = plot, mine = plot == mine})
            end
        end
    end
    return out
end

local function myPad()
    for _, pad in ipairs(deliveryPads()) do
        if pad.mine then return pad end
    end
    return nil
end

local function aimDir()
    local look = Cam.CFrame.LookVector
    local flat = Vector3.new(look.X, 0, look.Z)
    if flat.Magnitude < 0.001 then return Vector3.new(0, 0, -1) end
    return flat.Unit
end

local function pickTarget(origin, dir)
    if not L.AutoAim then return nil end
    local best, bestScore = nil, math.huge
    local limit = math.cos(math.rad(L.Cone))
    for _, pad in ipairs(deliveryPads()) do
        local to = pad.part.Position - origin
        local flat = Vector3.new(to.X, 0, to.Z)
        local dist = flat.Magnitude
        if dist > 6 then
            local dot = flat.Unit:Dot(dir)
            if dot >= limit then
                local score = (1 - dot) * 900 + dist * 0.5 - (pad.mine and 120 or 0)
                if score < bestScore then bestScore, best = score, pad end
            end
        end
    end
    return best
end

----------------------------------------------------------------------
-- ROUTING
----------------------------------------------------------------------
local function rayParams()
    local p = RaycastParams.new()
    p.FilterType = Enum.RaycastFilterType.Exclude
    p.FilterDescendantsInstances = {char(), workspace:FindFirstChild("LUMI_DASH")}
    p.IgnoreWater = true
    return p
end

local function segClear(a, b, params)
    local d = b - a
    if d.Magnitude < 0.01 then return true end
    return workspace:Raycast(a, d, params) == nil
end

-- Ground settle. Two things this has to get right:
--   * scan from just above the point's OWN height, not the player's, or a
--     roof above the destination is mistaken for its floor.
--   * skip non-collidable hits — the map is full of decorative parts a
--     raycast reports but you would fall straight through.
local function groundAt(pos)
    local params = rayParams()
    local ignore = {char(), workspace:FindFirstChild("LUMI_DASH")}
    local from = pos + Vector3.new(0, 6, 0)
    for _ = 1, 8 do
        local hit = workspace:Raycast(from, Vector3.new(0, -400, 0), params)
        if not hit then break end
        if hit.Instance.CanCollide then
            return Vector3.new(pos.X, hit.Position.Y + 3.5, pos.Z)
        end
        table.insert(ignore, hit.Instance)
        params.FilterDescendantsInstances = ignore
    end
    return pos
end

-- Prefer going around. Sweep perpendicular offsets outward, alternating
-- sides, and accept the first that can be reached AND can reach the next
-- point. Only when every lateral option fails do we climb.
local function findDetour(cur, nxt, params)
    local d = nxt - cur
    local flat = Vector3.new(d.X, 0, d.Z)
    if flat.Magnitude < 0.01 then return nil end
    local dir = flat.Unit
    local perp = Vector3.new(-dir.Z, 0, dir.X)

    for _, off in ipairs(L.Detours) do
        for _, sign in ipairs({1, -1}) do
            local side = cur + perp * (off * sign)
            if segClear(cur, side, params) and segClear(side, nxt, params) then
                return side, "side"
            end
        end
    end

    for h = 6, L.Climb, 6 do
        local up = cur + Vector3.new(0, h, 0)
        if segClear(cur, up, params) and segClear(up, nxt + Vector3.new(0, h, 0), params) then
            return up, "up"
        end
    end
    return nil
end

-- Returns a list of teleport stops. A stop only exists where the straight
-- line could not be followed, so a clear shot is a single hop and a walled
-- route is a handful.
local function buildRoute(origin, target)
    local params = rayParams()
    local stops = {}
    local cur = origin
    local guard = 0

    while guard < L.MaxHops do
        guard += 1
        local flat = Vector3.new(target.X - cur.X, 0, target.Z - cur.Z)
        local dist = flat.Magnitude
        if dist < 2 then break end
        local dir = flat.Unit
        local len = math.min(L.Step, dist)
        local nxt = cur + dir * len

        if segClear(cur, nxt, params) then
            cur = nxt
        else
            local detour, kind = findDetour(cur, nxt, params)
            if detour then
                stops[#stops + 1] = {pos = detour, kind = kind}
                cur = detour
            else
                cur = cur + Vector3.new(0, L.Climb, 0)
                stops[#stops + 1] = {pos = cur, kind = "lift"}
            end
        end
    end

    stops[#stops + 1] = {pos = groundAt(target), kind = "land"}
    return stops
end

----------------------------------------------------------------------
-- VISUALS
----------------------------------------------------------------------
local Folder = workspace:FindFirstChild("LUMI_DASH")
if Folder then Folder:Destroy() end
Folder = Instance.new("Folder")
Folder.Name = "LUMI_DASH"
Folder.Parent = workspace

local function makePart(props)
    local p = Instance.new("Part")
    p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch = true, false, false, false
    p.Material = Enum.Material.Neon
    p.TopSurface, p.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
    for k, v in pairs(props or {}) do p[k] = v end
    p.Parent = Folder
    return p
end

local Shaft = makePart({Size = Vector3.new(0.4, 0.4, 1), Color = T.ACCENT, Transparency = 1})
local Tip   = makePart({Size = Vector3.new(1.4, 1.4, 1.4), Shape = Enum.PartType.Ball, Color = T.HIGH, Transparency = 1})
local Ring  = makePart({Size = Vector3.new(7, 0.3, 7), Color = T.HIGH, Transparency = 1})
Instance.new("CylinderMesh").Parent = Ring

local Glow = Instance.new("Highlight")
Glow.FillColor, Glow.OutlineColor = T.ACCENT, T.HIGH
Glow.FillTransparency, Glow.OutlineTransparency = 0.85, 0.2
Glow.Enabled = false
Glow.Parent = Folder

local NodePool = {}
local function clearNodes()
    for _, n in ipairs(NodePool) do n.Transparency = 1 end
end
local function showNodes(stops)
    if not L.ShowPath then clearNodes() return end
    for i, s in ipairs(stops) do
        local n = NodePool[i]
        if not n then
            n = makePart({Size = Vector3.new(1.1, 1.1, 1.1), Shape = Enum.PartType.Ball, Transparency = 1})
            NodePool[i] = n
        end
        n.Color = (s.kind == "land") and T.GREEN or (s.kind == "side" and T.ORANGE or T.PURPLE)
        n.CFrame = CFrame.new(s.pos)
        n.Transparency = 0.25
    end
    for i = #stops + 1, #NodePool do NodePool[i].Transparency = 1 end
end

local function hideArrow()
    Shaft.Transparency, Tip.Transparency, Ring.Transparency = 1, 1, 1
    Glow.Enabled = false
    Glow.Adornee = nil
    clearNodes()
end

local function drawArrow(origin, landing, locked)
    local delta = landing - origin
    local flat = Vector3.new(delta.X, 0, delta.Z)
    local len = flat.Magnitude
    if len < 1 then hideArrow() return end
    local dir = flat.Unit
    local mid = origin + dir * (len * 0.5)
    local col = locked and T.GREEN or T.ACCENT

    Shaft.Size = Vector3.new(0.4, 0.4, len)
    Shaft.CFrame = CFrame.lookAt(Vector3.new(mid.X, origin.Y, mid.Z), Vector3.new(mid.X, origin.Y, mid.Z) + dir)
    Shaft.Color, Shaft.Transparency = col, 0.25

    Tip.CFrame = CFrame.new(Vector3.new(landing.X, origin.Y, landing.Z))
    Tip.Color, Tip.Transparency = col, 0.1

    Ring.CFrame = CFrame.new(landing + Vector3.new(0, 0.2, 0))
    Ring.Color, Ring.Transparency = col, 0.4
end

----------------------------------------------------------------------
-- DASH
----------------------------------------------------------------------
local function dashTo(landing, dir)
    local root, hum = hrp(), humanoid()
    if not root then return false, 0 end
    local stops = buildRoute(root.Position, landing)
    L.LastRoute = stops
    L.Hops = #stops

    if hum then
        hum:ChangeState(Enum.HumanoidStateType.Freefall)
        hum.PlatformStand = false
    end

    for i, s in ipairs(stops) do
        local face = dir
        if i < #stops then
            local d = stops[i + 1].pos - s.pos
            local f = Vector3.new(d.X, 0, d.Z)
            if f.Magnitude > 0.01 then face = f.Unit end
        end
        root.CFrame = CFrame.lookAt(s.pos, s.pos + face)
        root.AssemblyLinearVelocity = Vector3.zero
        if not L.Instant and i < #stops then RunS.RenderStepped:Wait() end
    end

    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
    return true, #stops
end

----------------------------------------------------------------------
-- UI PRIMITIVES
----------------------------------------------------------------------
local old = PG:FindFirstChild("LuminosityDash")
if old then old:Destroy() end

local function New(cls, props, kids)
    local i = Instance.new(cls)
    for k, v in pairs(props or {}) do i[k] = v end
    for _, c in ipairs(kids or {}) do c.Parent = i end
    return i
end
local function Corner(p, r) return New("UICorner", {CornerRadius = UDim.new(0, r or 10), Parent = p}) end
local function Pad(p, a) return New("UIPadding", {
    PaddingTop = UDim.new(0, a), PaddingBottom = UDim.new(0, a),
    PaddingLeft = UDim.new(0, a), PaddingRight = UDim.new(0, a), Parent = p}) end
local function Stroke(p, c, t, tr) return New("UIStroke", {Color = c or T.LINE, Thickness = t or 1,
    Transparency = tr or 0.4, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = p}) end
local function tw(o, t, s, d, g) return TS:Create(o, TweenInfo.new(t, s or Enum.EasingStyle.Quart,
    d or Enum.EasingDirection.Out), g) end

local Gui = New("ScreenGui", {Name = "LuminosityDash", ResetOnSpawn = false, IgnoreGuiInset = true,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 9999, Parent = PG})

----------------------------------------------------------------------
-- ARRAYLIST
--
-- Client-style module list, top right. Entries sort by rendered width so the
-- edge forms the usual staircase, each carries its own slice of a moving hue
-- sweep, and they slide in and out from the right rather than popping.
----------------------------------------------------------------------
local ArrayRoot = New("Frame", {
    AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, -8, 0, 6),
    Size = UDim2.fromOffset(320, 0),
    AutomaticSize = Enum.AutomaticSize.Y,
    BackgroundTransparency = 1, Parent = Gui})
New("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder,
    HorizontalAlignment = Enum.HorizontalAlignment.Right,
    Padding = UDim.new(0, 2), Parent = ArrayRoot})

local ArrayEntries = {}
local HueOffset = 0

local function makeEntry(name)
    local holder = New("Frame", {Size = UDim2.new(0, 120, 0, 20), BackgroundTransparency = 1,
        Parent = ArrayRoot})
    local bg = New("Frame", {Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = Color3.fromRGB(0, 0, 0),
        BackgroundTransparency = 0.45, BorderSizePixel = 0, Parent = holder})
    local bar = New("Frame", {Size = UDim2.new(0, 2, 1, 0), Position = UDim2.new(1, -2, 0, 0),
        BackgroundColor3 = T.ACCENT, BorderSizePixel = 0, Parent = bg})
    local lbl = New("TextLabel", {Size = UDim2.new(1, -12, 1, 0), Position = UDim2.fromOffset(6, 0),
        BackgroundTransparency = 1, Text = name, TextColor3 = T.WHITE,
        Font = Enum.Font.GothamBold, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left,
        TextTransparency = 1, Parent = bg})
    New("UIStroke", {Color = Color3.fromRGB(0, 0, 0), Thickness = 1.4, Transparency = 0.35, Parent = lbl})
    return {holder = holder, bg = bg, bar = bar, lbl = lbl, name = name, alive = true}
end

local function refreshArray()
    local active = {}
    if L.AutoAim   then active[#active + 1] = "AutoAim"   end
    if L.MineOnly  then active[#active + 1] = "MyBase"    end
    if L.AutoSteal then active[#active + 1] = "AutoSteal" end
    if L.Instant   then active[#active + 1] = "Instant"   end
    if L.ShowPath  then active[#active + 1] = "PathNodes" end
    if L.Aiming    then active[#active + 1] = "Aiming"    end

    local want = {}
    for _, n in ipairs(active) do want[n] = true end

    for name, e in pairs(ArrayEntries) do
        if not want[name] and e.alive then
            e.alive = false
            tw(e.holder, 0.18, nil, nil, {Size = UDim2.new(0, e.holder.Size.X.Offset, 0, 0)}):Play()
            tw(e.lbl, 0.15, nil, nil, {TextTransparency = 1}):Play()
            tw(e.bg, 0.15, nil, nil, {BackgroundTransparency = 1}):Play()
            local h = e.holder
            task.delay(0.2, function() if h then h:Destroy() end end)
            ArrayEntries[name] = nil
        end
    end

    for _, name in ipairs(active) do
        if not ArrayEntries[name] then
            local e = makeEntry(name)
            ArrayEntries[name] = e
            e.holder.Size = UDim2.fromOffset(120, 0)
            task.defer(function()
                if not e.holder then return end
                local w = e.lbl.TextBounds.X + 16
                e.holder.Size = UDim2.fromOffset(w, 0)
                tw(e.holder, 0.2, Enum.EasingStyle.Back, nil, {Size = UDim2.fromOffset(w, 20)}):Play()
                tw(e.lbl, 0.25, nil, nil, {TextTransparency = 0}):Play()
            end)
        end
    end

    local list = {}
    for _, e in pairs(ArrayEntries) do list[#list + 1] = e end
    table.sort(list, function(a, b) return a.lbl.TextBounds.X > b.lbl.TextBounds.X end)
    for i, e in ipairs(list) do e.holder.LayoutOrder = i end
end

task.spawn(function()
    while Gui.Parent do
        HueOffset = (HueOffset + 0.004) % 1
        local list = {}
        for _, e in pairs(ArrayEntries) do list[#list + 1] = e end
        table.sort(list, function(a, b) return a.holder.LayoutOrder < b.holder.LayoutOrder end)
        for i, e in ipairs(list) do
            local hue = (HueOffset + (i - 1) * 0.06) % 1
            local col = Color3.fromHSV(hue, 0.55, 1)
            e.lbl.TextColor3 = col
            e.bar.BackgroundColor3 = col
        end
        RunS.RenderStepped:Wait()
    end
end)

local Watermark = New("TextLabel", {
    AnchorPoint = Vector2.new(0, 0), Position = UDim2.new(0, 10, 0, 6),
    Size = UDim2.fromOffset(240, 26), BackgroundTransparency = 1,
    Text = "LUMINOSITY", TextColor3 = T.WHITE, Font = Enum.Font.GothamBlack, TextSize = 22,
    TextXAlignment = Enum.TextXAlignment.Left, Parent = Gui})
New("UIStroke", {Color = Color3.fromRGB(0,0,0), Thickness = 2, Transparency = 0.3, Parent = Watermark})
local WMGrad = New("UIGradient", {Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, T.ACCENT), ColorSequenceKeypoint.new(0.5, T.WHITE),
    ColorSequenceKeypoint.new(1, T.PURPLE)}), Parent = Watermark})
task.spawn(function()
    while Watermark.Parent do
        WMGrad.Rotation = (WMGrad.Rotation + 1) % 360
        task.wait(0.03)
    end
end)

----------------------------------------------------------------------
-- PANEL
----------------------------------------------------------------------
local PANEL_W = IS_MOBILE and 290 or 340
local Panel = New("Frame", {Size = UDim2.fromOffset(PANEL_W, 366),
    Position = UDim2.new(0, 26, 0.5, -183), BackgroundColor3 = T.SURFACE,
    BackgroundTransparency = 1, BorderSizePixel = 0, Parent = Gui})
Corner(Panel, 18); Pad(Panel, 16)
local PanelStroke = Stroke(Panel, T.LINE, 1, 1)

local PanelGrad = New("UIGradient", {Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, T.SURFACE),
    ColorSequenceKeypoint.new(0.5, T.SURFACE:Lerp(T.DEEP, 0.35)),
    ColorSequenceKeypoint.new(1, T.SURFACE)}), Rotation = 20, Parent = Panel})
task.spawn(function()
    while Panel.Parent do
        TS:Create(PanelGrad, TweenInfo.new(6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {Rotation = 200}):Play()
        task.wait(6)
        TS:Create(PanelGrad, TweenInfo.new(6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {Rotation = 20}):Play()
        task.wait(6)
    end
end)

local Header = New("Frame", {Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1, Parent = Panel})
local Handle = New("TextButton", {Size = UDim2.new(1, -28, 1, 0), BackgroundTransparency = 1,
    AutoButtonColor = false, Text = "", Parent = Header})
local Brand = New("TextLabel", {Size = UDim2.new(1, -18, 1, 0), Position = UDim2.fromOffset(18, 0),
    BackgroundTransparency = 1, Text = "DASH", TextColor3 = T.HIGH,
    Font = Enum.Font.GothamBlack, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left,
    TextTransparency = 1, Parent = Handle})

local Dot = New("Frame", {Size = UDim2.fromOffset(9, 9), Position = UDim2.new(0, 0, 0.5, -4),
    BackgroundColor3 = T.DEEP, BorderSizePixel = 0, Parent = Handle})
Corner(Dot, 5)
local Ring2 = New("Frame", {Size = UDim2.fromOffset(9, 9), Position = UDim2.new(0, 0, 0.5, -4),
    BackgroundTransparency = 1, BorderSizePixel = 0, Parent = Handle})
Corner(Ring2, 8)
local RingStroke = New("UIStroke", {Color = T.ACCENT, Thickness = 1, Transparency = 1, Parent = Ring2})

local CloseBtn = New("TextButton", {Size = UDim2.fromOffset(22, 22), Position = UDim2.new(1, -22, 0.5, -11),
    BackgroundColor3 = T.RAISED, AutoButtonColor = false, Text = "×", TextColor3 = T.MUTED,
    Font = Enum.Font.GothamBold, TextSize = 14, BackgroundTransparency = 1, TextTransparency = 1,
    Parent = Header})
Corner(CloseBtn, 7)

local Content = New("Frame", {Size = UDim2.new(1, 0, 1, -32), Position = UDim2.new(0, 0, 0, 32),
    BackgroundTransparency = 1, Parent = Panel})
New("UIListLayout", {Padding = UDim.new(0, 7), SortOrder = Enum.SortOrder.LayoutOrder, Parent = Content})

local StatusCard = New("Frame", {Size = UDim2.new(1, 0, 0, 52), BackgroundColor3 = T.BG,
    BackgroundTransparency = 0.25, BorderSizePixel = 0, LayoutOrder = 1, Parent = Content})
Corner(StatusCard, 12); Stroke(StatusCard, T.LINE, 1, 0.6); Pad(StatusCard, 10)
local StatusTop = New("TextLabel", {Size = UDim2.new(1, 0, 0, 14), BackgroundTransparency = 1,
    Text = "hold E to aim", TextColor3 = T.TEXT, Font = Enum.Font.GothamBold, TextSize = 13,
    TextXAlignment = Enum.TextXAlignment.Left, Parent = StatusCard})
local StatusSub = New("TextLabel", {Size = UDim2.new(1, 0, 0, 12), Position = UDim2.fromOffset(0, 17),
    BackgroundTransparency = 1, Text = "no target", TextColor3 = T.MUTED,
    Font = Enum.Font.Gotham, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd, Parent = StatusCard})
local StatusHops = New("TextLabel", {Size = UDim2.new(1, 0, 0, 12), Position = UDim2.fromOffset(0, 30),
    BackgroundTransparency = 1, Text = "route: —", TextColor3 = T.PURPLE,
    Font = Enum.Font.Gotham, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd, Parent = StatusCard})

local function ripple(btn, tint)
    local abs = btn.AbsoluteSize
    local c = New("Frame", {Size = UDim2.fromOffset(0, 0), Position = UDim2.fromScale(0.5, 0.5),
        AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = tint or T.HIGH,
        BackgroundTransparency = 0.75, BorderSizePixel = 0, ZIndex = 10, Parent = btn})
    Corner(c, 999)
    local target = math.max(abs.X, abs.Y) * 1.6
    tw(c, 0.45, nil, nil, {Size = UDim2.fromOffset(target, target), BackgroundTransparency = 1}):Play()
    task.delay(0.5, function() c:Destroy() end)
end

local function makeRow(label, order, valueText)
    local b = New("TextButton", {Size = UDim2.new(1, 0, 0, 34), BackgroundColor3 = T.RAISED,
        AutoButtonColor = false, Text = "", ClipsDescendants = true, LayoutOrder = order, Parent = Content})
    Corner(b, 10)
    local st = Stroke(b, T.LINE, 1, 0.55)
    local tag = New("Frame", {Size = UDim2.new(0, 3, 0.62, 0), Position = UDim2.new(0, 0, 0.19, 0),
        BackgroundColor3 = T.DEEP, BorderSizePixel = 0, Parent = b})
    New("TextLabel", {Size = UDim2.new(1, -86, 1, 0), Position = UDim2.fromOffset(13, 0),
        BackgroundTransparency = 1, Text = label, TextColor3 = T.TEXT, Font = Enum.Font.Gotham,
        TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left, Parent = b})
    local val = New("TextLabel", {Size = UDim2.new(0, 76, 1, 0), Position = UDim2.new(1, -87, 0, 0),
        BackgroundTransparency = 1, Text = valueText, TextColor3 = T.ACCENT,
        Font = Enum.Font.GothamBold, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Right, Parent = b})
    b.MouseEnter:Connect(function()
        tw(b, 0.15, nil, nil, {BackgroundColor3 = T.LINE}):Play()
        tw(st, 0.15, nil, nil, {Color = T.ACCENT, Transparency = 0.25}):Play()
    end)
    b.MouseLeave:Connect(function()
        tw(b, 0.15, nil, nil, {BackgroundColor3 = T.RAISED}):Play()
        tw(st, 0.15, nil, nil, {Color = T.LINE, Transparency = 0.55}):Play()
    end)
    return b, val, tag
end

local AimBtn,   AimVal,   AimTag   = makeRow("auto-aim", 2, "ON")
local MineBtn,  MineVal,  MineTag  = makeRow("my base only", 3, "OFF")
local StealBtn, StealVal, StealTag = makeRow("auto steal", 4, "ON")
local PathBtn,  PathVal,  PathTag  = makeRow("path nodes", 5, "ON")
local ModeBtn,  ModeVal,  ModeTag  = makeRow("travel", 6, "INSTANT")
local RangeBtn, RangeVal           = makeRow("free range", 7, L.Range .. "st")
local KeyBtn,   KeyVal             = makeRow("bind", 8, "E")

local function paint(tagFrame, valLabel, on)
    tw(tagFrame, 0.18, nil, nil, {BackgroundColor3 = on and T.GREEN or T.DEEP}):Play()
    valLabel.Text = on and "ON" or "OFF"
    valLabel.TextColor3 = on and T.GREEN or T.MUTED
end

local function bind(btn, fn)
    btn.MouseButton1Click:Connect(function() ripple(btn); fn(); refreshArray() end)
end

bind(AimBtn,   function() L.AutoAim   = not L.AutoAim;   paint(AimTag,   AimVal,   L.AutoAim)   end)
bind(MineBtn,  function() L.MineOnly  = not L.MineOnly;  paint(MineTag,  MineVal,  L.MineOnly)  end)
bind(StealBtn, function() L.AutoSteal = not L.AutoSteal; paint(StealTag, StealVal, L.AutoSteal) end)
bind(PathBtn,  function() L.ShowPath  = not L.ShowPath;  paint(PathTag,  PathVal,  L.ShowPath)  end)
bind(ModeBtn,  function()
    L.Instant = not L.Instant
    ModeVal.Text = L.Instant and "INSTANT" or "SWEEP"
    ModeVal.TextColor3 = L.Instant and T.GREEN or T.ORANGE
    tw(ModeTag, 0.18, nil, nil, {BackgroundColor3 = L.Instant and T.GREEN or T.ORANGE}):Play()
end)
bind(RangeBtn, function()
    L.Range = L.Range + 60
    if L.Range > 500 then L.Range = 140 end
    RangeVal.Text = L.Range .. "st"
end)

paint(AimTag, AimVal, L.AutoAim)
paint(MineTag, MineVal, L.MineOnly)
paint(StealTag, StealVal, L.AutoSteal)
paint(PathTag, PathVal, L.ShowPath)
ModeVal.TextColor3 = T.GREEN
tw(ModeTag, 0.1, nil, nil, {BackgroundColor3 = T.GREEN}):Play()

local rebinding = false
bind(KeyBtn, function()
    rebinding = true
    KeyVal.Text = "press…"
    KeyVal.TextColor3 = T.ORANGE
end)

do
    local dragging, startPos, startFrame = false, nil, nil
    Handle.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging, startPos, startFrame = true, i.Position, Panel.Position
        end
    end)
    UIS.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
            local d = i.Position - startPos
            Panel.Position = UDim2.new(startFrame.X.Scale, startFrame.X.Offset + d.X,
                                       startFrame.Y.Scale, startFrame.Y.Offset + d.Y)
        end
    end)
    UIS.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
end

CloseBtn.MouseButton1Click:Connect(function()
    hideArrow()
    L.Aiming = false
    tw(Panel, 0.2, nil, nil, {BackgroundTransparency = 1}):Play()
    task.delay(0.25, function() Gui:Destroy(); Folder:Destroy() end)
end)

----------------------------------------------------------------------
-- AIM LOOP
----------------------------------------------------------------------
local landing, lockedDir = nil, nil

RunS.RenderStepped:Connect(function()
    if not L.Aiming then return end
    local root = hrp()
    if not root then hideArrow() return end

    local origin = root.Position
    local dir = aimDir()
    local pad = pickTarget(origin, dir)
    L.Target = pad

    local point
    if pad then
        local p = pad.part.Position
        point = Vector3.new(p.X, p.Y, p.Z)
        local to = Vector3.new(p.X - origin.X, 0, p.Z - origin.Z)
        if to.Magnitude > 0.01 then dir = to.Unit end
        Glow.Adornee = pad.part
        Glow.Enabled = true
        StatusSub.Text = ("%s base · %dst"):format(pad.mine and "your" or pad.plot.Name:sub(1, 6),
            math.floor((p - origin).Magnitude))
        StatusSub.TextColor3 = pad.mine and T.GREEN or T.HIGH
    else
        point = origin + dir * L.Range
        Glow.Enabled = false
        Glow.Adornee = nil
        StatusSub.Text = ("free aim · %dst"):format(L.Range)
        StatusSub.TextColor3 = T.MUTED
    end

    landing, lockedDir = groundAt(point), dir
    drawArrow(origin, landing, pad ~= nil)

    local preview = buildRoute(origin, landing)
    showNodes(preview)
    local sides = 0
    for _, s in ipairs(preview) do if s.kind ~= "land" then sides += 1 end end
    StatusHops.Text = ("route: %d hop%s · %d detour%s"):format(#preview, #preview == 1 and "" or "s",
        sides, sides == 1 and "" or "s")
end)

----------------------------------------------------------------------
-- AUTO STEAL
--
-- PromptTriggered fires the instant the hold completes. The route runs inside
-- this handler, so there is no frame of delay between finishing the steal and
-- being gone.
----------------------------------------------------------------------
PPS.PromptTriggered:Connect(function(prompt, player)
    if not L.AutoSteal then return end
    if player ~= LP then return end
    local txt = ((prompt.ObjectText or "") .. " " .. (prompt.ActionText or "")):lower()
    if not txt:find("steal", 1, true) then return end

    local pad = myPad()
    if not pad then
        StatusSub.Text = "auto steal: no base found"
        StatusSub.TextColor3 = T.RED
        return
    end
    local root = hrp()
    if not root then return end
    local p = pad.part.Position
    local to = Vector3.new(p.X - root.Position.X, 0, p.Z - root.Position.Z)
    local dir = (to.Magnitude > 0.01) and to.Unit or aimDir()
    local ok, hops = dashTo(groundAt(p), dir)
    if ok then
        StatusTop.Text = "stole → home"
        StatusTop.TextColor3 = T.GREEN
        StatusHops.Text = ("route: %d hop%s"):format(hops, hops == 1 and "" or "s")
        task.delay(1.2, function()
            StatusTop.Text = "hold " .. L.Key.Name .. " to aim"
            StatusTop.TextColor3 = T.TEXT
        end)
    end
end)

----------------------------------------------------------------------
-- INPUT
----------------------------------------------------------------------
UIS.InputBegan:Connect(function(input, gpe)
    if rebinding and input.UserInputType == Enum.UserInputType.Keyboard then
        L.Key = input.KeyCode
        KeyVal.Text = input.KeyCode.Name
        KeyVal.TextColor3 = T.ACCENT
        StatusTop.Text = "hold " .. input.KeyCode.Name .. " to aim"
        rebinding = false
        return
    end
    if gpe then return end
    if input.KeyCode == L.Key then
        L.Aiming = true
        StatusTop.Text = "aiming"
        StatusTop.TextColor3 = T.ACCENT
        tw(Dot, 0.2, nil, nil, {BackgroundColor3 = T.ACCENT}):Play()
        refreshArray()
    end
end)

UIS.InputEnded:Connect(function(input, gpe)
    if input.KeyCode ~= L.Key or not L.Aiming then return end
    L.Aiming = false
    StatusTop.Text = "hold " .. L.Key.Name .. " to aim"
    StatusTop.TextColor3 = T.TEXT
    tw(Dot, 0.2, nil, nil, {BackgroundColor3 = T.DEEP}):Play()
    refreshArray()

    if landing and lockedDir then
        local ok, hops = dashTo(landing, lockedDir)
        if ok then
            StatusHops.Text = ("route: %d hop%s"):format(hops, hops == 1 and "" or "s")
            RingStroke.Transparency = 0.3
            Ring2.Size = UDim2.fromOffset(9, 9)
            tw(Ring2, 0.8, Enum.EasingStyle.Quad, nil, {Size = UDim2.fromOffset(28, 28),
                Position = UDim2.new(0, -10, 0.5, -14)}):Play()
            tw(RingStroke, 0.8, Enum.EasingStyle.Quad, nil, {Transparency = 1}):Play()
        end
    end
    hideArrow()
end)

----------------------------------------------------------------------
-- INTRO
----------------------------------------------------------------------
task.spawn(function()
    Panel.BackgroundTransparency = 1
    tw(Panel, 0.35, nil, nil, {BackgroundTransparency = 0}):Play()
    tw(PanelStroke, 0.35, nil, nil, {Transparency = 0.35}):Play()
    tw(Brand, 0.35, nil, nil, {TextTransparency = 0}):Play()
    tw(CloseBtn, 0.35, nil, nil, {BackgroundTransparency = 0.2, TextTransparency = 0}):Play()
    refreshArray()
end)

getgenv().LUMIDASH = L
return L
