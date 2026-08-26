do
-- Covers the three things the vararg-pack rework and the sent[] reorder actually
-- changed: FIFO slots must not lose or transpose an entry, and the exactly-once flag
-- must be readable by other surfaces while InvokeServer is still yielding.
local R = RIG
local H = R.H
H.pump(40000)
local L = R.genvTable.LUCK
if not L then print("no getgenv().LUCK") return end

local fails, checks = {}, 0
local function check(n, c, d)
    checks += 1
    if not c then fails[#fails + 1] = n .. (d and ("  -- " .. d) or "") end
end

print("DEFERRED-QUEUE / EXACTLY-ONCE")
print("================================================================")

-- 1. two announcements in one frame: both must be sent, in order, with their own
--    payloads surviving the shared flat slots
do
    local before = #R.sentLog()
    local histBefore = #L.CodeHistory
    R.notifyRemote.OnClientEvent:FireAll("QUEUEONE", 5.5, "Sounds.Sfx.Blop", "Top")
    R.notifyRemote.OnClientEvent:FireAll("QUEUETWO", 5.5, "Sounds.Sfx.Blop", "Top")
    H.pump(200000)
    local log = R.sentLog()
    local got = {}
    for i = before + 1, #log do got[#got + 1] = log[i] end
    check("both same-frame codes are sent", #got == 2, "sent=" .. table.concat(got, ","))
    check("in announcement order", got[1] == "QUEUEONE" and got[2] == "QUEUETWO",
        table.concat(got, ","))

    -- each has to come back out of the shared slots carrying its own code
    local seen = {}
    for _, item in ipairs(L.CodeHistory) do seen[tostring(item.code)] = true end
    check("QUEUEONE comes back out of the queue as itself", seen.QUEUEONE == true,
        "history=" .. tostring(#L.CodeHistory) .. " before=" .. tostring(histBefore))
    check("QUEUETWO comes back out of the queue as itself", seen.QUEUETWO == true)
end

-- 2. a burst deeper than the rings hold (32 entries each), so the full-ring fallback
--    to the plain vararg defer is exercised and has to keep order with the ring
do
    local before = #R.sentLog()
    local n = 120
    for i = 1, n do
        R.notifyRemote.OnClientEvent:FireAll("BURST" .. i, 5.5, "Sounds.Sfx.Blop", "Top")
    end
    H.pump(400000)
    local log, ok = R.sentLog(), true
    check("every code in a 120-deep burst is sent", #log - before == n,
        "sent=" .. tostring(#log - before))
    for i = 1, n do
        if log[before + i] ~= ("BURST" .. i) then ok = false end
    end
    check("burst drains in order", ok,
        "first mismatch around " .. tostring(log[before + 1]))
end

-- 3. the exactly-once flag has to be written BEFORE the invoke. The default sender
--    (soloRaw) only writes it, never tests it -- guarded is the one that reads it. So
--    the hole is: send on soloRaw, and while InvokeServer is still yielding, flip
--    MultiSurface so the next announcement lands on guarded. Written after the invoke,
--    the flag is still clear for the whole round trip and guarded resends.
do
    local resume
    local restore = R.setInvokeBehaviour(function(remote, code)
        -- park the send mid-flight, exactly like a real InvokeServer round trip
        local co = coroutine.running()
        resume = function() task.spawn(co, false, "Invalid Code") end
        return coroutine.yield()
    end)

    -- H.pump fast-forwards the virtual clock to the next timer, so where the warmup
    -- happens to stop decides whether the 30s janitor -- which clears sent[] and the
    -- in-flight marker -- lands in the middle of this test. Wait for a clear to happen,
    -- then start: that buys a full 30s of runway instead of leaving it to chance.
    L.SentCodes.__runway = true
    for _ = 1, 200 do
        H.pump(4000, H.virtualNow() + 0.5)
        if L.SentCodes.__runway == nil then break end
    end
    check("the test has a clean janitor window", L.SentCodes.__runway == nil)

    print("     handler at the time of the send: " .. tostring(L.HandlerName))
    -- Cap each advance to 20ms, well inside one round trip.
    local function tick() H.pump(20000, H.virtualNow() + 0.02) end
    local before = R.invokeCount()
    -- fired from a coroutine, because the send is going to park mid-call
    task.spawn(function()
        R.notifyRemote.OnClientEvent:FireAll("INFLIGHT1", 5.5, "Sounds.Sfx.Blop", "Top")
    end)
    tick()
    check("the send is actually in flight", R.invokeCount() - before == 1 and resume ~= nil,
        "invokes=" .. tostring(R.invokeCount() - before))
    local f1 = L.InFlight and L.InFlight() or nil
    check("the in-flight marker is set for it", f1 == "INFLIGHT1", "fly1=" .. tostring(f1))

    L.MultiSurface = true
    if L.SyncFast then L.SyncFast() end
    print("     handler after MultiSurface: " .. tostring(L.HandlerName))
    -- on a coroutine too: if it does resend, that send parks the same way
    task.spawn(function()
        R.notifyRemote.OnClientEvent:FireAll("INFLIGHT1", 5.5, "Sounds.Sfx.Blop", "Top")
    end)
    tick()
    check("no resend while the first round trip is still open",
        R.invokeCount() - before == 1,
        "invokes=" .. tostring(R.invokeCount() - before))

    if resume then resume() end
    H.pump(200000)
    L.MultiSurface = false
    if L.SyncFast then L.SyncFast() end
    R.setInvokeBehaviour(restore)
end

print("")
print(("checks: %d   failures: %d"):format(checks, #fails))
for _, f in ipairs(fails) do print("  FAIL  " .. f) end
print(("runtime errors: %d"):format(H.errors and #H.errors or 0))
if H.errors then
    local seen = {}
    for _, e in ipairs(H.errors) do
        local k = tostring(e)
        if not seen[k] then seen[k] = true; print("  ERR  " .. k) end
    end
end
end
