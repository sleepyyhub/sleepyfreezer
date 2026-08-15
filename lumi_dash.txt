--[[  LUMINOSITY — DASH  ]]--
-- Steal A Summertino — aimed fling with real navmesh pathfinding
-- Executor: any. No dependencies. Paste whole file, execute.
--
-- Hold the bind (default E) to raise an aim arrow, release to travel.
-- The arrow is horizontal only, so you never get launched into the sky.
--
-- ROUTING
-- Two engines, in order of preference:
--
--   1. PathfindingService. A real navmesh path is computed between you and
--      the landing point and its waypoints become teleport stops. This walks
--      around buildings and fences properly rather than guessing.
--   2. Raycast routing, used when the navmesh has no answer (off-mesh
--      targets, mid-air, inside geometry). Marches the straight line and,
--      where blocked, sweeps perpendicular offsets left and right for a way
--      around, falling back to lifting only if every lateral option fails.
--
-- Each stop is a hop with a short beat between them, so the route reads as
-- a series of steps rather than one clip through a wall.
--
-- AUTO STEAL
-- ProximityPromptService.PromptTriggered fires the moment a hold completes.
-- When the prompt's text contains "Steal" and the trigger was yours, the
-- route home runs inside that handler.

local Players    = game:GetService("Players")
local RepS       = game:GetService("ReplicatedStorage")
local RunS       = game:GetService("RunService")
local TS         = game:GetService("TweenService")
local UIS        = game:GetService("UserInputService")
local PPS        = game:GetService("ProximityPromptService")
local PathS      = game:GetService("PathfindingService")
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
L.Spacing    = 12
L.Detours    = {8, 16, 26, 38, 52, 68}
L.MaxHops    = 64
L.AutoAim    = true
L.MineOnly   = false
L.Pathfind   = true
L.HopDelay   = 0.01
L.AutoSteal  = true
L.ShowPath   = true
L.Aiming     = false
L.Target     = nil
L.Engine     = "-"
L.LastRoute  = {}

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
    PURPLE   = Color3.fromRGB(175, 135, 255),
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

-- Ground settle. Two things this has to get right: scan from just above the
-- point's OWN height, not the player's, or a roof above the destination is
-- mistaken for its floor; and skip non-collidable hits, since the map is full
-- of decorative parts a raycast reports but you would fall straight through.
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

