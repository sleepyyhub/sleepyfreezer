FLUSH()

local L = GENV.LUCK
assert(L, "LUCK did not publish itself into getgenv()")

local function reset()
    for k in pairs(SENT_LOG) do SENT_LOG[k] = nil end
    if L.SentCodes then table.clear(L.SentCodes) end
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
    for _, s in ipairs(SENT_LOG) do out[#out + 1] = s.code end
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

print("\n-- dedup --")
reset()
fire("OINKY7", 5, nil, "Top")
fire("OINKY7", 5, nil, "Top")
check("same code twice sends once", #SENT_LOG == 1, codes())

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
check("table payload still redeems",
    SENT_LOG[1] and SENT_LOG[1].code == "TABLECODE9", codes())

print("\n-- instrumentation --")
reset()
L.Instrument = true
L.SyncHot()
fire("TIMED42", 5, nil, "Top")
check("floor measured when instrumented", type(L.FloorUs) == "number",
    tostring(L.FloorUs))
L.Instrument = false
L.SyncHot()

print(("\n%d passed, %d failed\n"):format(pass, fail))
if fail > 0 then error("harness failures", 0) end
