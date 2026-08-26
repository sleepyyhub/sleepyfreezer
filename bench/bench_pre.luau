do
-- Load LUCK against a fake Roblox client and time detect -> send for real.
local H = require("./roblox_stub")


----------------------------------------------------------------- globals
task     = H.task
Enum     = H.Enum
Instance = H.Instance
UDim2    = H.UDim2
UDim     = H.UDim
Color3   = H.Color3
Vector2  = H.Vector2
ColorSequence         = H.ColorSequence
NumberSequence        = H.NumberSequence
ColorSequenceKeypoint = H.ColorSequenceKeypoint
NumberSequenceKeypoint= H.NumberSequenceKeypoint
TweenInfo             = H.TweenInfo
typeof   = H.typeof
warn     = function(...) end
-- The standalone Luau CLI hands out a readonly _G. Roblox's is writable, so shadow it
-- with a real table or every _G write in the script under test is a false failure.
_G = {}

-- The real debug table is readonly, so shadow the global with our own.
local realDebug = debug
debug = {
    info = realDebug.info,
    traceback = realDebug.traceback,
    getinfo = function(f)
        local ok, src = pcall(realDebug.info, f, "s")
        return {short_src = ok and src or "", source = ok and src or ""}
    end,
}

local genvTable = {}
getgenv = function() return genvTable end

local fpsCapSet = nil
setfpscap = function(n) fpsCapSet = n end

firesignal = function(sig, ...)
    -- Executors fire every connection on the signal, whether or not it has been
    -- Disabled. Pole relies on Disable to keep the game's handlers out of the way, so
    -- a firesignal reaches them anyway -- and pole then re-dispatches them itself.
    if type(sig) == "table" and sig.conns then
        local snap = table.clone(sig.conns)
        for i = 1, #snap do pcall(snap[i].Function, ...) end
    end
end

getconnections = function(sig)
    if type(sig) == "table" and sig.conns then return table.clone(sig.conns) end
    error("not a signal")
end

----------------------------------------------------------------- the place
local new = H.newInstance

local gameCalls = 0
local RepS   = new("Folder", "ReplicatedStorage")
local Pkgs   = new("Folder", "Packages");  Pkgs.Parent = RepS
local Net    = new("Folder", "Net");       Net.Parent  = Pkgs

local notifyRemote = new("RemoteEvent", "RE/NotificationService/Notify")
local redeemRemote = new("RemoteFunction", "RF/RequestRedemption")

-- Filler so the tree is not trivially small, like a real place -- and parented in an
-- order that puts the redeem remote at remote-index 70 and the notify remote at 146,
-- which is where they sit in his place. Without that the positional lookup lands on a
-- filler and the real-place code path in LUCK is never actually exercised here.
local filled = 0
local function fill(n)
    for _ = 1, n do
        filled += 1
        local r = new(filled % 3 == 0 and "RemoteFunction" or "RemoteEvent", "Filler" .. filled)
        r.Parent = Net
    end
end
fill(69)
redeemRemote.Parent = Net       -- remote index 70
fill(75)
notifyRemote.Parent = Net       -- remote index 146
fill(36)

-- The game's own notification handler. Loaded under a chunkname containing
-- "NotificationController" so LUCK's verified lookup identifies this remote the same
-- way it does in the real place. It also does what the real one does: a bit of work.
-- The counter is passed INTO the chunk rather than wrapped around it. A wrapper closure
-- is defined in this file, so debug.getinfo on it reports this file -- which made the
-- verified lookup miss every time and quietly left the whole resolver untested.
local makeHandler = loadstring([[
    return function(bump)
        return function(msg, dur, sound, position)
            bump()
            local acc = 0
            for i = 1, 400 do acc += i % 7 end
            return acc
        end
    end
]], "@ReplicatedStorage.Controllers.NotificationController")()
local gameHandler = makeHandler(function() gameCalls += 1 end)
notifyRemote.OnClientEvent:Connect(gameHandler)

-- A second remote in Net that also carries a NotificationController connection, parented
-- AFTER the real one so it comes later in tree order. The resolver has to keep taking the
-- first match, because that is what the test sender takes -- if the two disagree, the
-- sender fires at a remote nobody is listening on.
local decoyNotify = new("RemoteEvent", "RE/NotificationService/Decoy")
decoyNotify.Parent = Net
decoyNotify.OnClientEvent:Connect(makeHandler(function() end))


-- The game's NotificationController, as a module LUCK can require and hook.
local Controllers = new("Folder", "Controllers"); Controllers.Parent = RepS
local NCModule = new("Folder", "NotificationController"); NCModule.Parent = Controllers
NCModule._module = {
    Notify = loadstring([[
        return function(self, msg, dur, sound, position)
            local acc = 0
            for i = 1, 400 do acc += i % 7 end
            return acc
        end
    ]], "@ReplicatedStorage.Controllers.NotificationController")(),
}
local realRequire = require
require = function(target)
    if type(target) == "table" and target._module then return target._module end
    return realRequire(target)