-- Engine 1: the navmesh. ComputeAsync yields, so this is never called from a
-- hot path without the caller knowing.
local function navRoute(from, to)
    local path = safe(function()
        return PathS:CreatePath({
            AgentRadius = 2.5,
            AgentHeight = 5,
            AgentCanJump = true,
            AgentCanClimb = false,
            WaypointSpacing = L.Spacing,
        })
    end)
    if not path then return nil end
    local ok = pcall(function() path:ComputeAsync(from, to) end)
    if not ok or path.Status ~= Enum.PathStatus.Success then return nil end
    local wps = safe(function() return path:GetWaypoints() end)
    if not wps or #wps < 2 then return nil end

    local stops = {}
    for i = 2, #wps do
        local w = wps[i]
        stops[#stops + 1] = {
            pos  = w.Position + Vector3.new(0, 3, 0),
            kind = (w.Action == Enum.PathWaypointAction.Jump) and "jump" or "nav",
        }
    end
    stops[#stops] = {pos = groundAt(to), kind = "land"}
    return stops
end

-- Engine 2: straight line with lateral escapes. Prefer going around; climb
-- only when every offset is blocked.
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

local function rayRoute(origin, target)
    local params = rayParams()
    local stops, cur, guard = {}, origin, 0
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

local function buildRoute(origin, target, allowNav)
    if L.Pathfind and allowNav then
        local nav = navRoute(origin, target)
        if nav then L.Engine = "navmesh" return nav end
    end
    L.Engine = "raycast"
    return rayRoute(origin, target)
end

----------------------------------------------------------------------
-- WORLD VISUALS
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
            n = makePart({Size = Vector3.new(1, 1, 1), Shape = Enum.PartType.Ball, Transparency = 1})
            NodePool[i] = n
        end
        n.Color = (s.kind == "land") and T.GREEN
            or (s.kind == "side" and T.ORANGE)
            or (s.kind == "jump" and T.PURPLE or T.ACCENT)
        n.CFrame = CFrame.new(s.pos)
        n.Transparency = 0.3
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
local function dashTo(landing, dir, allowNav)
    local root, hum = hrp(), humanoid()
    if not root then return false, 0 end
    local stops = buildRoute(root.Position, landing, allowNav ~= false)
    L.LastRoute = stops

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
        if L.HopDelay > 0 and i < #stops then task.wait(L.HopDelay) end
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
local function Pad(p, a, b, c, d) return New("UIPadding", {
    PaddingTop = UDim.new(0, a or 0), PaddingBottom = UDim.new(0, b or a or 0),
    PaddingLeft = UDim.new(0, c or a or 0), PaddingRight = UDim.new(0, d or c or a or 0), Parent = p}) end
local function Stroke(p, col, th, tr)
    return New("UIStroke", {Color = col or T.LINE, Thickness = th or 1, Transparency = tr or 0.4,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = p})
end
local function tw(o, t, s, d, g) return TS:Create(o, TweenInfo.new(t, s or Enum.EasingStyle.Quart,
    d or Enum.EasingDirection.Out), g) end

local Gui = New("ScreenGui", {Name = "LuminosityDash", ResetOnSpawn = false, IgnoreGuiInset = true,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 9999, Parent = PG})

-- One palette, one clock: every gradient registered here is driven by a single
-- pass so the whole interface reads as one sheet of moving light.
local FLOW_WHITE = Color3.fromRGB(255, 255, 255)
local FLOW_LIGHT = Color3.fromRGB(138, 199, 255)
local FLOW_MID   = Color3.fromRGB(58, 118, 216)
local FLOW_DARK  = Color3.fromRGB(12, 38, 96)
local FLOW_SEQ = ColorSequence.new({
    ColorSequenceKeypoint.new(0.00, FLOW_DARK),
    ColorSequenceKeypoint.new(0.22, FLOW_MID),
    ColorSequenceKeypoint.new(0.45, FLOW_LIGHT),
    ColorSequenceKeypoint.new(0.58, FLOW_WHITE),
    ColorSequenceKeypoint.new(0.74, FLOW_LIGHT),
    ColorSequenceKeypoint.new(1.00, FLOW_DARK),
})
local Flows = {}
local function flow(parent, opts)
    opts = opts or {}
    local g = New("UIGradient", {Color = FLOW_SEQ, Rotation = opts.rotation or 0,
        Offset = Vector2.new(opts.phase or 0, 0), Parent = parent})
    Flows[#Flows + 1] = {g = g, speed = opts.speed or 0.35, phase = opts.phase or 0}
    return g
end
task.spawn(function()
    local t = 0
    while Gui.Parent do
        t += RunS.RenderStepped:Wait()
        for _, f in ipairs(Flows) do
            f.g.Offset = Vector2.new(((t * f.speed + f.phase) % 2) - 1, 0)
        end
    end
end)

----------------------------------------------------------------------
-- LOADING SCREEN
----------------------------------------------------------------------
local Loader = New("Frame", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
    BorderSizePixel = 0, ZIndex = 100, Parent = Gui})
local RainRoot = New("Frame", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
    ClipsDescendants = false, ZIndex = 100, Parent = Loader})

L.RainActive = true
task.spawn(function()
    while L.RainActive and Loader.Parent do
        local size = math.random(14, 34)
        local col = ({T.ACCENT, T.HIGH, T.DEEP})[math.random(1, 3)]
        local x = math.random(0, Cam and Cam.ViewportSize.X or 1200)
        local rot0 = math.random(-40, 40)
        local moon = New("TextLabel", {Size = UDim2.fromOffset(size, size),
            Position = UDim2.new(0, x, 0, -size - 20), BackgroundTransparency = 1,
            Text = "☾", TextColor3 = col, Font = Enum.Font.GothamBold, TextSize = size,
            TextTransparency = math.random(30, 65) / 100, Rotation = rot0,
            ZIndex = 100, Parent = RainRoot})
        New("UIStroke", {Color = col, Thickness = 0.5, Transparency = 0.6, Parent = moon})
        local vy = Cam and Cam.ViewportSize.Y or 800
        local dur = math.random(24, 44) / 10
        local drift = math.random(-60, 60)
        local endRot = rot0 + math.random(-90, 90)
        task.spawn(function()
            TS:Create(moon, TweenInfo.new(dur, Enum.EasingStyle.Linear),
                {Position = UDim2.new(0, x + drift, 0, vy + 40), Rotation = endRot}):Play()
            TS:Create(moon, TweenInfo.new(dur * 0.9, Enum.EasingStyle.Quad), {TextTransparency = 1}):Play()
            task.wait(dur)
            moon:Destroy()
        end)
        task.wait(0.11)
    end
end)

