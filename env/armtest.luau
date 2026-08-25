-- How long until the script is actually able to send? Nothing else in this
-- comparison matters if one build spends longer than the other unarmed.
local Env = require("./roblox")
local Place = require("./place")
local Sandbox = require("./sandbox")
local Input = require("./_source")

local errors = {}
Env.onError = function(e) errors[#errors + 1] = tostring(e) end
local G, genv = Sandbox.build()
local chunk = loadstring(Input.source, "@LUCK")
setfenv(chunk, G)
local t0 = Env.now()
local ok = pcall(chunk)
if not ok then print("BOOT FAILED") return end

-- Probe: call the connect by hand a few times right after load and record what
-- it returns, so a slow arm can be told apart from a failing one.
local probe = {}
for i = 1, 3 do
	Env.run(0.05)
	local L0 = genv.LUCK
	if type(L0) == "table" and L0.ConnectNotifyRemote then
		local pok, res = pcall(L0.ConnectNotifyRemote)
		probe[#probe + 1] = string.format(
			"try %d: pcall=%s result=%s  NotifyRemote=%s  FastNotify=%s  DetectOn=%s",
			i, tostring(pok), tostring(res),
			tostring(L0.NotifyRemote ~= nil), tostring(L0.FastNotify ~= nil),
			tostring(L0.RemoteDetectOn))
	end
end

local armedAt, detectAt, readyAt, notifyAt
local detectSrc, notifySrc
for _ = 1, 4000 do
	Env.run(0.02)
	local L = genv.LUCK
	if type(L) == "table" then
		if not detectAt and L.RemoteDetectOn then
			detectAt = Env.now()
			detectSrc = L.NotifyRemoteSource
		end
		if not notifyAt and L.NotifyRemote then
			notifyAt = Env.now()
			notifySrc = L.NotifyRemoteSource
		end
		if not armedAt and L.RedeemRemote then armedAt = Env.now() end
		if not readyAt and L.FastReady then readyAt = Env.now() end
		if detectAt and armedAt and readyAt then break end
	end
end

local L = genv.LUCK
print("")
print("  ARMING -- " .. Input.path)
print(string.format("    redeem remote resolved   %s",
	armedAt and string.format("%7.3f s", armedAt - t0) or "never"))
print(string.format("    notify remote FOUND      %s   via %s",
	notifyAt and string.format("%7.3f s", notifyAt - t0) or "never",
	tostring(notifySrc)))
print(string.format("    notify detect LIVE       %s   via %s",
	detectAt and string.format("%7.3f s", detectAt - t0) or "never",
	tostring(detectSrc)))
print(string.format("    fastReady (can send)     %s",
	readyAt and string.format("%7.3f s", readyAt - t0) or "never"))
print(string.format("    handler                  %s", tostring(L and L.HandlerName)))
print(string.format("    real cpu to get there    %7.3f s", Env.realBurned()))
for _, line in ipairs(probe) do print("    " .. line) end
if L then
	print(string.format("    discoverPass errors      %s", tostring(L.DiscoverErrs or 0)))
	if L.DiscoverErr then print("    last error: " .. tostring(L.DiscoverErr)) end
end
print("")
