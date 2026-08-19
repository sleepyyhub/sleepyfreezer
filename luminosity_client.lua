--[[  LUMINOSITY — CLIENT  ]]--
-- Steal A Summertino (place 109001683984840)
-- Executor: any (Volt, Wave, Solara...). No dependencies. Paste and execute.
--
-- F opens the tab menu. LeftShift is not used — Roblox binds it to
-- shiftlock and the game reads it for movement.
--
-- UI is Luminosity's, component for component: the same theme table, the
-- same New/Corner/Pad/Stroke/tw primitives, the same moon-rain loader and
-- letter assembly, the same notification cards with x N dedupe, the same
-- ripple/press/hoverFill interaction helpers. Only the layout above them is
-- new — tabs across the top with dropdown panels.
--
-- Everything that talks to the game was read off the live client:
--   * steal wire format from ReplicatedStorage.Classes.PlotClient, including
--     the double-send (raw cached FireServer + method call, different tokens)
--   * DeliveryHitbox is a direct child of each plot model
--   * slot data: player channel "AnimalPodiums" (keyed by the Player
--     INSTANCE) mirrored by plot channel "AnimalList"
--   * notifications are Template clones parented into PlayerGui.Notification
--
-- MOVEMENT: this game rubber bands teleports. Nothing on the client checks
-- movement, so the rejection is server-side and the only fix is to stop
-- handing it deltas it will reject. Default mode is GLIDE (continuous
-- travel at a fixed studs/sec, reads as fast running). HOP chunks the
-- teleport. FLING is not a teleport at all -- it is real physics: the
-- character is spun with AssemblyAngularVelocity and driven along ONE
-- locked direction, one leg per pathfinding waypoint with a short settle
-- between legs. The server sees ordinary physics motion rather than a
-- position delta, which is not the thing rubber banding rejects.
-- "calibrate threshold" measures which hop size your server actually
-- tolerates instead of guessing.
--
-- POTATO honesty: Camera.ViewportSize is read-only in Roblox, so a real
-- stretched resolution cannot be done from Lua. "STRETCH" cycles
-- FieldOfViewMode, which changes how the FOV maps across the aspect and is
-- the closest thing that actually exists. "STRIP" is a real performance cut
-- and is one-way until you rejoin.

local Players    = game:GetService("Players")
local RepS       = game:GetService("ReplicatedStorage")
local RunS       = game:GetService("RunService")
local TS         = game:GetService("TweenService")
local UIS        = game:GetService("UserInputService")
local PFS        = game:GetService("PathfindingService")
local Lighting   = game:GetService("Lighting")
local LP         = Players.LocalPlayer
local PG         = LP:WaitForChild("PlayerGui")
local Cam        = workspace.CurrentCamera
local IS_MOBILE  = UIS.TouchEnabled and not UIS.KeyboardEnabled and not UIS.MouseEnabled

local Net         = require(RepS:WaitForChild("Packages"):WaitForChild("Net"))
local Sync        = require(RepS.Packages:WaitForChild("Synchronizer"))
local SharedAnim  = require(RepS:WaitForChild("Shared"):WaitForChild("Animals"))
local AnimalData  = require(RepS:WaitForChild("Datas"):WaitForChild("Animals"))
local Rarities    = require(RepS.Datas:WaitForChild("Rarities"))

local L = {}
L.MenuKey     = Enum.KeyCode.F
L.DashKey     = Enum.KeyCode.E
L.ESP         = false
L.AutoAim     = true
L.Mode        = "GLIDE"   -- GLIDE | HOP | FLING
L.Speed       = 90        -- studs/sec in GLIDE
L.HopSize     = 18        -- studs per teleport in HOP
L.HopDelay    = 0.07      -- seconds between hops
-- FLING. Real physics, not a teleport: the character is handed to the
-- solver, spun, and driven along one locked direction.
L.FlingPower  = 190       -- studs/sec along the aim
L.FlingLift   = 0         -- constant Y velocity; 0 = dead level flight
L.FlingSpin   = 9000      -- angular velocity magnitude (the visible tumble)
L.FlingArrive = 10        -- studs from a waypoint before the leg ends
L.FlingLegMax = 2.5       -- seconds before a leg gives up
L.FlingSettle = 0.1       -- pause between legs, so the next one re-aims clean
L.FlingClimb  = true      -- follow each waypoint's height instead of flying level
L.Climb       = 40
L.Range       = 260
L.Pathfind    = true
L.KickAfter   = false
L.RewriteNotif= true
L.NotifText   = "Luminosity tax ez son get fucked"
L.Target      = nil       -- selected brainrot model
L.Aiming      = false
L.ArrayList   = true      -- on-screen target ArrayList
L.ArrayMax    = 12        -- entries shown before it stops drawing
L.ArrayHue    = true      -- animated gradient down the stack
L.ArrayHz     = 1.0       -- seconds between automatic list refreshes

local T = {
    VOID = Color3.fromRGB(6,9,18),        BG      = Color3.fromRGB(10,15,28),
    SURFACE = Color3.fromRGB(16,24,44),   RAISED  = Color3.fromRGB(24,34,58),
    LINE = Color3.fromRGB(38,54,88),      ACCENT  = Color3.fromRGB(120,180,255),
    HIGH = Color3.fromRGB(180,220,255),   DEEP    = Color3.fromRGB(72,130,210),
    TEXT = Color3.fromRGB(230,240,255),   MUTED   = Color3.fromRGB(120,145,185),
    RED  = Color3.fromRGB(255,130,155),   GREEN   = Color3.fromRGB(146,255,103),
    ORANGE = Color3.fromRGB(255,190,120), WHITE   = Color3.fromRGB(255,255,255),
}

local function safe(fn) local ok, r = pcall(fn); return ok and r or nil end
local function alive(i) return i and typeof(i) == "Instance" and i.Parent ~= nil end
local function char() return LP.Character end
local function hrp() local c = char(); return c and c:FindFirstChild("HumanoidRootPart") end
local function humanoid() local c = char(); return c and c:FindFirstChildOfClass("Humanoid") end

local function short(n)
    n = tonumber(n) or 0
    for _, u in ipairs({{1e12,"T"},{1e9,"B"},{1e6,"M"},{1e3,"K"}}) do
        if n >= u[1] then return ("%.2f%s"):format(n / u[1], u[2]) end
    end
    return ("%d"):format(n)
end

----------------------------------------------------------------------
-- GAME LAYER
----------------------------------------------------------------------
local R_GRAB    = Net:RemoteEvent("StealService/Grab")
local R_STEAL   = Net:RemoteEvent("5aa39ea1-0c65-4fcf-aff9-b18a7ef277c3")
local R_DELIVER = Net:RemoteEvent("5c8f0dd0-0f9e-44ba-8f9b-197958b661ab")
local rawFire   = Net:RemoteEvent("PlotService/ToggleFriends").FireServer

local TOK_STEAL_RAW = "c262398d-68e3-4499-8bea-99766bf11686"
local TOK_STEAL_MTD = "579e6c26-5a80-407d-9488-0f84752e8f1f"
local TOK_DELIVER   = "7799aa8a-03f9-4df1-ab0f-b6df84f6b36c"

local notify      -- forward declared, UI block defines it
local buildArray  -- forward declared: the ESP refresh loop calls it long
                  -- before the ArrayList block below defines it, and a
                  -- `local function` there would leave this call site
                  -- resolving to a nil global instead

local function myPlot()
    local folder = workspace:FindFirstChild("Plots")
    if not folder then return nil end
    for _, plot in ipairs(folder:GetChildren()) do
        local ch = safe(function() return Sync:Get(plot.Name) end)
        if ch and safe(function() return ch:Get("Owner") end) == LP then return plot end
    end
    return nil
end

local function myPad()
    local plot = myPlot()
    local pad = plot and plot:FindFirstChild("DeliveryHitbox")
    if pad and pad:IsA("BasePart") then return pad end
    return nil
end

local function myPods()
    for key in pairs(Sync:GetAllChannels()) do
        if key == LP then
            local t = safe(function() return Sync:GetTableFromChannel(key) end)
            if t then return t.AnimalPodiums end
        end
    end
end

local function firstFreeSlot()
    local pods = myPods()
    if not pods then return nil end
    local n = 0
    for _ in pairs(pods) do n = n + 1 end
    for i = 1, n do
        if type(pods[i]) ~= "table" then return i end
    end
    return nil
end

-- Podium index for a rendered brainrot: the models are plot children, so
-- the slot lives nowhere in the name. Nearest podium base wins.
local function podiumIndexFor(plot, model)
    local pods = plot:FindFirstChild("AnimalPodiums")
    if not pods or not model.PrimaryPart then return nil end
    local origin = model:GetPivot().Position
    local best, bestDist = nil, math.huge
    for _, pod in ipairs(pods:GetChildren()) do
        local base = pod:FindFirstChild("Base")
        local part = base and base:FindFirstChildWhichIsA("BasePart", true)
        if part then
            local d = (part.Position - origin).Magnitude
            if d < bestDist then bestDist, best = d, tonumber(pod.Name) end
        end
    end
    if bestDist > 25 then return nil end
    return best