local LoaderCard = New("Frame", {Size = UDim2.fromOffset(520, 150),
    Position = UDim2.new(0.5, -260, 0.5, -75), BackgroundTransparency = 1,
    BorderSizePixel = 0, ZIndex = 101, Parent = Loader})

local BRAND = "LUMINOSITY"
local BIG_SIZE = IS_MOBILE and 46 or 62
local Mark = New("Frame", {Size = UDim2.new(1, 0, 0, BIG_SIZE + 8), BackgroundTransparency = 1,
    ZIndex = 102, Parent = LoaderCard})
New("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal,
    HorizontalAlignment = Enum.HorizontalAlignment.Center,
    VerticalAlignment = Enum.VerticalAlignment.Center,
    Padding = UDim.new(0, 1), Parent = Mark})

local Letters = {}
for i = 1, #BRAND do
    local ch = BRAND:sub(i, i)
    local w = BIG_SIZE * (ch == "I" and 0.35 or 0.62)
    local wrap = New("Frame", {Size = UDim2.fromOffset(w, BIG_SIZE), BackgroundTransparency = 1,
        LayoutOrder = i, ZIndex = 102, Parent = Mark})
    local lbl = New("TextLabel", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
        Text = ch, TextColor3 = T.HIGH, Font = Enum.Font.GothamBold, TextSize = BIG_SIZE,
        TextTransparency = 1, Rotation = math.random(-60, 60), ZIndex = 103, Parent = wrap})
    lbl.Position = UDim2.fromOffset(math.random(-140, 140), math.random(-90, 90))
    New("UIStroke", {Color = Color3.fromRGB(0, 0, 0), Thickness = 2, Transparency = 0.1,
        LineJoinMode = Enum.LineJoinMode.Round, Parent = lbl})
    Letters[i] = lbl
end

local Underline = New("Frame", {Size = UDim2.new(0, 0, 0, 2),
    Position = UDim2.new(0.5, 0, 0, BIG_SIZE + 12), AnchorPoint = Vector2.new(0.5, 0),
    BackgroundColor3 = T.ACCENT, BackgroundTransparency = 0.15, BorderSizePixel = 0,
    ZIndex = 102, Parent = LoaderCard})
Corner(Underline, 1)
flow(Underline, {speed = 0.5})

local Sub = New("TextLabel", {Size = UDim2.new(1, 0, 0, 18),
    Position = UDim2.new(0, 0, 0, BIG_SIZE + 22), BackgroundTransparency = 1,
    Text = "initializing", TextColor3 = T.MUTED, Font = Enum.Font.Gotham, TextSize = 12,
    TextTransparency = 1, ZIndex = 102, Parent = LoaderCard})

----------------------------------------------------------------------
-- NOTIFICATIONS
----------------------------------------------------------------------
local NOTIF_W = IS_MOBILE and 270 or 320
local NotifRoot = New("Frame", {AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 14),
    Size = UDim2.fromOffset(NOTIF_W, 0), AutomaticSize = Enum.AutomaticSize.Y,
    BackgroundTransparency = 1, Parent = Gui})
New("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder,
    HorizontalAlignment = Enum.HorizontalAlignment.Right, Padding = UDim.new(0, 8), Parent = NotifRoot})

L.Notifs, L.NotifOrder = {}, 0

local function destroyNotif(s)
    if s.dead then return end
    s.dead = true
    L.Notifs[s.key] = nil
    tw(s.frame, 0.26, nil, nil, {Position = UDim2.fromOffset(NOTIF_W + 40, 0), BackgroundTransparency = 1}):Play()
    for _, o in ipairs(s.fade) do
        tw(o, 0.22, nil, nil, o:IsA("UIStroke") and {Transparency = 1}
            or (o:IsA("Frame") and {BackgroundTransparency = 1} or {TextTransparency = 1})):Play()
    end
    task.delay(0.3, function() if s.frame then s.frame:Destroy() end end)
