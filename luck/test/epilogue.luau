FLUSH()

local L = GENV.LUCK
assert(L, "LUCK did not publish itself into getgenv()")

local function reset()
    for k in pairs(SENT_LOG) do SENT_LOG[k] = nil end
    if L.SentCodes then table.clear(L.SentCodes) end
    if L.RaceLog then table.clear(L.RaceLog) end
    if L.FiredSeen then table.clear(L.FiredSeen) end
    L.OursPending = nil
    L.ResetBuf()
end

local pass, fail = 0, 0
local function check(label, cond, detail)
    if cond then
        pass += 1
        print(("  ok    %s"):format(label))
    else
        fail += 1
        print(("  FAIL  %s%s"):format(label, detail and ("  -> " .. detail) or ""))
    end
end
local function codes()
    local out = {}
    for _, s in ipairs(SENT_LOG) do out[#out + 1] = tostring(s.code) end
    return table.concat(out, " | ")
end
local function fire(...)
    NOTIFY_REMOTE._signals.OnClientEvent:Fire(...)
    FLUSH()
end

print("\n-- resolve --")
check("FastNotify installed", type(L.FastNotify) == "function")
check("redeem remote resolved", L.RedeemRemote == REDEEM_REMOTE,
    tostring(L.RedeemRemoteSource))
check("notify remote resolved", L.NotifyRemote == NOTIFY_REMOTE,
    tostring(L.NotifyRemoteSource))
check("notify listener live", L.RemoteDetectOn == true)
check("invoke method cached", L.FastInvoke ~= nil)
check("raw fire is the default", L.RawFire == true)

L.AutoOn = true
L.Threshold = 1
L.GuessCode = false
L.SyncHot()
check("gate open after SyncHot", L.FastReady == true)

print("\n-- clean code --")
reset()
fire("BANANA25", 5, nil, "Top")
check("one send", #SENT_LOG == 1, codes())
check("sent the code itself", SENT_LOG[1] and SENT_LOG[1].code == "BANANA25", codes())

print("\n-- dedup: solo trades it away, guarded keeps it --")
reset()
check("solo handler is bound by default", L.HandlerName == "solo", tostring(L.HandlerName))
fire("OINKY7", 5, nil, "Top")
fire("OINKY7", 5, nil, "Top")
check("solo mode does not dedup, by design", #SENT_LOG == 2, codes())

reset()
L.Solo = false
L.SyncFast()
check("guarded handler is bound when solo is off",
    L.HandlerName == "guarded", tostring(L.HandlerName))
fire("GUARD8", 5, nil, "Top")
fire("GUARD8", 5, nil, "Top")
check("guarded mode sends once", #SENT_LOG == 1, codes())
L.Solo = true
L.SyncFast()

print("\n-- side toast is never a code --")
reset()
fire("Welcome back!", 5, nil, nil)
check("non-Top sends nothing", #SENT_LOG == 0, codes())

print("\n-- filler sentence: raw first, cleaned by the tail --")
reset()
fire("NEW CODE RELEASED: DRAGON50", 5, nil, "Top")
check("raw went out first",
    SENT_LOG[1] and SENT_LOG[1].code == "NEW CODE RELEASED: DRAGON50", codes())
check("tail resent the extracted code",
    SENT_LOG[2] and SENT_LOG[2].code == "DRAGON50", codes())

print("\n-- rich text --")
reset()
fire('<font color="#92ff67">SPARKLE9</font>', 5, nil, "Top")
check("tail recovered the code from markup",
    SENT_LOG[#SENT_LOG] and SENT_LOG[#SENT_LOG].code == "SPARKLE9", codes())

print("\n-- multi-part falls through to the buffer --")
reset()
L.Threshold = 3
L.SyncHot()
check("gate closed for threshold 3", L.FastReady == false)
fire("FREE", 5, nil, "Top")
fire("DRAGS", 5, nil, "Top")
check("two of three send nothing", #SENT_LOG == 0, codes())
fire("500", 5, nil, "Top")
check("third sends the joined code",
    SENT_LOG[1] and SENT_LOG[1].code == "FREEDRAGS500", codes())

print("\n-- auto off --")
reset()
L.Threshold = 1
L.AutoOn = false
L.SyncHot()
fire("SHOULDNOTFIRE", 5, nil, "Top")
check("auto off sends nothing", #SENT_LOG == 0, codes())

print("\n-- table payload --")
reset()
L.AutoOn = true
L.SyncHot()
fire({Message = "TABLECODE9"}, 5, nil, "Top")
check("table payload is recovered by the tail",
    SENT_LOG[#SENT_LOG] and SENT_LOG[#SENT_LOG].code == "TABLECODE9", codes())

print("\n-- instrumentation --")
reset()
L.Instrument = true
L.SyncHot()
fire("TIMED42", 5, nil, "Top")
check("floor measured when instrumented", type(L.FloorUs) == "number",
    tostring(L.FloorUs))
L.Instrument = false
L.SyncHot()


print("\n-- surface race --")
L.AutoOn = true
L.Threshold = 1
L.SyncHot()
reset()

local armedRemotes, armedValues = L.RaceOn()
check("race armed extra remotes", armedRemotes >= 1, tostring(armedRemotes))
check("race armed string values", armedValues >= 1, tostring(armedValues))
check("timestamping switched on by the race", L.RaceArmed == true)

print("\n-- an earlier remote wins the race --")
reset()
EARLY._signals.OnClientEvent:Fire("EARLYCODE1")
fire("EARLYCODE1", 5, nil, "Top")
local log = L.RaceLog[1]
check("race logged the code", log and log.code == "EARLYCODE1",
    log and log.code or "nothing")
check("the early remote is named the winner",
    log and log.winner == "re:RE/CodeService/Sync", log and log.winner or "?")
check("notify remote recorded as late",
    log and type(log.late["remote"]) == "number",
    log and tostring(log.late["remote"]) or "?")
check("observe-only surface did not send", #SENT_LOG == 1, codes())
check("the send came from the notify lane",
    SENT_LOG[1] and SENT_LOG[1].code == "EARLYCODE1", codes())

print("\n-- promoting the winner makes it fire --")
reset()
L.Promote("re:RE/CodeService/Sync")
EARLY._signals.OnClientEvent:Fire("PROMOTED2")
check("promoted surface sent immediately", #SENT_LOG == 1, codes())
check("sent the right code", SENT_LOG[1] and SENT_LOG[1].code == "PROMOTED2", codes())
fire("PROMOTED2", 5, nil, "Top")
check("notify lane did not send it again", #SENT_LOG == 1, codes())

print("\n-- shape filter rejects chatter --")
reset()
EARLY._signals.OnClientEvent:Fire("hello there friend")
EARLY._signals.OnClientEvent:Fire("x")
EARLY._signals.OnClientEvent:Fire(12345)
check("non-code payloads send nothing", #SENT_LOG == 0, codes())

print("\n-- report --")
L.RacePrint()
check("report lists the winner first",
    L.RaceReport()[1] and L.RaceReport()[1].wins >= 1)

L.RaceOff()
check("race off returns to no timestamping", L.RaceArmed == false)


print("\n-- turbo --")
check("fps meter present", type(L.Fps) == "number", tostring(L.Fps))
check("turbo starts off", L.TurboOn == false)
local applied = L.SetTurbo(true)
check("turbo switched on", L.TurboOn == true)
check("every step reported a result", applied["3d rendering"] ~= nil
    and applied["quality level"] ~= nil and applied["shadows"] ~= nil)
check("fps cap raised with turbo", L.FpsCap == 999 and applied["fps cap"] == true,
    tostring(L.FpsCap))
L.SetTurbo(false)
check("turbo switched back off", L.TurboOn == false)
check("fps cap lowered again", L.FpsCap == 240, tostring(L.FpsCap))
check("executor without setfpscap is reported, not hidden",
    type(L.SetFpsCap) == "function")

print(("\n%d passed, %d failed\n"):format(pass, fail))
if fail > 0 then error("harness failures", 0) end