end

-- Every brainrot on someone else's plot, richest first.
local function targets()
    local out, mine = {}, myPlot()
    local folder = workspace:FindFirstChild("Plots")
    if not folder then return out end
    local origin = hrp() and hrp().Position
    for _, plot in ipairs(folder:GetChildren()) do
        if plot ~= mine then
            for _, model in ipairs(plot:GetChildren()) do
                if model:IsA("Model") and AnimalData[model.Name] and model.PrimaryPart then
                    local slot = podiumIndexFor(plot, model)
                    if slot then
                        table.insert(out, {
                            model = model, plot = plot, slot = slot, name = model.Name,
                            price = safe(function() return SharedAnim:GetPrice(model.Name) end) or 0,
                            dist = origin and (model:GetPivot().Position - origin).Magnitude or 0,
                        })
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.price > b.price end)
    return out
end

function L.Steal(plotName, slot)
    local t = workspace:GetServerTimeNow() + 67
    rawFire(R_STEAL, t, TOK_STEAL_RAW, plotName, slot)
    R_STEAL:FireServer(t, TOK_STEAL_MTD, plotName, slot)
end

function L.Deliver()
    rawFire(R_DELIVER, TOK_DELIVER)
    R_DELIVER:FireServer(TOK_DELIVER)
end

function L.Place(slot) R_GRAB:FireServer("Place", slot) end
function L.Grab(slot)  R_GRAB:FireServer("Grab", slot) end

