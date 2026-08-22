--[[
    Luminosity // Instant Stealer  --  Steal An Egg (placeId 107778070777162)
    Executor: any with getgenv + task library (built against Delta 1.0.733.988)
    Language: Luau (client-side, loadstring/execute)

    How it works
      The game exposes its steal as a RemoteFunction, "Eggs: RequestAreaEggCarry",
      invoked with (uid, firstAreaSlotKey?) and answering (ok, denyReason). Normally a
      CarryAreaEgg ProximityPrompt (8 stud range, 1.2s hold) is what calls it. This
      script skips the prompt and the hold: it reads the live area-egg snapshot from
      "Eggs: RequestAreaEggSnapshot", pivots the character onto the target for a frame
      so the server's range check passes, invokes the carry directly, then pivots home
      to bank the egg. Round trip is two frames instead of two runs across the map.
--]]

--=========================================================================
-- SERVICES / LOCALS
--=========================================================================

local Players     = game:GetService("Players")
local RS          = game:GetService("ReplicatedStorage")
local RunService  = game:GetService("RunService")
local TS          = game:GetService("TweenService")
local UIS         = game:GetService("UserInputService")
local Workspace    = game:GetService("Workspace")

local LP = Players.LocalPlayer
local PG = LP:WaitForChild("PlayerGui")

local NetFolder = RS:WaitForChild("Network", 30)

local EGG_STATES = {
    Slot         = "Slot",
    Carried      = "Carried",
    Dropped      = "Dropped",
    GuardCarried = "GuardCarried",
    Claimed      = "Claimed",
}

--=========================================================================
-- CONFIG / STATE
--=========================================================================

local L = {}
if type(getgenv) == "function" then
    local ok, env = pcall(getgenv)
    if ok and type(env) == "table" then
        if env.LuminosityStealer then env.LuminosityStealer.Destroy() end
        env.LuminosityStealer = L
    end
end

local CFG = {
    AutoSteal      = false,
    AutoBank       = true,   -- pivot home after a successful carry
    SkipOwnArea    = true,   -- ignore eggs sitting in your own first area
    MutatedFirst   = false,  -- sort targets by mutation count before distance
    IncludeDropped = true,   -- also grab eggs lying on the ground
    Delay          = 0.15,   -- seconds between steal attempts
    BankTimeout    = 3.0,    -- seconds to wait for the claim before moving on
    ToggleKey      = Enum.KeyCode.F,
    UIKey          = Enum.KeyCode.G,
}

local STATE = {
    running    = false,
    carrying   = false,
    carryUid   = nil,
    stolen     = 0,
    denied     = 0,
    lastMsg    = "idle",
    available  = 0,
    homeCFrame = nil,
    plotName   = nil,
}

--=========================================================================
-- NET LAYER
--=========================================================================

local Net = {}

local function endpoint(name)
    return NetFolder and NetFolder:FindFirstChild(name) or nil
end

function Net.Snapshot()
    local rf = endpoint("Eggs: RequestAreaEggSnapshot")
    if not rf then return nil end
    local ok, snap = pcall(function() return rf:InvokeServer() end)
    if ok and type(snap) == "table" and type(snap.Records) == "table" then
        return snap.Records
    end
    return nil
end

-- (ok, reason). slotKey is only meaningful for FirstAreaEgg_* uids.
function Net.Carry(uid, slotKey)
    local rf = endpoint("Eggs: RequestAreaEggCarry")
    if not rf then return false, "endpoint missing" end
    local ok, res, reason = pcall(function() return rf:InvokeServer(uid, slotKey) end)
    if not ok then return false, tostring(res) end
    return res == true, reason
end

function Net.Drop(reason)
    local rf = endpoint("Eggs: RequestAreaEggDrop")
    if not rf then return false end
    return (pcall(function() return rf:InvokeServer(reason or "PlayerRequest") end))
end

-- Server pushes carry state on every pickup / drop / claim.
do
    local ev = endpoint("Eggs: AreaEggCarryState")
    if ev then
        ev.OnClientEvent:Connect(function(payload)
            if type(payload) ~= "table" then return end
            STATE.carrying = payload.IsCarrying == true
            STATE.carryUid = payload.Uid
        end)
    end
end

--=========================================================================
-- TARGETING
--=========================================================================

