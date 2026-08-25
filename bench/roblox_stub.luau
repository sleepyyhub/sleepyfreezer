-- Minimal Roblox surface, enough to load LUCK and fire real announcements at it.
-- Scheduling is virtual (so 30s janitor loops do not actually wait); os.clock stays
-- real, because that is what the measurement reads.

local H = {}

------------------------------------------------------------------ scheduler
local deferQ, timerQ, vnow = {}, {}, 0
local threads = 0

local function pushTimer(at, fn, args)
    timerQ[#timerQ + 1] = {at = at, fn = fn, args = args}
end

local function resume(co, ...)
    local ok, err = coroutine.resume(co, ...)
    if not ok then
        H.errors = H.errors or {}
        H.errors[#H.errors + 1] = tostring(err)
    end
end

local task = {}
function task.spawn(f, ...)
    local co = type(f) == "thread" and f or coroutine.create(f)
    threads += 1
    resume(co, ...)
    return co
end
function task.defer(f, ...)
    deferQ[#deferQ + 1] = {f = f, args = table.pack(...)}
    return f
end
function task.delay(t, f, ...)
    pushTimer(vnow + (tonumber(t) or 0), f, table.pack(...))
    return f
end
function task.wait(t)
    local co = coroutine.running()
    pushTimer(vnow + (tonumber(t) or 0), co, nil)
    return coroutine.yield()
end
function task.cancel() end
H.task = task

-- Pump the scheduler. Bounded so a while-true loop cannot hang the run.
function H.pump(maxSteps, untilTime)
    maxSteps = maxSteps or 20000
    for _ = 1, maxSteps do
        if #deferQ > 0 then
            local q = deferQ
            deferQ = {}
            for i = 1, #q do
                local item = q[i]
                if type(item.f) == "thread" then resume(item.f, table.unpack(item.args, 1, item.args.n))
                else task.spawn(item.f, table.unpack(item.args, 1, item.args.n)) end
            end
        elseif #timerQ > 0 then
            local best, bi = nil, nil
            for i = 1, #timerQ do
                if not best or timerQ[i].at < best.at then best, bi = timerQ[i], i end
            end
            if untilTime and best.at > untilTime then vnow = untilTime return end
            table.remove(timerQ, bi)
            vnow = best.at
            if type(best.fn) == "thread" then
                resume(best.fn)
            elseif best.args then
                -- NOT `best.args and table.unpack(...)`: `and` truncates a multi-value
                -- expression to its first value, which silently drops every argument
                -- after the first.
                task.spawn(best.fn, table.unpack(best.args, 1, best.args.n))
            else
                task.spawn(best.fn)
            end
        else
            return
        end
    end
end
function H.virtualNow() return vnow end

------------------------------------------------------------------ signals
local Signal = {}
Signal.__index = Signal
local function newSignal()
    return setmetatable({conns = {}}, Signal)
end
function Signal:Connect(fn)
    local c = {Function = fn, _enabled = true, _sig = self}
    function c:Disconnect()
        for i, v in ipairs(self._sig.conns) do
            if v == self then table.remove(self._sig.conns, i) break end
        end
    end
    function c:Disable() self._enabled = false end
    function c:Enable() self._enabled = true end
    self.conns[#self.conns + 1] = c
    return c
end
Signal.connect = Signal.Connect
function Signal:Once(fn) return self:Connect(fn) end
function Signal:Wait() task.wait(0) end
function Signal:Fire(...)
    local snapshot = table.clone(self.conns)
    for i = 1, #snapshot do
        local c = snapshot[i]
        if c._enabled then
            -- Roblox runs each handler in its own thread; a yield in one does not
            -- block the others. Same here.
            task.spawn(c.Function, ...)
        end
    end
end
-- Fire the first enabled handler synchronously on THIS thread, so a measurement can
-- time detect -> send without the scheduler in between. Timing only: it models WHO
-- RUNS FIRST, not what a real client does.
function Signal:FireDirect(...)
    for i = 1, #self.conns do
        local c = self.conns[i]
        if c._enabled then return c.Function(...) end
    end
end

-- What a real client actually does: every enabled handler runs. Correctness tests use
-- this; using FireDirect for them measures connection order, not behaviour.
function Signal:FireAll(...)
    local snapshot = table.clone(self.conns)
    for i = 1, #snapshot do
        local c = snapshot[i]
        if c._enabled then pcall(c.Function, ...) end
    end
end
H.newSignal = newSignal

------------------------------------------------------------------ instances
local Instance = {}
local instMT = {}

local CLASS_KIN = {
    RemoteEvent = {"RemoteEvent"},
    RemoteFunction = {"RemoteFunction"},
    Folder = {"Folder"},
    TextLabel = {"TextLabel", "GuiObject", "GuiBase2d"},
    TextButton = {"TextButton", "GuiObject", "GuiBase2d"},
    TextBox = {"TextBox", "GuiObject", "GuiBase2d"},
    Frame = {"Frame", "GuiObject", "GuiBase2d"},
    ScrollingFrame = {"ScrollingFrame", "GuiObject", "GuiBase2d"},
    ScreenGui = {"ScreenGui", "LayerCollector"},
    StringValue = {"StringValue"},
}

local function newInstance(class, name)
    local self = {}
    local props = {
        Name = name or class,
        ClassName = class,
        Parent = nil,
        Text = "",
        Active = true,
        TextEditable = true,
        Visible = true,
        LayoutOrder = 0,
    }
    local children, signals = {}, {}
    local attributes = {}

    local function sig(key)
        if not signals[key] then signals[key] = newSignal() end
        return signals[key]
    end

    self._props, self._children, self._sig = props, children, sig

    function self:IsA(want)
        local kin = CLASS_KIN[props.ClassName]
        if kin then
            for _, k in ipairs(kin) do if k == want then return true end end
        end
        return props.ClassName == want
    end
    function self:GetChildren() return table.clone(children) end
    function self:GetDescendants()
        local out = {}
        local function walk(node)
            for _, c in ipairs(node._children) do
                out[#out + 1] = c
                walk(c)
            end
        end
        walk(self)
        return out
    end
    function self:FindFirstChild(n, recursive)
        for _, c in ipairs(children) do if c.Name == n then return c end end
        if recursive then
            for _, c in ipairs(children) do
                local hit = c:FindFirstChild(n, true)
                if hit then return hit end
            end
        end
        return nil
    end
    function self:WaitForChild(n) return self:FindFirstChild(n) end
    function self:GetPropertyChangedSignal(k) return sig("prop:" .. k) end
    function self:GetAttribute(k) return attributes[k] end
    function self:SetAttribute(k, v) attributes[k] = v end
    function self:Destroy()
        if props.Parent then
            local p = props.Parent._children
            for i, c in ipairs(p) do if c == self then table.remove(p, i) break end end
        end
        props.Parent = nil
    end
    function self:IsDescendantOf(other)
        local p = props.Parent
        while p do
            if p == other then return true end
            p = p._props and p._props.Parent
        end
        return false
    end
    function self:Clone() return newInstance(props.ClassName, props.Name) end
    function self:CaptureFocus() end

    -- remote surface
    if class == "RemoteEvent" then
        self.OnClientEvent = sig("OnClientEvent")
        function self:FireServer(...) return H.onFireServer(self, ...) end
    elseif class == "RemoteFunction" then
        function self:InvokeServer(...) return H.onInvokeServer(self, ...) end
    end

    self.ChildAdded = sig("ChildAdded")
    self.DescendantAdded = sig("DescendantAdded")
    self.AncestryChanged = sig("AncestryChanged")
    self.AttributeChanged = sig("AttributeChanged")
    self.Activated = sig("Activated")
    self.MouseButton1Click = sig("MouseButton1Click")
    self.MouseEnter = sig("MouseEnter")
    self.MouseLeave = sig("MouseLeave")
    self.InputBegan = sig("InputBegan")
    self.FocusLost = sig("FocusLost")
    self.Changed = sig("Changed")

    return setmetatable(self, {
        __index = function(t, k) return props[k] end,
        __newindex = function(t, k, v)
            local old = props[k]
            props[k] = v
            if k == "Parent" then
                if v and v._children then
                    v._children[#v._children + 1] = t
                    v.ChildAdded:Fire(t)
                    local node = v
                    while node do
                        if node.DescendantAdded then node.DescendantAdded:Fire(t) end
                        node = node._props and node._props.Parent
                    end
                end
                t.AncestryChanged:Fire(t, v)
            elseif old ~= v and signals["prop:" .. k] then
                signals["prop:" .. k]:Fire()
            end
        end,
    })
end
H.newInstance = newInstance
Instance.new = function(class, parent)
    local i = newInstance(class)
    if parent then i.Parent = parent end
    return i
end
H.Instance = Instance

------------------------------------------------------------------ datatypes
local function passthru(name)
    return setmetatable({}, {__index = function(_, k)
        return function(...) return {__t = name, k, ...} end
    end, __call = function(_, ...) return {__t = name, ...} end})
end

local Enum = setmetatable({}, {__index = function(t, cat)
    local e = setmetatable({}, {__index = function(_, k)
        return setmetatable({}, {__tostring = function()
            return ("Enum.%s.%s"):format(cat, k)
        end})
    end})
    rawset(t, cat, e)
    return e
end})
H.Enum = Enum

local function udim2(xs, xo, ys, yo)
    return {X = {Scale = xs or 0, Offset = xo or 0},
            Y = {Scale = ys or 0, Offset = yo or 0}}
end
H.UDim2 = {new = udim2, fromScale = udim2, fromOffset = function(x, y) return udim2(0, x, 0, y) end}
H.UDim = {new = function(s, o) return {Scale = s, Offset = o} end}

local Color3 = {}
Color3.fromRGB = function(r, g, b)
    local c = {R = (r or 0) / 255, G = (g or 0) / 255, B = (b or 0) / 255}
    function c:Lerp() return c end
    return c
end
Color3.new = function(r, g, b)
    local c = {R = r or 0, G = g or 0, B = b or 0}
    function c:Lerp() return c end
    return c
end
H.Color3 = Color3

H.Vector2 = {new = function(x, y) return {X = x or 0, Y = y or 0} end}
H.ColorSequence = passthru("ColorSequence")
H.NumberSequence = passthru("NumberSequence")
H.ColorSequenceKeypoint = passthru("ColorSequenceKeypoint")
H.NumberSequenceKeypoint = passthru("NumberSequenceKeypoint")
H.TweenInfo = passthru("TweenInfo")

function H.typeof(v)
    if type(v) == "table" then
        if v._props then return "Instance" end
        if v.__t then return v.__t end
    end
    return type(v)
end

return H