end

L.Notify = function(msg, color, sub)
    msg = tostring(msg or "")
    if msg == "" then return end
    color = color or T.HIGH
    local e = L.Notifs[msg]
    if e and not e.dead then
        e.count += 1
        e.badge.Text = "×" .. e.count
        e.badge.Visible = true
        if sub then e.sub.Text = sub end
        e.token += 1
        local tok = e.token
        tw(e.badge, 0.12, Enum.EasingStyle.Back, nil, {TextSize = 17}):Play()
        task.delay(0.12, function() if not e.dead then tw(e.badge, 0.16, Enum.EasingStyle.Back, nil, {TextSize = 13}):Play() end end)
        task.delay(3.2, function() if not e.dead and e.token == tok then destroyNotif(e) end end)
        return
    end
    L.NotifOrder += 1
    local h = sub and 72 or 52
    local frame = New("Frame", {Size = UDim2.new(1, 0, 0, h), Position = UDim2.fromOffset(NOTIF_W + 40, 0),
        BackgroundColor3 = T.SURFACE, BackgroundTransparency = 1, BorderSizePixel = 0,
        ClipsDescendants = true, LayoutOrder = L.NotifOrder, Parent = NotifRoot})
    Corner(frame, 12)
    local stroke = Stroke(frame, T.LINE, 1, 1)
    local bar = New("Frame", {Size = UDim2.new(0, 4, 1, -16), Position = UDim2.new(0, 8, 0, 8),
        BackgroundColor3 = color, BackgroundTransparency = 1, BorderSizePixel = 0, Parent = frame})
    Corner(bar, 2)
    local body = New("TextLabel", {Size = UDim2.new(1, -58, 0, sub and 22 or 52),
        Position = UDim2.new(0, 20, 0, sub and 11 or 0), BackgroundTransparency = 1,
        Text = msg, TextColor3 = color, Font = Enum.Font.GothamBold, TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = sub and Enum.TextYAlignment.Top or Enum.TextYAlignment.Center,
        TextTruncate = Enum.TextTruncate.AtEnd, TextTransparency = 1, Parent = frame})
    local subLbl = New("TextLabel", {Size = UDim2.new(1, -58, 0, 30), Position = UDim2.new(0, 20, 0, 35),
        BackgroundTransparency = 1, Text = sub or "", TextColor3 = T.MUTED,
        Font = Enum.Font.Gotham, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = true, Visible = sub ~= nil,
        TextTransparency = 1, Parent = frame})
    local badge = New("TextLabel", {Size = UDim2.fromOffset(32, 20), Position = UDim2.new(1, -40, 0, 9),
        BackgroundTransparency = 1, Text = "", TextColor3 = T.WHITE, Font = Enum.Font.GothamBold,
        TextSize = 13, TextXAlignment = Enum.TextXAlignment.Right, Visible = false,
        TextTransparency = 1, Parent = frame})
    local s = {key = msg, frame = frame, badge = badge, sub = subLbl, count = 1, token = 0,
               dead = false, fade = {body, subLbl, badge, bar, stroke}}
    L.Notifs[msg] = s
    tw(frame, 0.3, Enum.EasingStyle.Quint, nil, {Position = UDim2.fromOffset(0, 0), BackgroundTransparency = 0.08}):Play()
    tw(stroke, 0.3, nil, nil, {Transparency = 0.45}):Play()
    tw(bar, 0.3, nil, nil, {BackgroundTransparency = 0}):Play()
    tw(body, 0.3, nil, nil, {TextTransparency = 0}):Play()
    if sub then tw(subLbl, 0.3, nil, nil, {TextTransparency = 0.15}):Play() end
    tw(badge, 0.3, nil, nil, {TextTransparency = 0.1}):Play()
    local tok = s.token
    task.delay(3.2, function() if not s.dead and s.token == tok then destroyNotif(s) end end)
end

----------------------------------------------------------------------
-- PANEL
----------------------------------------------------------------------
local PANEL_W = IS_MOBILE and 280 or 320
local Panel = New("Frame", {Size = UDim2.fromOffset(PANEL_W, 300),
    Position = UDim2.new(0.5, -(PANEL_W / 2), 0.5, -150 + 40),
    BackgroundColor3 = T.SURFACE, BackgroundTransparency = 1, BorderSizePixel = 0, Parent = Gui})
