do
-- Minimal Roblox stub so LUCK.lua can actually run outside a client.
-- Enough surface for the engine (services, instances, signals, remotes);
-- the UI is wrapped in pcall inside the script, so gaps there are harmless.

local function Signal()
    local s = {handlers = {}}
    function s:Connect(fn)
        table.insert(self.handlers, fn)
        local c = {Connected = true, Function = fn, Enabled = true}
        function c:Disable() c.Enabled = false end
        function c:Enable() c.Enabled = true end
        s.conns = s.conns or {}
        table.insert(s.conns, c)
        c._signal = s
        function c:Disconnect()
            c.Connected = false
            for i, h in ipairs(s.handlers) do
                if h == fn then table.remove(s.handlers, i) break end
            end
            for i, other in ipairs(s.conns or {}) do
                if other == c then table.remove(s.conns, i) break end
            end
        end
        return c
    end
    function s:Wait() end
    function s:Fire(...)
        for _, c in ipairs(self.conns or {}) do
            if c.Enabled then c.Function(...) end
        end
    end
    return s
end

local INSTANCE_MT
local function newInstance(class, name)
    local props = {
        ClassName = class,
        Name = name or class,
        Parent = nil,
        Text = "",
        Visible = true,
        Active = true,
        _children = {},
        _signals = {},
    }
    return setmetatable(props, INSTANCE_MT)
end

local instanceMethods = {}
INSTANCE_MT = {
    __index = function(t, k)
        local m = instanceMethods[k]
        if m then return m end
        -- Unknown property: hand back a signal-ish stub so UI code survives.
        local sig = rawget(t, "_signals")[k]
        if sig then return sig end
        return nil
    end,
    __newindex = function(t, k, v) rawset(t, k, v) end,
    __tostring = function(t) return rawget(t, "Name") end,
}

function instanceMethods:IsA(class)
    local c = rawget(self, "ClassName")
    if c == class then return true end
    if class == "GuiObject" or class == "Instance" then return true end
    return false
end
function instanceMethods:FindFirstChild(name, recursive)
    for _, c in ipairs(rawget(self, "_children")) do
        if rawget(c, "Name") == name then return c end
    end
    if recursive then
        for _, c in ipairs(rawget(self, "_children")) do
            local hit = c:FindFirstChild(name, true)
            if hit then return hit end
        end
    end
    return nil
end
function instanceMethods:GetChildren()
    return rawget(self, "_children")
