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
-- The whole route is applied within a single frame, so it arrives instantly
-- rather than gliding, while still passing through each stop in order.
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
L.Spacing    = 4
L.Detours    = {6, 12, 20, 30, 42, 56}
L.Slim       = true
L.SlimWidth  = 0.70
L.SlimDepth  = 0.60
L.SlimHeight = 0.85
L.SlimHead   = 0.75
L.Precompute = true
L.Ready      = nil
L.MaxHops    = 64
L.AutoAim    = true
L.LockBase   = true
L.MineOnly   = false
L.Pathfind   = true
L.HopDelay   = 0
L.Stepped    = false
L.PreviewHz  = 0.12
L.StopShort  = 20
L.StealShort = 40
L.StealHop   = 20
L.StealHang  = 0.2
L.StepDelay  = 0.02
L.AutoSteal  = true
L.ShowPath   = true
L.Aiming     = false
L.Target     = nil
L.Engine     = "-"
L.LastRoute  = {}
L.HomeReady  = nil
L.HomeHz     = 0.35
L.Retries    = 7
L.RetryTol   = 12
L.RetryGap   = 0.05
L.Retried    = 0

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

local groundAt   -- forward declaration: world helpers settle points with it

local function safe(fn) local ok, r = pcall(fn); return ok and r or nil end
local function alive(i) return i and typeof(i) == "Instance" and i.Parent ~= nil end
local function char()   return LP.Character end
local function hrp()    local c = char(); return c and c:FindFirstChild("HumanoidRootPart") end
local function humanoid() local c = char(); return c and c:FindFirstChildOfClass("Humanoid") end

----------------------------------------------------------------------
-- AVATAR
--
-- R15 exposes its proportions as NumberValues under the Humanoid. Narrowing
-- depth and width is what actually matters for squeezing through gaps, and it
-- also lets the navmesh agent radius shrink to match, so pathfinding stops
-- refusing gaps the body would now fit through.
--
-- These are replicated, so a server that validates proportions can snap them
-- back. Nothing here depends on them holding: the agent radius is derived
-- from the values we asked for, and a reset only costs accuracy, not routes.
----------------------------------------------------------------------
local SCALE_KEYS = {
    BodyWidthScale  = "SlimWidth",
    BodyDepthScale  = "SlimDepth",
    BodyHeightScale = "SlimHeight",
    HeadScale       = "SlimHead",
}
local Original = {}

local function applyScale(on)
    local h = humanoid()
    if not h then return false end
    for key, field in pairs(SCALE_KEYS) do
        local o = h:FindFirstChild(key)
        if o and o:IsA("NumberValue") then
            if Original[key] == nil then Original[key] = o.Value end
            pcall(function() o.Value = on and L[field] or Original[key] end)
        end
    end
    return true
end

-- Radius the navmesh should plan for. Half the shoulder width of a default
-- R15 is about 2 studs, so scaling that by the width we asked for keeps the
-- agent honest instead of optimistic.
local function agentRadius()
    local w = L.Slim and L.SlimWidth or 1
    return math.max(0.6, 2.0 * w)
end
local function agentHeight()
    local h = L.Slim and L.SlimHeight or 1
    return math.max(2, 5.0 * h)
end

LP.CharacterAdded:Connect(function()
    task.wait(0.6)
    table.clear(Original)
    if L.Slim then applyScale(true) end
end)

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

-- Why pathing to the delivery hitbox failed.
--
-- DeliveryHitbox is a trigger volume, roughly 47 x 17 x 14, CanCollide false
-- and invisible. Its CENTRE therefore floats around eight studs above the
-- floor, in mid air, nowhere near the navmesh. PathfindingService plans
-- between points on the mesh, so asking it to reach a point hanging inside an
-- empty box returns NoPath every time -- the target was never reachable, the
-- planner was right to refuse.
--
-- The fix is to aim at the floor under the volume instead of at the volume.
local function padPoint(pad)
    if not pad or not pad.part then return nil end
    return groundAt(pad.part.Position)
end

