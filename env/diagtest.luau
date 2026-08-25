--[[
    Validates LUCK_racediag.lua by running it inside the simulated client
    alongside the real LUCK, with a planted "early source" the server touches
    before it announces. If the diagnostic is honest it should name that source
    and price the head start.

    Usage:  ./run.sh /path/to/LUCK.txt diag
]]

local Env = require("./roblox")
local Place = require("./place")
local Sandbox = require("./sandbox")
local Input = require("./_source")
local Diag = require("./_diag")

local errors = {}
Env.onError = function(e) errors[#errors + 1] = tostring(e) end

local G, genv = Sandbox.build()

local chunk, err = loadstring(Input.source, "@LUCK")
if not chunk then print("LUCK COMPILE ERROR: " .. tostring(err)) return end
setfenv(chunk, G)
local ok, bootErr = pcall(chunk)
if not ok then print("LUCK BOOT FAILED: " .. tostring(bootErr)) return end
Env.run(6.0)

local L = genv.LUCK
print("")
print("================================================================")
print("  RACEDIAG, validated inside the simulated client")
print("================================================================")
print(string.format("  LUCK armed: handler=%s fastReady=%s",
	tostring(L.HandlerName), tostring(L.FastReady)))

--------------------------------------------------------------------------------
-- plant an EARLY source: a StringValue the server writes before it announces
--------------------------------------------------------------------------------
local early = G.Instance.new("StringValue")
early.Name = "ActiveCode"
early.Value = ""
early.Parent = Place.ReplicatedStorage

Env.CFG.fps = 60
Env.CFG.pingMs = 40
Env.CFG.signalBehavior = "Immediate"

--------------------------------------------------------------------------------
-- load the diagnostic into the same sandbox
--------------------------------------------------------------------------------
local dchunk, derr = loadstring(Diag.source, "@RACEDIAG")
if not dchunk then print("DIAG COMPILE ERROR: " .. tostring(derr)) return end
setfenv(dchunk, G)
local dok, dres = pcall(dchunk)
if not dok then print("DIAG BOOT FAILED: " .. tostring(dres)) return end
Env.run(0.5)

local D = genv.RACEDIAG
if type(D) ~= "table" then print("RACEDIAG did not publish itself") return end

--------------------------------------------------------------------------------
-- one code drop: the value lands 25 ms before the announcement
--------------------------------------------------------------------------------
local CODE = "SIMWIN42"
local LEAD = 0.025

Place.Server:publish(CODE)

-- the server writes the value now...
Env.queueToClient(function()
	early.Value = CODE
end, table.pack(), Env.now(), 1)

-- ...and announces LEAD later
Env.queueToClient(function(...)
	Place.lastNotifyAt = Env.now()
	Place.notifySignal:Fire(...)
end, table.pack(CODE, 5, nil, "Top"), Env.now(), 1, LEAD)

Env.run(1.0)

print(string.format("  planted: ReplicatedStorage.ActiveCode written %.0f ms before the announcement",
	LEAD * 1000))

D.report(CODE)

if #errors > 0 then
	print(string.format("  thread errors during the run: %d", #errors))
	for i = 1, math.min(#errors, 5) do print("    " .. errors[i]) end
end
