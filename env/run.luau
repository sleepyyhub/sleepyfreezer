--[[
    Loads the real LUCK.txt into the simulated client and speed-tests it.

    Usage:  luau run.luau -a /path/to/LUCK.txt [scenario]

    The measurement: the server announces a code at T0. Somewhere later the
    server receives a redeem packet carrying that code. The gap is what decides
    whether you get the code. Every stage in between is real script execution;
    only the wire delay and the frame cadence are simulated.
]]

local Env = require("./roblox")
local Place = require("./place")
local Sandbox = require("./sandbox")

-- The Luau CLI has no io library, so run.sh materialises the target script and
-- the run options as generated modules. _source.luau is byte-for-byte LUCK.txt.
local Input = require("./_source")
local SCRIPT_PATH = Input.path
local SCENARIO = Input.scenario

local function fmtms(v) return string.format("%.3f ms", v * 1000) end

--------------------------------------------------------------------------------
-- boot the client
--------------------------------------------------------------------------------
local errors = {}
Env.onError = function(e) errors[#errors + 1] = tostring(e) end

local source = Input.source
local G, genv = Sandbox.build()

local chunk, compileErr = loadstring(source, "@LUCK")
if not chunk then
	print("COMPILE ERROR: " .. tostring(compileErr))
	return
end
setfenv(chunk, G)

local bootStart = Env.now()
local bootOk, bootErr = pcall(chunk)
local bootReal = Env.realBurned()

print("")
print("================================================================")
print("  LUCK in a simulated client")
print("================================================================")
print(string.format("  script            %s  (%d bytes)", SCRIPT_PATH, #source))
print(string.format("  load              %s", bootOk and "ok" or ("FAILED: " .. tostring(bootErr))))
if not bootOk then
	for i = 1, math.min(#errors, 10) do print("    thread error: " .. errors[i]) end
	return
end

-- let the script finish its async arming (remote resolution, hooks, UI)
Env.run(6.0)

local L = genv.LUCK
if type(L) ~= "table" then
	print("  LUCK did not publish itself to getgenv(). aborting.")
	return
end

print(string.format("  boot cpu          %.2f ms real", bootReal * 1000))
print(string.format("  arm               redeem=%s  notify=%s",
	tostring(L.RedeemRemoteSource), tostring(L.NotifyRemoteSource)))
print(string.format("  remote detect     %s", tostring(L.RemoteDetectOn)))
print(string.format("  remote tested     %s   (%s)",
	tostring(L.RedeemRemoteTested), tostring(L.RedeemRemoteReply)))
print(string.format("  handler           %s   fastReady=%s",
	tostring(L.HandlerName), tostring(L.FastReady)))
print(string.format("  speed mode        %s   rawFire=%s   auto=%s",
	L.Mode and L.Mode.name or "?", tostring(L.RawFire ~= false), tostring(L.AutoOn)))
print(string.format("  signal mode       %s   (script asked for Immediate)",
	tostring(L.SignalMode)))
if #errors > 0 then
	print(string.format("  thread errors     %d during boot", #errors))
	local shown = {}
	for _, e in ipairs(errors) do
		local key = e:sub(1, 90)
		if not shown[key] then shown[key] = true; print("      " .. key) end
	end
end

--------------------------------------------------------------------------------
-- one measured code drop
--------------------------------------------------------------------------------
local dropN = 0

local function drop(phaseIndex, phaseTotal)
	dropN += 1
	local code = "SIMCODE" .. dropN
	local text = code

	-- Place the announcement at an EXACT offset inside the client's frame.
	-- Sweeping that offset evenly across one whole frame beats rolling it at
	-- random: every config then sees the identical set of phases, so two runs
	-- differ only by the code under test. With random phase, the real CPU each
	-- pass burns shifts the grid and a few ms of luck reads as a result.
	if phaseIndex and phaseTotal then
		local frameDt = 1 / Env.CFG.fps
		local want = ((phaseIndex - 1) / phaseTotal) * frameDt
		local untilFrame = (Env.nextFrameAt() or Env.now()) - Env.now()
		untilFrame = untilFrame % frameDt
		Env.advance((untilFrame - want) % frameDt)
	end

	local before = #Place.Server.receipts
	local t0 = Place.Server:announce(text, code)

	-- give the pipeline a generous window to complete
	local deadline = Env.now() + 1.5
	while Env.now() < deadline do
		Env.run(1 / Env.CFG.fps)
		if #Place.Server.receipts > before then break end
	end

	for i = before + 1, #Place.Server.receipts do
		local r = Place.Server.receipts[i]
		if r.code == code then
			return r.at - t0, r.accepted, code
		end
	end
	return nil, false, code
end

local function warmup(n)
	for _ = 1, n or 3 do drop() end
end

local SAMPLES = 40

-- Each group sweeps the same evenly-spaced set of intra-frame phases, so the
-- median below is a true expectation over arrival timing rather than a sample
-- of whatever offsets the RNG happened to pick.
local function sample(n)
	local total = n or SAMPLES
	local out = {}
	for i = 1, total do
		local dt = drop(i, total)
		if dt then out[#out + 1] = dt * 1000 end
		Env.run(0.05)
	end
	if #out == 0 then return nil end
	table.sort(out)
	local sum = 0
	for _, v in ipairs(out) do sum += v end
	local function q(p) return out[math.clamp(math.ceil(#out * p), 1, #out)] end
	return {
		min = out[1], p10 = q(0.10), med = q(0.50), p90 = q(0.90),
		max = out[#out], mean = sum / #out, n = #out,
	}
end

--------------------------------------------------------------------------------
-- scenarios
--------------------------------------------------------------------------------
local function header(t)
	print("")
	print("  " .. t .. "   (ms, announce -> server receipt)")
	print("  " .. string.rep("-", 70))
end

local function row(label, s)
	if not s then
		print(string.format("  %-28s   no redeem reached the server", label))
		return
	end
	print(string.format("  %-28s %7.2f %7.2f %7.2f %7.2f %7.2f   n=%d",
		label, s.min, s.p10, s.med, s.p90, s.max, s.n))
end

local function colhead()
	print(string.format("  %-28s %7s %7s %7s %7s %7s",
		"", "min", "p10", "med", "p90", "max"))
end

print("")
print("  announce -> the server has your redeem")
print("  (real script execution, simulated wire and frame clock)")

warmup(3)

if SCENARIO == "sweep" or SCENARIO == "all" then
	header("by ping, at 60 fps")
	colhead()
	Env.CFG.fps = 60
	for _, p in ipairs({ 10, 25, 40, 80, 150 }) do
		Env.CFG.pingMs = p
		warmup(1)
		row(string.format("ping %d ms", p), sample())
	end

	header("by frame rate, at 40 ms ping")
	colhead()
	Env.CFG.pingMs = 40
	for _, f in ipairs({ 30, 60, 120, 240 }) do
		Env.CFG.fps = f
		warmup(1)
		row(string.format("%d fps", f), sample())
	end

	header("by signal behaviour, 40 ms ping / 60 fps")
	colhead()
	Env.CFG.fps = 60
	Env.CFG.pingMs = 40
	for _, mode in ipairs({ "Deferred", "Immediate" }) do
		Env.CFG.signalBehavior = mode
		warmup(1)
		row(mode, sample())
	end
	Env.CFG.signalBehavior = "Immediate"

	header("by script setting, 40 ms ping / 60 fps")
	colhead()
	local function withSetting(label, apply, restore)
		apply()
		if L.SyncFast then L.SyncFast() end
		warmup(1)
		row(label, sample())
		restore()
		if L.SyncFast then L.SyncFast() end
	end

	withSetting("RawFire on (default)", function() L.RawFire = true end, function() end)
	withSetting("RawFire off (parses text)",
		function() L.RawFire = false end, function() L.RawFire = true end)
	withSetting("Instrument on",
		function() L.Instrument = true end, function() L.Instrument = false end)
	withSetting("guarded handler",
		function() L.Solo = false; if L.ApplyBinding then L.ApplyBinding() end end,
		function() L.Solo = true; if L.ApplyBinding then L.ApplyBinding() end end)
	withSetting("Auto off (detect only)",
		function() L.AutoOn = false; if L.SyncHot then L.SyncHot() end end,
		function() L.AutoOn = true; if L.SyncHot then L.SyncHot() end end)
end

--------------------------------------------------------------------------------
-- the floor: a handler that does nothing but forward
--------------------------------------------------------------------------------
-- The only fair question about a sniper is how close it gets to the fastest a
-- client could possibly be. So: same place, same wire, same frame grid, same
-- phase sequence -- but the notify signal is served by four lines that read the
-- message and invoke the redeem remote. Nothing else. LUCK is switched off for
-- this pass (proven above to produce no redeem) so the two never race.

header("LUCK vs the theoretical floor, 40 ms ping / 60 fps / Immediate")
colhead()

Env.CFG.fps = 60
Env.CFG.pingMs = 40
Env.CFG.signalBehavior = "Immediate"
L.RawFire = true
L.Instrument = false
L.Solo = true
if L.ApplyBinding then L.ApplyBinding() end
if L.SyncFast then L.SyncFast() end
warmup(2)
local luckStats = sample()
row("LUCK (solo, raw)", luckStats)

local redeem = Place.redeemRemote
local refConn = Place.notifySignal:Connect(function(msg, _, _, position)
	if position ~= "Top" then return end
	redeem:InvokeServer(msg)
end)
L.AutoOn = false
if L.SyncHot then L.SyncHot() end
if L.SyncFast then L.SyncFast() end
warmup(2)
local floorStats = sample()
row("bare forwarding handler", floorStats)
refConn:Disconnect()
L.AutoOn = true
if L.SyncHot then L.SyncHot() end
if L.SyncFast then L.SyncFast() end

if luckStats and floorStats then
	print("")
	print(string.format("  gap at the median  %+.3f ms", luckStats.med - floorStats.med))
	print(string.format("  gap at the minimum %+.3f ms", luckStats.min - floorStats.min))
	print("  anything under a millisecond here is frame phase, not code.")
end

--------------------------------------------------------------------------------
-- the breakdown, at a realistic default
--------------------------------------------------------------------------------
Env.CFG.fps = 60
Env.CFG.pingMs = 40
Env.CFG.signalBehavior = "Immediate"
L.RawFire = true
L.Instrument = false
L.Solo = true
if L.ApplyBinding then L.ApplyBinding() end
if L.SyncFast then L.SyncFast() end
warmup(2)

header("where the milliseconds go, 40 ms ping / 60 fps / Immediate")

local s = sample()
local oneWay = Env.CFG.pingMs / 2
if s then
	local cpuNs = L.BenchNs
	if not cpuNs and L.Bench then cpuNs = L.Bench(300000) end
	local cpuMs = (cpuNs or 0) / 1e6
	local frameMs = 1000 / Env.CFG.fps

	print(string.format("  %-34s %9.3f ms", "announcement over the wire", oneWay))
	print(string.format("  %-34s %9.3f ms", "waiting for the client frame", s.med - oneWay * 2 - cpuMs))
	print(string.format("  %-34s %9.6f ms", "LUCK's own code", cpuMs))
	print(string.format("  %-34s %9.3f ms", "redeem over the wire", oneWay))
	print("  " .. string.rep("-", 62))
	print(string.format("  %-34s %9.3f ms  (median measured)", "TOTAL", s.med))
	print("")
	print(string.format("  LUCK's share            %.6f ms  =  %.5f %%",
		cpuMs, cpuMs / s.med * 100))
	print(string.format("  network's share         %9.3f ms  =  %.2f %%",
		oneWay * 2, oneWay * 2 / s.med * 100))
	print(string.format("  frame clock's share     %9.3f ms  =  %.2f %%",
		s.med - oneWay * 2 - cpuMs, (s.med - oneWay * 2 - cpuMs) / s.med * 100))
	print("")
	print(string.format("  one frame at %d fps is %.2f ms — %.0fx the entire script",
		Env.CFG.fps, frameMs, frameMs / math.max(cpuMs, 1e-9)))
end

print("")
print(string.format("  simulated time elapsed %.2f s   real cpu burned %.2f s   frames %d",
	Env.simulated(), Env.realBurned(), Env.frameCount()))
print(string.format("  packets: %d out, %d in   server receipts: %d",
	Env.stats.packetsOut, Env.stats.packetsIn, #Place.Server.receipts))
if #errors > 0 then
	print(string.format("  thread errors during the run: %d", #errors))
end
print("")
