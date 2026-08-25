--[[
    Back-to-back codes.

    The send path is byte-identical between the two builds; the only difference
    is that one defers its post-send bookkeeping (L.Note, killFeed, postRedeem)
    behind task.delay(L.PostDelay) instead of running it inline. That cannot
    affect a single code -- it is all downstream of the send -- but it is meant
    to stop the first code's paperwork from sitting in front of the second
    code's handler.

    So: fire a burst and measure EVERY code in it, not just the first.

    Usage:  ./run.sh /path/to/LUCK.txt burst
]]

local Env = require("./roblox")
local Place = require("./place")
local Sandbox = require("./sandbox")
local Input = require("./_source")

local BURST   = 6      -- codes per burst
local SPACING = 0.004  -- seconds between them
local BURSTS  = 24

local errors = {}
Env.onError = function(e) errors[#errors + 1] = tostring(e) end

local G, genv = Sandbox.build()
local chunk, err = loadstring(Input.source, "@LUCK")
if not chunk then print("COMPILE ERROR: " .. tostring(err)) return end
setfenv(chunk, G)
local ok, bootErr = pcall(chunk)
if not ok then print("BOOT FAILED: " .. tostring(bootErr)) return end
-- Generous: one build arms noticeably slower than the other, and measuring
-- that as a throughput difference instead of an arming difference would be
-- flatly wrong. Give both all the time they want before the clock starts.
Env.run(20.0)

local L = genv.LUCK
if type(L) ~= "table" then print("LUCK did not arm") return end

Env.CFG.fps = 240
Env.CFG.pingMs = 20
Env.CFG.signalBehavior = "Immediate"
L.RawFire, L.Instrument, L.Solo = true, false, true
if L.ApplyBinding then L.ApplyBinding() end
if L.SyncFast then L.SyncFast() end

print("")
print("================================================================")
print("  BURST TEST -- " .. Input.path)
print("================================================================")
print(string.format("  handler=%s   PostDelay=%s   fps=%d  ping=%d ms",
	tostring(L.HandlerName), tostring(L.PostDelay), Env.CFG.fps, Env.CFG.pingMs))
print(string.format("  %d codes per burst, %.0f ms apart, %d bursts",
	BURST, SPACING * 1000, BURSTS))
print("")

local n = 0
local missing = {}
-- per position in the burst: how long announce -> server receipt took
local byPos = {}
for i = 1, BURST do byPos[i] = {} end

for b = 1, BURSTS do
	local sent = {}
	local before = #Place.Server.receipts
	for i = 1, BURST do
		n += 1
		local code = "BURST" .. n
		Place.Server:publish(code)
		sent[i] = { code = code, t0 = Env.now() }
		Env.queueToClient(function(...)
			Place.notifySignal:Fire(...)
		end, table.pack(code, 5, nil, "Top"), Env.now(), 1)
		Env.run(SPACING)
	end
	Env.run(0.6)

	local got = 0
	for i = 1, BURST do
		for r = before + 1, #Place.Server.receipts do
			local rec = Place.Server.receipts[r]
			if rec.code == sent[i].code then
				table.insert(byPos[i], (rec.at - sent[i].t0) * 1000)
				got += 1
				break
			end
		end
	end
	if got < BURST then
		missing[#missing + 1] = string.format("burst %d: %d/%d arrived", b, got, BURST)
	end
	Env.run(0.1)
end

local function stat(t)
	if #t == 0 then return nil end
	table.sort(t)
	local sum = 0
	for _, v in ipairs(t) do sum += v end
	local function q(p) return t[math.clamp(math.ceil(#t * p), 1, #t)] end
	return { min = t[1], med = q(0.5), p90 = q(0.9), max = t[#t],
	         mean = sum / #t, n = #t }
end

print(string.format("  %-10s %8s %8s %8s %8s   n", "position",
	"min", "med", "p90", "max"))
print("  " .. string.rep("-", 56))
local allMed, allMax = {}, 0
for i = 1, BURST do
	local s = stat(byPos[i])
	if s then
		print(string.format("  #%-9d %8.2f %8.2f %8.2f %8.2f  %3d",
			i, s.min, s.med, s.p90, s.max, s.n))
		allMed[#allMed + 1] = s.med
		if s.max > allMax then allMax = s.max end
	else
		print(string.format("  #%-9d   never reached the server", i))
	end
end
print("  " .. string.rep("-", 56))

local first = stat(byPos[1])
local last = stat(byPos[BURST])
if first and last then
	print(string.format("  first vs last in the burst: %+.3f ms at the median",
		last.med - first.med))
end
print(string.format("  worst single code in the whole run: %.2f ms", allMax))
print(string.format("  real cpu burned %.2f s over %d codes", Env.realBurned(), n))
print(string.format("  packets out %d   server receipts %d   codes announced %d",
	Env.stats.packetsOut, #Place.Server.receipts, n))
if #missing > 0 then
	print(string.format("  INCOMPLETE BURSTS: %d", #missing))
	for i = 1, math.min(#missing, 8) do print("    " .. missing[i]) end
end
if #errors > 0 then print(string.format("  thread errors: %d", #errors)) end
print("")