Corner(Panel, 16); Pad(Panel, 16)
local PanelStroke = Stroke(Panel, T.LINE, 1, 1)
flow(Panel, {speed = 0.16, rotation = 22})
flow(PanelStroke, {speed = 0.3, rotation = 22})

local Header = New("Frame", {Size = UDim2.new(1, 0, 0, 20), BackgroundTransparency = 1, Parent = Panel})
local Handle = New("TextButton", {Size = UDim2.new(1, -52, 1, 0), BackgroundTransparency = 1,
    AutoButtonColor = false, Text = "", Parent = Header})
local Brand = New("TextLabel", {Size = UDim2.new(1, -18, 1, 0), Position = UDim2.fromOffset(16, 0),
    BackgroundTransparency = 1, Text = "LUMINOSITY", TextColor3 = T.HIGH,
    Font = Enum.Font.GothamBold, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
    TextTransparency = 1, Parent = Handle})
flow(Brand, {speed = 0.42})
local SubBrand = New("TextLabel", {Size = UDim2.new(0, 60, 1, 0), Position = UDim2.new(0, 100, 0, 0),
    BackgroundTransparency = 1, Text = "DASH", TextColor3 = T.PURPLE,
    Font = Enum.Font.GothamBold, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left,
    TextTransparency = 1, Parent = Handle})

local Dot = New("Frame", {Size = UDim2.fromOffset(8, 8), Position = UDim2.new(0, 0, 0.5, -4),
    BackgroundColor3 = Color3.fromRGB(30, 40, 60), BackgroundTransparency = 1,
    BorderSizePixel = 0, Parent = Handle})
Corner(Dot, 4)
local DotStroke = New("UIStroke", {Color = Color3.fromRGB(0, 0, 0), Thickness = 1, Transparency = 0.4, Parent = Dot})
local Ring2 = New("Frame", {Size = UDim2.fromOffset(8, 8), Position = UDim2.new(0, 0, 0.5, -4),
    BackgroundTransparency = 1, BorderSizePixel = 0, Parent = Handle})
Corner(Ring2, 8)
local RingStroke = New("UIStroke", {Color = T.ACCENT, Thickness = 1, Transparency = 1, Parent = Ring2})

local MinBtn = New("TextButton", {Size = UDim2.fromOffset(20, 20), Position = UDim2.new(1, -46, 0.5, -10),
    BackgroundColor3 = T.RAISED, AutoButtonColor = false, Text = "—", TextColor3 = T.MUTED,
    Font = Enum.Font.GothamBold, TextSize = 11, BackgroundTransparency = 1, TextTransparency = 1, Parent = Header})
Corner(MinBtn, 6)
local CloseBtn = New("TextButton", {Size = UDim2.fromOffset(20, 20), Position = UDim2.new(1, -22, 0.5, -10),
    BackgroundColor3 = T.RAISED, AutoButtonColor = false, Text = "×", TextColor3 = T.MUTED,
    Font = Enum.Font.GothamBold, TextSize = 13, BackgroundTransparency = 1, TextTransparency = 1, Parent = Header})
Corner(CloseBtn, 6)

local Content = New("Frame", {Size = UDim2.new(1, 0, 1, -32), Position = UDim2.new(0, 0, 0, 32),
    BackgroundTransparency = 1, Parent = Panel})
local ContentList = New("UIListLayout", {Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = Content})

local StatusCard = New("Frame", {Size = UDim2.new(1, 0, 0, 50), BackgroundColor3 = T.BG,
    BackgroundTransparency = 1, BorderSizePixel = 0, LayoutOrder = 1, Parent = Content})
Corner(StatusCard, 10)
local StatusStroke = Stroke(StatusCard, T.LINE, 1, 1)
flow(StatusStroke, {speed = 0.34, phase = 0.3})
Pad(StatusCard, 9)
local StatusTop = New("TextLabel", {Size = UDim2.new(1, 0, 0, 13), BackgroundTransparency = 1,
    Text = "hold E to aim", TextColor3 = T.TEXT, Font = Enum.Font.GothamBold, TextSize = 12,
    TextXAlignment = Enum.TextXAlignment.Left, TextTransparency = 1, Parent = StatusCard})
