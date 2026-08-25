--[[
    The fake place LUCK runs against.

    Built to satisfy the script's own remote-resolution paths, in the order it
    tries them, so nothing here is special-cased for the benchmark:

      ReplicatedStorage
        Packages/Net                  ModuleScript -> Net:RemoteFunction(guid)
                                                      Net:RemoteEvent(name)
          RF/7d14a912-…               RemoteFunction   the redeem remote
          RE/NotificationService/Notify  RemoteEvent   the announcement channel
        Controllers/NotificationController  ModuleScript with :Notify()

      Players.LocalPlayer.PlayerGui
        Codes/Codes/CodeRedeem/TextBox   TextBox
        Codes/Codes/Confirm              TextButton with a CodesController-ish
                                         Activated handler, so the UI path works

    Plus a server that actually validates codes and records, to the microsecond,
    when each redeem packet landed. That receipt timestamp is the whole point.
]]

local Env = require("./roblox")

local Place = {}
local Instance = Env.Instance
local newSignal = Env.newSignal
local task = Env.task
local now = Env.now

local REDEEM_GUID = "7d14a912-1040-4867-b005-98838eb9acc4"

--------------------------------------------------------------------------------
-- module registry, so require(ModuleScript) works
--------------------------------------------------------------------------------
local moduleReturns = setmetatable({}, { __mode = "k" })
Place.moduleReturns = moduleReturns

Place.require = function(target)
	if Env.isInstance(target) then
		local v = moduleReturns[target]
		if v ~= nil then return v end
		error("module has no return value: " .. tostring(target), 2)
	end
	error("require expects a ModuleScript", 2)
end

--------------------------------------------------------------------------------
-- remotes
--------------------------------------------------------------------------------
local function makeRemoteFunction(name, parent)
	local rf = Instance.new("RemoteFunction")
	rf.Name = name
	rf.Parent = parent
	local props = rawget(rf, "__props")
	props.InvokeServer = function(self, ...)
		local co = coroutine.running()
		local args = table.pack(...)
		Env.queueToServer(self, "invoke", args, function(...)
			Env.schedule(co, now(), table.pack(...))
		end)
		return coroutine.yield()
	end
	return rf
end

local function makeRemoteEvent(name, parent)
	local re = Instance.new("RemoteEvent")
	re.Name = name
	re.Parent = parent
	local sig = newSignal("OnClientEvent")
	rawget(re, "__signals").OnClientEvent = sig
	rawget(re, "__props").FireServer = function(self, ...)
		Env.queueToServer(self, "fire", table.pack(...), nil)
	end
	return re, sig
end

local ReplicatedStorage = Instance.new("ReplicatedStorage")
ReplicatedStorage.Name = "ReplicatedStorage"

-- pad the descendant list so the script's "index 70 / index 146" heuristic has
-- something plausible to walk past; it should fall through to the Net path
local filler = Instance.new("Folder")
filler.Name = "Shared"
filler.Parent = ReplicatedStorage
for i = 1, 60 do
	local f = Instance.new(i % 2 == 0 and "RemoteEvent" or "RemoteFunction")
	f.Name = "Misc_" .. i
	f.Parent = filler
	if i % 2 == 0 then
		rawget(f, "__signals").OnClientEvent = newSignal("OnClientEvent")
		rawget(f, "__props").FireServer = function() end
	else
		rawget(f, "__props").InvokeServer = function() return nil end
	end
end

local Packages = Instance.new("Folder")
Packages.Name = "Packages"
Packages.Parent = ReplicatedStorage

local NetModule = Instance.new("ModuleScript")
NetModule.Name = "Net"
NetModule.Parent = Packages

local RFFolder = Instance.new("Folder")
RFFolder.Name = "RF"
RFFolder.Parent = NetModule
local REFolder = Instance.new("Folder")
REFolder.Name = "RE"
REFolder.Parent = NetModule

local redeemRemote = makeRemoteFunction("RF/" .. REDEEM_GUID, RFFolder)
local notifyRemote, notifySignal = makeRemoteEvent("RE/NotificationService/Notify", REFolder)

Place.redeemRemote = redeemRemote
Place.notifyRemote = notifyRemote
Place.notifySignal = notifySignal

moduleReturns[NetModule] = {
	RemoteFunction = function(_, key)
		if key == REDEEM_GUID then return redeemRemote end
		return nil
	end,
	RemoteEvent = function(_, key)
		if key == "NotificationService/Notify" then return notifyRemote end
		return nil
	end,
}

--------------------------------------------------------------------------------
-- NotificationController — the module LUCK hooks in UI detect mode
--------------------------------------------------------------------------------
local Controllers = Instance.new("Folder")
Controllers.Name = "Controllers"
Controllers.Parent = ReplicatedStorage

