do
local R = RIG
local H = R.H
local notifyRemote, redeemRemote = R.notifyRemote, R.redeemRemote
local RepS, genvTable = R.RepS, R.genvTable
local fpsCapSet = R.fpsCap()

H.pump(40000)

local L = genvTable.LUCK
if not L then print("no getgenv().LUCK") return end

print(("environment    place %s   instances in ReplicatedStorage %d")
    :format(tostring(game.PlaceId), #RepS:GetDescendants()))
print(("resolved       notify %s (%s)   redeem %s (%s)   tested %s"):format(
    L.NotifyRemote and L.NotifyRemote.Name or "none", tostring(L.NotifyRemoteSource),
    L.RedeemRemote and L.RedeemRemote.Name or "none", tostring(L.RedeemRemoteSource),
    tostring(L.RedeemRemoteTested)))
print(("binding        handler %s   pole held %s   detect live %s   fps cap %s"):format(
    tostring(L.HandlerName), tostring(L.PoleOn), tostring(L.RemoteDetectOn),
    tostring(fpsCapSet)))
print("")

-- Cost of reading the clock, so it can be subtracted from every delta below.
local CLOCK_NS
do
    local n = 200000
    local t = os.clock()
    for _ = 1, n do local _ = os.clock() end
    CLOCK_NS = (os.clock() - t) / n * 1e9
end

local function announce(code)
    R.clearStamp()
    local before = R.invokeCount()
    local t0 = os.clock()
    notifyRemote.OnClientEvent:FireDirect(code, 5.5, "Sounds.Sfx.Blop", "Top")
    local t1 = R.invokeStamp()
    if R.invokeCount() == before or not t1 then return nil end
    return (t1 - t0) * 1e9 - CLOCK_NS
end

print("three announcements, one at a time, cold")
print("---------------------------------------------------------------")
for i = 1, 3 do
    local ns = announce("LUCKYDROP" .. i)
    print(("  #%d  LUCKYDROP%d   detect -> send  %9.0f ns   (%.6f ms)")
        :format(i, i, ns or 0, (ns or 0) / 1e6))
    H.pump(4000)
end
print("")
print(("auto-measure spent; inner handler is now soloRaw (wrapper: %s)")
    :format(tostring(L.HandlerName)))
print("")

-- Amortised detect -> send: accumulate only the announcement-to-invoke delta.
local function detectToSend(n, tag)
    local codes = table.create(n)
    for i = 1, n do codes[i] = tag .. i end
    for i = 1, math.min(n, 400) do
        notifyRemote.OnClientEvent:FireDirect(codes[i], 5.5, nil, "Top")
    end
    H.pump(40000)

    local acc, hits = 0, 0
    for i = 1, n do
        R.clearStamp()
        local t0 = os.clock()
        notifyRemote.OnClientEvent:FireDirect(codes[i], 5.5, nil, "Top")
        local t1 = R.invokeStamp()
        if t1 then acc += (t1 - t0); hits += 1 end
        if i % 500 == 0 then H.pump(20000) end
    end
    H.pump(60000)
    if hits == 0 then return nil, 0 end
    return acc / hits * 1e9 - CLOCK_NS, hits
end

local N = 6000
local withPole = detectToSend(N, "POLE")

L.DropPole()
H.pump(20000)
local noPole = detectToSend(N, "BARE")

print(("detect -> send, amortised over %d announcements"):format(N))
print("---------------------------------------------------------------")
print(("  pole held  (wrapper -> soloRaw -> send)   %8.1f ns"):format(withPole or 0))
print(("  pole off   (soloRaw -> send)              %8.1f ns"):format(noPole or 0))
print(("  what the pole wrapper costs              %8.1f ns")
    :format(math.max((withPole or 0) - (noPole or 0), 0)))
print("")

-- What pole buys: the game's own handler no longer runs ahead of our invoke.
local gameFn
for _, c in ipairs(getconnections(notifyRemote.OnClientEvent)) do
    local src = debug.getinfo(c.Function).short_src or ""
    if src:find("NotificationController", 1, true) then gameFn = c.Function end
end
if gameFn then
    local n = 200000
    local t = os.clock()
    for i = 1, n do gameFn("X", 5, nil, "Top") end
    local gameNs = (os.clock() - t) / n * 1e9
    print(("the game's own notification handler, per announcement  %8.1f ns")
        :format(gameNs))
    print("  without pole that runs BEFORE our invoke, so it is added to detect -> send")
    print(("  pole trades %.0f ns of wrapper for %.0f ns of someone else's work")
        :format(math.max((withPole or 0) - (noPole or 0), 0), gameNs))
end

print("")

-- ------------------------------------------------------------------ surfaces
-- Same measurement, three different detection surfaces, so they can be compared
-- against each other rather than only against the wire.
local function timeSurface(n, fire, tag)
    local codes = table.create(n)
    for i = 1, n do codes[i] = tag .. i end
    for i = 1, math.min(n, 300) do fire(codes[i]) end
    H.pump(40000)
    local acc, hits = 0, 0
    for i = 1, n do
        R.clearStamp()
        local t0 = os.clock()
        fire(codes[i])
        local t1 = R.invokeStamp()
        if t1 then acc += (t1 - t0); hits += 1 end
        if i % 500 == 0 then H.pump(20000) end
    end
    H.pump(60000)
    if hits == 0 then return nil, 0 end
    return acc / hits * 1e9 - CLOCK_NS, hits
end

print("")
print("detection surfaces, each timed to the same point (entry -> send entered)")
print("---------------------------------------------------------------")

local M = 4000

local remoteNs, remoteHits = timeSurface(M, function(code)
    notifyRemote.OnClientEvent:FireDirect(code, 5.5, nil, "Top")
end, "SURFA")
print(("  notify remote  OnClientEvent      %8.1f ns   (%d/%d sent)")
    :format(remoteNs or 0, remoteHits, M))

L.DetectMode = "ui"
L.RemoteDetectOn = false
pcall(L.HookNotify)
local NC = genvTable.__LumNotifyNC
if NC and NC.Notify then
    local hookNs, hookHits = timeSurface(M, function(code)
        NC:Notify(code, 5.5, nil, "Top")
    end, "SURFB")
    print(("  NotificationController hook       %8.1f ns   (%d/%d sent)")
        :format(hookNs or 0, hookHits, M))
else
    print("  NotificationController hook       not installed in this rig")
end

L.NotifyHooked = false
local top = H.newInstance("Folder", "TopNotification")
top.Parent = PlayerGuiRef
local inner = H.newInstance("TextLabel", "TopNotification")
inner.Parent = top
if pcall(L.HookGui) and L.GuiHooked then
    local freshNs, freshHits = timeSurface(M, function(code)
        L.OursPending = nil          -- fresh announcement, nothing awaiting an answer
        inner._props.Text = code
        inner._sig("prop:Text"):FireDirect()
    end, "SURFC")
    print(("  GUI label, fresh code             %8.1f ns   (%d/%d sent)")
        :format(freshNs or 0, freshHits, M))
    local pendNs, pendHits = timeSurface(M, function(code)
        L.OursPending = "PENDINGCODE" -- a redeem is still awaiting its answer
        L.OursAt = os.clock()
        inner._props.Text = code
        inner._sig("prop:Text"):FireDirect()
    end, "SURFD")
    L.OursPending = nil
    print(("  GUI label, redeem still pending   %8.1f ns   (%d/%d sent)")
        :format(pendNs or 0, pendHits, M))
else
    print("  GUI label watch                   not installed in this rig")
end

print("")
print("LUCK's own bench (stubs its post-send work, so this is the handler alone)")
print("---------------------------------------------------------------")
pcall(L.BenchPrint, 20000)

print("")
print(("errors during the whole run: %d"):format(H.errors and #H.errors or 0))
end