local StatusSub = New("TextLabel", {Size = UDim2.new(1, 0, 0, 12), Position = UDim2.fromOffset(0, 16),
    BackgroundTransparency = 1, Text = "no target", TextColor3 = T.MUTED, Font = Enum.Font.Gotham,
    TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
    TextTransparency = 1, Parent = StatusCard})
local StatusHops = New("TextLabel", {Size = UDim2.new(1, 0, 0, 12), Position = UDim2.fromOffset(0, 29),
    BackgroundTransparency = 1, Text = "route: —", TextColor3 = T.PURPLE, Font = Enum.Font.Gotham,
    TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
    TextTransparency = 1, Parent = StatusCard})

local Rows = {}
local function ToggleRow(label, order, get, onChange)
    local Box = New("Frame", {Size = UDim2.new(1, 0, 0, 38), BackgroundColor3 = T.RAISED,
        BackgroundTransparency = 1, LayoutOrder = order, Parent = Content})
    Corner(Box, 10); Pad(Box, 0, 0, 12, 12)
    local BoxStroke = Stroke(Box, T.LINE, 1, 1)
    flow(BoxStroke, {speed = 0.3, phase = order * 0.13})
    local Tag = New("TextLabel", {Size = UDim2.new(1, -50, 1, 0), BackgroundTransparency = 1,
        Text = label, TextColor3 = T.MUTED, Font = Enum.Font.GothamSemibold, TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left, TextTransparency = 1, Parent = Box})
    local Sw = New("TextButton", {Size = UDim2.fromOffset(38, 20), Position = UDim2.new(1, 0, 0.5, 0),
        AnchorPoint = Vector2.new(1, 0.5), BackgroundColor3 = T.SURFACE, AutoButtonColor = false,
        Text = "", BackgroundTransparency = 1, Parent = Box})
    Corner(Sw, 10)
    local SwStroke = Stroke(Sw, T.LINE, 1, 1)
    local Kn = New("Frame", {Size = UDim2.fromOffset(14, 14), Position = UDim2.new(0, 3, 0.5, -7),
        BackgroundColor3 = T.MUTED, BackgroundTransparency = 1, BorderSizePixel = 0, Parent = Sw})
    Corner(Kn, 7)
    local state = get
    local function set(on)
        state = on
        tw(Sw, 0.18, nil, nil, {BackgroundColor3 = on and T.ACCENT or T.SURFACE}):Play()
        tw(SwStroke, 0.18, nil, nil, {Color = on and T.HIGH or T.LINE, Transparency = on and 0.3 or 0.5}):Play()
        TS:Create(Kn, TweenInfo.new(0.26, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
            Position = on and UDim2.new(1, -17, 0.5, -7) or UDim2.new(0, 3, 0.5, -7),
            BackgroundColor3 = on and T.WHITE or T.MUTED}):Play()
        tw(Tag, 0.18, nil, nil, {TextColor3 = on and T.TEXT or T.MUTED}):Play()
        tw(BoxStroke, 0.18, nil, nil, {Transparency = on and 0.3 or 0.5}):Play()
        if onChange then onChange(on) end
    end
    Sw.MouseButton1Click:Connect(function() set(not state) end)
    local entry = {Box = Box, BoxStroke = BoxStroke, Tag = Tag, Sw = Sw, SwStroke = SwStroke,
                   Kn = Kn, Set = set, Get = function() return state end}
    Rows[#Rows + 1] = entry
    return entry
end

local AimRow   = ToggleRow("auto-aim",     2, L.AutoAim,   function(on) L.AutoAim = on end)
local MineRow  = ToggleRow("my base only", 3, L.MineOnly,  function(on) L.MineOnly = on end)
local PathRow  = ToggleRow("pathfinding",  4, L.Pathfind,  function(on)
    L.Pathfind = on
    L.Notify(on and "Pathfinding on" or "Pathfinding off", on and T.GREEN or T.MUTED,
        on and "navmesh route, falls back to raycast" or "raycast routing only")
end)
local StealRow = ToggleRow("auto steal",   5, L.AutoSteal, function(on) L.AutoSteal = on end)
local NodeRow  = ToggleRow("path nodes",   6, L.ShowPath,  function(on) L.ShowPath = on end)

local Fab = New("TextButton", {Size = UDim2.fromOffset(48, 48), Position = UDim2.new(0, 20, 1, -90),
    BackgroundColor3 = T.SURFACE, AutoButtonColor = false, Text = "L", TextColor3 = T.HIGH,
    Font = Enum.Font.GothamBold, TextSize = 18, Visible = false, Parent = Gui})
Corner(Fab, 14)
local FabStroke = Stroke(Fab, T.ACCENT, 1, 0.5)
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
    else tw(Panel, 0.28, nil, nil, {Size = UDim2.fromOffset(PANEL_W, h)}):Play() end
end
ContentList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function() fit(false) end)