local function isFirstAreaUid(uid)
    return string.find(uid, "FirstAreaEgg_", 1, true) == 1
end

local function firstAreaOwner(uid)
    local id = string.match(uid, "^FirstAreaEgg_(-?%d+)_")
    return id and tonumber(id) or nil
end

local function slotKeyFor(record)
    if isFirstAreaUid(record.Uid) then
        return string.format("%s:%s", record.AreaId, record.NestId)
    end
    return nil
end

local function rootPart()
    local char = LP.Character
    return char and char:FindFirstChild("HumanoidRootPart") or nil
end

local function eggPosition(record)
    local cf = record.BottomCFrame
    return typeof(cf) == "CFrame" and cf.Position or nil
end

-- Stealable = sitting in a nest (or dropped, if enabled) and nobody is holding it.
local function isStealable(record)
    if record.CarrierUserId ~= nil then return false end
    if record.State == EGG_STATES.Slot then
        -- fall through
    elseif record.State == EGG_STATES.Dropped and CFG.IncludeDropped then
        -- fall through
    else
        return false
    end
    if CFG.SkipOwnArea and isFirstAreaUid(record.Uid) and firstAreaOwner(record.Uid) == LP.UserId then
        return false
    end
    return eggPosition(record) ~= nil
end

local function collectTargets()
    local records = Net.Snapshot()
    if not records then return {} end

    local hrp = rootPart()
    local origin = hrp and hrp.Position or Vector3.zero

    local out = {}
    for _, record in ipairs(records) do
        if isStealable(record) then
            local pos = eggPosition(record)
            out[#out + 1] = {
                record   = record,
                distance = (pos - origin).Magnitude,
                mutations = type(record.Mutations) == "table" and #record.Mutations or 0,
            }
        end
    end

    table.sort(out, function(a, b)
        if CFG.MutatedFirst and a.mutations ~= b.mutations then
            return a.mutations > b.mutations
        end
        return a.distance < b.distance
    end)

    STATE.available = #out
    return out
end

--=========================================================================
-- MOVEMENT / BANKING
--=========================================================================

-- Your plot is the one whose sign carries your name.
local function resolveHome()
    local plots = Workspace:FindFirstChild("Plots")
    if not plots then return nil end

    for _, plot in ipairs(plots:GetChildren()) do
        local sign = plot:FindFirstChild("PlotSign")
        local gui  = sign and sign:FindFirstChild("PlayerPlotSign")
        local frame = gui and gui:FindFirstChild("Frame")
        local label = frame and frame:FindFirstChild("PlayerName")
        if label and label:IsA("TextLabel") then
            local text = label.Text
            if text == LP.DisplayName or text == LP.Name
                or string.find(text, LP.Name, 1, true)
                or string.find(text, LP.DisplayName, 1, true) then
                local anchor = plot:FindFirstChild("CenterPoint") or plot:FindFirstChild("SpawnPoint")
                if anchor and anchor:IsA("BasePart") then
                    STATE.plotName = plot.Name
                    return anchor.CFrame + Vector3.new(0, 4, 0)
                end
            end
        end
    end
    return nil
end

local function pivotTo(cframe)
    local char = LP.Character
    local hrp = rootPart()
    if not (char and hrp) then return false end
    char:PivotTo(cframe)
    hrp.AssemblyLinearVelocity = Vector3.zero
    hrp.AssemblyAngularVelocity = Vector3.zero
    return true
end

-- Land just beside the egg, facing it: inside the 8 stud prompt radius with room to spare.
local function moveToEgg(record)
    local pos = eggPosition(record)
    if not pos then return false end
    return pivotTo(CFrame.new(pos + Vector3.new(0, 3.5, 3), pos))
end

local function bank()
    if not STATE.homeCFrame then
        STATE.homeCFrame = resolveHome()
    end
    if not STATE.homeCFrame then
        STATE.lastMsg = "no plot found - bank manually"
        return false
    end

    pivotTo(STATE.homeCFrame)

    local deadline = os.clock() + CFG.BankTimeout
    while STATE.carrying and os.clock() < deadline do
        RunService.Heartbeat:Wait()
        -- nudge back if physics or a guard drags us off the plot
        pivotTo(STATE.homeCFrame)
    end
    return not STATE.carrying
end

--=========================================================================
-- STEAL ENGINE
--=========================================================================

local Notify -- forward declared, defined with the UI

