do
-- What a real code drop costs.
--
-- The amortised number (6000 announcements back to back) is not the number that
-- decides a race. Codes arrive one at a time with a long quiet gap in front of
-- them, so every send is a cold send: the deferred tail from last time has long
-- since drained, the heap has moved on, and a GC step can land anywhere.
--
-- This fires ONE announcement, drains everything, idles, and fires the next --
-- then reports the distribution rather than the mean, because a race is lost by
-- the tail and not by the median.
local R = RIG
local H = R.H
local notifyRemote = R.notifyRemote
H.pump(200000)
local L = R.genvTable.LUCK
if not L then print("no getgenv().LUCK") return end

L.AutoOn, L.GuessCode, L.Threshold, L.RedeemPath = true, false, 1, "remote"
L.SyncHot(); H.pump(40000)

local N = tonumber(_G.COLD_N) or 400

local function sample(n, tag)
    local out = table.create(n)
    local kept = 0
    for i = 1, n do
        -- Everything the last announcement left behind: the deferred tail, its
        -- timers, the janitor. Drained before the clock starts, exactly as it
        -- would be by the time the next code drops.
        H.pump(4000)
        R.clearStamp()
        local code = tag .. i
        local t0 = os.clock()
        notifyRemote.OnClientEvent:FireAll(code, 5.5, nil, "Top")
        local t1 = R.invokeStamp()
        if t1 then
            kept += 1
            out[kept] = (t1 - t0) * 1e9
        end
    end
    table.sort(out, function(a, b) return a < b end)
    return out, kept
end

local function pct(t, n, p)
    if n == 0 then return 0 end
    local i = math.clamp(math.floor(p * n + 0.5), 1, n)
    return t[i]
end

-- Warm the paths once so the very first call's one-time cost does not land in
-- the sample; after that every entry is a genuine cold send.
sample(40, "WARM")

local s, n = sample(N, "COLD")
print("")
print("one announcement, cold, x" .. n)
print("---------------------------------------------------------------")
print(string.format("  min      %8.0f ns", s[1] or 0))
print(string.format("  median   %8.0f ns", pct(s, n, 0.50)))
print(string.format("  p90      %8.0f ns", pct(s, n, 0.90)))
print(string.format("  p99      %8.0f ns", pct(s, n, 0.99)))
print(string.format("  max      %8.0f ns", s[n] or 0))

local sum = 0
for i = 1, n do sum += s[i] end
print(string.format("  mean     %8.0f ns", sum / n))

-- How much of the total is spent above the floor, i.e. what a perfect run would
-- give back. This is the size of the prize, and it is all tail.
local floor = s[1] or 0
local waste = sum - floor * n
print(string.format("  over the floor, total %.0f us across %d sends", waste / 1000, n))
print("")
print("checks: 0   failures: 0")
print("runtime errors: 0")
end
