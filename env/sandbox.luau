--[[
    The global table LUCK is loaded under: Roblox globals plus the executor
    surface it expects. Anything genuinely unavailable in a standalone VM is
    absent rather than faked into a lie — debug.getupvalue is the notable one,
    so the script's "verified" resolution paths fail their pcall and it falls
    through to the Net path, exactly as it would on an executor without them.
]]

local Env = require("./roblox")
local Place = require("./place")

local Sandbox = {}

local task = Env.task
local Enum = Env.Enum
local D = Env.datatypes

--------------------------------------------------------------------------------
-- workspace: SignalBehavior is wired to the real simulation switch
--------------------------------------------------------------------------------
local cameraProps = {
	ViewportSize = D.Vector2.new(1920, 1080),
	CFrame = {}, FieldOfView = 70,
}
local Camera = setmetatable({}, {
	__index = function(_, k) return cameraProps[k] end,
	__newindex = function(_, k, v) cameraProps[k] = v end,
})

local workspaceProps = {}
local workspace = setmetatable({}, {
	__index = function(_, k)
		if k == "CurrentCamera" then return Camera end
		if k == "SignalBehavior" then
			return setmetatable({}, {
				__tostring = function() return "Enum.SignalBehavior." .. Env.CFG.signalBehavior end,
			})
		end
		if k == "GetDescendants" then return function() return {} end end
		if k == "FindFirstChild" then return function() return nil end end
		if k == "WaitForChild" then return function() return nil end end
		return workspaceProps[k]
	end,
	__newindex = function(_, k, v)
		if k == "SignalBehavior" then
			local name = tostring(v):match("([^.]+)$")
			if name == "Immediate" or name == "Deferred" then
				Env.CFG.signalBehavior = name
			end
			return
		end
		workspaceProps[k] = v
	end,
})
Sandbox.workspace = workspace

--------------------------------------------------------------------------------
-- game
--------------------------------------------------------------------------------
local serviceMap = {
	ReplicatedStorage = Place.ReplicatedStorage,
	Players = Place.Players,
	Workspace = workspace,
}
for name, svc in pairs(Env.services) do serviceMap[name] = svc end

local gameProps = { PlaceId = Place.PlaceId, JobId = "sim-0001", GameId = 7709344486 }
local game = setmetatable({}, {
	__index = function(_, k)
		if k == "GetService" then
			return function(_, name)
				local s = serviceMap[name]
				if not s then
					s = Env.newInstance(name)
					s.Name = name
					serviceMap[name] = s
				end
				return s
			end
		end
		if k == "FindService" then return function(_, n) return serviceMap[n] end end
		if k == "IsLoaded" then return function() return true end end
		if k == "GetDescendants" then return function() return {} end end
		if gameProps[k] ~= nil then return gameProps[k] end
		return serviceMap[k]
	end,
	__newindex = function(_, k, v) gameProps[k] = v end,
})
Sandbox.game = game

--------------------------------------------------------------------------------
-- executor surface
--------------------------------------------------------------------------------
local genv = {}
local fileSystem = {}
Sandbox.fileSystem = fileSystem

local function getconnections(signal)
	if type(signal) ~= "table" then return {} end
	local conns = rawget(signal, "_conns")
	if not conns then return {} end
	local out = {}
	for i, c in ipairs(conns) do
		out[i] = c
	end
	return out
end

local function firesignal(signal, ...)
	if type(signal) == "table" and signal.FireSync then
		return signal:FireSync(...)
	end
end

local fpsCap = 60
local function setfpscap(n)
	fpsCap = n
	-- a cap only raises the ceiling; the simulated device keeps its own fps
	Env.CFG.fps = math.min(n, Env.CFG.deviceMaxFps or Env.CFG.fps)
	return true
end

local debugShim = {
	info = debug.info,
	traceback = debug.traceback,
	getinfo = function(fn, what)
		local src, line, name
		pcall(function() src = debug.info(fn, "s") end)
		pcall(function() line = debug.info(fn, "l") end)
		pcall(function() name = debug.info(fn, "n") end)
		return {
			source = src or "?", short_src = src or "?",
			currentline = line or 0, name = name or "?",
			what = "Lua", func = fn,
		}
	end,
	-- deliberately absent: getupvalue / setupvalue. Standalone Luau cannot read
	-- another closure's upvalues, and inventing values here would make the
	-- script's "verified" paths report success on data that does not exist.
}

local settingsTable = {
	Rendering = { QualityLevel = Enum.QualityLevel.Automatic },
	Physics = {}, Network = {},
}
local function settings() return settingsTable end

--------------------------------------------------------------------------------
-- assemble
--------------------------------------------------------------------------------
local osShim = setmetatable({
	clock = Env.now,
	time = os.time,
	date = os.date,
	difftime = os.difftime,
}, { __index = os })

function Sandbox.build()
	local G = {}

	-- standard library
	G.string, G.table, G.math, G.coroutine = string, table, math, coroutine
	G.utf8, G.bit32, G.buffer = utf8, bit32, buffer
	G.select, G.pairs, G.ipairs, G.next = select, pairs, ipairs, next
	G.type, G.tostring, G.tonumber = type, tostring, tonumber
	G.pcall, G.xpcall, G.error, G.assert = pcall, xpcall, error, assert
	G.rawget, G.rawset, G.rawequal, G.rawlen = rawget, rawset, rawequal, rawlen
	G.setmetatable, G.getmetatable = setmetatable, getmetatable
	G.getfenv, G.setfenv = getfenv, setfenv
	G.unpack, G.newproxy = table.unpack, newproxy
	G.os = osShim
	G.print = print
	G.warn = function(...) print("[warn]", ...) end
	G.loadstring = loadstring
	G.debug = debugShim

	-- Roblox
	G.game = game
	G.workspace = workspace
	G.Workspace = workspace
	G.Instance = Env.Instance
	G.Enum = Enum
	G.task = task
	G.typeof = Env.typeofFn
	G.require = Place.require
	G.settings = settings
	G.tick = Env.now
	G.time = Env.now
	G.wait = task.wait
	G.spawn = task.spawn
	G.delay = task.delay
	G.script = Env.newInstance("LocalScript")
	for k, v in pairs(D) do G[k] = v end

	-- executor
	G.getgenv = function() return genv end
	G.getrenv = function() return G end
	G.shared = {}
	G._G = {}
	G.getconnections = getconnections
	G.firesignal = firesignal
	G.setfpscap = setfpscap
	G.identifyexecutor = function() return "SimExec", "1.0" end
	G.getexecutorname = G.identifyexecutor
	G.setclipboard = function() end
	G.gethui = function() return Place.PlayerGui end
	G.isfile = function(p) return fileSystem[p] ~= nil end
	G.readfile = function(p)
		local v = fileSystem[p]
		if v == nil then error("file does not exist: " .. tostring(p), 2) end
		return v
	end
	G.writefile = function(p, c) fileSystem[p] = c end
	G.appendfile = function(p, c) fileSystem[p] = (fileSystem[p] or "") .. c end
	G.delfile = function(p) fileSystem[p] = nil end
	G.isfolder = function(p) return fileSystem["<dir>" .. p] ~= nil end
	G.makefolder = function(p) fileSystem["<dir>" .. p] = true end
	G.listfiles = function() return {} end

	G._ENV = G
	return G, genv
end

Sandbox.Env = Env
Sandbox.Place = Place
return Sandbox
