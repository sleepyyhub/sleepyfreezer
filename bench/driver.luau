--------------------------------------------------------------------
-- Driver: times the REAL handlers that the block above defined.
-- Method: N calls per trial, sent[] cleared every 32 (same as L.Bench),
-- min of TRIALS trials (min = the run least polluted by scheduler noise).
--------------------------------------------------------------------
local clockf = os.clock
local handlers = L.Handlers
local sent = L.SentCodes

local NCODES = 65536
local codes = table.create(NCODES)
for i = 1, NCODES do codes[i] = "LUCK" .. i .. "XZ" end

local anns = table.create(NCODES)
for i = 1, NCODES do
	anns[i] = '<b>NEW CODE</b> just dropped: <font color="#96FF67">SUMMER' .. i .. '</font> - redeem it now!'
end

local fastRemote = L.RedeemRemote
local fastInvoke = fastRemote.InvokeServer
local fastTime, fastRaw = false, true
local find = string.find

-- 1. harness floor: empty body, same signature, same call shape
local function empty(msg, a, b, position) end

-- 2. reference: the least a handler could possibly do
local function sendref(msg, _, _, position)
	if position ~= "Top" then return end
	return fastInvoke(fastRemote, msg)
end

-- 3. solo truncated at the send -- everything real solo does BEFORE the packet
local function solo_presend(msg, _, _, position)
	if position ~= "Top" then return end
	if fastTime or not fastRaw then return end
	local a, b = fastInvoke(fastRemote, msg)
	return a, b
end

-- 4. guarded truncated at the send -- guarded dedups BEFORE sending,
--    so that table lookup IS on the latency path
local function guarded_presend(msg, _, _, position)
	if position ~= "Top" then return end
	local entry = fastTime and clockf() or nil
	if type(msg) ~= "string" then return end
	local code = msg
	if not fastRaw and (#msg > 50 or find(msg, "[^%w]")) then return end
	if sent[code] then return end
	sent[code] = true
	local a, b = fastInvoke(fastRemote, code)
	return a, b
end

local CHUNK = 32

local function timeit(fn, src, passes)
	local t = clockf()
	for _ = 1, passes do
		local i = 1
		while i <= NCODES do
			local stop = i + CHUNK - 1
			for k = i, stop do
				fn(src[k], 5, nil, "Top")
			end
			table.clear(sent)
			i = stop + 1
		end
	end
	return (clockf() - t) / (passes * NCODES) * 1e9
end

local function best(label, fn, src, passes, trials)
	timeit(fn, src, 2) -- warm
	local lo, acc = math.huge, 0
	for _ = 1, trials do
		local ns = timeit(fn, src, passes)
		if ns < lo then lo = ns end
		acc += ns
	end
	return { label = label, min = lo, mean = acc / trials }
end

local PASSES = 40   -- 40 * 65536 = 2.6M calls per trial
local TRIALS = 11

local rows = {}
local function add(r) rows[#rows + 1] = r; return r end

local rFloor = add(best("empty fn (harness floor)", empty, codes, PASSES, TRIALS))
local rRef   = add(best("send call alone (reference)", sendref, codes, PASSES, TRIALS))
local rPre   = add(best("solo   entry -> send", solo_presend, codes, PASSES, TRIALS))
local rSolo  = add(best("solo   full handler", handlers.solo, codes, PASSES, TRIALS))
local rGPre  = add(best("guard  entry -> send", guarded_presend, codes, PASSES, TRIALS))
local rGuard = add(best("guard  full handler", handlers.guarded, codes, PASSES, TRIALS))

L.Instrument = true
L.SyncFast()
local rInst = add(best("solo   Instrument on (soloSlow)", L.Handlers.solo, codes, PASSES // 2, TRIALS))
L.Instrument = false
L.SyncFast()

L.RawFire = false
L.SyncFast()
local rParse = add(best("non-raw  codeFrom() parse first", L.Handlers.solo, anns, 2, TRIALS))
L.RawFire = true
L.SyncFast()

local GHZ = 2.8002

print("")
print("  LUCK hot path, measured on real Luau (-O2), Xeon @ 2.80 GHz")
print("  " .. string.rep("-", 70))
print(string.format("  %-33s %10s %10s %10s", "path", "min ns", "mean ns", "cycles"))
print("  " .. string.rep("-", 70))
for _, r in ipairs(rows) do
	print(string.format("  %-33s %10.2f %10.2f %10.0f", r.label, r.min, r.mean, r.min * GHZ))
end
print("  " .. string.rep("-", 70))

local floor_ = rFloor.min
print("")
print("  net of the harness floor:")
print(string.format("    the send call itself             %8.2f ns", rRef.min - floor_))
print(string.format("    solo,  work before the send      %8.2f ns   <- delays the packet", rPre.min - rRef.min))
print(string.format("    solo,  work after the send       %8.2f ns   (packet already gone)", rSolo.min - rPre.min))
print(string.format("    guard, work before the send      %8.2f ns   <- delays the packet", rGPre.min - rRef.min))
print(string.format("    guard, work after the send       %8.2f ns", rGuard.min - rGPre.min))
print(string.format("    codeFrom() on a full sentence    %8.2f ns   <- delays the packet", rParse.min - rSolo.min))
print("")
print(string.format("    solo  handler end to end         %8.2f ns  = %.6f ms", rSolo.min - floor_, (rSolo.min - floor_) / 1e6))
print(string.format("    guard handler end to end         %8.2f ns  = %.6f ms", rGuard.min - floor_, (rGuard.min - floor_) / 1e6))
print("")

local ns, refns = L.Bench(2000000)
if ns then
	print(string.format("  the script's own L.Bench():  handler %.1f ns   send %.1f ns", ns, refns))
else
	print("  the script's own L.Bench(): " .. tostring(refns))
end
print("")
print("  end-to-end budget, script cost plugged in as measured:")
L.BenchNs = rSolo.min - floor_
for _, cfg in ipairs({ {12, 60}, {12, 240}, {45, 60}, {90, 30} }) do
	print("")
	L.Budget(cfg[1], cfg[2])
end