local function stealOne(target)
    local record = target.record
    local origin = rootPart() and rootPart().CFrame or nil

    if not moveToEgg(record) then
        STATE.lastMsg = "no character"
        return false
    end
    RunService.Heartbeat:Wait() -- let the new position replicate before we ask

    local ok, reason = Net.Carry(record.Uid, slotKeyFor(record))

    if not ok then
        STATE.denied += 1
        STATE.lastMsg = "denied: " .. tostring(reason or "unknown")
        if origin then pivotTo(origin) end
        return false
    end

    STATE.carrying = true
    STATE.carryUid = record.Uid

    if CFG.AutoBank then
        if bank() then
            STATE.stolen += 1
            STATE.lastMsg = string.format("banked %s", record.AssetCategory or "egg")
        else
            STATE.lastMsg = "carry ok, bank timed out"
        end
    else
        STATE.stolen += 1
        STATE.lastMsg = string.format("carrying %s", record.AssetCategory or "egg")
    end

    return true
end

local function stealNearest()
    local targets = collectTargets()
    if #targets == 0 then
        STATE.lastMsg = "nothing to steal"
        return false
    end
    return stealOne(targets[1])
end

local loopThread
local function startLoop()
    if STATE.running then return end
    STATE.running = true
    STATE.homeCFrame = resolveHome()

    loopThread = task.spawn(function()
        while STATE.running do
            -- Drop whatever we are already holding only if we cannot bank it.
            if STATE.carrying and CFG.AutoBank then
                bank()
            end

            local targets = collectTargets()
            if #targets == 0 then
                STATE.lastMsg = "waiting for spawns"
                task.wait(1)
            else
                stealOne(targets[1])
                task.wait(CFG.Delay)
            end
        end
    end)
end

local function stopLoop()
    STATE.running = false
    if loopThread then
        task.cancel(loopThread)
        loopThread = nil
    end
    STATE.lastMsg = "stopped"
end

--=========================================================================
-- LUMINOSITY UI
--=========================================================================

local T = {
    VOID    = Color3.fromRGB(6, 9, 18),
    BG      = Color3.fromRGB(10, 15, 28),
    SURFACE = Color3.fromRGB(16, 24, 44),
    RAISED  = Color3.fromRGB(24, 34, 58),
    LINE    = Color3.fromRGB(38, 54, 88),
    ACCENT  = Color3.fromRGB(120, 180, 255),
    HIGH    = Color3.fromRGB(180, 220, 255),
    DEEP    = Color3.fromRGB(72, 130, 210),
    TEXT    = Color3.fromRGB(230, 240, 255),
    MUTED   = Color3.fromRGB(120, 145, 185),
    RED     = Color3.fromRGB(255, 130, 155),
    GREEN   = Color3.fromRGB(146, 255, 103),
    WHITE   = Color3.fromRGB(255, 255, 255),
}

local IS_MOBILE
do
    local platform
    pcall(function() platform = UIS:GetPlatform() end)
    IS_MOBILE = platform == Enum.Platform.IOS or platform == Enum.Platform.Android
    if platform == nil then IS_MOBILE = UIS.TouchEnabled and not UIS.MouseEnabled end
end
local PANEL_W = IS_MOBILE and 340 or 420

local function New(cls, props, kids)
    local i = Instance.new(cls)
    for k, v in pairs(props or {}) do i[k] = v end
    for _, c in ipairs(kids or {}) do c.Parent = i end
    return i
end
local function Corner(p, r) return New("UICorner", {CornerRadius = UDim.new(0, r or 10), Parent = p}) end
local function Pad(p, a, b, c, d)
    return New("UIPadding", {
        PaddingTop = UDim.new(0, a or 0), PaddingBottom = UDim.new(0, b or a or 0),
        PaddingLeft = UDim.new(0, c or a or 0), PaddingRight = UDim.new(0, d or c or a or 0),
        Parent = p,
    })
end
local function Stroke(p, col, th, tr)
    return New("UIStroke", {
        Color = col or T.LINE, Thickness = th or 1, Transparency = tr or 0.4,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = p,
    })
end
local function tw(obj, time, style, dir, goal)
    return TS:Create(obj, TweenInfo.new(time, style or Enum.EasingStyle.Quart, dir or Enum.EasingDirection.Out), goal)
end

