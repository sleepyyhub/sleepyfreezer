--[[
    Your setup, exactly: you on 9 ms ping, the rival on 11 ms, both at 480 fps,
    both running a reactive handler off the notify remote.

    The rival's code is assumed to be as good as yours -- that is the case worth
    pricing, since LUCK's handler is 1.6-3.3 ns above a bare send and there is
    no room for anyone to beat it there.

    The one variable left is frame phase: two clients on one machine never share
    a frame clock. So the phase offset is swept across a whole frame and the win
    rate reported for each, plus the total across all offsets -- which is what
    you would actually see over an evening, since you do not get to choose it.

    Usage:  ./run.sh /path/to/LUCK.txt yourcase
]]

local Env = require("./roblox")
local Place = require("./place")
local Sandbox = require("./sandbox")
local Input = require("./_source")

local MY_PING    = 9
local THEIR_PING = 11
local FPS        = 480

--------------------------------------------------------------------------------
local errors = {}
Env.onError = function(e) errors[#errors + 1] = tostring(e) end

local G, genv = Sandbox.build()
local chunk, err = loadstring(Input.source, "@LUCK")
if not chunk then print("COMPILE ERROR: " .. tostring(err)) return end
setfenv(chunk, G)
local ok, bootErr = pcall(chunk)
if not ok then print("BOOT FAILED: " .. tostring(bootErr)) return end
Env.run(6.0)

local L = genv.LUCK
if type(L) ~= "table" then print("LUCK did not arm") return end

Env.CFG.fps = FPS
Env.CFG.pingMs = MY_PING
Env.CFG.signalBehavior = "Immediate"
L.RawFire, L.Instrument, L.Solo = true, false, true
if L.ApplyBinding then L.ApplyBinding() end
if L.SyncFast then L.SyncFast() end

local frameMs = 1000 / FPS

print("")
print("================================================================")
print("  YOUR SETUP")
print("================================================================")
print(string.format("  you        %d ms ping   %d fps   handler=%s",
	MY_PING, FPS, tostring(L.HandlerName)))
print(string.format("  the rival  %d ms ping   %d fps   reactive, same speed",
	THEIR_PING, FPS))
print(string.format("  frame      %.3f ms      flush step %.3f ms", frameMs, frameMs))
print(string.format("  your wire edge  %.1f ms one way, %.1f ms both ways",
	(THEIR_PING - MY_PING) / 2, THEIR_PING - MY_PING))
print("")

--------------------------------------------------------------------------------
local redeem = Place.redeemRemote
local function rivalFire(code)
	Env.queueToServer(redeem, "invoke", table.pack(code), nil, 2)
end
local function rivalReactive(msg, position)
	if position ~= "Top" then return end
	rivalFire(msg)
end

local raceN = 0

local function runRace(phaseIndex, phaseTotal)
	raceN += 1
	local code = "YC" .. raceN

	local frameDt = 1 / Env.CFG.fps
	local want = ((phaseIndex - 1) / phaseTotal) * frameDt
	local untilFrame = ((Env.nextFrameAt() or Env.now()) - Env.now()) % frameDt
	Env.advance((untilFrame - want) % frameDt)

	local before = #Place.Server.receipts
	Place.Server:publish(code)
	local t0 = Env.now()

	Env.queueToClient(function(...)
		Place.lastNotifyAt = Env.now()
		Place.notifySignal:Fire(...)
	end, table.pack(code, 5, nil, "Top"), t0, 1)

	Env.queueToClient(function(...)
		rivalReactive(...)
	end, table.pack(code, "Top"), t0, 2)

	local deadline = Env.now() + 1.0
	local function settled()
		local a, b = false, false
		for i = before + 1, #Place.Server.receipts do
			local r = Place.Server.receipts[i]
			if r.code == code then
				if r.cid == 2 then b = true else a = true end
			end
		end
		return a and b
	end
	while Env.now() < deadline do
		Env.run(1 / Env.CFG.fps / 2)
		if settled() then break end
	end

	local mine, theirs
	for i = before + 1, #Place.Server.receipts do
		local r = Place.Server.receipts[i]
		if r.code == code then
			if r.cid == 2 then theirs = theirs or r.at else mine = mine or r.at end
		end
	end
	return mine, theirs
end

local function raceSet(n)
	local wins, ties, losses, gaps = 0, 0, 0, {}
	for i = 1, n do
		local mine, theirs = runRace(i, n)
		if mine and theirs then
			local d = (mine - theirs) * 1000
			gaps[#gaps + 1] = d
			if math.abs(d) < 0.05 then ties += 1
			elseif d < 0 then wins += 1
			else losses += 1 end
		elseif mine then wins += 1
		elseif theirs then losses += 1 end
		Env.run(0.02)
	end
	table.sort(gaps)
	local med = #gaps > 0 and gaps[(#gaps + 1) // 2] or 0
	return wins, ties, losses, med
end

--------------------------------------------------------------------------------
print("  frame phase is the one thing you do not control, so it is swept.")
print("  negative gap = you reached the server first.")
print("")
print(string.format("  %-30s %5s %5s %5s %12s", "rival's grid vs yours",
	"win", "tie", "lose", "median gap"))
print("  " .. string.rep("-", 64))

local N = 32
local tw, tt, tl = 0, 0, 0
local offsets = {}
for i = 0, 7 do offsets[#offsets + 1] = i * frameMs / 8 end

for _, off in ipairs(offsets) do
	Env.setRival({ fps = FPS, pingMs = THEIR_PING, phase = -off / 1000 })
	-- let both grids settle at the new offset
	Env.run(0.2)
	local w, t, l, med = raceSet(N)
	tw, tt, tl = tw + w, tt + t, tl + l
	print(string.format("  %-30s %5d %5d %5d %+9.3f ms",
		string.format("theirs %.3f ms earlier", off), w, t, l, med))
end

local total = tw + tt + tl
print("  " .. string.rep("-", 64))
print(string.format("  %-30s %5d %5d %5d", "across every phase", tw, tt, tl))
print("")
print(string.format("  you take the code in %.1f%% of races (%.1f%% incl. ties)",
	tw / total * 100, (tw + tt) / total * 100))
print("")

print("  why -- and this is the part that is NOT like a detection head start:")
print(string.format("    your %.1f ms edge is two separate legs, and only one of them",
	THEIR_PING - MY_PING))
print("    is subject to the frame clock.")
print("")
print(string.format("      inbound   %.1f ms  the announcement reaches you sooner.",
	(THEIR_PING - MY_PING) / 2))
print(string.format("                        QUANTISED -- it only pays if it crosses"))
print(string.format("                        a %.3f ms flush boundary.", frameMs))
print(string.format("      outbound  %.1f ms  your redeem flies home faster.",
	(THEIR_PING - MY_PING) / 2))
print("                        NOT quantised -- it lands after the flush,")
print("                        straight on the wire. phase cannot take it.")
print("")
print(string.format("    that outbound half is why the gap at a 0 ms phase offset is"))
print(string.format("    %.1f ms and not zero: both clients flush at the same instant and",
	(THEIR_PING - MY_PING) / 2))
print("    your packet still gets there first. a ping edge always pays at")
print("    least half. a detection edge can pay nothing at all.")
--------------------------------------------------------------------------------
-- Control: swap the pings. If the harness were biased toward client 1 the
-- result would not invert, and everything above would be worthless.
--------------------------------------------------------------------------------
print("  control -- pings swapped, you on " .. THEIR_PING .. " ms, them on " .. MY_PING .. " ms")
print("  " .. string.rep("-", 64))
Env.CFG.pingMs = THEIR_PING
local cw, ct, cl = 0, 0, 0
for _, off in ipairs(offsets) do
	Env.setRival({ fps = FPS, pingMs = MY_PING, phase = -off / 1000 })
	Env.run(0.2)
	local w, t, l = raceSet(N)
	cw, ct, cl = cw + w, ct + t, cl + l
end
local ctotal = cw + ct + cl
print(string.format("  %-30s %5d %5d %5d", "across every phase", cw, ct, cl))
print(string.format("  you take the code in %.1f%% of races", cw / ctotal * 100))
if cw < ctotal * 0.5 and tw > total * 0.5 then
	print("  inverts cleanly -- the result above is the ping, not the harness.")
else
	print("  DID NOT INVERT -- treat the numbers above as suspect.")
end
Env.CFG.pingMs = MY_PING

if #errors > 0 then
	print(string.format("  thread errors: %d", #errors))
end
print("")
