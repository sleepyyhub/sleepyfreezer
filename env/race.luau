--[[
    Code race: two clients, one stock, first redeem to reach the server wins.

    Client 1 runs the real LUCK.txt. Client 2 is a rival on its OWN frame grid,
    because two Roblox clients on one machine do not share a frame clock.

    Nothing here knows what the real rival script does. Each scenario prices a
    DIFFERENT hypothesis so the win/loss pattern can be matched against what
    actually happens in game.

    Usage:  ./run.sh /path/to/LUCK.txt race
]]

local Env = require("./roblox")
local Place = require("./place")
local Sandbox = require("./sandbox")
local Input = require("./_source")

--------------------------------------------------------------------------------
-- boot client 1 with the real script
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

print("")
print("================================================================")
print("  CODE RACE — one stock, first packet on the server wins")
print("================================================================")
print(string.format("  client 1   the real LUCK   handler=%s  fastReady=%s",
	tostring(L.HandlerName), tostring(L.FastReady)))

Env.CFG.fps = 60
Env.CFG.pingMs = 40
Env.CFG.signalBehavior = "Immediate"
L.RawFire, L.Instrument, L.Solo = true, false, true
if L.ApplyBinding then L.ApplyBinding() end
if L.SyncFast then L.SyncFast() end

--------------------------------------------------------------------------------
-- the rival
--------------------------------------------------------------------------------
local redeem = Place.redeemRemote

-- fire on client 2's network queue, so it rides ITS frame grid, not ours
local function rivalFire(code)
	Env.queueToServer(redeem, "invoke", table.pack(code), nil, 2)
end

local rivalPending = nil

-- strategy A: identical to LUCK. reads the announcement, fires the redeem.
local function rivalReactive(msg, position)
	if position ~= "Top" then return end
	rivalFire(msg)
end

--------------------------------------------------------------------------------
-- the race
--------------------------------------------------------------------------------
local raceN = 0
Place.Server.winner = {}

-- the server already records receipts in arrival order; first one with the
-- code takes the single stock
local function whoWon(code, before)
	for i = before + 1, #Place.Server.receipts do
		local r = Place.Server.receipts[i]
		if r.code == code then
			return r.accepted and (r.by or "?") or nil, r.at, r.by
		end
	end
	return nil
end

local function runRace(phaseIndex, phaseTotal, opts)
	opts = opts or {}
	raceN += 1
	local code = "RACE" .. raceN

	-- put the announcement at an exact offset in OUR frame
	local frameDt = 1 / Env.CFG.fps
	local want = ((phaseIndex - 1) / phaseTotal) * frameDt
	local untilFrame = ((Env.nextFrameAt() or Env.now()) - Env.now()) % frameDt
	Env.advance((untilFrame - want) % frameDt)

	local before = #Place.Server.receipts
	Place.Server:publish(code)

	local t0 = Env.now()
	local lead = (opts.rivalLeadMs or 0) / 1000

	-- The rival's source leaves the server at t0. Ours leaves `lead` later.
	-- Delaying OUR side rather than back-dating theirs is what actually
	-- creates the head start -- the first version queued both at t0 and so
	-- measured nothing at all.
	Env.queueToClient(function(...)
		Place.lastNotifyAt = Env.now()
		Place.notifySignal:Fire(...)
	end, table.pack(code, 5, nil, "Top"), t0, 1, lead)

	Env.queueToClient(function(...)
		if rivalPending then rivalPending(...) end
	end, table.pack(code, "Top"), t0, 2)

	-- Wait for BOTH sides, not the first arrival. Breaking on the first one
	-- scored the loser as "never showed up" and threw its gap away.
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

	-- gather every receipt for this code, in arrival order
	local mine, theirs
	for i = before + 1, #Place.Server.receipts do
		local r = Place.Server.receipts[i]
		if r.code == code then
			if r.cid == 2 then theirs = theirs or r.at else mine = mine or r.at end
		end
	end
	return mine, theirs, t0
end

