--[[
    LUCK — real client speed test
    Roblox / Luau. Run in your executor AFTER LUCK.lua is loaded (needs getgenv().LUCK).

    Measures, on the actual device, in this order:
      1. environment      executor, place, redeem remote, active handler
      2. signal mode      probed, not assumed — Deferred costs you a frame
      3. frame clock      real frame times, min / median / p99 over a window
      4. ping             Stats "Data Ping", plus a real InvokeServer round trip
      5. handler CPU      L.Bench, split into send-alone vs script overhead
      6. live floor       L.Instrument on, real announcements, entry -> send in µs
      7. budget           all of the above added up, measured values only

    Everything except step 4 and step 6 is passive. Step 4 fires throwaway codes at
    the redeem remote (same shape LUCK's own WarmRemote already sends). Step 6 just
    listens. Set RTT_SAMPLES = 0 to skip the only part that touches the server.
]]

local RTT_SAMPLES  = 5      -- server round trips to sample; 0 disables
local RTT_GAP      = 1.0    -- seconds between them
local FRAME_WINDOW = 3.0    -- seconds of frame timing
local LIVE_WINDOW  = 0      -- seconds to sit and catch real announcements; 0 skips
local BENCH_N      = 200000 -- handler iterations; raise on desktop, lower on phone

--------------------------------------------------------------------------------

local RunService = game:GetService("RunService")
local Stats      = game:GetService("Stats") -- resolved for parity; L.Ping() reads it

local L = (getgenv and getgenv().LUCK) or (shared and shared.LUCK)
if type(L) ~= "table" then
    warn("[SPEEDTEST] LUCK is not loaded. Run the main script first.")
    return
end

local out = {}
local function say(fmt, ...)
    local line = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    out[#out + 1] = line
    print("[SPEEDTEST] " .. line)
end
local function rule() say(string.rep("-", 62)) end

local function median(t)
    local c = table.clone(t)
    table.sort(c)
    local n = #c
    if n == 0 then return 0 end
    if n % 2 == 1 then return c[(n + 1) // 2] end
    return (c[n // 2] + c[n // 2 + 1]) / 2
end
local function pct(t, p)
    local c = table.clone(t)
    table.sort(c)
    if #c == 0 then return 0 end
    return c[math.clamp(math.ceil(#c * p), 1, #c)]
end

--------------------------------------------------------------------------------
-- 1. environment
--------------------------------------------------------------------------------
say("")
say("LUCK client speed test")
rule()

local execName = (identifyexecutor and select(1, identifyexecutor())) or "unknown"
say("executor           %s", tostring(execName))
say("place              %d", game.PlaceId)
say("profile            %s", L.PerformanceProfile and L.PerformanceProfile.name or "?")
say("speed mode         %s", L.Mode and L.Mode.name or "?")
say("detect             %s%s", tostring(L.DetectMode),
    L.RemoteDetectOn and " (remote hook live)" or " (remote hook OFF)")
say("redeem path        %s", tostring(L.RedeemPath))

local rr = L.RedeemRemote
if rr then
    say("redeem remote      %s  [%s]  %s", rr.Name,
        L.RedeemRemoteIsEvent and "RemoteEvent" or "RemoteFunction",
        tostring(L.RedeemRemoteSource))
    say("remote tested      %s", tostring(L.RedeemRemoteTested))
else
    say("redeem remote      NONE RESOLVED  <-- nothing below will be representative")
end
say("handler            %s", tostring(L.HandlerName))
say("raw fire           %s", tostring(L.RawFire ~= false))

local myIdx, total = nil, nil
if L.ConnIndex then myIdx, total = L.ConnIndex() end
if myIdx then
    say("listener slot      %d of %d on OnClientEvent", myIdx, total)
end

--------------------------------------------------------------------------------
-- 2. signal mode — probed
--------------------------------------------------------------------------------
rule()
local be = Instance.new("BindableEvent")
local synchronous = false
be.Event:Connect(function() synchronous = true end)
be:Fire()
local immediate = synchronous
be:Destroy()

say("signal behaviour   %s", immediate and "Immediate  (callback ran inline)"
    or "Deferred   (callback queued to the next resumption point)")
if not immediate then
    say("                   ^ costs you up to one frame before your handler even starts")
end

--------------------------------------------------------------------------------
-- 3. frame clock
--------------------------------------------------------------------------------
rule()
say("sampling frames for %.1fs ...", FRAME_WINDOW)
local frames = {}
do
    local last = os.clock()
    local stop = last + FRAME_WINDOW
    local conn
    conn = RunService.Heartbeat:Connect(function()
        local now = os.clock()
        frames[#frames + 1] = (now - last) * 1000
        last = now
    end)
    repeat task.wait() until os.clock() >= stop
    conn:Disconnect()
end

local fMin, fMed, fP99 = math.huge, median(frames), pct(frames, 0.99)
for _, v in ipairs(frames) do if v < fMin then fMin = v end end
local fps = fMed > 0 and (1000 / fMed) or 0

say("frames sampled     %d", #frames)
say("frame time         min %.2f ms   median %.2f ms   p99 %.2f ms", fMin, fMed, fP99)
say("effective fps      %.0f", fps)
say("frame clock cost   %.2f ms typical, %.2f ms worst case", fMed / 2, fP99)

--------------------------------------------------------------------------------
-- 4. ping
--------------------------------------------------------------------------------
rule()
local dataPing = L.Ping and L.Ping() or nil
if dataPing then
    say("Stats data ping    %.1f ms   (one way ~%.1f ms)", dataPing, dataPing / 2)
else
    say("Stats data ping    unavailable")
end

local rtts = {}
if RTT_SAMPLES > 0 and rr and not L.RedeemRemoteIsEvent then
    say("sampling %d real round trips on the redeem remote ...", RTT_SAMPLES)
    for i = 1, RTT_SAMPLES do
        local code = "LUCKPING" .. tostring(math.random(100000, 999999))
        local t = os.clock()
        local ok = pcall(rr.InvokeServer, rr, code)
        local ms = (os.clock() - t) * 1000
        if ok then rtts[#rtts + 1] = ms end
        if i < RTT_SAMPLES then task.wait(RTT_GAP) end
    end
end

local rttMed
if #rtts > 0 then
    rttMed = median(rtts)
    local lo = math.huge
    for _, v in ipairs(rtts) do if v < lo then lo = v end end
    say("redeem round trip  min %.1f ms   median %.1f ms   n=%d", lo, rttMed, #rtts)
    say("                   ^ client -> server -> client, includes server think time")
elseif RTT_SAMPLES > 0 then
    if L.RedeemRemoteIsEvent then
        say("redeem round trip  skipped, remote is a RemoteEvent (fire and forget, no reply)")
    else
        say("redeem round trip  no successful samples")
    end
end

--------------------------------------------------------------------------------
-- 5. handler CPU
--------------------------------------------------------------------------------
rule()
say("benchmarking the handler, %d iterations ...", BENCH_N)
local hNs, sNs = L.Bench(BENCH_N)
if not hNs then
    say("handler bench      failed: %s", tostring(sNs))
else
    say("handler end to end %.1f ns   (%.6f ms)", hNs, hNs / 1e6)
    say("the send call      %.1f ns", sNs)
    say("script overhead    %.1f ns   most of it runs after the packet is gone",
        math.max(hNs - sNs, 0))
end

--------------------------------------------------------------------------------
-- 6. live floor on real announcements
--------------------------------------------------------------------------------
if LIVE_WINDOW > 0 then
    rule()
    local wasInstrument = L.Instrument
    L.Instrument = true
    if L.SyncFast then L.SyncFast() end
    L.BestFloorUs = nil
    say("listening %.0fs for real announcements (Instrument on) ...", LIVE_WINDOW)
    say("note: Instrument routes solo -> soloSlow, ~190 ns slower per event.")
    say("      it is restored when the window ends. do not leave it on.")

    local seen, stop = 0, os.clock() + LIVE_WINDOW
    local lastFloor = nil
    repeat
        task.wait(0.05)
        local f = L.FloorUs
        if f and f ~= lastFloor then
            lastFloor = f
            seen += 1
            say("  announcement #%d   entry -> send  %.2f µs", seen, f)
        end
    until os.clock() >= stop

    L.Instrument = wasInstrument
    if L.SyncFast then L.SyncFast() end

    if seen == 0 then
        say("no announcements fired in the window — nothing live to measure")
    else
        say("best real entry -> send  %.2f µs over %d announcements",
            L.BestFloorUs or 0, seen)
    end
end

--------------------------------------------------------------------------------
-- 7. the budget, measured values only
--------------------------------------------------------------------------------
rule()
local oneWay = rttMed and (rttMed / 2) or (dataPing and dataPing / 2) or nil
if not oneWay then
    say("not enough network data for a budget — set RTT_SAMPLES > 0 and rerun")
else
    local scriptMs = (hNs or 0) / 1e6
    local deferMs  = immediate and 0 or (fMed / 2)
    local netStep  = fMed / 2
    local totalMs  = oneWay + deferMs + scriptMs + netStep + oneWay

    say("announce -> your redeem lands on the server:")
    say("")
    local rows = {
        {"announcement over the wire", oneWay},
        {immediate and "signal dispatch (immediate)" or "deferred signal queue", deferMs},
        {"LUCK itself", scriptMs},
        {"network step wait", netStep},
        {"redeem over the wire", oneWay},
    }
    for _, r in ipairs(rows) do
        say("  %-30s %9.3f ms   %6.2f%%", r[1], r[2], r[2] / totalMs * 100)
    end
    say("  %-30s %9.3f ms", "TOTAL", totalMs)
    say("")
    say("LUCK's share of that          %.6f ms  =  %.5f%%",
        scriptMs, scriptMs / totalMs * 100)
    say("network's share               %9.3f ms  =  %.2f%%",
        oneWay * 2, oneWay * 2 / totalMs * 100)
    say("frame clock's share           %9.3f ms  =  %.2f%%",
        deferMs + netStep, (deferMs + netStep) / totalMs * 100)
    say("")
    say("if the script cost dropped to literally zero you would save %.6f ms", scriptMs)
    say("one extra frame of hitch costs you %.3f ms — %dx more", fP99, math.floor(fP99 / math.max(scriptMs, 1e-9)))
end
rule()

if setclipboard then
    pcall(setclipboard, table.concat(out, "\n"))
    say("full report copied to clipboard")
end

return table.concat(out, "\n")