end
function instanceMethods:GetDescendants()
    local out = {}
    local function walk(node)
        for _, c in ipairs(rawget(node, "_children")) do
            out[#out + 1] = c
            walk(c)
        end
    end
    walk(self)
    return out
end
function instanceMethods:WaitForChild(name)
    return self:FindFirstChild(name) or self:_add(newInstance("Folder", name))
end
function instanceMethods:GetPropertyChangedSignal(prop)
    local sigs = rawget(self, "_signals")
    sigs[prop] = sigs[prop] or Signal()
    return sigs[prop]
end
function instanceMethods:Destroy() end
function instanceMethods:Clone() return newInstance(rawget(self, "ClassName")) end
function instanceMethods:_add(child)
    table.insert(rawget(self, "_children"), child)
    rawset(child, "Parent", self)
    return child
end

-- Signals every instance is expected to expose.
local function withSignals(inst, ...)
    local sigs = rawget(inst, "_signals")
    for _, n in ipairs({...}) do sigs[n] = Signal() end
    return inst
end

-- ── services ──────────────────────────────────────────────────────────────
local RepS = newInstance("ReplicatedStorage", "ReplicatedStorage")
withSignals(RepS, "DescendantAdded", "AttributeChanged")
function RepS:GetAttribute() return nil end

-- The two remotes the script resolves by direct name (modded-place path).
local redeem = newInstance("RemoteFunction", "RF/RequestRedemption")
local notify = newInstance("RemoteEvent", "RE/NotificationService/Notify")
withSignals(notify, "OnClientEvent")
RepS:_add(redeem)
RepS:_add(notify)

local early = newInstance("RemoteEvent", "RE/CodeService/Sync")
withSignals(early, "OnClientEvent")
RepS:_add(early)
EARLY_REMOTE = early

local codeValue = newInstance("StringValue", "ActiveCode")
rawset(codeValue, "Value", "")
withSignals(codeValue, "Changed")
RepS:_add(codeValue)
CODE_VALUE = codeValue

local SENT = {}
LAST_SEND_AT = 0
function redeem:InvokeServer(code)
    LAST_SEND_AT = os.clock()
    SENT[#SENT + 1] = {code = code, at = LAST_SEND_AT}
    -- A non-string argument is legal over a real remote: it serialises and
    -- the server rejects it. Erroring here would be the stub inventing a
    -- failure the live game does not have.
    if type(code) ~= "string" then return false, "Invalid Code" end
    if string.find(code, "[^%w]") then return false, "Invalid Code" end
    return true, "REDEEMED"
end

local PlayerGui = newInstance("PlayerGui", "PlayerGui")
withSignals(PlayerGui, "DescendantAdded", "ChildAdded")

local LocalPlayer = newInstance("Player", "tester")
rawset(LocalPlayer, "UserId", 1)
rawset(LocalPlayer, "DisplayName", "tester")
LocalPlayer:_add(PlayerGui)

local Players = newInstance("Players", "Players")
rawset(Players, "LocalPlayer", LocalPlayer)
function Players:GetPlayers() return {LocalPlayer} end

local RunS = newInstance("RunService", "RunService")
rawset(RunS, "Heartbeat", Signal())
function RunS:Set3dRenderingEnabled() end

local UIS = newInstance("UserInputService", "UserInputService")
rawset(UIS, "TouchEnabled", false)
rawset(UIS, "MouseEnabled", true)
withSignals(UIS, "InputBegan")
function UIS:GetPlatform() return "Windows" end

local TS = newInstance("TweenService", "TweenService")
function TS:Create() return {Play = function() end, Completed = Signal()} end

local HttpService = newInstance("HttpService", "HttpService")
function HttpService:JSONEncode() return "{}" end
function HttpService:JSONDecode() return {} end
function HttpService:GenerateGUID() return "guid" end

local services = {
    Players = Players, UserInputService = UIS, TweenService = TS,
    HttpService = HttpService, ReplicatedStorage = RepS, RunService = RunS,
    CoreGui = newInstance("CoreGui", "CoreGui"),
    Lighting = newInstance("Lighting", "Lighting"),
    TextService = newInstance("TextService", "TextService"),
}

game = setmetatable({PlaceId = 1}, {
    __index = function(_, k)
        if k == "GetService" then
            return function(_, name)
                services[name] = services[name] or newInstance(name, name)
                return services[name]
            end
        end
        return services[k]
    end,
})

workspace = newInstance("Workspace", "Workspace")
rawset(workspace, "CurrentCamera", {ViewportSize = {X = 1920, Y = 1080}})
rawset(workspace, "SignalBehavior", "Deferred")

-- ── datatypes ─────────────────────────────────────────────────────────────
local auto
auto = setmetatable({}, {__index = function() return auto end,
                        __call = function() return auto end,
                        __tostring = function() return "Enum.Stub" end})
Enum = auto
Color3 = {fromRGB = function() return {R = 0, G = 0, B = 0} end,
          fromHSV = function() return {R = 0, G = 0, B = 0} end,
          new = function() return {R = 0, G = 0, B = 0} end}
UDim2 = {new = function() return {} end, fromScale = function() return {} end,
         fromOffset = function() return {} end}
UDim = {new = function() return {} end}
Vector2 = {new = function() return {} end}
Vector3 = {new = function() return {} end}
ColorSequence = {new = function() return {} end}
ColorSequenceKeypoint = {new = function() return {} end}
NumberSequence = {new = function() return {} end}
NumberSequenceKeypoint = {new = function() return {} end}
TweenInfo = {new = function() return {} end}
Rect = {new = function() return {} end}

Instance = {new = function(class, parent)
    local i = newInstance(class)
    withSignals(i, "Activated", "MouseButton1Click", "MouseButton1Down",
        "MouseButton1Up", "MouseEnter", "MouseLeave", "InputBegan", "InputEnded",
        "InputChanged", "AncestryChanged", "DescendantAdded", "ChildAdded",
        "Changed", "FocusLost", "Destroying")
    if parent then parent:_add(i) end
    return i
end}

local realType = type
function typeof(v)
    if realType(v) == "table" and getmetatable(v) == INSTANCE_MT then
        return "Instance"
    end
    return realType(v)
end

-- ── task ──────────────────────────────────────────────────────────────────
local pending = {}
task = {
    spawn = function(fn, ...)
        local co = coroutine.create(realType(fn) == "function" and fn or function() end)
        coroutine.resume(co, ...)
        return co
    end,
    defer = function(fn, ...) pending[#pending + 1] = {fn, table.pack(...)} end,
    delay = function(_, fn, ...) pending[#pending + 1] = {fn, table.pack(...)} end,
    wait = function() coroutine.yield() return 0 end,
}
local function flush()
    for _ = 1, 12 do
        local batch = pending
        pending = {}
        if #batch == 0 then return end
        for _, item in ipairs(batch) do
            pcall(item[1], table.unpack(item[2], 1, item[2].n))
        end
    end
end


warn = print
function getconnections(sig)
    return sig.conns or {}
end
FPSCAP = nil
function setfpscap(n) FPSCAP = n end
function settings() return {Rendering = {QualityLevel = 1}} end
GENV = {}
function getgenv() return GENV end
SENT_LOG = SENT
NOTIFY_REMOTE = notify
FLUSH = flush
REDEEM_REMOTE = redeem
EARLY = EARLY_REMOTE
CODEVAL = CODE_VALUE
end
