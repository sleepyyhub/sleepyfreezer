--[[
    Proves the result notification actually fires, with the right text, once.

    The server is made to answer with real prize strings. Then:
      * L.Notify is wrapped to capture every line the feed receives
      * L.Toast is wrapped to capture what the game-side popup receives
    and both are checked against what the server actually said.

    Also covers the double-notify case: a fire-and-forget remote learns its
    result from a follow-up announcement, claimOurs shows it, and PostRedeem
    must not then show it a second time.

    Usage:  ./run.sh /path/to/LUCK.txt notify
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
Env.run(6.0)

local L = genv.LUCK
if type(L) ~= "table" then print("LUCK did not arm") return end

print("")
print("================================================================")
print("  RESULT NOTIFICATION TEST")
print("================================================================")
print(string.format("  handler=%s  remoteDetect=%s", tostring(L.HandlerName),
	tostring(L.RemoteDetectOn)))

--------------------------------------------------------------------------------
-- capture what reaches the screen
--------------------------------------------------------------------------------
local feed, toasts = {}, {}

local function wrap()
	local realNotify = L.Notify
	L.Notify = function(text, colour)
		-- the colour is half the contract: first return true -> green,
		-- false -> red. Capturing only the text would let a wrong colour
		-- pass the suite unnoticed.
		feed[#feed + 1] = tostring(text)
		feed[#feed] = tostring(text)
		feed.colours = feed.colours or {}
		feed.colours[#feed] = colour
		if type(realNotify) == "function" then return realNotify(text, colour) end
	end
	local realToast = L.Toast
	L.Toast = function(text, colour)
		toasts[#toasts + 1] = tostring(text)
		if type(realToast) == "function" then return realToast(text, colour) end
	end
end
wrap()

-- LUCK gates its own feed behind the intro animation; in a headless run that
-- never completes, so mark it done or nothing would be recorded at all.
L.IntroDone = true

--------------------------------------------------------------------------------
-- make the server answer with a real prize line
--------------------------------------------------------------------------------
local PRIZE = "Meowl spawned!"
local redeem = Place.redeemRemote
Env.serverHandlers[redeem] = function(kind, payload, arrivedAt, wire)
	local code = payload[1]
	if type(code) ~= "string" then return false, "INVALID" end
	code = code:upper()
	Place.Server.receipts[#Place.Server.receipts + 1] = {
		code = code, at = arrivedAt, accepted = Place.Server.live[code] == true,
		cid = wire and wire.cid or 1,
	}
	if not Place.Server.live[code] then return false, "Invalid code" end
	if Place.Server.redeemed[code] then return false, "Already redeemed" end
	Place.Server.redeemed[code] = arrivedAt
	return true, PRIZE
end

Env.CFG.fps = 240
Env.CFG.pingMs = 20
Env.CFG.signalBehavior = "Immediate"

local function drop(code, live)
	local n = #feed
	if live then Place.Server:publish(code) end
	Env.queueToClient(function(...)
		Place.notifySignal:Fire(...)
	end, table.pack(code, 5, nil, "Top"), Env.now(), 1)
	Env.run(0.8)
	local new = {}
	for i = n + 1, #feed do new[#new + 1] = feed[i] end
	return new
end

local function contains(list, needle)
	for _, v in ipairs(list) do
		if v:find(needle, 1, true) then return v end
	end
	return nil
end

local pass, fail = 0, 0
local function check(name, cond, detail)
	if cond then
		pass += 1
		print(string.format("  PASS  %-46s %s", name, detail or ""))
	else
		fail += 1
		print(string.format("  FAIL  %-46s %s", name, detail or ""))
	end
end

--------------------------------------------------------------------------------
print("")
print("  the server answers a good code with: " .. PRIZE)
print("")

local lines = drop("MEOWLCODE", true)
local hit = contains(lines, PRIZE)
check("prize reaches the feed", hit ~= nil, hit and ("\"" .. hit .. "\"") or "nothing")

local n = 0
for _, v in ipairs(lines) do if v:find(PRIZE, 1, true) then n += 1 end end
check("shown exactly once", n == 1, string.format("%d line(s)", n))

check("code is carried alongside it",
	hit ~= nil and hit:find("MEOWLCODE", 1, true) ~= nil,
	hit or "-")

local tHit = contains(toasts, PRIZE)
check("game-side popup leads with the prize",
	tHit ~= nil and tHit:find(PRIZE, 1, true) < tHit:find("MEOWLCODE", 1, true),
	tHit or "nothing")

-- the colour half of the contract
local function colourOf(needle)
	for i, v in ipairs(feed) do
		if v:find(needle, 1, true) then return feed.colours and feed.colours[i] end
	end
	return nil
end
local function sameColour(a, b)
	-- Compare components directly. `typeof` here is the host's, not the
	-- sandbox's, so it reports "table" for a sandbox Color3 and a type guard
	-- would reject correct colours -- which is exactly what it did first time.
	if type(a) ~= "table" or type(b) ~= "table" then return false end
	if type(a.R) ~= "number" or type(b.R) ~= "number" then return false end
	return math.abs(a.R - b.R) < 1e-4
		and math.abs(a.G - b.G) < 1e-4
		and math.abs(a.B - b.B) < 1e-4
end
local GREEN = G.Color3.fromRGB(146, 255, 103)
local RED   = G.Color3.fromRGB(255, 130, 155)

local okColour = colourOf(PRIZE)
check("first return true  -> green", sameColour(okColour, GREEN),
	okColour and string.format("rgb(%.0f,%.0f,%.0f)",
		okColour.R * 255, okColour.G * 255, okColour.B * 255) or "nil")

-- a bad code
local before = #feed
local badLines = drop("NOTACODE", false)
local badHit = contains(badLines, "Invalid code")
check("failure reply also reaches the feed", badHit ~= nil,
	badHit and ("\"" .. badHit .. "\"") or "nothing")

local badColour = colourOf("Invalid code")
check("first return false -> red", sameColour(badColour, RED),
	badColour and string.format("rgb(%.0f,%.0f,%.0f)",
		badColour.R * 255, badColour.G * 255, badColour.B * 255) or "nil")

-- placeholder must be suppressed
check("\"sent\" placeholder is not shown",
	contains(feed, "» sent") == nil, "-")

-- the dedup guard
L.ResultShown = "GUARDED"
local shown = L.ResultNotify("GUARDED", true, "Something spawned!")
check("claimOurs marker suppresses the repeat", shown == false,
	"ResultNotify returned " .. tostring(shown))
check("marker clears after use", L.ResultShown == nil,
	"ResultShown = " .. tostring(L.ResultShown))

-- and it still fires for the next, different code
local shown2 = L.ResultNotify("FRESHONE", true, "Tralalero spawned!")
check("next code still notifies", shown2 == true,
	"ResultNotify returned " .. tostring(shown2))

print("")
print(string.format("  %d passed, %d failed", pass, fail))
if #errors > 0 then
	print(string.format("  thread errors: %d", #errors))
	for i = 1, math.min(#errors, 4) do print("    " .. errors[i]) end
end
print("")
