do
local R = RIG local H = R.H local notifyRemote = R.notifyRemote
H.pump(40000)
local L = R.genvTable.LUCK
L.AutoOn = true; L.SyncHot(); H.pump(20000)

local NC = R.genvTable.__LumNotifyNC
if type(NC) ~= "table" then
    local ctrl = R.RepS:FindFirstChild("Controllers")
    local mod = ctrl and ctrl:FindFirstChild("NotificationController")
    NC = mod and require(mod) or nil
    R.genvTable.__LumNotifyNC = NC
end
local heard = {}
NC.Notify = function(self, msg) heard[#heard + 1] = tostring(msg) end

print(("EagerRedispatch default: %s"):format(tostring(L.EagerRedispatch)))

local redeemsBefore = R.invokeCount()
L.SpamRedeem(true)
for _ = 1, 30 do H.pump(4000, H.virtualNow() + 0.4) end
H.pump(40000)

print(("REDEEMS SENT while spamming: %d   <- must be 0")
    :format(R.invokeCount() - redeemsBefore))
print(("red lines drawn:             %d"):format(L.SpamShown))
print(("still spamming:              %s"):format(tostring(L.SpamOn)))

-- the game's rate-limit notice must not reach the screen while it runs
heard = {}
NC:Notify("Please wait before trying to redeem another Code", 5, nil, "Top")
local leaked = 0
for _, m in ipairs(heard) do
    if m:lower():find("please wait", 1, true) then leaked += 1 end
end
print(("'Please wait' leaked:        %d   <- must be 0"):format(leaked))
print(("what it showed instead:      %s"):format(heard[1] or "(nothing)"))

-- a real redeem landing turns it off by itself
notifyRemote.OnClientEvent:FireAll("REALCODE", 5.5, nil, "Top")
for _ = 1, 10 do H.pump(4000, H.virtualNow() + 0.2) end
H.pump(40000)
print(("after a real redeem landed:  spamming=%s"):format(tostring(L.SpamOn)))
L.SpamRedeem(false)
end
