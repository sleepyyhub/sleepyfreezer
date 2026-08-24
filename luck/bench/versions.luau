-- Timed epilogue. Appended after a real LUCK build so the whole detection
-- path runs: the notify RemoteEvent is fired and the time until control
-- returns is the synchronous work between the announcement arriving and the
-- redeem going out. Deferred bookkeeping is excluded on purpose -- it happens
-- after the packet and cannot delay it.

local L = GENV.LUCK
assert(L, "build did not publish itself into getgenv()")

L.AutoOn = true
L.Threshold = 1
L.GuessCode = false
if L.SyncHot then L.SyncHot() end

local N = tonumber(BENCH_N) or 20000
local ROUNDS = tonumber(BENCH_ROUNDS) or 9

local codes = table.create(N)
for i = 1, N do codes[i] = "VBENCH" .. i end

local signal = NOTIFY_REMOTE._signals.OnClientEvent
local fire = signal.Fire

local function clearState()
    if L.SentCodes then table.clear(L.SentCodes) end
    if L.FiredSeen then table.clear(L.FiredSeen) end
    if L.PacketSeen then table.clear(L.PacketSeen) end
    for k in pairs(SENT_LOG) do SENT_LOG[k] = nil end
    L.OursPending = nil
end

-- One warm pass so any lazily resolved state is already in place.
for i = 1, math.min(N, 500) do fire(signal, codes[i], 5, nil, "Top") end
local warmed = #SENT_LOG
clearState()

local samples = {}
for _ = 1, ROUNDS do
    clearState()
    local started = os.clock()
    for i = 1, N do
        fire(signal, codes[i], 5, nil, "Top")
    end
    local elapsed = os.clock() - started
    samples[#samples + 1] = elapsed / N * 1e9
end

table.sort(samples)
local sum = 0
for _, v in ipairs(samples) do sum += v end

print(("NOTIFY_CONNECTIONS=%d"):format(#(getconnections(signal) or {})))
print(("SENDS_PER_FIRE=%.2f"):format(warmed / math.min(N, 500)))
print(("VERSION=%s"):format(BENCH_LABEL or "?"))
print(("SENDS_PER_WARM=%d"):format(warmed))
print(("N=%d ROUNDS=%d"):format(N, ROUNDS))
print(("MIN=%.1f"):format(samples[1]))
print(("MEDIAN=%.1f"):format(samples[(#samples + 1) // 2]))
print(("MEAN=%.1f"):format(sum / #samples))
print(("MAX=%.1f"):format(samples[#samples]))
local raw = {}
for _, v in ipairs(samples) do raw[#raw + 1] = ("%.1f"):format(v) end
print(("ALL=%s"):format(table.concat(raw, " ")))

-- Latency, not total CPU. The stub stamps LAST_SEND_AT the instant the send
-- is entered, so this is the announcement-to-packet gap and excludes the
-- bookkeeping that runs after it. Two clock calls per iteration are part of
-- the reading, so their cost is measured separately and subtracted.
local pairCost = 0
do
    local acc = 0
    for _ = 1, N do
        local a = os.clock()
        local b = os.clock()
        acc += (b - a)
    end
    pairCost = acc / N
end

local latency = {}
for _ = 1, ROUNDS do
    clearState()
    local acc = 0
    for i = 1, N do
        local t0 = os.clock()
        fire(signal, codes[i], 5, nil, "Top")
        acc += (LAST_SEND_AT - t0)
    end
    latency[#latency + 1] = math.max(acc / N - pairCost, 0) * 1e9
end
table.sort(latency)
local lsum = 0
for _, v in ipairs(latency) do lsum += v end

print(("CLOCKPAIR_NS=%.1f"):format(pairCost * 1e9))
print(("LATENCY_MIN=%.1f"):format(latency[1]))
print(("LATENCY_MEDIAN=%.1f"):format(latency[(#latency + 1) // 2]))
print(("LATENCY_MEAN=%.1f"):format(lsum / #latency))
print(("LATENCY_MAX=%.1f"):format(latency[#latency]))
local lraw = {}
for _, v in ipairs(latency) do lraw[#lraw + 1] = ("%.1f"):format(v) end
print(("LATENCY_ALL=%s"):format(table.concat(lraw, " ")))

-- Reference: the same signal, the same fire, but the handler does nothing
-- except the send. Whatever this costs is dispatch and call overhead that
-- belongs to the engine, not to the script. The gap between it and the real
-- build is the script's actual contribution to latency.
local refSignal = REF_REMOTE._signals.OnClientEvent
refSignal:Connect(function(msg)
    LAST_SEND_AT = os.clock()
end)
local refFire = refSignal.Fire

local ref = {}
for _ = 1, ROUNDS do
    local acc = 0
    for i = 1, N do
        local t0 = os.clock()
        refFire(refSignal, codes[i], 5, nil, "Top")
        acc += (LAST_SEND_AT - t0)
    end
    ref[#ref + 1] = math.max(acc / N - pairCost, 0) * 1e9
end
table.sort(ref)
print(("DISPATCH_MEDIAN=%.1f"):format(ref[(#ref + 1) // 2]))
print(("SCRIPT_SHARE=%.1f"):format(
    latency[(#latency + 1) // 2] - ref[(#ref + 1) // 2]))

-- Second reference, shaped like the real handler: it reaches the stamp
-- through a call rather than inline, because the real handler cannot stamp
-- inline -- it has to call into the send. The gap between this and the real
-- build is the script's logic and nothing else.
local sink = function(_, msg) LAST_SEND_AT = os.clock() end
local shaped = REF2_REMOTE._signals.OnClientEvent
shaped:Connect(function(msg, _, _, position)
    return sink(nil, msg)
end)
local shapedFire = shaped.Fire

local ref2 = {}
for _ = 1, ROUNDS do
    local acc = 0
    for i = 1, N do
        local t0 = os.clock()
        shapedFire(shaped, codes[i], 5, nil, "Top")
        acc += (LAST_SEND_AT - t0)
    end
    ref2[#ref2 + 1] = math.max(acc / N - pairCost, 0) * 1e9
end
table.sort(ref2)
local m2 = ref2[(#ref2 + 1) // 2]
print(("DISPATCH_PLUS_CALL=%.1f"):format(m2))
print(("LOGIC_ONLY=%.1f"):format(latency[(#latency + 1) // 2] - m2))
