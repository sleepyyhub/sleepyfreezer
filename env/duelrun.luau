--[[
    One half of a duel: run ONE build through a fixed set of rounds and print
    the announce -> server-receipt time for each.

    Each round places the announcement at an exact, reproducible offset inside
    the client's frame, so both builds see the identical sequence of arrival
    phases. duel.sh runs this twice and pairs the rounds up.

    Emits machine-readable lines: ROUND <n> <ms>

    Usage:  ./run.sh /path/to/build.txt duelrun
]]

local Env = require("./roblox")
local Place = require("./place")
local Sandbox = require("./sandbox")
local Input = require("./_source")

local ROUNDS  = 20
local FPS     = 240
local PING    = 20

local errors = {}
Env.onError = function(e) errors[#errors + 1] = tostring(e) end

local G, genv = Sandbox.build()
local chunk, err = loadstring(Input.source, "@LUCK")
if not chunk then print("COMPILE ERROR: " .. tostring(err)) return end
setfenv(chunk, G)
local ok, bootErr = pcall(chunk)
if not ok then print("BOOT FAILED: " .. tostring(bootErr)) return end

-- Two modes.
--
-- "duelrun" waits for the build to actually be able to send, however long that
-- takes. One of these arms much slower than the other, and scoring rounds it
-- was never awake for would measure arming and call it speed.
--
-- "duelcold" does not wait. Codes start dropping straight after load, which is
-- what happens when you join a server and one lands in the first seconds.
local COLD = Input.scenario == "duelcold"
local armStart = Env.now()
local armedAt
if not COLD then
	for _ = 1, 3000 do
		Env.run(0.02)
		local L0 = genv.LUCK
		if type(L0) == "table" and L0.RemoteDetectOn and L0.FastReady then
			armedAt = Env.now() - armStart
			break
		end
	end
else
	Env.run(0.2)   -- just enough for the script to finish loading
end

local L = genv.LUCK
if type(L) ~= "table" then print("LUCK did not arm") return end

Env.CFG.fps = FPS
Env.CFG.pingMs = PING
Env.CFG.signalBehavior = "Immediate"
L.RawFire, L.Instrument, L.Solo = true, false, true
if L.ApplyBinding then L.ApplyBinding() end
if L.SyncFast then L.SyncFast() end
Env.run(0.5)

print(string.format("META handler=%s armed=%s fps=%d ping=%d mode=%s",
	tostring(L.HandlerName),
	armedAt and string.format("%.3f", armedAt) or "not waited",
	FPS, PING, COLD and "cold" or "warm"))

local frameDt = 1 / FPS

for r = 1, ROUNDS do
	local code = "DUEL" .. r

	-- exact, reproducible intra-frame phase for this round
	local want = ((r - 1) / ROUNDS) * frameDt
	local untilFrame = ((Env.nextFrameAt() or Env.now()) - Env.now()) % frameDt
	Env.advance((untilFrame - want) % frameDt)

	local before = #Place.Server.receipts
	Place.Server:publish(code)
	local t0 = Env.now()
	Env.queueToClient(function(...)
		Place.notifySignal:Fire(...)
	end, table.pack(code, 5, nil, "Top"), t0, 1)

	local deadline = Env.now() + 1.0
	local hit
	while Env.now() < deadline do
		Env.run(frameDt / 2)
		for i = before + 1, #Place.Server.receipts do
			if Place.Server.receipts[i].code == code then
				hit = Place.Server.receipts[i]
				break
			end
		end
		if hit then break end
	end

	if hit then
		print(string.format("ROUND %d %.6f", r, (hit.at - t0) * 1000))
	else
		print(string.format("ROUND %d MISS", r))
	end
	Env.run(COLD and 0.6 or 0.05)
end

if #errors > 0 then
	print(string.format("META errors=%d", #errors))
end