----------------------------------------------------------------------
-- MOVEMENT
--
-- Two modes. Pathfind builds a navmesh route that walks around solid
-- geometry, then hops the character waypoint to waypoint. Direct is the
-- straight line with obstacle lifting for when the navmesh has no route
-- (podiums on raised bases usually don't).
----------------------------------------------------------------------
local function rayParams()
    local p = RaycastParams.new()
    p.FilterType = Enum.RaycastFilterType.Exclude
    p.FilterDescendantsInstances = {char()}
    p.IgnoreWater = true
    return p
end

-- Skip non-collidable hits: the map is full of decor and trigger volumes a
-- raycast reports but you fall straight through.
local function groundAt(pos)
    local params = rayParams()
    local ignore = {char()}
    params.FilterDescendantsInstances = ignore
    for _ = 1, 8 do
        local hit = workspace:Raycast(pos + Vector3.new(0, 6, 0), Vector3.new(0, -400, 0), params)
        if not hit then break end
        if hit.Instance.CanCollide then
            return Vector3.new(pos.X, hit.Position.Y + 3.5, pos.Z)
        end
        table.insert(ignore, hit.Instance)
        params.FilterDescendantsInstances = ignore
    end
    return pos
end

local function directPath(origin, target)
    local delta = target - origin
    local flat = Vector3.new(delta.X, 0, delta.Z)
    local dist = flat.Magnitude
    if dist < 1 then return {target} end
    local unit = flat.Unit
    local step, travelled, cur, pts = 8, 0, origin, {}
    local params = rayParams()
    while travelled < dist do
        local len = math.min(step, dist - travelled)
        local nxt = cur + unit * len
        if workspace:Raycast(cur, unit * len, params) then
            local lifted = false
            for h = 5, L.Climb, 5 do
                local from = Vector3.new(cur.X, origin.Y + h, cur.Z)
                if not workspace:Raycast(from, unit * len, params) then
                    table.insert(pts, from)
                    nxt = from + unit * len
                    cur = Vector3.new(nxt.X, from.Y, nxt.Z)
                    lifted = true
                    break
                end
            end
            if not lifted then
                cur = Vector3.new(cur.X, origin.Y + L.Climb, cur.Z)
                nxt = cur + unit * len
            end
        end
        table.insert(pts, nxt)
        cur = nxt
        travelled = travelled + len
    end
    pts[#pts] = groundAt(pts[#pts])
    return pts
end

local function navPath(origin, target)
    local path = PFS:CreatePath({
        AgentRadius = 2.5, AgentHeight = 5, AgentCanJump = true,
        AgentMaxSlope = 60, WaypointSpacing = 6,
    })
    local ok = pcall(function() path:ComputeAsync(origin, target) end)
    if not ok or path.Status ~= Enum.PathStatus.Success then return nil end
    local pts = {}
    for _, wp in ipairs(path:GetWaypoints()) do
        table.insert(pts, wp.Position + Vector3.new(0, 2.5, 0))
    end
    if #pts < 2 then return nil end
    return pts
end

-- Rubber banding is the server rejecting a position delta it considers
-- impossible and pulling you back. Nothing validates movement on the client
-- (checked: no client anticheat references movement at all), so the only
-- lever is to never hand the server a delta worth rejecting.
--
--   GLIDE   travels the path continuously at a fixed studs/sec. The server
--           sees fast running, not a jump. Slowest, and the one that
--           survives. Default.
--   HOP     teleports in small chunks with a pause between, so each single
--           delta stays under the threshold. Fast, usually fine.
--   FLING   real physics. PlatformStand hands you to the solver, a large
--           AssemblyAngularVelocity spins you, and the linear velocity is
--           rewritten every step so you travel ONE locked direction and
--           nothing drifts. One leg per waypoint, settling between legs.
--
-- Movement is applied to the whole assembly and velocity is re-zeroed each
-- step, otherwise the physics solver keeps carrying you and overshoots.
local snapWatch = 0

----------------------------------------------------------------------
-- FLING
--
-- A real fling, not a teleport. PlatformStand hands the character to the
-- physics solver and stops the Humanoid standing itself back up and
-- damping the rotation; a large AssemblyAngularVelocity makes it tumble.
--
-- "Only in that direction" is the whole trick. The aim is captured ONCE
-- when the leg starts, then the linear velocity is overwritten every
-- physics step. Gravity, collisions and the solver all try to add
-- sideways drift and vertical fall; rewriting the vector each step means
-- none of it accumulates. You travel the line you aimed and nothing else,
-- while still genuinely spinning.
--
-- Applied on Stepped (before the physics step) rather than Heartbeat
-- (after), so the solver integrates the velocity we just set instead of
-- one that is already a frame stale.
local function flingLeg(root, hum, targetPos)
    local from = root.Position
    local delta = targetPos - from
    local flat = Vector3.new(delta.X, 0, delta.Z)
    if flat.Magnitude < 0.5 then return true end
    local aim = flat.Unit

    -- Cartwheel forward with a bit of yaw: spin about the axis
    -- perpendicular to travel, tilted. Reads as a fling rather than a
    -- beyblade.
    local side = Vector3.new(-aim.Z, 0, aim.X)
    local spin = (side + Vector3.new(0, 0.45, 0)).Unit * L.FlingSpin

    if hum then
        hum.PlatformStand = true
        hum:ChangeState(Enum.HumanoidStateType.Physics)
    end

    local t0 = os.clock()
    local reached = false
    while true do
        RunS.Stepped:Wait()
        if not (root and root.Parent) then break end
        local cur = root.Position
        local rem = Vector3.new(targetPos.X - cur.X, 0, targetPos.Z - cur.Z)
        if rem.Magnitude <= L.FlingArrive then reached = true break end
        if os.clock() - t0 > L.FlingLegMax then break end
        -- Vertical is handled apart from the locked horizontal aim. Pinning
        -- Y to a constant flies you dead level out of your launch height,
        -- which walks straight into anything the route climbs over, so by
        -- default the Y velocity seeks the waypoint's own altitude. The
        -- horizontal direction is still untouched -- this only ever changes
        -- height, never course.
        local vy = L.FlingLift
        if L.FlingClimb then
            vy = math.clamp((targetPos.Y - cur.Y) * 3, -60, 60) + L.FlingLift
        end
        -- the lock: direction never re-derived from current motion
        root.AssemblyLinearVelocity  = aim * L.FlingPower + Vector3.new(0, vy, 0)
        root.AssemblyAngularVelocity = spin
    end
    return reached
end

-- Cut the spin and hand the character back to the Humanoid. Without this
-- you keep tumbling after arrival and the Humanoid never recovers.
local function flingStop(root, hum, faceDir)
    if root and root.Parent then  -- nil after a respawn; skip, do not error
        root.AssemblyAngularVelocity = Vector3.zero
        root.AssemblyLinearVelocity  = Vector3.zero
        if faceDir then
            local p = root.Position
            root.CFrame = CFrame.lookAt(p, p + faceDir)
        end
    end
    if hum then
        hum.PlatformStand = false
        hum:ChangeState(Enum.HumanoidStateType.GettingUp)
    end
end

local function stepTo(root, pt, dir)
    root.CFrame = CFrame.lookAt(pt, pt + dir)
    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
end

local function travel(landing)
    local root, hum = hrp(), humanoid()
    if not root then return false, "no character" end

    local pts, how
    if L.Pathfind then
        pts = navPath(root.Position, landing)
        how = pts and "navmesh" or nil
    end
    if not pts then
        pts = directPath(root.Position, landing)
        how = L.Pathfind and "direct (no nav route)" or "direct"
    end

    if hum then hum.PlatformStand = false end

    local startPos = root.Position
    local dir = landing - startPos
    dir = Vector3.new(dir.X, 0, dir.Z)
    dir = dir.Magnitude > 0.01 and dir.Unit or root.CFrame.LookVector

    if L.Mode == "FLING" then
        -- One leg per waypoint. Each leg locks its own direction, so the
        -- route is flown as a series of straight flings that bend at the
        -- waypoints instead of one curve through them.
        for i, pt in ipairs(pts) do
            -- Re-fetch every leg: a respawn mid-route destroys the old
            -- HumanoidRootPart and every write to the stale one silently
            -- does nothing, which looks exactly like the fling "not working".
            root = hrp()
            hum = humanoid()
            if not (root and root.Parent) then break end
            flingLeg(root, hum, pt)
            root = hrp()
            if not (root and root.Parent) then break end
            -- Stop dead between legs. The pause is what lets the next leg
            -- re-aim from a settled position rather than inheriting the
            -- last one's momentum and drifting wide of the waypoint.
            root.AssemblyAngularVelocity = Vector3.zero
            root.AssemblyLinearVelocity  = Vector3.zero
            if i < #pts then task.wait(L.FlingSettle) end
        end
        flingStop(hrp(), humanoid(), dir)

    elseif L.Mode == "HOP" then
        for _, pt in ipairs(pts) do
            local from = root.Position
            local seg = pt - from
            local len = seg.Magnitude
            if len > L.HopSize then
                local steps = math.ceil(len / L.HopSize)
                for s = 1, steps do
                    stepTo(root, from:Lerp(pt, s / steps), dir)
                    task.wait(L.HopDelay)
                end
            else
                stepTo(root, pt, dir)
                task.wait(L.HopDelay)
            end
        end

    else -- GLIDE
        for _, pt in ipairs(pts) do
            while true do
                local cur = root.Position
                local seg = pt - cur
                local len = seg.Magnitude
                if len < 1.5 then break end
                local dt = RunS.RenderStepped:Wait()
                local move = math.min(len, L.Speed * dt)
                local face = Vector3.new(seg.X, 0, seg.Z)
                face = face.Magnitude > 0.01 and face.Unit or dir
                stepTo(root, cur + seg.Unit * move, face)
            end
        end
    end

    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero

    -- Watch for a snap-back: if the server yanks you, you end up far from
    -- where you stopped, back toward where you started.
    snapWatch = snapWatch + 1
    local id = snapWatch
    local settled = root.Position
    task.spawn(function()
        for _ = 1, 30 do
            task.wait(0.05)
            if id ~= snapWatch then return end
            local now = hrp() and hrp().Position
            if not now then return end
            if (now - settled).Magnitude > 25 and (now - startPos).Magnitude < (settled - startPos).Magnitude then
                notify("Rubber band", "server pulled you back", T.RED,
                    L.Mode == "GLIDE" and "lower speed" or "switch to GLIDE")
                return
            end
        end
    end)

    return true, ("%s - %s"):format(how, L.Mode:lower())
end

-- Empirical threshold finder: teleport increasing distances straight up the
-- path and see which size survives. Reports the largest hop that stuck.
function L.Calibrate()
    local root = hrp()
    if not root then return notify("Calibrate", "no character", T.RED) end
    local dir = root.CFrame.LookVector
    dir = Vector3.new(dir.X, 0, dir.Z).Unit
    local best = 0
    for _, size in ipairs({8, 14, 20, 28, 40, 60, 90}) do
        local from = root.Position
        local to = groundAt(from + dir * size)
        stepTo(root, to, dir)
        task.wait(0.45)
        local now = hrp() and hrp().Position
        if not now then return end
        local kept = (now - to).Magnitude < 12
        notify("Calibrate", ("%d studs: %s"):format(size, kept and "held" or "SNAPPED"),
            kept and T.GREEN or T.RED)
        if not kept then break end
        best = size
        stepTo(root, from, dir)   -- walk it back for the next sample
        task.wait(0.35)
    end
    if best > 0 then
        L.HopSize = math.max(6, math.floor(best * 0.6))
        notify("Calibrate", ("largest safe hop %d"):format(best), T.ACCENT,
            ("hop size set to %d"):format(L.HopSize))
    else
        L.Mode = "GLIDE"
        notify("Calibrate", "even 8 studs snapped", T.ORANGE, "forced GLIDE mode")
    end
end

function L.GoHome()
    local pad = myPad()
    if not pad then return notify("Dash", "your base not found", T.RED) end
    local ok, how = travel(groundAt(pad.Position))
    if ok then notify("Dash", "home", T.GREEN, how) end
end

function L.GoTo(model)
    if not alive(model) then return notify("Dash", "target gone", T.RED) end
    local ok, how = travel(groundAt(model:GetPivot().Position))
    if ok then notify("Dash", model.Name, T.GREEN, how) end
end

----------------------------------------------------------------------
-- NOTIFICATION REWRITE
--
-- The game clones PlayerGui.Notification.Notification.Template and parents
-- it in with the text already applied, so read it on ChildAdded. Nothing is
-- hooked or disabled — this is a second listener on an existing container,
-- the same approach Luminosity uses for its own scanner.
----------------------------------------------------------------------
local function stripRich(s)
    return (tostring(s):gsub("<br%s*/>", " "):gsub("<[^>]->", ""))
end

local NotifRootGame = safe(function()
    return PG:WaitForChild("Notification", 10):WaitForChild("Notification", 10)
end)

local lastSteal = 0

if NotifRootGame then
    NotifRootGame.ChildAdded:Connect(function(child)
        if not L.RewriteNotif then return end
        if not child:IsA("TextLabel") or child.Name == "Template" then return end
        task.defer(function()
            local plain = stripRich(child.Text):lower()
            if plain:find("stole") or plain:find("stolen") or (os.clock() - lastSteal) < 4 then
                child.Text = L.NotifText
                child.TextColor3 = T.HIGH
                if L.KickAfter then
                    task.defer(function() LP:Kick(L.NotifText) end)
                end
            end
        end)
    end)
end

----------------------------------------------------------------------
-- ESP + TARGET HIGHLIGHT
----------------------------------------------------------------------
local EspFolder = Instance.new("Folder")
EspFolder.Name = "LUMI_ESP"
EspFolder.Parent = PG

local espTags = {}

local function clearESP()
    for _, g in ipairs(espTags) do if alive(g) then g:Destroy() end end
    espTags = {}
end

local function buildESP()
    clearESP()
    if not L.ESP then return 0 end
    local n = 0
    for _, t in ipairs(targets()) do
        local rar = AnimalData[t.name] and AnimalData[t.name].Rarity
        local col = (rar and Rarities[rar] and Rarities[rar].Color) or T.HIGH
        local bb = Instance.new("BillboardGui")
        bb.Adornee = t.model.PrimaryPart
        bb.Size = UDim2.fromOffset(200, 34)
        bb.StudsOffset = Vector3.new(0, 4.5, 0)
        bb.AlwaysOnTop = true
        bb.MaxDistance = 900
        bb.Parent = EspFolder
        local name = Instance.new("TextLabel")
        name.Size = UDim2.new(1, 0, 0, 17)
        name.BackgroundTransparency = 1
        name.Text = t.name
        name.TextColor3 = col
        name.Font = Enum.Font.GothamBold
        name.TextSize = 13
        name.TextStrokeTransparency = 0.4
        name.Parent = bb
        local price = Instance.new("TextLabel")
        price.Size = UDim2.new(1, 0, 0, 14)
        price.Position = UDim2.fromOffset(0, 17)
        price.BackgroundTransparency = 1
        price.Text = ("$%s  -  slot %d"):format(short(t.price), t.slot)
        price.TextColor3 = T.GREEN
        price.Font = Enum.Font.Gotham
        price.TextSize = 11
        price.TextStrokeTransparency = 0.5
        price.Parent = bb
        table.insert(espTags, bb)
        n = n + 1
    end
    return n
end

-- The selected steal target gets a breathing blue highlight. Highlight has
-- no gradient support, so the gradient is done in time: FillColor is driven
-- between deep blue and light blue on a sine, which reads as a slow pulse.
local TargetGlow = Instance.new("Highlight")
TargetGlow.Name = "LUMI_TARGET"
TargetGlow.FillTransparency = 0.6
TargetGlow.OutlineTransparency = 0
TargetGlow.Enabled = false
TargetGlow.Parent = EspFolder

local BLUE_DEEP  = Color3.fromRGB(20, 90, 255)
local BLUE_LIGHT = Color3.fromRGB(150, 215, 255)

task.spawn(function()
    while true do
        if L.Target and alive(L.Target) then
            TargetGlow.Adornee = L.Target
            TargetGlow.Enabled = true
            local a = (math.sin(os.clock() * 2.2) + 1) * 0.5
            TargetGlow.FillColor = BLUE_DEEP:Lerp(BLUE_LIGHT, a)
            TargetGlow.OutlineColor = BLUE_LIGHT:Lerp(BLUE_DEEP, a)
            TargetGlow.FillTransparency = 0.72 - a * 0.22
        else
            TargetGlow.Enabled = false
            TargetGlow.Adornee = nil
        end
        RunS.RenderStepped:Wait()
    end
end)

task.spawn(function()
    while true do
        task.wait(3)
        if L.ESP then
            local stale = #espTags == 0
            for _, bb in ipairs(espTags) do
                if not alive(bb) or not bb.Adornee or not bb.Adornee.Parent then stale = true break end
            end
            if stale then buildESP() end
        end
        -- targets get stolen and plots repopulate, so the ArrayList would go
        -- stale exactly like the ESP tags do
        if L.ArrayList then buildArray() end
    end
end)

----------------------------------------------------------------------
-- POTATO
----------------------------------------------------------------------
local FOV_MODES = {
    Enum.FieldOfViewMode.Vertical, Enum.FieldOfViewMode.Horizontal,
    Enum.FieldOfViewMode.MaxAxis, Enum.FieldOfViewMode.Diagonal,
}
local fovIdx = 1

local function cycleStretch()
    fovIdx = fovIdx % #FOV_MODES + 1
    Cam.FieldOfViewMode = FOV_MODES[fovIdx]
    return FOV_MODES[fovIdx].Name
end

local function stripGraphics()
    pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Level01 end)
    Lighting.GlobalShadows = false
    Lighting.FogEnd = 1e9
    Lighting.Brightness = 1
    for _, e in ipairs(Lighting:GetChildren()) do
        if e:IsA("PostEffect") then e.Enabled = false end
    end
    local t = workspace:FindFirstChildOfClass("Terrain")
    if t then
        t.WaterWaveSize, t.WaterWaveSpeed, t.WaterReflectance = 0, 0, 0
        t.Decoration = false
    end
    local n = 0
    for _, d in ipairs(workspace:GetDescendants()) do
        if d:IsA("BasePart") then
            d.Material = Enum.Material.SmoothPlastic
            d.Reflectance = 0
            d.CastShadow = false
            n = n + 1
        elseif d:IsA("Decal") or d:IsA("Texture") then
            d.Transparency = 1
        elseif d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam")
            or d:IsA("Smoke") or d:IsA("Fire") or d:IsA("Sparkles") then
            d.Enabled = false
        end
    end
    return n
end

----------------------------------------------------------------------
-- UI PRIMITIVES  (Luminosity, verbatim)
----------------------------------------------------------------------
local old = PG:FindFirstChild("LuminosityClient")
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
    PaddingLeft = UDim.new(0, c or a or 0), PaddingRight = UDim.new(0, d or c or a or 0),
    Parent = p}) end