local Gui = New("ScreenGui", {
    Name = "LuminosityStealer",
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    DisplayOrder = 9999,
})
pcall(function() Gui.Parent = gethui and gethui() or PG end)
if not Gui.Parent then Gui.Parent = PG end

local Panel = New("Frame", {
    Size = UDim2.fromOffset(PANEL_W, 476),
    Position = UDim2.new(0.5, -(PANEL_W / 2), 0.5, -238),
    BackgroundColor3 = T.SURFACE,
    BorderSizePixel = 0,
    Parent = Gui,
})
Corner(Panel, 16); Pad(Panel, 16)
Stroke(Panel, T.LINE, 1, 0.4)

local PanelGrad = New("UIGradient", {
    Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, T.SURFACE),
        ColorSequenceKeypoint.new(0.5, T.SURFACE:Lerp(T.DEEP, 0.35)),
        ColorSequenceKeypoint.new(1, T.SURFACE),
    }),
    Rotation = 20, Parent = Panel,
})
task.spawn(function()
    while Panel.Parent do
        TS:Create(PanelGrad, TweenInfo.new(6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {Rotation = 200}):Play()
        task.wait(6)
        TS:Create(PanelGrad, TweenInfo.new(6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {Rotation = 20}):Play()
        task.wait(6)
    end
end)

-- Header ------------------------------------------------------------------
local Header = New("Frame", {Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1, Parent = Panel})
local Handle = New("TextButton", {
    Size = UDim2.new(1, -60, 1, 0), BackgroundTransparency = 1,
    AutoButtonColor = false, Text = "", Parent = Header,
})

local Dot = New("Frame", {
    Size = UDim2.fromOffset(8, 8), Position = UDim2.new(0, 0, 0.5, -4),
    BackgroundColor3 = T.MUTED, BorderSizePixel = 0, Parent = Handle,
})
Corner(Dot, 4)

local Brand = New("TextLabel", {
    Size = UDim2.new(1, -18, 1, 0), Position = UDim2.fromOffset(16, 0),
    BackgroundTransparency = 1, Text = "LUMINOSITY  //  STEALER",
    TextColor3 = T.HIGH, Font = Enum.Font.GothamBold, TextSize = 12,
    TextXAlignment = Enum.TextXAlignment.Left, Parent = Handle,
})
local BrandGrad = New("UIGradient", {
    Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, T.HIGH),
        ColorSequenceKeypoint.new(0.45, T.HIGH),
        ColorSequenceKeypoint.new(0.5, T.WHITE),
        ColorSequenceKeypoint.new(0.55, T.HIGH),
        ColorSequenceKeypoint.new(1, T.HIGH),
    }),
    Offset = Vector2.new(-1, 0), Parent = Brand,
})
task.spawn(function()
    while Brand.Parent do
        task.wait(4)
        BrandGrad.Offset = Vector2.new(-1, 0)
        TS:Create(BrandGrad, TweenInfo.new(1.1, Enum.EasingStyle.Sine), {Offset = Vector2.new(1, 0)}):Play()
    end
end)

local function headerButton(offsetX, glyph)
    local b = New("TextButton", {
        Size = UDim2.fromOffset(24, 22), Position = UDim2.new(1, offsetX, 0, 0),
        BackgroundColor3 = T.RAISED, AutoButtonColor = false, Text = glyph,
        TextColor3 = T.MUTED, Font = Enum.Font.GothamBold, TextSize = 12,
        Parent = Header,
    })
    Corner(b, 7)
    return b
end
local MinBtn   = headerButton(-52, "-")
local CloseBtn = headerButton(-24, "x")

-- Body --------------------------------------------------------------------
local Body = New("ScrollingFrame", {
    Size = UDim2.new(1, 0, 1, -30),
    Position = UDim2.fromOffset(0, 30),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ScrollBarThickness = 2,
    ScrollBarImageColor3 = T.LINE,
    CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    Parent = Panel,
})
New("UIListLayout", {Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = Body})

local order = 0
local function nextOrder() order += 1; return order end

local function makeRow(height)
    local box = New("Frame", {
        Size = UDim2.new(1, -4, 0, height),
        BackgroundColor3 = T.RAISED,
        LayoutOrder = nextOrder(), Parent = Body,
    })
    Corner(box, 12)
    Stroke(box, T.LINE, 1, 0.5)
    return box
end

