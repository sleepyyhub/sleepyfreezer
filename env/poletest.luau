--[[
    Pole position, measured.

    The claim under test: with pole held the redeem goes out in ~232 ns; without
    it, our invoke lands behind the game's own notification handler -- which
    builds GUI and plays a sound before yielding -- and detect -> send measures
    ~3204 ns. Roughly 11x.

    This measures detect -> send directly: the moment the notify signal is
    delivered to the client, against the moment the redeem is handed to the
    engine. Nothing here is amortised or inferred.

    The game's handler is given real work to do, because a handler that returns
    immediately cannot delay anything and would make pole look worthless.

    Usage:  ./run.sh /path/to/build.txt pole
]]

local Env = require("./roblox")
local Place = require("./place")
local Sandbox = require("./sandbox")
local Input = require("./_source")

local errors = {}
Env.onError = function(e) errors[#errors + 1] = tostring(e) end

local G, genv = Sandbox.build()
local chunk, err = loadstring(Input.source, "@LUCK")
if not chunk then print("COMPILE ERROR: " .. tostring(err)) return end
setfenv(chunk, G)
local ok, bootErr = pcall(chunk)
if not ok then print("BOOT FAILED: " .. tostring(bootErr)) return end

for _ = 1, 3000 do
	Env.run(0.02)
	local L0 = genv.LUCK
	if type(L0) == "table" and L0.RemoteDetectOn and L0.FastReady then break end
end

local L = genv.LUCK
if type(L) ~= "table" then print("LUCK did not arm") return end

Env.CFG.fps = 240
Env.CFG.pingMs = 20
Env.CFG.signalBehavior = "Immediate"

--------------------------------------------------------------------------------
-- Give the game's own notification handler something to do. A real one builds
-- a frame, tweens it and starts a sound before it yields; an empty stub would
-- make pole look free to give up.
--------------------------------------------------------------------------------
local sink = 0
local realNotify = Place.NC.Notify
Place.NC.Notify = function(self, msg, dur, sound, position, ...)
	for i = 1, 900 do sink += i % 7 end   -- stand-in for the GUI + sound work
	return realNotify(self, msg, dur, sound, position, ...)
end

--------------------------------------------------------------------------------
local n = 0
local function measure(rounds)
	local out = {}
	for _ = 1, rounds do
		n += 1
		local code = "POLE" .. n
		local before = #Place.Server.receipts
		Place.Server:publish(code)
		Place.lastNotifyAt = nil
		Env.queueToClient(function(...)
			Place.lastNotifyAt = Env.now()
			Place.notifySignal:Fire(...)
		end, table.pack(code, 5, nil, "Top"), Env.now(), 1)

		local deadline = Env.now() + 0.6
		local hit
		while Env.now() < deadline do
			Env.run(1 / Env.CFG.fps / 2)
			for i = before + 1, #Place.Server.receipts do
				if Place.Server.receipts[i].code == code then
					hit = Place.Server.receipts[i]; break
				end
			end
			if hit then break end
		end
		if hit and hit.queuedAt and Place.lastNotifyAt then
			out[#out + 1] = (hit.queuedAt - Place.lastNotifyAt) * 1e9   -- ns
		end
		Env.run(0.02)
	end
	if #out == 0 then return nil end
	table.sort(out)
	local sum = 0
	for _, v in ipairs(out) do sum += v end
	local function q(p) return out[math.clamp(math.ceil(#out * p), 1, #out)] end
	return { min = out[1], med = q(0.5), p90 = q(0.9), mean = sum / #out, n = #out }
end

local function row(label, s, held, slot, total)
	if not s then
		print(string.format("  %-22s   nothing measured", label))
		return
	end
	print(string.format("  %-22s %9.0f %9.0f %9.0f   pole=%-5s slot %s/%s  n=%d",
		label, s.min, s.med, s.p90, tostring(held), tostring(slot), tostring(total), s.n))
end

print("")
print("================================================================")
print("  POLE POSITION -- detect -> send, in nanoseconds")
print("================================================================")
print("  " .. Input.path)
print("")
print(string.format("  %-22s %9s %9s %9s", "", "min", "med", "p90"))
print("  " .. string.rep("-", 74))

measure(6)  -- warm

local function slots()
	if not L.ConnIndex then return "?", "?" end
	local a, b = L.ConnIndex()
	return a, b
end

-- as the build left itself
local m1, t1 = slots()
local held = L.PoleOn
row(held and "pole held" or "pole NOT held", measure(24), held, m1, t1)

-- and the other way round
if L.PoleOn and L.DropPole then
	pcall(L.DropPole)
	Env.run(0.2)
	local m2, t2 = slots()
	row("after DropPole", measure(24), L.PoleOn, m2, t2)
	if L.TakePole then
		pcall(L.TakePole)
		Env.run(0.2)
		local m3, t3 = slots()
		row("after TakePole again", measure(24), L.PoleOn, m3, t3)
	end
elseif L.TakePole then
	pcall(L.TakePole)
	Env.run(0.2)
	local m2, t2 = slots()
	row("after TakePole", measure(24), L.PoleOn, m2, t2)
end

print("")
if #errors > 0 then print(string.format("  thread errors: %d", #errors)) end
print("")