local function draggable(frame, handle)
    handle = handle or frame
    local dragging, start, spos
    handle.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging, start, spos = true, i.Position, frame.Position
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

MinBtn.MouseButton1Click:Connect(function()
    minimized = not minimized
    if minimized then
        Content.Visible = false
        tw(Panel, 0.26, nil, nil, {Size = UDim2.fromOffset(PANEL_W, 44)}):Play()
        MinBtn.Text = "+"
    else
        MinBtn.Text = "—"
        fit(false)
        task.delay(0.1, function() if not minimized then Content.Visible = true end end)
    end
end)
CloseBtn.MouseButton1Click:Connect(function()
    hideArrow()
    L.Aiming = false
    tw(Panel, 0.2, nil, nil, {BackgroundTransparency = 1}):Play()
    task.delay(0.22, function()
        Panel.Visible = false
        Panel.BackgroundTransparency = 0.7
        Fab.Visible = true
        Fab.Size = UDim2.fromOffset(0, 0)
        tw(Fab, 0.3, Enum.EasingStyle.Back, nil, {Size = UDim2.fromOffset(48, 48)}):Play()
    end)
end)
Fab.MouseButton1Click:Connect(function()
    tw(Fab, 0.18, nil, nil, {Size = UDim2.fromOffset(0, 0)}):Play()
    task.delay(0.18, function()
        Fab.Visible = false
        Fab.Size = UDim2.fromOffset(48, 48)
        Panel.Visible = true
    end)
end)

----------------------------------------------------------------------
-- AIM LOOP
--
-- The preview uses raycast routing only. ComputeAsync yields, and calling it
-- every frame would stall the render loop; the navmesh is asked once, on
-- release, when its cost is paid off by an accurate route.
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

    local preview = rayRoute(origin, landing)
    showNodes(preview)
    StatusHops.Text = ("preview: %d hop%s · %s on release")
        :format(#preview, #preview == 1 and "" or "s", L.Pathfind and "navmesh" or "raycast")
end)

----------------------------------------------------------------------
-- AUTO STEAL
----------------------------------------------------------------------
PPS.PromptTriggered:Connect(function(prompt, player)
    if not L.AutoSteal then return end
    if player ~= LP then return end
    local txt = ((prompt.ObjectText or "") .. " " .. (prompt.ActionText or "")):lower()
    if not txt:find("steal", 1, true) then return end

    local pad = myPad()
    if not pad then
        L.Notify("Auto steal", T.RED, "no owned base found")
        return
    end
    local root = hrp()
    if not root then return end
    local p = pad.part.Position
    local to = Vector3.new(p.X - root.Position.X, 0, p.Z - root.Position.Z)
    local dir = (to.Magnitude > 0.01) and to.Unit or aimDir()
    local ok, hops = dashTo(groundAt(p), dir, true)
    if ok then
        L.Notify("Stole → home", T.GREEN, ("%s · %d hop%s"):format(L.Engine, hops, hops == 1 and "" or "s"))
        StatusHops.Text = ("route: %s · %d hop%s"):format(L.Engine, hops, hops == 1 and "" or "s")
    end
end)

----------------------------------------------------------------------
-- INPUT
----------------------------------------------------------------------
UIS.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == L.Key then
        L.Aiming = true
        StatusTop.Text = "aiming"
        StatusTop.TextColor3 = T.ACCENT
        tw(Dot, 0.2, nil, nil, {BackgroundColor3 = T.ACCENT}):Play()
    end
end)

