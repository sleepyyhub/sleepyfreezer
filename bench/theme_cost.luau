do
-- What the sweep costs the main thread.
--
-- It used to ride RenderStepped, so the bill was one Lua call per FRAME -- about
-- a thousand a second at the cap -- to do work thirty times a second. Now it
-- wakes on its own schedule, so the bill is the work and nothing else. Both
-- numbers are here: what one update costs, and how often anything runs at all.
local R = RIG
local H = R.H
H.pump(200000)
local L = R.genvTable.LUCK

-- Nothing of ours may be sitting on the render signal. The base build holds no
-- standing per-frame callback and this build must not put one back.
local onRender = 0
do
    local ok, conns = pcall(getconnections, RunServiceRef and RunServiceRef.RenderStepped)
    if ok and type(conns) == "table" then onRender = #conns end
end
print(("  per-frame callbacks   %d"):format(onRender))

local N = 4000
local rate = 1 / math.max(1, L.ThemeFps)

-- One update, driven straight, with the throttle cleared each time.
local t0 = os.clock()
for _ = 1, N do RENDER(1, rate) end
local perSec = (os.clock() - t0) / N

-- Wakeups and bytes over a virtual minute of the script just sitting there.
collectgarbage("collect"); collectgarbage("collect")
local vb, vt = collectgarbage("count"), H.virtualNow()
H.pump(400000, H.virtualNow() + 60)
local dt = H.virtualNow() - vt
local db = collectgarbage("count") - vb

print(("  one update            %8.2f us   (%d keypoints)"):format(perSec * 1e6, L.ThemeKeys))
print(("  at %d updates/sec      %6.3f%% of one core"):format(L.ThemeFps, perSec * L.ThemeFps * 100))
print(("  garbage while idle    %8.0f bytes/s over %.0f virtual s"):format(db * 1024 / math.max(dt, 1), dt))
print(("  a 999fps frame is 1000 us; the sweep is now off the frame clock entirely"))
end