local function Stroke(p, col, th, tr) return New("UIStroke", {Color = col or T.LINE,
    Thickness = th or 1, Transparency = tr or 0.4,
    ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = p}) end
local function tw(obj, time, style, dir, goal) return TS:Create(obj,
    TweenInfo.new(time, style or Enum.EasingStyle.Quart, dir or Enum.EasingDirection.Out), goal) end

local Gui = New("ScreenGui", {Name = "LuminosityClient", ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling, IgnoreGuiInset = true,
    DisplayOrder = 9999, Parent = PG})

----------------------------------------------------------------------
-- LOADING SCREEN  (Luminosity: moon rain + letter assembly)
----------------------------------------------------------------------
local Loader = New("Frame", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
    BorderSizePixel = 0, ZIndex = 100, Parent = Gui})
local RainRoot = New("Frame", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
    ZIndex = 100, Parent = Loader})

L.RainActive = true
task.spawn(function()
    while L.RainActive and Loader.Parent do
        local size = math.random(14, 34)
        local col = ({T.ACCENT, T.HIGH, T.DEEP})[math.random(1, 3)]
        local x = math.random(0, Cam and Cam.ViewportSize.X or 1200)
        local rot0 = math.random(-40, 40)
        -- drawn, not typed: the moon glyph is not in Roblox's font set and
        -- renders as a tofu box, so the particle is a real circle
        local dotSize = math.floor(size * 0.42)
        local moon = New("Frame", {Size = UDim2.fromOffset(dotSize, dotSize),
            Position = UDim2.new(0, x, 0, -size - 20), BackgroundColor3 = col,
            BackgroundTransparency = math.random(30, 65) / 100, BorderSizePixel = 0,
            Rotation = rot0, ZIndex = 100, Parent = RainRoot})
        New("UICorner", {CornerRadius = UDim.new(1, 0), Parent = moon})
        New("UIStroke", {Color = col, Thickness = 0.6, Transparency = 0.5, Parent = moon})
        local vy = Cam and Cam.ViewportSize.Y or 800
        local dur = math.random(24, 44) / 10
        task.spawn(function()
            TS:Create(moon, TweenInfo.new(dur, Enum.EasingStyle.Linear), {
                Position = UDim2.new(0, x + math.random(-60, 60), 0, vy + 40),
                Rotation = rot0 + math.random(-90, 90)}):Play()
            TS:Create(moon, TweenInfo.new(dur * 0.9, Enum.EasingStyle.Quad), {BackgroundTransparency = 1}):Play()
            task.wait(dur)
            moon:Destroy()
        end)
        task.wait(0.11)
    end
end)

local LoaderCard = New("Frame", {Size = UDim2.fromOffset(520, 150),
    Position = UDim2.new(0.5, -260, 0.5, -75), BackgroundTransparency = 1,
    ZIndex = 101, Parent = Loader})

local BRAND = "LUMINOSITY"
local BIG = IS_MOBILE and 46 or 62
local Mark = New("Frame", {Size = UDim2.new(1, 0, 0, BIG + 8), BackgroundTransparency = 1,
    ZIndex = 102, Parent = LoaderCard})
New("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal,
    HorizontalAlignment = Enum.HorizontalAlignment.Center,
    VerticalAlignment = Enum.VerticalAlignment.Center,
    Padding = UDim.new(0, 1), Parent = Mark})

local Letters = {}
for i = 1, #BRAND do
    local ch = BRAND:sub(i, i)
    local wrap = New("Frame", {Size = UDim2.fromOffset(BIG * (ch == "I" and 0.35 or 0.62), BIG),
        BackgroundTransparency = 1, LayoutOrder = i, ZIndex = 102, Parent = Mark})
    local lbl = New("TextLabel", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
        Text = ch, TextColor3 = T.HIGH, Font = Enum.Font.GothamBold, TextSize = BIG,
        TextTransparency = 1, Rotation = math.random(-60, 60), ZIndex = 103, Parent = wrap})
    lbl.Position = UDim2.fromOffset(math.random(-140, 140), math.random(-90, 90))
    New("UIStroke", {Color = Color3.new(0, 0, 0), Thickness = 2, Transparency = 0.1,
        LineJoinMode = Enum.LineJoinMode.Round, Parent = lbl})
    Letters[i] = lbl
end

local Underline = New("Frame", {Size = UDim2.new(0, 0, 0, 2),
    Position = UDim2.new(0.5, 0, 0, BIG + 12), AnchorPoint = Vector2.new(0.5, 0),
    BackgroundColor3 = T.ACCENT, BackgroundTransparency = 0.15, BorderSizePixel = 0,
    ZIndex = 102, Parent = LoaderCard})
Corner(Underline, 1)
New("UIGradient", {Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, T.DEEP), ColorSequenceKeypoint.new(0.5, T.HIGH),
    ColorSequenceKeypoint.new(1, T.DEEP)}), Parent = Underline})

local Sub = New("TextLabel", {Size = UDim2.new(1, 0, 0, 18),
    Position = UDim2.new(0, 0, 0, BIG + 22), BackgroundTransparency = 1,
    Text = "initializing", TextColor3 = T.MUTED, Font = Enum.Font.Gotham, TextSize = 12,
    TextTransparency = 1, ZIndex = 102, Parent = LoaderCard})

----------------------------------------------------------------------
-- NOTIFICATIONS  (Luminosity: top-right stack, dedupe with x N)
----------------------------------------------------------------------
local NotifRoot = New("Frame", {Size = UDim2.fromOffset(300, 0),
    Position = UDim2.new(1, -316, 0, 16), BackgroundTransparency = 1, Parent = Gui})
New("UIListLayout", {Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder,
    HorizontalAlignment = Enum.HorizontalAlignment.Right, Parent = NotifRoot})

local live, notifSeq = {}, 0

local function destroyNotif(state)
    if state.dead then return end
    state.dead = true
    live[state.key] = nil
    tw(state.card, 0.25, nil, nil, {Position = UDim2.new(1, 40, 0, 0), BackgroundTransparency = 1}):Play()
    task.delay(0.3, function() if state.card then state.card:Destroy() end end)
end