-- Land short of a target rather than on top of it. A single jump that ends
-- exactly inside the delivery volume is the shape a server rejects; finishing
-- a few studs out and closing the gap on foot is not. Pulled back along the
-- approach direction, so the stop is always between you and the pad.
local function pullBack(from, to, studs)
    if studs <= 0 then return to end
    local d = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
    local dist = d.Magnitude
    if dist <= studs + 1 then return to end
    return to - d.Unit * studs
end

local function aimDir()
    local look = Cam.CFrame.LookVector
    local flat = Vector3.new(look.X, 0, look.Z)
    if flat.Magnitude < 0.001 then return Vector3.new(0, 0, -1) end
    return flat.Unit
end

local function pickTarget(origin, dir)
    if not L.AutoAim then return nil end

    -- Hard lock. Your own base is the only thing worth flinging to, so it wins
    -- outright: no cone, no angle scoring, no dependence on where the camera
    -- happens to point. Aim anywhere and the route still goes home.
    if L.LockBase then
        local mine = myPad()
        if mine then return mine end
    end
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

local findDetour   -- forward declaration: navRoute repairs with it

local function segClear(a, b, params)
    local d = b - a
    if d.Magnitude < 0.01 then return true end
    return workspace:Raycast(a, d, params) == nil
end

-- Ground settle. Two things this has to get right: scan from just above the
-- point's OWN height, not the player's, or a roof above the destination is
-- mistaken for its floor; and skip non-collidable hits, since the map is full
-- of decorative parts a raycast reports but you would fall straight through.
function groundAt(pos)
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