local NCModule = Instance.new("ModuleScript")
NCModule.Name = "NotificationController"
NCModule.Parent = Controllers

local NC = {}
Place.NC = NC
NC.seen = {}
function NC:Notify(msg, dur, sound, position, ...)
	NC.seen[#NC.seen + 1] = { msg = msg, position = position, at = now() }
end
moduleReturns[NCModule] = NC

-- the real controller listens on the notify remote and forwards to itself;
-- this is the connection LUCK's verifiedNotify() goes looking for
local ncConnection = notifySignal:Connect(function(msg, dur, sound, position)
	NC:Notify(msg, dur, sound, position)
end)
Place.ncConnection = ncConnection

--------------------------------------------------------------------------------
-- Players / PlayerGui / the Codes UI
--------------------------------------------------------------------------------
local Players = Instance.new("Players")
Players.Name = "Players"

local LocalPlayer = Instance.new("Player")
LocalPlayer.Name = "forbiddentomove123"
rawget(LocalPlayer, "__props").DisplayName = "clover"
rawget(LocalPlayer, "__props").UserId = 8568412616
LocalPlayer.Parent = Players
rawget(Players, "__props").LocalPlayer = LocalPlayer
rawget(Players, "__props").GetPlayers = function() return { LocalPlayer } end
rawget(Players, "__signals").PlayerAdded = newSignal("PlayerAdded")
rawget(Players, "__signals").PlayerRemoving = newSignal("PlayerRemoving")

local PlayerGui = Instance.new("PlayerGui")
PlayerGui.Name = "PlayerGui"
PlayerGui.Parent = LocalPlayer

local CodesGui = Instance.new("ScreenGui")
CodesGui.Name = "Codes"
CodesGui.Parent = PlayerGui
local CodesInner = Instance.new("Frame")
CodesInner.Name = "Codes"
CodesInner.Parent = CodesGui
local CodeRedeem = Instance.new("Frame")
CodeRedeem.Name = "CodeRedeem"
CodeRedeem.Parent = CodesInner
local TextBox = Instance.new("TextBox")
TextBox.Name = "TextBox"
TextBox.Text = ""
TextBox.Parent = CodeRedeem
local Confirm = Instance.new("TextButton")
Confirm.Name = "Confirm"
Confirm.Parent = CodesInner
local ConfirmLabel = Instance.new("TextLabel")
ConfirmLabel.Name = "Confirm"
ConfirmLabel.Text = "CONFIRM"
ConfirmLabel.Parent = Confirm

Place.TextBox = TextBox
Place.Confirm = Confirm

-- the game's own submit handler, behind an Activated connection, the way a
-- Knit/Roblox-TS controller would wire it
local function codesControllerSubmit()
	local code = TextBox.Text
	if code == "" then return end
	TextBox.Text = ""
	return redeemRemote:InvokeServer(code)
end
Confirm.Activated:Connect(function()
	task.spawn(codesControllerSubmit)
end)

--------------------------------------------------------------------------------
-- the server
--------------------------------------------------------------------------------
local Server = {
	live = {},        -- code -> true while redeemable
	receipts = {},    -- { code = , at = , accepted = }
	redeemed = {},
}
Place.Server = Server

function Server:publish(code)
	self.live[code] = true
end

Env.serverHandlers[redeemRemote] = function(kind, payload, arrivedAt, wire)
	local code = payload[1]
	if type(code) ~= "string" then return false, "INVALID" end
	code = code:upper()

	local accepted = false
	local msg = "INVALID"
	if Server.live[code] then
		if Server.redeemed[code] then
			msg = "ALREADY"
		else
			Server.redeemed[code] = arrivedAt
			accepted = true
			msg = "REDEEMED"
		end
	end

	Server.receipts[#Server.receipts + 1] = {
		code = code, at = arrivedAt, accepted = accepted,
		-- when the script handed the packet to the engine, and when the
		-- engine's outgoing replication step actually put it on the wire
		queuedAt = wire and wire.queuedAt, flushAt = wire and wire.flushAt,
	}
	return accepted, msg
end

-- broadcast an announcement exactly the way the game does: the server sends,
-- the wire delays it, the client's frame picks it up
function Server:announce(text, code)
	if code then self:publish(code) end
	-- deliver through a function so the exact moment the client's replication
	-- step handed the packet up can be timestamped
	Env.queueToClient(function(...)
		Place.lastNotifyAt = now()
		notifySignal:Fire(...)
	end, table.pack(text, 5, nil, "Top"), now())
	return now()
end

--------------------------------------------------------------------------------
Place.ReplicatedStorage = ReplicatedStorage
Place.Players = Players
Place.LocalPlayer = LocalPlayer
Place.PlayerGui = PlayerGui
Place.PlaceId = 109983668079237

return Place
