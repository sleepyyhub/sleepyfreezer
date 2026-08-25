do
local R = RIG
local H = R.H
local notifyRemote = R.notifyRemote
local RepS, genvTable = R.RepS, R.genvTable
H.pump(40000)
local L = genvTable.LUCK
if not L then print("no getgenv().LUCK -- cannot measure") return end

-- Same starting point for both builds: auto on, remote route, threshold 1.
L.AutoOn, L.GuessCode, L.Threshold, L.RedeemPath = true, false, 1, "remote"
if L.SyncHot then L.SyncHot() elseif L.SyncFast then L.SyncFast() end
H.pump(20000)

print(("handler       %s        pole %s        detect live %s")
    :format(tostring(L.HandlerName), tostring(L.PoleOn ~= nil and L.PoleOn or "n/a"),
            tostring(L.RemoteDetectOn)))
print(("redeem        %s (%s)   tested %s"):format(
    L.RedeemRemote and L.RedeemRemote.Name or "none",
    tostring(L.RedeemRemoteSource), tostring(L.RedeemRemoteTested)))

print(("fastReady %s   FastInvoke %s   AutoOn %s   Threshold %s   Guess %s   path %s")
    :format(tostring(L.FastReady), tostring(L.FastInvoke ~= nil), tostring(L.AutoOn),
            tostring(L.Threshold), tostring(L.GuessCode), tostring(L.RedeemPath)))
if L.SyncFast then L.SyncFast() end
print(("after an explicit SyncFast: handler %s   fastReady %s")
    :format(tostring(L.HandlerName), tostring(L.FastReady)))

local CLOCK_NS
do
    local n = 200000
    local t = os.clock()
    for _ = 1, n do local _ = os.clock() end
    CLOCK_NS = (os.clock() - t) / n * 1e9
end

-- Announcement dispatched to EVERY handler, in connection order, exactly as a real
-- client does it. Timed from the start of that dispatch to our invoke, so whatever
-- runs ahead of us is counted -- which is the whole point of the comparison.
local function detectToSend(n, tag)
    local codes = table.create(n)
    for i = 1, n do codes[i] = tag .. i end
    for i = 1, math.min(n, 400) do
        notifyRemote.OnClientEvent:FireAll(codes[i], 5.5, nil, "Top")
    end
    H.pump(40000)
    local acc, hits = 0, 0
    for i = 1, n do
        R.clearStamp()
        local t0 = os.clock()
        notifyRemote.OnClientEvent:FireAll(codes[i], 5.5, nil, "Top")
        local t1 = R.invokeStamp()
        if t1 and t1 >= t0 then acc += (t1 - t0); hits += 1 end
        if i % 400 == 0 then H.pump(20000) end
    end
    H.pump(60000)
    if hits == 0 then return nil, 0 end
    return acc / hits * 1e9 - CLOCK_NS, hits
end

local ns, hits = detectToSend(4000, "CMP")
print(("detect -> send   %s   (%d of 4000 announcements produced a send)")
    :format(ns and ("%.0f ns"):format(ns) or "never sent", hits))

-- and the same build with pole dropped, to separate "who runs first" from the handler
if L.DropPole and L.PoleOn then
    pcall(L.DropPole); H.pump(20000)
    local n2, h2 = detectToSend(4000, "NOPOLE")
    print(("  same build, pole dropped   %s   (%d of 4000)")
        :format(n2 and ("%.0f ns"):format(n2) or "never sent", h2))
    pcall(L.TakePole); H.pump(20000)
end

-- exactly-once
local before = R.invokeCount()
for _ = 1, 20 do notifyRemote.OnClientEvent:FireAll("ONECODE", 5.5, nil, "Top") end
H.pump(40000)
print(("one code announced 20x   ->   %d redeems"):format(R.invokeCount() - before))

-- distinct codes still all land
local b2 = R.invokeCount()
for i = 1, 30 do notifyRemote.OnClientEvent:FireAll("MANY" .. i, 5.5, nil, "Top") end
H.pump(40000)
print(("30 distinct codes        ->   %d redeems"):format(R.invokeCount() - b2))

-- test sender, if it is reachable
if L.SenderSubmit and L.SenderBox then
    local r0, g0 = R.invokeCount(), R.gameHandlerCalls()
    L.SenderBox.Text = "SENDERTEST"
    L.SenderSubmit(); L.SenderSubmit()
    H.pump(20000)
    print(("test sender, one action  ->   %d redeems, %d game popups")
        :format(R.invokeCount() - r0, R.gameHandlerCalls() - g0))
else
    print("test sender              ->   not exposed for testing in this build")
end
print(("runtime errors: %d"):format(H.errors and #H.errors or 0))
end