-- Engine 1: the navmesh.
--
-- Accuracy comes from four things, in order of how much they matter:
--   * a tight agent. Radius and height follow the slimmed avatar, so the
--     planner stops rejecting gaps the body actually fits through.
--   * dense waypoints. Spacing of 4 instead of 12 means the route hugs the
--     mesh through corners rather than cutting them.
--   * settling. Every waypoint is dropped onto real collidable floor, since
--     mesh points sit on the navmesh surface, not on geometry.
--   * verification. Consecutive waypoints are raycast against the world and
--     any segment the mesh cut through gets a lateral detour spliced in, so
--     a corner clipped by the planner is repaired rather than trusted.
--
-- If the planner refuses outright, the agent is widened step by step and
-- retried; a fat route beats no route.
local function rawNav(from, to, radius)
    local path = safe(function()
        return PathS:CreatePath({
            AgentRadius = radius,
            AgentHeight = agentHeight(),
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
    return wps
end

local function navRoute(from, to)
    local base = agentRadius()
    local wps
    -- Widen the agent, then give ground on the target itself. A destination a
    -- few studs short is still a route; NoPath is not.
    for _, mult in ipairs({1, 1.35, 1.8, 2.4}) do
        wps = rawNav(from, to, base * mult)
        if wps then break end
    end
    if not wps then
        for _, back in ipairs({6, 14, 24}) do
            local relaxed = pullBack(from, to, back)
            wps = rawNav(from, relaxed, base * 1.35)
            if wps then to = relaxed break end
        end
    end
    if not wps then return nil end

    -- settle every waypoint onto real floor
    local stops = {}
    for i = 2, #wps do
        local w = wps[i]
        local p = groundAt(w.Position)
        stops[#stops + 1] = {
            pos  = p,
            kind = (w.Action == Enum.PathWaypointAction.Jump) and "jump" or "nav",
        }
    end
    if #stops == 0 then return nil end

    -- verify and repair: anywhere the planner cut a corner, splice a detour
    local params = rayParams()
    local fixed, cur = {}, from
    for _, s in ipairs(stops) do
        local a = cur + Vector3.new(0, 2, 0)
        local b = s.pos + Vector3.new(0, 2, 0)
        if not segClear(a, b, params) then
            local detour = findDetour(a, b, params)
            if detour then
                fixed[#fixed + 1] = {pos = groundAt(detour), kind = "side"}
            end
        end
        fixed[#fixed + 1] = s
        cur = s.pos
    end

    fixed[#fixed] = {pos = groundAt(to), kind = "land"}
    return fixed
end

-- Engine 2: straight line with lateral escapes. Prefer going around; climb
-- only when every offset is blocked.
function findDetour(cur, nxt, params)
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
-- PRECOMPUTE
--
-- ComputeAsync yields, so paying for it at release would put a stall exactly
-- where it is most felt. Instead a worker plans continuously while you aim
-- and parks the finished route. Release then does nothing but walk the stops.
--
-- The cache is only honoured when it was planned from close to where you now
-- stand and towards close to where you are now pointing; drift past those
-- thresholds and it is discarded rather than followed somewhere stale.
----------------------------------------------------------------------
L.PlanFrom  = Vector3.zero
L.PlanTo    = Vector3.zero
L.Planning  = false
L.PlanTol   = 6

local function cacheUsable(origin, target)
    local r = L.Ready
    if not r or not r.stops or #r.stops == 0 then return false end
    if (r.from - origin).Magnitude > L.PlanTol then return false end
    if (r.to - target).Magnitude > L.PlanTol then return false end
    return true
end

task.spawn(function()
    while true do
        if L.Aiming and L.Pathfind and L.Precompute then
            local root = hrp()
            local target = L.PendingTarget
            if root and target then
                local origin = root.Position
                local moved = (origin - L.PlanFrom).Magnitude > L.PlanTol
                    or (target - L.PlanTo).Magnitude > L.PlanTol
                if moved and not L.Planning then
                    L.Planning = true
                    L.PlanFrom, L.PlanTo = origin, target
                    local stops = navRoute(origin, target)
                    if stops then
                        L.Ready = {stops = stops, from = origin, to = target, engine = "navmesh"}
                    else
                        L.Ready = nil
                    end
                    L.Planning = false
                end
            end
        else
            L.Ready = nil
        end
        task.wait(0.08)
    end
end)

-- The route home, kept permanently warm.
--
-- Auto steal used to call buildRoute inside PromptTriggered, which meant
-- ComputeAsync yielded right at the moment that has to be instant. Planning
-- runs on its own clock instead, so the handler only ever reads a finished
-- answer. Nothing in the steal path is allowed to yield.
L.HomePlanning = false
task.spawn(function()
    while true do
        if L.AutoSteal and L.Pathfind then
            local root, pad = hrp(), myPad()
            if root and pad and not L.HomePlanning then
                local from = root.Position
                local to = pullBack(from, padPoint(pad) or pad.part.Position, L.StealShort)
                local stale = (not L.HomeReady)
                    or (L.HomeReady.from - from).Magnitude > 12
                    or (L.HomeReady.to - to).Magnitude > 12
                if stale then
                    L.HomePlanning = true
                    local stops = navRoute(from, to)
                    L.HomeReady = stops and {stops = stops, from = from, to = to} or nil
                    L.HomePlanning = false
                end
            end
        else
            L.HomeReady = nil
        end
        task.wait(L.HomeHz)
    end
end)

-- Release path. Never yields on planning: a warm cache is walked as-is, and
-- a cold one falls straight through to raycast routing, which is synchronous.
local function instantRoute(origin, target)
    if cacheUsable(origin, target) then
        L.Engine = "navmesh (ready)"
        return L.Ready.stops
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
-- Rubber-band guard.
--
-- The server can reject a jump and snap the character back. Writing the
-- CFrame once and walking away means you silently end up where you started.
-- This re-checks shortly after arrival and, if you have drifted further than
-- the tolerance, writes again -- up to Retries times, spaced by RetryGap.
--
-- Horizontal distance only: settling a few studs vertically onto the floor is
-- normal and is not a snap-back. It gives up as soon as one check passes, so
-- a teleport the server accepted costs a single comparison.
local function enforce(target, dir)
    if L.Retries <= 0 then return end
    task.spawn(function()
        for i = 1, L.Retries do
            task.wait(L.RetryGap)
            local root = hrp()
            if not root then return end
            local d = root.Position - target
            local flat = Vector3.new(d.X, 0, d.Z).Magnitude
            if flat <= L.RetryTol then
                if i > 1 then L.Retried = i - 1 end
                return
            end
            root.CFrame = CFrame.lookAt(target, target + dir)
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
            L.Retried = i
        end
        L.Retried = L.Retries
        if L.Notify then
            L.Notify("Snapped back", T.ORANGE,
                ("held %d/%d · server is rejecting the jump"):format(L.Retries, L.Retries))
        end
    end)
end

local function dashTo(landing, dir, allowNav, prebuilt)
    local root, hum = hrp(), humanoid()
    if not root then return false, 0 end

    -- Route is only used to choose WHERE to land, not how to get there.
    -- Everything below happens inside one frame, and Roblox only replicates
    -- the CFrame a part holds at the end of a frame, so intermediate stops
    -- are invisible to the server no matter how many we write. Writing just
    -- the final one is identical in result and costs nothing.
    local stops = prebuilt
    if not stops or #stops == 0 then
        stops = {{pos = groundAt(landing), kind = "land"}}
        L.Engine = "direct"
    end
    L.LastRoute = stops

    local final = stops[#stops].pos

    if hum then
        hum:ChangeState(Enum.HumanoidStateType.Freefall)
        hum.PlatformStand = false
    end

    if L.Stepped and L.HopDelay > 0 then
        -- Opt-in only. Real frames between stops, which the server does see,
        -- at the cost of it reading as movement instead of a teleport.
        for i, st in ipairs(stops) do
            local face = dir
            if i < #stops then
                local d = stops[i + 1].pos - st.pos
                local f = Vector3.new(d.X, 0, d.Z)
                if f.Magnitude > 0.01 then face = f.Unit end
            end
            root.CFrame = CFrame.lookAt(st.pos, st.pos + face)
            root.AssemblyLinearVelocity = Vector3.zero
            if i < #stops then task.wait(L.HopDelay) end
        end
    else
        root.CFrame = CFrame.lookAt(final, final + dir)
    end

    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
    L.Retried = 0
    enforce(final, dir)
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

local function ValueRow(label, order, initial, onClick)
    local Box = New("Frame", {Size = UDim2.new(1, 0, 0, 38), BackgroundColor3 = T.RAISED,
        BackgroundTransparency = 1, LayoutOrder = order, Parent = Content})
    Corner(Box, 10); Pad(Box, 0, 0, 12, 12)
    local BoxStroke = Stroke(Box, T.LINE, 1, 1)
    flow(BoxStroke, {speed = 0.3, phase = order * 0.13})
    local Tag = New("TextLabel", {Size = UDim2.new(1, -70, 1, 0), BackgroundTransparency = 1,
        Text = label, TextColor3 = T.TEXT, Font = Enum.Font.GothamSemibold, TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left, TextTransparency = 1, Parent = Box})
    local Val = New("TextButton", {Size = UDim2.new(0, 64, 0, 24), Position = UDim2.new(1, 0, 0.5, 0),
        AnchorPoint = Vector2.new(1, 0.5), BackgroundColor3 = T.SURFACE, AutoButtonColor = false,
        Text = initial, TextColor3 = T.HIGH, Font = Enum.Font.GothamBold, TextSize = 12,
        BackgroundTransparency = 1, TextTransparency = 1, Parent = Box})
    Corner(Val, 7)
    Val.MouseButton1Click:Connect(function() Val.Text = onClick() end)
    local entry = {Box = Box, BoxStroke = BoxStroke, Tag = Tag, Sw = Val, SwStroke = BoxStroke,
                   Kn = Val, Set = function() end}
    Rows[#Rows + 1] = entry
    return entry, Val
end

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

local LockRow  = ToggleRow("lock to base", 2, L.LockBase, function(on)
    L.LockBase = on
    L.Notify(on and "Base lock on" or "Base lock off", on and T.GREEN or T.MUTED,
        on and "aims home from any direction" or "uses camera aim cone")
end)
local AimRow   = ToggleRow("auto-aim",     3, L.AutoAim,   function(on) L.AutoAim = on end)
local MineRow  = ToggleRow("my base only", 4, L.MineOnly,  function(on) L.MineOnly = on end)
local PathRow  = ToggleRow("pathfinding",  5, L.Pathfind,  function(on)
    L.Pathfind = on
    L.Notify(on and "Pathfinding on" or "Pathfinding off", on and T.GREEN or T.MUTED,
        on and "navmesh route, falls back to raycast" or "raycast routing only")
end)
local StealRow = ToggleRow("auto steal",   6, L.AutoSteal, function(on) L.AutoSteal = on end)
local NodeRow  = ToggleRow("path nodes",   7, L.ShowPath,  function(on) L.ShowPath = on end)
local ShortRow, ShortVal = ValueRow("stop short", 8, L.StopShort .. "st", function()
    local steps = {0, 5, 10, 15, 20, 30}
    local i = 1
    for k, v in ipairs(steps) do if v == L.StopShort then i = k break end end
    L.StopShort = steps[(i % #steps) + 1]
    return L.StopShort .. "st"
end)

local StealShortRow, StealShortVal = ValueRow("steal stop", 9, L.StealShort .. "st", function()
    local steps = {10, 20, 30, 40, 60, 80}
    local i = 1
    for k, v in ipairs(steps) do if v == L.StealShort then i = k break end end
    L.StealShort = steps[(i % #steps) + 1]
    L.HomeReady = nil
    return L.StealShort .. "st"
end)

local StepRow, StepVal = ValueRow("hop mode", 10, "instant", function()
    if not L.Stepped then
        L.Stepped, L.HopDelay = true, L.StepDelay
        L.Notify("Stepped hops", T.ORANGE, ("real frames, %.2fs apart"):format(L.StepDelay))
        return ("%.0fms"):format(L.StepDelay * 1000)
    end
    L.Stepped, L.HopDelay = false, 0
    L.Notify("Instant hops", T.GREEN, "single frame, one write")
    return "instant"
end)

local HoldRow, HoldVal = ValueRow("hold position", 11, L.Retries .. "x", function()
    local steps = {0, 3, 5, 7, 10, 15}
    local i = 1
    for k, v in ipairs(steps) do if v == L.Retries then i = k break end end
    L.Retries = steps[(i % #steps) + 1]
    return L.Retries .. "x"
end)

local SlimRow  = ToggleRow("slim avatar", 12, L.Slim,      function(on)
    L.Slim = on
    local applied = applyScale(on)
    L.Notify(on and "Slim avatar on" or "Slim avatar off",
        on and T.GREEN or T.MUTED,
        applied and ("agent radius " .. string.format("%.1f", agentRadius())) or "no R15 humanoid")
end)

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
        local p = padPoint(pad) or pad.part.Position
        point = p
        local to = Vector3.new(p.X - origin.X, 0, p.Z - origin.Z)
        if to.Magnitude > 0.01 then dir = to.Unit end
        point = pullBack(origin, point, L.StopShort)
        Glow.Adornee = pad.part
        Glow.Enabled = true
        StatusSub.Text = ("%s base%s · %dst%s"):format(pad.mine and "your" or pad.plot.Name:sub(1, 6),
            (L.LockBase and pad.mine) and " [LOCK]" or "",
            math.floor((p - origin).Magnitude),
            L.StopShort > 0 and (" · stop " .. L.StopShort .. "st short") or "")
        StatusSub.TextColor3 = pad.mine and T.GREEN or T.HIGH
    else
        point = origin + dir * L.Range
        Glow.Enabled = false
        Glow.Adornee = nil
        StatusSub.Text = ("free aim · %dst"):format(L.Range)
        StatusSub.TextColor3 = T.MUTED
    end

    landing, lockedDir = groundAt(point), dir
    L.PendingTarget = landing
    drawArrow(origin, landing, pad ~= nil)

    -- rayRoute is hundreds of raycasts; running it per frame while aiming
    -- was costing more than the dash itself. Refresh on a timer instead, and
    -- reuse the parked navmesh route for free whenever it is warm.
    local ready = cacheUsable(origin, landing)
    local now = os.clock()
    if ready then
        L.Preview = L.Ready.stops
    elseif now - (L.PreviewAt or 0) >= L.PreviewHz then
        L.PreviewAt = now
        L.Preview = rayRoute(origin, landing)
    end
    local preview = L.Preview or {}
    showNodes(preview)
    StatusHops.Text = ("%s · %d hop%s%s"):format(
        ready and "navmesh READY" or (L.Planning and "planning…" or "raycast"),
        #preview, #preview == 1 and "" or "s",
        ready and " · instant" or "")
    StatusHops.TextColor3 = ready and T.GREEN or T.PURPLE
end)

----------------------------------------------------------------------
-- AUTO STEAL
----------------------------------------------------------------------
PPS.PromptTriggered:Connect(function(prompt, player)
    if not L.AutoSteal then return end
    if player ~= LP then return end
    local txt = ((prompt.ObjectText or "") .. " " .. (prompt.ActionText or "")):lower()
    if not txt:find("steal", 1, true) then return end

    local root = hrp()
    local pad = myPad()
    if not root then return end

    -- Phase 1, on this very frame: straight up.
    --
    -- Nothing above this line yields, so the lift lands on the same frame the
    -- prompt completed. The route home was planned in advance precisely so
    -- this handler never has to wait on a planner.
    local origin = root.Position
    local rot = root.CFrame - root.CFrame.Position
    local up = origin + Vector3.new(0, L.StealHop, 0)
    root.CFrame = rot + up
    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero

    local hum = humanoid()
    if hum then
        hum:ChangeState(Enum.HumanoidStateType.Freefall)
        hum.PlatformStand = false
    end

    if not pad then
        L.Notify("Auto steal", T.RED, "lifted, but no owned base found")
        return
    end

    -- Phases 2 and 3 need the hang time, so they leave the handler.
    task.spawn(function()
        -- Hold the lift. Velocity is pinned every frame or gravity eats the
        -- height before the drop is due.
        local hangUntil = os.clock() + L.StealHang
        while os.clock() < hangUntil do
            local r = hrp()
            if not r then return end
            r.CFrame = rot + up
            r.AssemblyLinearVelocity = Vector3.zero
            RunS.RenderStepped:Wait()
        end

        -- Phase 2: back down to the floor beneath us.
        local r = hrp()
        if not r then return end
        local down = groundAt(Vector3.new(up.X, origin.Y, up.Z))
        r.CFrame = rot + down
        r.AssemblyLinearVelocity = Vector3.zero

        -- Phase 3: home. Warm route when it still describes where we are,
        -- otherwise a direct drop short of the pad, which needs no planner.
        local from = r.Position
        local target = pullBack(from, padPoint(pad) or pad.part.Position, L.StealShort)
        local route, warm = nil, L.HomeReady
        if warm and (warm.from - origin).Magnitude <= 12 and (warm.to - target).Magnitude <= 12 then
            route, L.Engine = warm.stops, "navmesh (warm)"
        else
            route, L.Engine = {{pos = target, kind = "land"}}, "direct"
        end

        local to = Vector3.new(target.X - from.X, 0, target.Z - from.Z)
        local dir = (to.Magnitude > 0.01) and to.Unit or aimDir()
        local ok, hops = dashTo(target, dir, false, route)
        if ok then
            L.Notify("Stole to home", T.GREEN,
                ("up %d · hang %.2fs · %s · %d hop%s"):format(L.StealHop, L.StealHang,
                    L.Engine, hops, hops == 1 and "" or "s"))
            StatusHops.Text = ("route: %s · %d hop%s"):format(L.Engine, hops, hops == 1 and "" or "s")
        end
    end)
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
        local root = hrp()
        local route = root and instantRoute(root.Position, target) or nil
        do
            local ok, hops = dashTo(target, face, true, route)
            if ok then
                StatusHops.Text = ("route: %s · %d hop%s"):format(L.Engine, hops, hops == 1 and "" or "s")
                RingStroke.Transparency = 0.3
                Ring2.Size = UDim2.fromOffset(8, 8)
                tw(Ring2, 0.8, Enum.EasingStyle.Quad, nil, {Size = UDim2.fromOffset(26, 26),
                    Position = UDim2.new(0, -9, 0.5, -13)}):Play()
                tw(RingStroke, 0.8, Enum.EasingStyle.Quad, nil, {Transparency = 1}):Play()
            end
        end
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
        LockRow.Set(L.LockBase)
        AimRow.Set(L.AutoAim)
        MineRow.Set(L.MineOnly)
        PathRow.Set(L.Pathfind)
        StealRow.Set(L.AutoSteal)
        NodeRow.Set(L.ShowPath)
        SlimRow.Set(L.Slim)
        if L.Slim then applyScale(true) end
        L.Notify("Dash online", T.HIGH, "hold " .. L.Key.Name .. " to aim")
    end)
end)

getgenv().LUMIDASH = L
return L