local function raceSet(label, opts, n)
	n = n or 40
	local wins, losses, ties, gaps = 0, 0, 0, {}
	local noShow = 0
	for i = 1, n do
		local mine, theirs = runRace(i, n, opts)
		if not mine and not theirs then
			noShow += 1
		elseif mine and not theirs then
			wins += 1
		elseif theirs and not mine then
			losses += 1
		else
			local d = (mine - theirs) * 1000
			gaps[#gaps + 1] = d
			-- Under 0.05 ms the two packets land in the same server tick and
			-- the order is decided by the NIC and the OS, not by either
			-- script. Scoring that as a loss would be inventing a result.
			if math.abs(d) < 0.05 then ties += 1
			elseif d < 0 then wins += 1
			else losses += 1 end
		end
		Env.run(0.05)
	end
	table.sort(gaps)
	local med = #gaps > 0 and gaps[(#gaps + 1) // 2] or 0
	print(string.format("  %-38s  win %3d  tie %3d  lose %3d   median gap %+7.2f ms",
		label, wins, ties, losses, med))
	return wins, losses, med
end

--------------------------------------------------------------------------------
print("")
print("  hypothesis 1: the rival's code is no faster than yours.")
print("  We cannot know that it is -- but we do know LUCK's handler has no")
print("  room left in it, so this is the case worth pricing. Identical code,")
print("  fps and ping; the ONLY difference is that two clients on one machine")
print("  never share a frame clock.")
print("")
print(string.format("  %-38s  %s", "rival's frame grid offset", "result"))
print("  " .. string.rep("-", 76))

rivalPending = rivalReactive
for _, off in ipairs({ 0, 1, 2, 4, 8, 12, 16 }) do
	Env.setRival({ fps = 60, phase = -off / 1000, handler = rivalReactive })
	rivalPending = rivalReactive
	raceSet(string.format("rival's frames land %2d ms before yours", off), nil, 40)
end

print("")
print("  hypothesis 2: some OTHER channel carries the code before the notify")
print("  remote fires, and the rival reads that one. LUCK is already on the")
print("  notify remote's OnClientEvent, which is as early as that remote can")
print("  be observed -- so this is about WHICH channel, not how it is read.")
print("")
print(string.format("  %-38s  %s", "how much earlier", "result"))
print("  " .. string.rep("-", 76))

for _, lead in ipairs({ 1, 5, 17, 50 }) do
	Env.setRival({ fps = 60, phase = 0, handler = rivalReactive })
	rivalPending = rivalReactive
	raceSet(string.format("rival's source is %2d ms ahead", lead),
		{ rivalLeadMs = lead }, 40)
end

print("")
print("  the quantisation test: does a head start of X actually buy anything?")
print("  swept from one microsecond to well past a frame. if latency were")
print("  continuous this would be a slope. the outgoing replication step is a")
print("  rendezvous -- everything queued before it leaves at the same instant --")
print("  so it should be a staircase with exactly one step in it.")
print("")
print(string.format("  %-38s  %s", "rival's head start", "result"))
print("  " .. string.rep("-", 76))

for _, lead in ipairs({ 0.001, 0.01, 0.1, 0.5, 1, 2, 4, 8, 12, 16, 17, 20, 34 }) do
	Env.setRival({ fps = 60, phase = 0, handler = rivalReactive })
	rivalPending = rivalReactive
	local label
	if lead < 1 then
		label = string.format("%8.0f ns ahead", lead * 1e6)
	else
		label = string.format("%8.0f ms ahead", lead)
	end
	raceSet(label, { rivalLeadMs = lead }, 40)
end

print("")
print("  hypothesis 3: the rival does not react at all -- it pre-fires.")
print("  Nothing about your reaction time matters against this.")
print("")

do
	local guessHz = 20
	Env.setRival({
		fps = 60, phase = 0,
		onFrame = function()
			-- spray the live code space; on a real client this is a guess loop
			for c in pairs(Place.Server.live) do
				if not Place.Server.redeemed[c] then rivalFire(c) end
			end
		end,
	})
	rivalPending = nil
	raceSet("rival pre-fires every frame", {}, 20)
	Env.setRival(nil)
end

print("")
print("  " .. string.rep("-", 76))
print("  None of this identifies which case you are actually in. What it")
print("  gives you is the signature of each: a fixed frame offset loses a")
print("  FIXED FRACTION of races; an earlier source under one frame mostly")
print("  ties; over one frame it loses every single time. Match the pattern")
print("  you see in game against these and you know which one you have.")
print("")