notify = function(title, msg, color, footer)
    color = color or T.ACCENT
    local key = title .. "|" .. tostring(msg)
    local ex = live[key]
    if ex and not ex.dead then
        ex.n = ex.n + 1
        ex.badge.Text = "x" .. ex.n
        ex.badge.Visible = true
        if ex.timer then task.cancel(ex.timer) end
        ex.timer = task.delay(4.5, function() destroyNotif(ex) end)
        tw(ex.card, 0.12, nil, nil, {Size = UDim2.new(1, 0, 0, ex.h + 4)}):Play()
        task.delay(0.12, function()
            if ex.card and ex.card.Parent then
                tw(ex.card, 0.12, nil, nil, {Size = UDim2.new(1, 0, 0, ex.h)}):Play()
            end
        end)
        return
    end
    notifSeq = notifSeq + 1
    local h = footer and 66 or 52
    local card = New("Frame", {Size = UDim2.new(1, 0, 0, h), BackgroundColor3 = T.RAISED,
        BackgroundTransparency = 1, BorderSizePixel = 0, LayoutOrder = notifSeq, Parent = NotifRoot})
    Corner(card, 10); Stroke(card, T.LINE, 1, 0.5)
    local bar = New("Frame", {Size = UDim2.new(0, 3, 1, -14), Position = UDim2.new(0, 6, 0, 7),
        BackgroundColor3 = color, BorderSizePixel = 0, Parent = card})
    Corner(bar, 2)
    New("TextLabel", {Size = UDim2.new(1, -60, 0, 16), Position = UDim2.fromOffset(16, 8),
        BackgroundTransparency = 1, Text = title, TextColor3 = color,
        Font = Enum.Font.GothamBold, TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left, Parent = card})
    New("TextLabel", {Size = UDim2.new(1, -26, 0, 16), Position = UDim2.fromOffset(16, 26),
        BackgroundTransparency = 1, Text = tostring(msg), TextColor3 = T.TEXT,
        Font = Enum.Font.Gotham, TextSize = 12, TextTruncate = Enum.TextTruncate.AtEnd,
        TextXAlignment = Enum.TextXAlignment.Left, Parent = card})
    if footer then
        New("TextLabel", {Size = UDim2.new(1, -26, 0, 14), Position = UDim2.fromOffset(16, 44),
            BackgroundTransparency = 1, Text = footer, TextColor3 = T.MUTED,
            Font = Enum.Font.Gotham, TextSize = 10,
            TextXAlignment = Enum.TextXAlignment.Left, Parent = card})
    end
    local badge = New("TextLabel", {Size = UDim2.fromOffset(28, 16), Position = UDim2.new(1, -34, 0, 8),
        BackgroundTransparency = 1, Text = "x1", TextColor3 = T.MUTED,
        Font = Enum.Font.GothamBold, TextSize = 11, Visible = false, Parent = card})
    local state = {card = card, badge = badge, n = 1, key = key, h = h}
    live[key] = state
    card.Position = UDim2.new(1, 40, 0, 0)
    tw(card, 0.28, nil, nil, {Position = UDim2.new(0, 0, 0, 0), BackgroundTransparency = 0.18}):Play()
    state.timer = task.delay(4.5, function() destroyNotif(state) end)
end
L.Notify = notify

----------------------------------------------------------------------
-- INTERACTION HELPERS  (Luminosity: ripple, press, hoverFill)
----------------------------------------------------------------------
local function ripple(btn, tint)
    local abs = btn.AbsoluteSize
    local circle = New("Frame", {Size = UDim2.fromOffset(0, 0), Position = UDim2.fromScale(0.5, 0.5),
        AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = tint or T.HIGH,
        BackgroundTransparency = 0.75, BorderSizePixel = 0, ZIndex = 10, Parent = btn})
    Corner(circle, 999)
    local target = math.max(abs.X, abs.Y) * 1.6
    tw(circle, 0.45, nil, nil, {Size = UDim2.fromOffset(target, target), BackgroundTransparency = 1}):Play()
    task.delay(0.5, function() circle:Destroy() end)
end

local function press(btn, fn)
    btn.MouseButton1Click:Connect(function()
        ripple(btn)
        task.spawn(fn)
    end)
end

local function hoverFill(btn, base, hover)
    btn.MouseEnter:Connect(function() tw(btn, 0.16, nil, nil, {BackgroundColor3 = hover}):Play() end)
    btn.MouseLeave:Connect(function() tw(btn, 0.16, nil, nil, {BackgroundColor3 = base}):Play() end)
end

----------------------------------------------------------------------
-- ARRAYLIST
--
-- The target list rendered the way a Minecraft client draws its module
-- list: right-aligned against the screen edge, longest entry on top,
-- animated hue running down the stack, each row sliding in from the right.
--
-- Sorted by RENDERED width, not string length. Proportional fonts make
-- those different things -- "Illlli" is six characters and narrower than
-- "WWW" at three -- and sorting by #text gives the ragged edge the whole
-- style exists to avoid. TextService measures the real pixel width.
--
-- Entries stay clickable, so this replaces the panel's scrolling list
-- rather than just decorating it: click a row to select that target.
----------------------------------------------------------------------
local TxtS = game:GetService("TextService")

local ArrayRoot = New("Frame", {
    AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 44),
    Size = UDim2.fromOffset(340, 0), AutomaticSize = Enum.AutomaticSize.Y,
    BackgroundTransparency = 1, Parent = Gui})
New("UIListLayout", {Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder,
    HorizontalAlignment = Enum.HorizontalAlignment.Right, Parent = ArrayRoot})

local arrayRows = {}     -- model -> row, kept across refreshes
local arrayLive = {}     -- ordered view, for the hue pass

local function textWidth(str, size, font)
    local ok, v = pcall(function()
        return TxtS:GetTextSize(str, size, font, Vector2.new(10000, 100)).X
    end)
    -- GetTextSize can fail on some executors; fall back to an estimate that
    -- is at least monotonic in length so the sort still means something.
    if ok and v and v > 0 then return v end
    return #str * size * 0.55
end

local function rowLabel(t, rank)
    return ("%d  %s  $%s"):format(rank, t.name, short(t.price))
end

local function makeRow(model)
    local row = New("TextButton", {
        Size = UDim2.fromOffset(120, 21), BackgroundColor3 = T.VOID,
        BackgroundTransparency = 0.32, AutoButtonColor = false, Text = "",
        BorderSizePixel = 0, Parent = ArrayRoot})
    Corner(row, 4)
    local name = New("TextLabel", {
        Size = UDim2.new(1, -14, 1, 0), Position = UDim2.fromOffset(4, 0),
        BackgroundTransparency = 1, Text = "", TextColor3 = T.HIGH,
        Font = Enum.Font.GothamBold, TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Right,
        TextStrokeTransparency = 0.5, Parent = row})
    local dist = New("TextLabel", {
        Size = UDim2.new(0, 46, 1, 0), Position = UDim2.fromOffset(6, 0),
        BackgroundTransparency = 1, Text = "", TextColor3 = T.MUTED,
        Font = Enum.Font.Gotham, TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextStrokeTransparency = 0.7, Parent = row})
    -- accent bar down the right edge, as the clients draw it
    local bar = New("Frame", {Size = UDim2.new(0, 2, 1, 0),
        Position = UDim2.new(1, -2, 0, 0), BackgroundColor3 = T.ACCENT,
        BorderSizePixel = 0, Parent = row})

    row.MouseButton1Click:Connect(function()
        local t = arrayRows[model] and arrayRows[model].t
        if not t then return end
        L.Target = model
        notify("Target", t.name, T.ACCENT,
            ("plot %s - slot %d"):format(t.plot.Name:sub(1, 6), t.slot))
    end)
    row.MouseEnter:Connect(function()
        tw(row, 0.12, nil, nil, {BackgroundTransparency = 0.08}):Play()
    end)
    row.MouseLeave:Connect(function()
        local sel = (L.Target == model)
        tw(row, 0.15, nil, nil, {BackgroundTransparency = sel and 0.14 or 0.32}):Play()
    end)

    -- slide in from the right edge, once, on creation only
    row.Position = UDim2.fromOffset(44, 0)
    tw(row, 0.24, Enum.EasingStyle.Quart, nil, {Position = UDim2.fromOffset(0, 0)}):Play()

    return {frame = row, label = name, dist = dist, bar = bar, model = model}
end

local function dropRow(r)
    if not alive(r.frame) then return end
    local f = r.frame
    tw(f, 0.18, Enum.EasingStyle.Quart, nil,
        {Position = UDim2.fromOffset(44, 0), BackgroundTransparency = 1}):Play()
    tw(r.label, 0.15, nil, nil, {TextTransparency = 1}):Play()
    tw(r.dist, 0.15, nil, nil, {TextTransparency = 1}):Play()
    task.delay(0.2, function() if f then f:Destroy() end end)
end

