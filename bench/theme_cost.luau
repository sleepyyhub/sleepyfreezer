do
-- What does the sweep actually cost the main thread? It runs on RenderStepped, so it
-- competes with everything else there -- the number worth knowing is per second, not
-- per tick.
local R = RIG
local H = R.H
H.pump(200000)
local L = R.genvTable.LUCK

local N = 20000
local t0 = os.clock()
for _ = 1, N do RENDER(1, 1 / 30) end          -- every frame clears the throttle
local perTick = (os.clock() - t0) / N * 1e6

L.ThemeOn = false
local t1 = os.clock()
for _ = 1, N do RENDER(1, 1 / 30) end
local perSkip = (os.clock() - t1) / N * 1e6
L.ThemeOn = true

print(("  one update        %8.2f us   (%d gradients, %d keypoints)")
    :format(perTick, 9, L.ThemeKeys))
print(("  skipped frame     %8.2f us"):format(perSkip))
print(("  at %d updates/sec  %6.2f%% of one core")
    :format(L.ThemeFps, perTick * L.ThemeFps / 10000))
print(("  a 999fps frame is  %6.2f us, so a frame that updates spends %.1f%% of it")
    :format(1000, perTick / 1000 * 100))
end