end

local PlayerGui = new("Folder", "PlayerGui")
local CoreGui   = new("Folder", "CoreGui")

----------------------------------------------------------------- services
local function svc(name)
    local s = new("Folder", name)
    return s
end

local RunService = svc("RunService")
RunService.Heartbeat = H.newSignal()
RunService.RenderStepped = H.newSignal()
-- Drive RenderStepped by hand so a test can advance the theme engine a known
-- number of frames instead of hoping the scheduler produces some.
RENDER = function(frames, dt)
    for _ = 1, (frames or 1) do
        RunService.RenderStepped:FireAll(dt or 1/60)
    end
end
RunService.Set3dRenderingEnabled = function() end

local UIS = svc("UserInputService")
UIS.InputChanged = H.newSignal()
UIS.InputBegan   = H.newSignal()
UIS.TouchEnabled = false
UIS.MouseEnabled = true
UIS.GetPlatform  = function() return Enum.Platform.Windows end

local TweenService = svc("TweenService")
TweenService.Create = function(_, inst, info, goal)
    return {Play = function() end, Cancel = function() end}
end

local HttpService = svc("HttpService")
HttpService.JSONEncode = function(_, t) return "{}" end
HttpService.JSONDecode = function(_, s) return {} end

local LocalPlayer = new("Folder", "clover")
LocalPlayer.DisplayName = "clover"
PlayerGui.Parent = LocalPlayer

local Players = svc("Players")
Players.LocalPlayer = LocalPlayer
Players.GetPlayers = function()
    local out = {}
    for i = 1, 40 do
        local p = new("Folder", "Player" .. i)
        p.DisplayName = "Player" .. i
        out[i] = p
    end
    return out
end

local Lighting = svc("Lighting")
Lighting.GlobalShadows = true
Lighting.Technology = "ShadowMap"

local Stats = svc("Stats")
Stats.Network = {ServerStatsItem = {["Data Ping"] = {GetValue = function() return 62 end}}}

local SERVICES = {
    Players = Players, UserInputService = UIS, TweenService = TweenService,
    HttpService = HttpService, ReplicatedStorage = RepS, RunService = RunService,
    Lighting = Lighting, Stats = Stats, CoreGui = CoreGui,
}

game = {
    PlaceId = 1,           -- not his place id, so the direct-name lookup path runs
    GetService = function(_, n) return SERVICES[n] or svc(n) end,
}

-- SignalBehavior belongs to the place. A live client cannot write it, so the stub
-- swallows the write and keeps reporting whatever the place chose. LOCK_SIGNALS picks
-- which world we are testing.
do
    local realBehaviour = LOCK_SIGNALS and Enum.SignalBehavior.Deferred
                                       or Enum.SignalBehavior.Deferred
    local camera = {ViewportSize = {X = 1440, Y = 900}}
    workspace = setmetatable({}, {
        __index = function(_, k)
            if k == "CurrentCamera" then return camera end
            if k == "SignalBehavior" then return realBehaviour end
            return nil
        end,
        __newindex = function(_, k, v)
            if k == "SignalBehavior" then
                if not LOCK_SIGNALS then realBehaviour = v end
                return                       -- locked: silently ignored, like live
            end
            rawset(workspace, k, v)
        end,
    })
end

settings = function()
    return {Rendering = {QualityLevel = Enum.QualityLevel.Automatic}}
end

----------------------------------------------------------------- server stub
local invokeStamp, invokeCount = nil, 0
local sendLog = {}

local invokeBehaviour = nil
H.onInvokeServer = function(remote, code)
    if invokeBehaviour then
        invokeStamp = os.clock(); invokeCount += 1
        sendLog[#sendLog + 1] = code
        return invokeBehaviour(remote, code)
    end
    -- Stamped the instant the send call is entered. This is "send" for our purposes:
    -- everything before it is the client's own work.
    invokeStamp = os.clock()
    invokeCount += 1
    sendLog[#sendLog + 1] = code
    if type(code) == "string" and code:find("^LUCK") then return false, "invalid code" end
    return true, "Meowl spawned!"
end
H.onFireServer = function() end


PlayerGuiRef = PlayerGui
RIG = {
    H = H,
    sentLog = function() return sendLog end,
    setInvokeBehaviour = function(fn) local old = invokeBehaviour; invokeBehaviour = fn; return old end,
    gameHandlerCalls = function() return gameCalls end, notifyRemote = notifyRemote, redeemRemote = redeemRemote,
    decoyNotify = decoyNotify,
    RepS = RepS, genvTable = genvTable,
    fpsCap = function() return fpsCapSet end,
    invokeCount = function() return invokeCount end,
    invokeStamp = function() return invokeStamp end,
    clearStamp = function() invokeStamp = nil end,
}

end
