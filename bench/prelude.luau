-- Harness prelude: minimal Roblox-side stand-ins so the REAL hot-path block
-- from LUCK.txt (lines 1435-1826, pasted verbatim below) loads and runs.
-- Nothing in the measured path is rewritten; only the engine boundary is stubbed.

local INVOKES = 0
local function fakeInvokeServer(self, code)
	INVOKES += 1
	return true, "sent"
end
local function fakeFireServer(self, code)
	INVOKES += 1
end

-- task.* stand-ins. spawn/wait are no-ops so the script's housekeeping loops
-- (table.clear(sent) every 30s) never fire during a measurement.
local task = {
	spawn = function() end,
	wait = function() end,
	defer = function() end, -- replaced per-experiment by the driver
	delay = function() end,
	cancel = function() end,
}
local function typeof(v) return type(v) end
local game = { GetService = function() return nil end, PlaceId = 0 }
local workspace = nil

local L = {}
L.PacketSeen = {}
L.PacketDupWindow = 0.15
L.Settings = { PartTTL = 12 }
L.DedupOn = true
