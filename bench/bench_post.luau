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

-- ------------------------------------------------------------------- knobs
-- Every configuration reachable through the methods the script already exposes,
-- measured the same way: announcement entry -> the send call being entered.
local function restoreDefaults()
    L.RedeemPath   = "remote"
    L.DetectMode   = "remote"
    L.RawFire      = true
    L.Instrument   = false
    L.RaceArmed    = false
    L.MultiSurface = false
    L.Solo         = true
    L.AutoOn       = true
    L.GuessCode    = false
    L.Threshold    = 1
    L.EagerRedispatch = false        -- the shipped default
    L.RemoteDetectOn = true
    L.SyncHot()
end

local function sweep(label, apply, tag)
    restoreDefaults()
    apply()
    L.SyncHot()
    local handler, pole = tostring(L.HandlerName), L.PoleOn and "yes" or "no"

    local n = 3000
    local codes = table.create(n)
    for i = 1, n do codes[i] = tag .. i end
    for i = 1, 300 do
        notifyRemote.OnClientEvent:FireDirect(codes[i], 5.5, nil, "Top")
    end
    H.pump(40000)

    local acc, hits = 0, 0
    for i = 1, n do
        R.clearStamp()
        L.OursPending = nil
        local t0 = os.clock()
        notifyRemote.OnClientEvent:FireDirect(codes[i], 5.5, nil, "Top")
        local t1 = R.invokeStamp()
        if t1 then acc += (t1 - t0); hits += 1 end
        if i % 400 == 0 then H.pump(20000) end
    end
    H.pump(60000)
    local ns = hits > 0 and (acc / hits * 1e9 - CLOCK_NS) or nil
    print(("  %-34s %-9s %-5s %9s   %d/%d"):format(
        label, handler, pole,
        ns and ("%.0f ns"):format(ns) or "no send", hits, n))
    return ns
end

print("")
print("every setting the script already exposes, measured")
print("  setting                            handler   pole      detect->send   sent")
print("  ---------------------------------------------------------------------------")

local base = sweep("defaults", function() end, "K01")
sweep("EagerRedispatch = true", function() L.EagerRedispatch = true end, "K12")
sweep("Instrument = true", function() L.Instrument = true end, "K02")
sweep("RawFire = false", function() L.RawFire = false end, "K03")
sweep("Solo = false", function() L.Solo = false end, "K04")
sweep("MultiSurface = true", function() L.MultiSurface = true end, "K05")
sweep("RaceArmed = true  (RaceOn)", function() L.RaceArmed = true end, "K06")
sweep("Threshold = 2", function() L.Threshold = 2 end, "K07")
sweep("GuessCode = true", function() L.GuessCode = true end, "K08")
sweep("RedeemPath = 'both'", function() L.RedeemPath = "both" end, "K09")
sweep("RedeemPath = 'ui'", function() L.RedeemPath = "ui" end, "K10")

restoreDefaults()
L.DropPole()
H.pump(20000)
do
    local n = 3000
    local codes = table.create(n)
    for i = 1, n do codes[i] = "K11x" .. i end
    for i = 1, 300 do notifyRemote.OnClientEvent:FireDirect(codes[i], 5.5, nil, "Top") end
    H.pump(40000)
    local acc, hits = 0, 0
    for i = 1, n do
        R.clearStamp()
        L.OursPending = nil
        local t0 = os.clock()
        notifyRemote.OnClientEvent:FireDirect(codes[i], 5.5, nil, "Top")
        local t1 = R.invokeStamp()
        if t1 then acc += (t1 - t0); hits += 1 end
        if i % 400 == 0 then H.pump(20000) end
    end
    H.pump(60000)
    print(("  %-34s %-9s %-5s %9s   %d/%d"):format(
        "pole dropped (DropPole)", tostring(L.HandlerName), L.PoleOn and "yes" or "no",
        hits > 0 and ("%.0f ns"):format(acc / hits * 1e9 - CLOCK_NS) or "no send",
        hits, n))
end
restoreDefaults()
pcall(L.TakePole)
H.pump(20000)
print("")
print(("  baseline (defaults) = %s ns"):format(base and ("%.0f"):format(base) or "?"))

print("")

-- ------------------------------------------------------- exactly-once test
-- The same code, seen by every surface that can see it, plus a repeat of the
-- announcement itself. It must reach the server exactly once.
print("")
print("exactly-once: one code, every surface, how many redeems reach the server")
print("---------------------------------------------------------------")
do
    restoreDefaults()
    pcall(L.TakePole)
    H.pump(20000)

    local function countFor(label, code, fire)
        local before = R.invokeCount()
        fire(code)
        H.pump(40000)
        local n = R.invokeCount() - before
        print(("  %-44s %d redeem%s"):format(label, n, n == 1 and "" or "s"))
        return n
    end

    countFor("announcement fired once", "ONCE01", function(code)
        notifyRemote.OnClientEvent:FireDirect(code, 5.5, nil, "Top")
    end)

    countFor("same announcement fired 5 times", "ONCE02", function(code)
        for _ = 1, 5 do
            notifyRemote.OnClientEvent:FireDirect(code, 5.5, nil, "Top")
        end
    end)

    countFor("remote + 4 label dispatches, same code", "ONCE03", function(code)
        notifyRemote.OnClientEvent:FireDirect(code, 5.5, nil, "Top")
        if L.WatchLabel then
            for _ = 1, 4 do
                if L.FastNotify then pcall(L.FastNotify, code, nil, nil, "Top") end
            end
        end
    end)

    countFor("announcement while its own reply is pending", "ONCE04", function(code)
        notifyRemote.OnClientEvent:FireDirect(code, 5.5, nil, "Top")
        L.OursPending = code
        notifyRemote.OnClientEvent:FireDirect(code, 5.5, nil, "Top")
        L.OursPending = nil
    end)

    print("")
    print(("  NotificationController hooked while on the remote path: %s")
        :format(L.NotifyHooked and "YES (wrong)" or "no"))
    print(("  our results routed through the game's notifier: %s")
        :format(L.ToastOn and "YES (wrong)" or "no"))
end

print("")
print("LUCK's own bench (stubs its post-send work, so this is the handler alone)")
print("---------------------------------------------------------------")
pcall(L.BenchPrint, 20000)

print("")
print(("errors during the whole run: %d"):format(H.errors and #H.errors or 0))
end