-- Rebuilt incrementally rather than torn down and recreated.
--
-- The old version destroyed every row on each refresh, which replayed the
-- slide-in animation from scratch, dropped whatever the mouse was hovering,
-- and made the whole stack flicker on a list that had barely changed. Rows
-- are now keyed by model: existing ones are updated in place, only genuinely
-- new targets animate in, and only departed ones animate out.
function buildArray()   -- assigns the forward-declared local above
    if not L.ArrayList then
        for m, r in pairs(arrayRows) do dropRow(r); arrayRows[m] = nil end
        arrayLive = {}
        ArrayRoot.Visible = false
        return 0
    end
    ArrayRoot.Visible = true

    local list = targets()
    local rows, want = {}, {}
    for i, t in ipairs(list) do
        if i > L.ArrayMax then break end
        local label = rowLabel(t, i)
        rows[#rows + 1] = {t = t, label = label,
                           w = textWidth(label, 14, Enum.Font.GothamBold)}
        want[t.model] = true
    end
    -- longest first: the signature straight left edge of an ArrayList.
    -- Sorted by RENDERED width, not string length -- proportional fonts make
    -- those different things, and #text gives the ragged edge the style
    -- exists to avoid.
    table.sort(rows, function(x, y) return x.w > y.w end)

    for m, r in pairs(arrayRows) do
        if not want[m] then dropRow(r); arrayRows[m] = nil end
    end

    arrayLive = {}
    for i, r in ipairs(rows) do
        local model = r.t.model
        local row = arrayRows[model]
        if not row then
            row = makeRow(model)
            arrayRows[model] = row
        end
        row.t = r.t
        row.frame.Size = UDim2.fromOffset(r.w + 62, 21)
        row.frame.LayoutOrder = i
        row.label.Text = r.label
        row.dist.Text = (r.t.dist > 0) and (math.floor(r.t.dist) .. "m") or ""
        arrayLive[#arrayLive + 1] = row
    end
    return #rows
end

-- Keep it live. The list only refreshed when a button was pressed before,
-- so it went stale the moment anyone bought, sold or moved.
task.spawn(function()
    while true do
        task.wait(L.ArrayHz)
        if L.ArrayList then pcall(buildArray) end
    end
end)

-- Hue runs down the stack and drifts over time. The selected target is
-- pinned white and filled so it reads out of the gradient instead of
-- blending into it.
RunS.RenderStepped:Connect(function()
    if not L.ArrayList or #arrayLive == 0 then return end
    local base = L.ArrayHue and (os.clock() * 0.08) % 1 or 0.58
    for i, r in ipairs(arrayLive) do
        if alive(r.frame) then
            if L.Target and r.model == L.Target then
                r.label.TextColor3 = T.WHITE
                r.bar.BackgroundColor3 = T.WHITE
                r.bar.Size = UDim2.new(0, 4, 1, 0)
                r.bar.Position = UDim2.new(1, -4, 0, 0)
            else
                local h = (base + (i - 1) * 0.045) % 1
                local c = L.ArrayHue and Color3.fromHSV(h, 0.5, 1) or T.HIGH
                r.label.TextColor3 = c
                r.bar.BackgroundColor3 = c
                r.bar.Size = UDim2.new(0, 2, 1, 0)
                r.bar.Position = UDim2.new(1, -2, 0, 0)
            end
        end
    end
end)

-- Notifications share this corner, so push them below whatever the
-- ArrayList currently occupies instead of letting them overlap. Derived from
-- the roots themselves rather than a hardcoded inset, so changing either
-- width does not silently break the other.
local function restackNotifs()
    -- X comes from the notification stack's OWN width so it stays flush with
    -- the right edge; Y comes from however tall the ArrayList currently is,
    -- so the two never overlap. Deriving X from the ArrayList instead would
    -- push the stack inward by the difference between the two widths.
    local h = ArrayRoot.AbsoluteSize.Y
    NotifRoot.Position = UDim2.new(1, -(NotifRoot.Size.X.Offset + 14), 0,
        ArrayRoot.Position.Y.Offset + (h > 0 and h + 10 or 0))
end
ArrayRoot:GetPropertyChangedSignal("AbsoluteSize"):Connect(restackNotifs)
restackNotifs()

----------------------------------------------------------------------
-- WATERMARK
--
-- Brand, framerate and ping in the corner, the way a client always carries
-- them. FPS is averaged over a rolling second rather than taken from a single
-- delta -- per-frame 1/dt is far too noisy to read.
----------------------------------------------------------------------
local Mark = New("Frame", {Position = UDim2.new(0, 12, 0, 10),
    Size = UDim2.fromOffset(0, 24), AutomaticSize = Enum.AutomaticSize.X,
    BackgroundColor3 = T.VOID, BackgroundTransparency = 0.35,
    BorderSizePixel = 0, Parent = Gui})
Corner(Mark, 6); Pad(Mark, 0, 0, 9, 9)
New("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal,
    VerticalAlignment = Enum.VerticalAlignment.Center,
    Padding = UDim.new(0, 7), Parent = Mark})

local MarkName = New("TextLabel", {Size = UDim2.fromOffset(0, 24),
    AutomaticSize = Enum.AutomaticSize.X, BackgroundTransparency = 1,
    Text = "LUMINOSITY", TextColor3 = T.WHITE, Font = Enum.Font.GothamBlack,
    TextSize = 13, TextStrokeTransparency = 0.5, LayoutOrder = 1, Parent = Mark})
New("UIGradient", {Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, T.ACCENT),
    ColorSequenceKeypoint.new(0.5, T.WHITE),
    ColorSequenceKeypoint.new(1, T.DEEP)}), Parent = MarkName})
local MarkStat = New("TextLabel", {Size = UDim2.fromOffset(0, 24),
    AutomaticSize = Enum.AutomaticSize.X, BackgroundTransparency = 1,
    Text = "", TextColor3 = T.MUTED, Font = Enum.Font.Gotham, TextSize = 11,
    TextStrokeTransparency = 0.6, LayoutOrder = 2, Parent = Mark})

task.spawn(function()
    local Stats = game:GetService("Stats")
    local frames, last = 0, os.clock()
    RunS.RenderStepped:Connect(function() frames = frames + 1 end)
    while true do
        task.wait(0.5)
        local now = os.clock()
        local dt = now - last
        if dt > 0 then
            local fps = math.floor(frames / dt + 0.5)
            frames, last = 0, now
            local ping = safe(function()
                return math.floor(Stats.Network.ServerStatsItem["Data Ping"]:GetValue())
            end)
            MarkStat.Text = ("%d fps  ·  %s ms"):format(fps, ping and tostring(ping) or "?")
        end
    end
end)

----------------------------------------------------------------------
-- TAB BAR  (Minecraft-style: tabs across the top, dropdown per tab)
----------------------------------------------------------------------
local Bar = New("Frame", {Size = UDim2.new(0, 0, 0, 34), Position = UDim2.new(0.5, 0, 0, 18),
    AnchorPoint = Vector2.new(0.5, 0), BackgroundTransparency = 1,
    AutomaticSize = Enum.AutomaticSize.X, Visible = false, Parent = Gui})
New("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal,
    Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = Bar})

local tabs, openTab = {}, nil

local function closeAll()
    for _, tab in ipairs(tabs) do
        tab.panel.Visible = false
        tw(tab.btn, 0.15, nil, nil, {BackgroundColor3 = T.RAISED, BackgroundTransparency = 0.15}):Play()
        tab.label.TextColor3 = T.MUTED
        tab.chev.set(T.MUTED)
        tab.arrow.Rotation = 45
    end
    openTab = nil
end

local function makeTab(name, order)
    -- The button does NOT clip, so the panel can hang below it. Clipping is
    -- moved to an inner frame that only the ripple lives in.
    local btn = New("TextButton", {Size = UDim2.fromOffset(0, 34), AutomaticSize = Enum.AutomaticSize.X,
        BackgroundColor3 = T.RAISED, BackgroundTransparency = 0.15, AutoButtonColor = false,
        Text = "", ClipsDescendants = false, LayoutOrder = order, Parent = Bar})
    Corner(btn, 9); Stroke(btn, T.LINE, 1, 0.5); Pad(btn, 0, 0, 14, 28)
    local clip = New("Frame", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
        ClipsDescendants = true, ZIndex = 2, Parent = btn})
    Corner(clip, 9)
    local label = New("TextLabel", {Size = UDim2.new(0, 0, 1, 0),
        AutomaticSize = Enum.AutomaticSize.X, BackgroundTransparency = 1, Text = name,
        TextColor3 = T.MUTED, Font = Enum.Font.GothamBold, TextSize = 12, Parent = btn})

    -- drawn chevron: two short bars meeting in a v. The arrow glyph is not
    -- in Roblox's font set and renders as a tofu box, and a UIStroke on a
    -- rotated square draws all four edges, which is a diamond, not an arrow.
    local arrow = New("Frame", {Size = UDim2.fromOffset(12, 8),
        Position = UDim2.new(1, 9, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5),
        BackgroundTransparency = 1, Parent = btn})
    local barL = New("Frame", {Size = UDim2.fromOffset(7, 1.6), AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.28, 0, 0.5, 0), BackgroundColor3 = T.MUTED,
        BorderSizePixel = 0, Rotation = 40, Parent = arrow})
    local barR = New("Frame", {Size = UDim2.fromOffset(7, 1.6), AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.72, 0, 0.5, 0), BackgroundColor3 = T.MUTED,
        BorderSizePixel = 0, Rotation = -40, Parent = arrow})
    local chev = {
        set = function(c) barL.BackgroundColor3 = c; barR.BackgroundColor3 = c end,
    }

    -- parented to the button, so it is always directly UNDER its tab
    -- regardless of screen inset or where the bar ends up
    local panel = New("Frame", {Size = UDim2.fromOffset(258, 0),
        Position = UDim2.new(0, -14, 1, 10), AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = T.SURFACE, BackgroundTransparency = 0.12,
        BorderSizePixel = 0, Visible = false, ZIndex = 5, Parent = btn})
    Corner(panel, 12); Stroke(panel, T.LINE, 1, 0.35); Pad(panel, 10)
    New("UIGradient", {Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, T.SURFACE),
        ColorSequenceKeypoint.new(0.5, T.SURFACE:Lerp(T.DEEP, 0.3)),
        ColorSequenceKeypoint.new(1, T.SURFACE)}), Rotation = 35, Parent = panel})
    New("UIListLayout", {Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = panel})

    -- Header inside the dropdown. Cheap, but it means an open panel still
    -- says what it is when the tab strip is behind it or off the edge.
    local head = New("Frame", {Size = UDim2.new(1, 0, 0, 16),
        BackgroundTransparency = 1, LayoutOrder = 0, Parent = panel})
    New("TextLabel", {Size = UDim2.new(1, -30, 1, 0), BackgroundTransparency = 1,
        Text = name, TextColor3 = T.MUTED, Font = Enum.Font.GothamBold,
        TextSize = 10, TextXAlignment = Enum.TextXAlignment.Left, Parent = head})
    New("Frame", {Size = UDim2.new(0, 26, 0, 1), Position = UDim2.new(1, -26, 0.5, 0),
        BackgroundColor3 = T.LINE, BorderSizePixel = 0, Parent = head})

    local tab = {name = name, btn = btn, label = label, arrow = arrow,
                 chev = chev, panel = panel, clip = clip, order = 0}
    table.insert(tabs, tab)

    btn.MouseButton1Click:Connect(function()
        ripple(clip)
        local wasOpen = openTab == tab
        closeAll()
        if not wasOpen then
            openTab = tab
            panel.Visible = true
            tw(btn, 0.15, nil, nil, {BackgroundColor3 = T.DEEP, BackgroundTransparency = 0.05}):Play()
            label.TextColor3 = T.WHITE
            chev.set(T.WHITE)
            arrow.Rotation = 225   -- chevron flips to point up
        end
    end)
    return tab