UIS.InputEnded:Connect(function(input)
    if input.KeyCode ~= L.Key or not L.Aiming then return end
    L.Aiming = false
    StatusTop.Text = "hold " .. L.Key.Name .. " to aim"
    StatusTop.TextColor3 = T.TEXT
    tw(Dot, 0.2, nil, nil, {BackgroundColor3 = Color3.fromRGB(30, 40, 60)}):Play()

    if landing and lockedDir then
        local target, face = landing, lockedDir
        task.spawn(function()
            local ok, hops = dashTo(target, face, true)
            if ok then
                StatusHops.Text = ("route: %s · %d hop%s"):format(L.Engine, hops, hops == 1 and "" or "s")
                RingStroke.Transparency = 0.3
                Ring2.Size = UDim2.fromOffset(8, 8)
                tw(Ring2, 0.8, Enum.EasingStyle.Quad, nil, {Size = UDim2.fromOffset(26, 26),
                    Position = UDim2.new(0, -9, 0.5, -13)}):Play()
                tw(RingStroke, 0.8, Enum.EasingStyle.Quad, nil, {Transparency = 1}):Play()
            end
        end)
    end
    hideArrow()
end)

----------------------------------------------------------------------
-- INTRO
----------------------------------------------------------------------
task.spawn(function()
    for i, lbl in ipairs(Letters) do
        task.delay((i - 1) * 0.055, function()
            TS:Create(lbl, TweenInfo.new(0.7, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
                Position = UDim2.fromOffset(0, 0), Rotation = 0, TextTransparency = 0}):Play()
        end)
    end
    task.wait(0.055 * #Letters + 0.35)
    tw(Underline, 0.55, nil, nil, {Size = UDim2.new(0.72, 0, 0, 2)}):Play()
    task.wait(0.15)
    tw(Sub, 0.4, nil, nil, {TextTransparency = 0}):Play()

    for _, s in ipairs({"loading modules", "mapping plots", "building navmesh", "arming dash", "ready"}) do
        Sub.Text = s
        task.wait(0.26)
    end
    task.wait(0.18)

    for _, lbl in ipairs(Letters) do TS:Create(lbl, TweenInfo.new(0.35), {TextTransparency = 1}):Play() end
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
    tw(SubBrand, 0.4, nil, nil, {TextTransparency = 0.15}):Play()
    tw(Dot, 0.4, nil, nil, {BackgroundTransparency = 0}):Play()
    tw(MinBtn, 0.4, nil, nil, {BackgroundTransparency = 0, TextTransparency = 0}):Play()
    tw(CloseBtn, 0.4, nil, nil, {BackgroundTransparency = 0, TextTransparency = 0}):Play()

    task.delay(0.05, function()
        tw(StatusCard, 0.4, nil, nil, {BackgroundTransparency = 0.25}):Play()
        tw(StatusStroke, 0.4, nil, nil, {Transparency = 0.5}):Play()
        tw(StatusTop, 0.4, nil, nil, {TextTransparency = 0}):Play()
        tw(StatusSub, 0.4, nil, nil, {TextTransparency = 0}):Play()
        tw(StatusHops, 0.4, nil, nil, {TextTransparency = 0}):Play()
    end)
    for i, r in ipairs(Rows) do
        task.delay(0.1 + i * 0.05, function()
            tw(r.Box, 0.35, nil, nil, {BackgroundTransparency = 0}):Play()
            tw(r.BoxStroke, 0.35, nil, nil, {Transparency = 0.5}):Play()
            tw(r.Tag, 0.35, nil, nil, {TextTransparency = 0}):Play()
            tw(r.Sw, 0.35, nil, nil, {BackgroundTransparency = 0}):Play()
            tw(r.SwStroke, 0.35, nil, nil, {Transparency = 0.5}):Play()
            tw(r.Kn, 0.35, nil, nil, {BackgroundTransparency = 0}):Play()
        end)
    end

    task.delay(0.7, function()
        AimRow.Set(L.AutoAim)
        MineRow.Set(L.MineOnly)
        PathRow.Set(L.Pathfind)
        StealRow.Set(L.AutoSteal)
        NodeRow.Set(L.ShowPath)
        L.Notify("Dash online", T.HIGH, "hold " .. L.Key.Name .. " to aim")
    end)
end)

getgenv().LUMIDASH = L
return L