local function rowLabel(box, text)
    return New("TextLabel", {
        Size = UDim2.new(1, -140, 1, 0), Position = UDim2.fromOffset(12, 0),
        BackgroundTransparency = 1, Text = text,
        TextColor3 = T.MUTED, Font = Enum.Font.GothamSemibold, TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left, Parent = box,
    })
end

local function makeToggle(label, get, set)
    local box = makeRow(50)
    local lbl = rowLabel(box, label)
    local sw = New("TextButton", {
        Size = UDim2.fromOffset(48, 26), Position = UDim2.new(1, -62, 0.5, -13),
        BackgroundColor3 = T.SURFACE, AutoButtonColor = false, Text = "", Parent = box,
    })
    Corner(sw, 13)
    local swStroke = Stroke(sw, T.LINE, 1, 0.5)
    local knob = New("Frame", {
        Size = UDim2.fromOffset(18, 18), Position = UDim2.new(0, 4, 0.5, -9),
        BackgroundColor3 = T.MUTED, BorderSizePixel = 0, Parent = sw,
    })
    Corner(knob, 9)

    local function paint(on)
        tw(sw, 0.18, nil, nil, {BackgroundColor3 = on and T.ACCENT or T.SURFACE}):Play()
        tw(swStroke, 0.18, nil, nil, {Color = on and T.HIGH or T.LINE}):Play()
        TS:Create(knob, TweenInfo.new(0.26, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
            Position = on and UDim2.new(1, -22, 0.5, -9) or UDim2.new(0, 4, 0.5, -9),
            BackgroundColor3 = on and T.WHITE or T.MUTED,
        }):Play()
        tw(lbl, 0.18, nil, nil, {TextColor3 = on and T.TEXT or T.MUTED}):Play()
    end

    sw.MouseButton1Click:Connect(function()
        local on = not get()
        set(on)
        paint(on)
        Notify(label .. (on and " on" or " off"), on and T.GREEN or T.MUTED)
    end)
    paint(get())
    return paint
end

local function makeStepper(label, get, set, min, max, step, fmt)
    local box = makeRow(50)
    rowLabel(box, label)

    local count = New("TextLabel", {
        Size = UDim2.fromOffset(52, 28), Position = UDim2.new(1, -80, 0.5, -14),
        BackgroundTransparency = 1, Text = fmt(get()),
        TextColor3 = T.TEXT, Font = Enum.Font.GothamBold, TextSize = 12, Parent = box,
    })

    local function bump(dir)
        local v = math.clamp(get() + dir * step, min, max)
        v = math.floor(v * 100 + 0.5) / 100
        set(v)
        count.Text = fmt(v)
    end

    local minus = New("TextButton", {
        Size = UDim2.fromOffset(28, 28), Position = UDim2.new(1, -112, 0.5, -14),
        BackgroundColor3 = T.SURFACE, AutoButtonColor = false, Text = "-",
        TextColor3 = T.HIGH, Font = Enum.Font.GothamBold, TextSize = 16, Parent = box,
    })
    Corner(minus, 7)
    local plus = New("TextButton", {
        Size = UDim2.fromOffset(28, 28), Position = UDim2.new(1, -30, 0.5, -14),
        BackgroundColor3 = T.SURFACE, AutoButtonColor = false, Text = "+",
        TextColor3 = T.HIGH, Font = Enum.Font.GothamBold, TextSize = 16, Parent = box,
    })
    Corner(plus, 7)

    minus.MouseButton1Click:Connect(function() bump(-1) end)
    plus.MouseButton1Click:Connect(function() bump(1) end)
end