end

local function rowBase(tab, height)
    tab.order = tab.order + 1
    local b = New("TextButton", {Size = UDim2.new(1, 0, 0, height or 30),
        BackgroundColor3 = T.RAISED, BackgroundTransparency = 0.25,
        AutoButtonColor = false, Text = "",
        ClipsDescendants = true, LayoutOrder = tab.order, Parent = tab.panel})
    Corner(b, 8); Stroke(b, T.LINE, 1, 0.55)
    hoverFill(b, T.RAISED, T.LINE)
    return b
end

local function addToggle(tab, name, default, fn)
    local b = rowBase(tab)
    New("TextLabel", {Size = UDim2.new(1, -60, 1, 0), Position = UDim2.fromOffset(11, 0),
        BackgroundTransparency = 1, Text = name, TextColor3 = T.TEXT,
        Font = Enum.Font.Gotham, TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left, Parent = b})
    local val = New("TextLabel", {Size = UDim2.new(0, 46, 1, 0),
        Position = UDim2.new(1, -57, 0, 0), BackgroundTransparency = 1,
        Text = default and "ON" or "OFF", TextColor3 = default and T.ACCENT or T.MUTED,
        Font = Enum.Font.GothamBold, TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Right, Parent = b})
    local state = default
    press(b, function()
        state = not state
        val.Text = state and "ON" or "OFF"
        val.TextColor3 = state and T.ACCENT or T.MUTED
        fn(state)
    end)
    return function(v)
        state = v
        val.Text = v and "ON" or "OFF"
        val.TextColor3 = v and T.ACCENT or T.MUTED
    end
end

local function addButton(tab, name, fn, accent)
    local b = rowBase(tab)
    if accent then b.BackgroundColor3 = T.DEEP; hoverFill(b, T.DEEP, T.ACCENT) end
    New("TextLabel", {Size = UDim2.new(1, -22, 1, 0), Position = UDim2.fromOffset(11, 0),
        BackgroundTransparency = 1, Text = name, TextColor3 = accent and T.WHITE or T.TEXT,
        Font = accent and Enum.Font.GothamBold or Enum.Font.Gotham, TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left, Parent = b})
    press(b, fn)
    return b
end

local function addValue(tab, name, initial, fn)
    local b = rowBase(tab)
    New("TextLabel", {Size = UDim2.new(1, -80, 1, 0), Position = UDim2.fromOffset(11, 0),
        BackgroundTransparency = 1, Text = name, TextColor3 = T.TEXT,
        Font = Enum.Font.Gotham, TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left, Parent = b})
    local val = New("TextLabel", {Size = UDim2.new(0, 70, 1, 0), Position = UDim2.new(1, -81, 0, 0),
        BackgroundTransparency = 1, Text = initial, TextColor3 = T.ACCENT,
        Font = Enum.Font.GothamBold, TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Right, Parent = b})
    press(b, function() val.Text = fn() or val.Text end)
    return val
end

local function addLabel(tab, text, color)
    tab.order = tab.order + 1
    return New("TextLabel", {Size = UDim2.new(1, 0, 0, 15), BackgroundTransparency = 1,
        Text = text, TextColor3 = color or T.MUTED, Font = Enum.Font.Gotham, TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left, TextWrapped = true,
        LayoutOrder = tab.order, Parent = tab.panel})
end

----------------------------------------------------------------------
-- TABS
----------------------------------------------------------------------
local TabSteal  = makeTab("STEAL", 1)
local TabMove   = makeTab("MOVEMENT", 2)
local TabVisual = makeTab("VISUALS", 3)
local TabRender = makeTab("RENDER", 4)
local TabMisc   = makeTab("MISC", 5)

-- STEAL ------------------------------------------------------------
-- The scrolling list that used to live in this panel is gone: the
-- ArrayList above is the target list now, and it stays on screen with the
-- menu closed, which the panel version could not do.
local function refreshTargets()
    return buildArray()
end

addButton(TabSteal, "refresh targets", function()
    local n = refreshTargets()
    notify("Targets", n .. " listed", T.ACCENT,
        L.ArrayList and "click a row in the ArrayList to select" or "ArrayList is off")
end, true)

addButton(TabSteal, "tp to target", function()
    if not L.Target then return notify("TP", "pick a target first", T.ORANGE) end
    L.GoTo(L.Target)
end)

addButton(TabSteal, "steal target", function()
    if not (L.Target and alive(L.Target)) then return notify("Steal", "pick a target first", T.ORANGE) end
    local plot = L.Target.Parent
    local slot = podiumIndexFor(plot, L.Target)
    if not slot then return notify("Steal", "slot unresolved", T.RED) end
    lastSteal = os.clock()
    L.Steal(plot.Name, slot)
    notify("Steal", L.Target.Name, T.GREEN, ("plot %s - slot %d"):format(plot.Name:sub(1, 6), slot))
end, true)

addButton(TabSteal, "deliver", function()
    L.Deliver()
    notify("Deliver", "ping sent", T.ACCENT, "only lands inside your pad")
end)

addButton(TabSteal, "place into free slot", function()
    local free = firstFreeSlot()
    if not free then return notify("Place", "base is full", T.ORANGE) end
    L.Place(free)
    notify("Place", "slot " .. free, T.GREEN)
end)

-- MOVEMENT ---------------------------------------------------------
addButton(TabMove, "dash home", function() L.GoHome() end, true)
addToggle(TabMove, "pathfinding", L.Pathfind, function(v)
    L.Pathfind = v
    notify("Pathfind", v and "navmesh routing" or "straight line", T.ACCENT)
end)
addValue(TabMove, "travel mode", L.Mode, function()
    L.Mode = (L.Mode == "GLIDE" and "HOP") or (L.Mode == "HOP" and "FLING") or "GLIDE"
    notify("Travel", L.Mode, T.ACCENT,
        L.Mode == "GLIDE" and "safest, no snap-back"
        or L.Mode == "HOP" and "chunked, usually safe"
        or "real physics fling, spins, follows the path")
    return L.Mode
end)
addValue(TabMove, "glide speed", L.Speed .. "/s", function()
    L.Speed = L.Speed + 30
    if L.Speed > 300 then L.Speed = 60 end
    return L.Speed .. "/s"
end)
addValue(TabMove, "hop size", L.HopSize .. "st", function()
    L.HopSize = L.HopSize + 6
    if L.HopSize > 60 then L.HopSize = 6 end
    return L.HopSize .. "st"
end)
addValue(TabMove, "fling power", L.FlingPower .. "/s", function()
    L.FlingPower = L.FlingPower + 40
    if L.FlingPower > 400 then L.FlingPower = 80 end
    return L.FlingPower .. "/s"
end)
addValue(TabMove, "fling spin", tostring(L.FlingSpin), function()
    L.FlingSpin = L.FlingSpin + 3000
    if L.FlingSpin > 24000 then L.FlingSpin = 0 end
    return tostring(L.FlingSpin)
end)
addValue(TabMove, "fling lift", L.FlingLift .. "/s", function()
    L.FlingLift = L.FlingLift + 10
    if L.FlingLift > 60 then L.FlingLift = -20 end
    return L.FlingLift .. "/s"
end)
addValue(TabMove, "fling settle", ("%.2fs"):format(L.FlingSettle), function()
    L.FlingSettle = L.FlingSettle + 0.05
    if L.FlingSettle > 0.5 then L.FlingSettle = 0 end
    return ("%.2fs"):format(L.FlingSettle)
end)
addToggle(TabMove, "fling follows height", L.FlingClimb, function(v)
    L.FlingClimb = v
    notify("Fling", v and "tracks waypoint height" or "flies dead level", T.ACCENT)
end)
addLabel(TabMove, "FLING spins you and drives ONE locked direction per waypoint. spin 0 = no tumble. height tracking off = dead level from launch.")
addButton(TabMove, "calibrate threshold", function() L.Calibrate() end)
addToggle(TabMove, "hold-E aim", L.AutoAim, function(v) L.AutoAim = v end)
addValue(TabMove, "free range", L.Range .. "st", function()
    L.Range = L.Range + 60
    if L.Range > 500 then L.Range = 140 end
    return L.Range .. "st"
end)
addValue(TabMove, "climb height", L.Climb .. "st", function()
    L.Climb = L.Climb + 20
    if L.Climb > 120 then L.Climb = 20 end
    return L.Climb .. "st"
end)

