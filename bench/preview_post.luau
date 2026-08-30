do
-- The preview should say a code is out while it is still out.
--
-- It learned a code existed from postRedeemBody, which runs off the back of the
-- invoke -- and InvokeServer parks that thread for the whole round trip. So the
-- panel sat on "waiting for code…" for the entire time the redeem was actually
-- in flight, then filled in code and verdict together, a tenth of a second
-- later. It read as if nothing had happened.
local R = RIG
local H = R.H
local notifyRemote = R.notifyRemote
H.pump(300000)
local L = R.genvTable.LUCK
local fails, checks = {}, 0
local function check(name, cond, detail)
    checks += 1
    if not cond then fails[#fails + 1] = name .. (detail and ("  -- " .. detail) or "") end
end

if not L then print("no getgenv().LUCK") return end
L.AutoOn, L.GuessCode, L.Threshold, L.RedeemPath = true, false, 1, "remote"
L.SyncHot(); H.pump(40000)

check("the live preview is on by default", L.PreviewLive ~= false)
check("and it picks the eager sender", L.HandlerName == "poleEagerRaw",
    tostring(L.HandlerName))

-- A server that takes 120ms, like a real one.
R.setInvokeBehaviour(function() task.wait(0.12) return false, "This code is out of stock" end)

local painted = {}
local realPaint = L.PreviewSending
L.PreviewSending = function(code)
    painted[#painted + 1] = tostring(code)
    if realPaint then pcall(realPaint, code) end
end

L.LastPreviewCode, L.SendingCode = nil, nil
local t0 = H.virtualNow()
task.spawn(function()
    notifyRemote.OnClientEvent:FireAll("INFLIGHT1", 5.5, nil, "Top")
end)
-- Drain the deferred queue and stop well short of the server's 120ms.
H.pump(200000, H.virtualNow() + 0.01)
local elapsed = (H.virtualNow() - t0) * 1000
check("we are still mid-flight", elapsed < 100, string.format("%.0f ms", elapsed))
check("the preview already has the code", L.LastPreviewCode == "INFLIGHT1",
    tostring(L.LastPreviewCode))
check("SendingCode is set", L.SendingCode == "INFLIGHT1", tostring(L.SendingCode))
check("the paint ran exactly once", #painted == 1, tostring(#painted))

-- And the answer still lands afterwards.
H.pump(200000, H.virtualNow() + 1)
check("the reply arrives after", L.LastReply and L.LastReply.message == "This code is out of stock",
    tostring(L.LastReply and L.LastReply.message))
check("the preview still shows the code", L.LastPreviewCode == "INFLIGHT1",
    tostring(L.LastPreviewCode))

-- Turning it off returns the send path to its floor: the late sender, no paint
-- queued in front of the invoke at all.
L.PreviewLive = false
L.SyncFast(); H.pump(40000)
check("off picks the floor sender", L.HandlerName == "poleLateRaw", tostring(L.HandlerName))

painted = {}
L.LastPreviewCode, L.SendingCode = nil, nil
t0 = H.virtualNow()
task.spawn(function()
    notifyRemote.OnClientEvent:FireAll("INFLIGHT2", 5.5, nil, "Top")
end)
H.pump(200000, H.virtualNow() + 0.01)
check("off paints nothing mid-flight", #painted == 0, tostring(#painted))
H.pump(200000, H.virtualNow() + 1)
check("off still reports the result", L.LastPreviewCode == "INFLIGHT2",
    tostring(L.LastPreviewCode))

L.PreviewLive = true
L.SyncFast(); H.pump(40000)
check("it goes back on", L.HandlerName == "poleEagerRaw", tostring(L.HandlerName))

R.setInvokeBehaviour(nil)
print(("checks: %d   failures: %d"):format(checks, #fails))
for _, f in ipairs(fails) do print("  FAIL  " .. f) end
print("runtime errors: " .. #(H.errors or {}))
end