local function makeButton(label, tint, onClick)
    local btn = New("TextButton", {
        Size = UDim2.new(1, -4, 0, 42), BackgroundColor3 = T.RAISED,
        AutoButtonColor = false, Text = label, TextColor3 = tint or T.HIGH,
        Font = Enum.Font.GothamBold, TextSize = 13,
        LayoutOrder = nextOrder(), Parent = Body,
    })
    Corner(btn, 12)
    Stroke(btn, T.LINE, 1, 0.5)
    btn.MouseEnter:Connect(function()
        tw(btn, 0.15, nil, nil, {BackgroundColor3 = T.RAISED:Lerp(tint or T.ACCENT, 0.18)}):Play()
    end)
    btn.MouseLeave:Connect(function()
        tw(btn, 0.2, nil, nil, {BackgroundColor3 = T.RAISED}):Play()
    end)
    btn.MouseButton1Down:Connect(function(x, y)
        local abs = btn.AbsolutePosition
        local size = math.max(btn.AbsoluteSize.X, btn.AbsoluteSize.Y) * 2
        local r = New("Frame", {
            Size = UDim2.fromOffset(0, 0),
            Position = UDim2.fromOffset(x - abs.X, y - abs.Y),
            AnchorPoint = Vector2.new(0.5, 0.5),
            BackgroundColor3 = tint or T.WHITE, BackgroundTransparency = 0.75,
            BorderSizePixel = 0, ZIndex = 10, Parent = btn,
        })
        Corner(r, 999)
        tw(r, 0.45, Enum.EasingStyle.Quad, nil, {Size = UDim2.fromOffset(size, size), BackgroundTransparency = 1}):Play()
        task.delay(0.5, function() r:Destroy() end)
    end)
    btn.MouseButton1Click:Connect(onClick)
    return btn
end

-- Status card -------------------------------------------------------------
local StatusBox = makeRow(76)
local StatusMain = New("TextLabel", {
    Size = UDim2.new(1, -24, 0, 20), Position = UDim2.fromOffset(12, 12),
    BackgroundTransparency = 1, Text = "idle",
    TextColor3 = T.TEXT, Font = Enum.Font.GothamBold, TextSize = 13,
    TextXAlignment = Enum.TextXAlignment.Left, Parent = StatusBox,
})
local StatusSub = New("TextLabel", {
    Size = UDim2.new(1, -24, 0, 16), Position = UDim2.fromOffset(12, 34),
    BackgroundTransparency = 1, Text = "",
    TextColor3 = T.MUTED, Font = Enum.Font.Gotham, TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Left, Parent = StatusBox,
})
local StatusPlot = New("TextLabel", {
    Size = UDim2.new(1, -24, 0, 14), Position = UDim2.fromOffset(12, 52),
    BackgroundTransparency = 1, Text = "",
    TextColor3 = T.MUTED, Font = Enum.Font.Gotham, TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left, Parent = StatusBox,
})

-- Notifications -----------------------------------------------------------
local NotifRoot = New("Frame", {
    Size = UDim2.fromOffset(300, 200),
    Position = UDim2.new(1, -316, 1, -216),
    BackgroundTransparency = 1, Parent = Gui,
})
New("UIListLayout", {
    Padding = UDim.new(0, 6),
    VerticalAlignment = Enum.VerticalAlignment.Bottom,
    SortOrder = Enum.SortOrder.LayoutOrder, Parent = NotifRoot,
})

function Notify(text, color)
    local card = New("Frame", {
        Size = UDim2.new(1, 0, 0, 34), BackgroundColor3 = T.RAISED,
        BackgroundTransparency = 1, BorderSizePixel = 0, Parent = NotifRoot,
    })
    Corner(card, 10)
    local stroke = Stroke(card, color or T.ACCENT, 1, 1)
    local lbl = New("TextLabel", {
        Size = UDim2.new(1, -20, 1, 0), Position = UDim2.fromOffset(12, 0),
        BackgroundTransparency = 1, Text = text,
        TextColor3 = color or T.TEXT, Font = Enum.Font.GothamSemibold, TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left, TextTransparency = 1, Parent = card,
    })
    tw(card, 0.2, nil, nil, {BackgroundTransparency = 0.1}):Play()
    tw(stroke, 0.2, nil, nil, {Transparency = 0.4}):Play()
    tw(lbl, 0.2, nil, nil, {TextTransparency = 0}):Play()
    task.delay(2.6, function()
        tw(card, 0.25, nil, nil, {BackgroundTransparency = 1}):Play()
        tw(stroke, 0.25, nil, nil, {Transparency = 1}):Play()
        tw(lbl, 0.25, nil, nil, {TextTransparency = 1}):Play()
        task.delay(0.3, function() card:Destroy() end)
    end)
end

-- Controls ----------------------------------------------------------------
local paintAuto = makeToggle("Auto steal", function() return CFG.AutoSteal end, function(v)
    CFG.AutoSteal = v
    if v then startLoop() else stopLoop() end
end)