-- VISUALS ----------------------------------------------------------
addToggle(TabVisual, "brainrot esp", L.ESP, function(v)
    L.ESP = v
    if v then
        local n = buildESP()
        notify("ESP", n .. " tagged", T.GREEN)
    else
        clearESP()
        notify("ESP", "cleared", T.MUTED)
    end
end)
addButton(TabVisual, "rebuild esp", function()
    if not L.ESP then return notify("ESP", "turn it on first", T.ORANGE) end
    notify("ESP", buildESP() .. " tagged", T.GREEN)
end)
addToggle(TabVisual, "arraylist", L.ArrayList, function(v)
    L.ArrayList = v
    buildArray()
    notify("ArrayList", v and "shown" or "hidden", T.ACCENT)
end)
addToggle(TabVisual, "arraylist hue", L.ArrayHue, function(v)
    L.ArrayHue = v
    notify("ArrayList", v and "animated gradient" or "flat colour", T.ACCENT)
end)
addValue(TabVisual, "arraylist size", tostring(L.ArrayMax), function()
    L.ArrayMax = L.ArrayMax + 4
    if L.ArrayMax > 24 then L.ArrayMax = 4 end
    buildArray()
    return tostring(L.ArrayMax)
end)
addButton(TabVisual, "clear target glow", function()
    L.Target = nil
    notify("Target", "cleared", T.MUTED)
end)
addLabel(TabVisual, "target glows blue, breathing deep -> light")

-- RENDER (potato) --------------------------------------------------
addValue(TabRender, "stretch mode", Cam.FieldOfViewMode.Name, function()
    local m = cycleStretch()
    notify("Stretch", m, T.ACCENT, "FOV mapping, not resolution")
    return m
end)
addButton(TabRender, "strip graphics", function()
    local n = stripGraphics()
    notify("Potato", n .. " parts stripped", T.GREEN, "one-way until rejoin")
end, true)
addLabel(TabRender, "Camera.ViewportSize is read-only in Roblox, so true stretched resolution is not possible from Lua. STRETCH cycles FieldOfViewMode instead.", T.ORANGE)

-- MISC -------------------------------------------------------------
addToggle(TabMisc, "rewrite steal notif", L.RewriteNotif, function(v) L.RewriteNotif = v end)
addToggle(TabMisc, "kick after steal", L.KickAfter, function(v)
    L.KickAfter = v
    if v then notify("Auto-kick", "armed", T.RED, "disconnects right after a steal") end
end)
addButton(TabMisc, "kick me now", function() LP:Kick(L.NotifText) end)
addLabel(TabMisc, 'steal notifications become: "' .. L.NotifText .. '"')
addLabel(TabMisc, "F toggles this menu")

----------------------------------------------------------------------
-- HOLD-E AIM  (arrow + fling, reuses the movement layer)
----------------------------------------------------------------------
local ArrowFolder = Instance.new("Folder")
ArrowFolder.Name = "LUMI_ARROW"
ArrowFolder.Parent = workspace

local function makePart(props)
    local p = Instance.new("Part")
    p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch = true, false, false, false
    p.Material = Enum.Material.Neon
    for k, v in pairs(props or {}) do p[k] = v end
    p.Parent = ArrowFolder
    return p
end

local Shaft = makePart({Size = Vector3.new(0.4, 0.4, 1), Color = T.ACCENT, Transparency = 1})
local Tip   = makePart({Size = Vector3.new(1.4, 1.4, 1.4), Shape = Enum.PartType.Ball,
    Color = T.HIGH, Transparency = 1})
local RingP = makePart({Size = Vector3.new(7, 0.3, 7), Color = T.HIGH, Transparency = 1})
Instance.new("CylinderMesh").Parent = RingP

local function hideArrow()
    Shaft.Transparency, Tip.Transparency, RingP.Transparency = 1, 1, 1
end

local landing, lockedDir

RunS.RenderStepped:Connect(function()
    if not L.Aiming then return end
    local root = hrp()
    if not root then hideArrow() return end
    local origin = root.Position
    local look = Cam.CFrame.LookVector
    local dir = Vector3.new(look.X, 0, look.Z)
    dir = dir.Magnitude > 0.001 and dir.Unit or Vector3.new(0, 0, -1)

    local point, locked
    local pad = L.AutoAim and myPad() or nil
    if pad then
        local p = pad.Position
        point = Vector3.new(p.X, p.Y, p.Z)
        local to = Vector3.new(p.X - origin.X, 0, p.Z - origin.Z)
        if to.Magnitude > 6 then dir = to.Unit end
        locked = true
    else
        point = origin + dir * L.Range
    end

    landing, lockedDir = groundAt(point), dir
    local delta = landing - origin
    local flat = Vector3.new(delta.X, 0, delta.Z)
    local len = flat.Magnitude
    if len < 1 then hideArrow() return end
    local u = flat.Unit
    local mid = origin + u * (len * 0.5)
    local col = locked and T.GREEN or T.ACCENT

    Shaft.Size = Vector3.new(0.4, 0.4, len)
    Shaft.CFrame = CFrame.lookAt(Vector3.new(mid.X, origin.Y, mid.Z), Vector3.new(mid.X, origin.Y, mid.Z) + u)
    Shaft.Color, Shaft.Transparency = col, 0.25
    Tip.CFrame = CFrame.new(Vector3.new(landing.X, origin.Y, landing.Z))
    Tip.Color, Tip.Transparency = col, 0.1
    RingP.CFrame = CFrame.new(landing + Vector3.new(0, 0.2, 0))
    RingP.Color, RingP.Transparency = col, 0.4
end)

----------------------------------------------------------------------
-- INPUT
----------------------------------------------------------------------
local menuOpen = false

UIS.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == L.MenuKey then
        menuOpen = not menuOpen
        Bar.Visible = menuOpen
        if not menuOpen then closeAll() end
        if menuOpen then refreshTargets() end
    elseif input.KeyCode == L.DashKey then
        L.Aiming = true
    end
end)

UIS.InputEnded:Connect(function(input)
    if input.KeyCode ~= L.DashKey or not L.Aiming then return end
    L.Aiming = false
    hideArrow()
    -- GLIDE and HOP yield, so never run them inside the input handler
    if landing then
        local dest = landing
        task.spawn(function() travel(dest) end)
    end
end)

----------------------------------------------------------------------
-- INTRO  (Luminosity sequence)
----------------------------------------------------------------------
task.spawn(function()
    task.wait(0.15)
    for i, lbl in ipairs(Letters) do
        task.spawn(function()
            task.wait(i * 0.045)
            tw(lbl, 0.55, Enum.EasingStyle.Back, Enum.EasingDirection.Out, {
                Position = UDim2.fromOffset(0, 0), Rotation = 0, TextTransparency = 0}):Play()
        end)
    end
    task.wait(0.75)
    tw(Underline, 0.5, nil, nil, {Size = UDim2.new(0.6, 0, 0, 2)}):Play()
    tw(Sub, 0.4, nil, nil, {TextTransparency = 0}):Play()

    local deadline = os.clock() + 8
    while not myPods() and os.clock() < deadline do task.wait(0.15) end
    Sub.Text = myPods() and "base channel linked" or "base channel not found"

    task.wait(0.7)
    L.RainActive = false
    for _, lbl in ipairs(Letters) do
        tw(lbl, 0.35, nil, nil, {TextTransparency = 1, Position = UDim2.fromOffset(0, -30)}):Play()
    end
    tw(Underline, 0.3, nil, nil, {Size = UDim2.new(0, 0, 0, 2)}):Play()
    tw(Sub, 0.3, nil, nil, {TextTransparency = 1}):Play()
    task.wait(0.4)
    Loader:Destroy()

    notify("Luminosity", "F for menu", T.ACCENT, "hold E to aim - release to go")
end)

getgenv().LUMI = L
print("[LUMINOSITY] loaded - F for menu, hold E to dash")
return L