makeToggle("Auto bank to plot", function() return CFG.AutoBank end, function(v) CFG.AutoBank = v end)
makeToggle("Prefer mutated", function() return CFG.MutatedFirst end, function(v) CFG.MutatedFirst = v end)
makeToggle("Include dropped eggs", function() return CFG.IncludeDropped end, function(v) CFG.IncludeDropped = v end)
makeToggle("Skip my own area", function() return CFG.SkipOwnArea end, function(v) CFG.SkipOwnArea = v end)

makeStepper("Steal delay", function() return CFG.Delay end, function(v) CFG.Delay = v end,
    0.05, 2, 0.05, function(v) return string.format("%.2fs", v) end)

makeStepper("Bank timeout", function() return CFG.BankTimeout end, function(v) CFG.BankTimeout = v end,
    1, 10, 0.5, function(v) return string.format("%.1fs", v) end)

makeButton("STEAL NEAREST", T.ACCENT, function()
    task.spawn(function()
        local ok = stealNearest()
        Notify(ok and "stole one" or STATE.lastMsg, ok and T.GREEN or T.RED)
    end)
end)

makeButton("BANK NOW", T.HIGH, function()
    task.spawn(function()
        local ok = bank()
        Notify(ok and "banked" or STATE.lastMsg, ok and T.GREEN or T.RED)
    end)
end)

makeButton("DROP EGG", T.RED, function()
    Net.Drop("PlayerRequest")
    Notify("dropped", T.MUTED)
end)

makeButton("RELOCATE PLOT", T.MUTED, function()
    STATE.homeCFrame = resolveHome()
    Notify(STATE.homeCFrame and ("plot " .. tostring(STATE.plotName)) or "plot not found",
        STATE.homeCFrame and T.GREEN or T.RED)
end)

-- Live status -------------------------------------------------------------
task.spawn(function()
    while Gui.Parent do
        collectTargets()
        StatusMain.Text = STATE.running and "auto stealing" or (STATE.carrying and "carrying" or "idle")
        StatusMain.TextColor3 = STATE.running and T.GREEN or T.TEXT
        StatusSub.Text = string.format("stolen %d   denied %d   available %d", STATE.stolen, STATE.denied, STATE.available)
        StatusPlot.Text = string.format("plot: %s   |   %s", tostring(STATE.plotName or "?"), STATE.lastMsg)
        tw(Dot, 0.3, nil, nil, {BackgroundColor3 = STATE.running and T.GREEN or T.MUTED}):Play()
        task.wait(0.5)
    end
end)

--=========================================================================
-- WINDOW BEHAVIOUR
--=========================================================================

do -- drag
    local dragging, dragStart, startPos
    Handle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = Panel.Position
        end
    end)
    UIS.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch then
            local d = input.Position - dragStart
            Panel.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
                                       startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
    UIS.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
end

local minimized = false
MinBtn.MouseButton1Click:Connect(function()
    minimized = not minimized
    Body.Visible = not minimized
    tw(Panel, 0.25, Enum.EasingStyle.Quart, nil, {
        Size = UDim2.fromOffset(PANEL_W, minimized and 54 or 476),
    }):Play()
end)

function L.Destroy()
    stopLoop()
    pcall(function() Gui:Destroy() end)
end
CloseBtn.MouseButton1Click:Connect(L.Destroy)

UIS.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == CFG.ToggleKey then
        CFG.AutoSteal = not CFG.AutoSteal
        paintAuto(CFG.AutoSteal)
        if CFG.AutoSteal then startLoop() else stopLoop() end
        Notify("auto steal " .. (CFG.AutoSteal and "on" or "off"), CFG.AutoSteal and T.GREEN or T.MUTED)
    elseif input.KeyCode == CFG.UIKey then
        Panel.Visible = not Panel.Visible
    end
end)

LP.CharacterAdded:Connect(function()
    task.wait(1.5)
    STATE.homeCFrame = resolveHome()
    STATE.carrying = false
end)

--=========================================================================
-- BOOT
--=========================================================================

L.Config = CFG
L.State = STATE
L.StealNearest = stealNearest
L.Start = startLoop
L.Stop = stopLoop
L.Bank = bank

STATE.homeCFrame = resolveHome()
Notify(STATE.homeCFrame and ("linked - plot " .. tostring(STATE.plotName)) or "linked - plot not found",
    STATE.homeCFrame and T.GREEN or T.RED)
