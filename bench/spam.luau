do
local R = RIG local H = R.H local notifyRemote = R.notifyRemote
H.pump(40000)
local L = R.genvTable.LUCK
L.AutoOn = true; L.SyncHot(); H.pump(20000)

-- the game answers with its rate-limit notice until the Nth try, then accepts
local tries, acceptAt = 0, 5
local heard = {}
local NC = R.genvTable.__LumNotifyNC
if type(NC) ~= "table" then
    local ctrl = R.RepS:FindFirstChild("Controllers")
    local mod = ctrl and ctrl:FindFirstChild("NotificationController")
    NC = mod and require(mod) or nil
    R.genvTable.__LumNotifyNC = NC
end
NC.Notify = function(self, msg) heard[#heard + 1] = tostring(msg) end

R.setInvokeBehaviour(function(_, code)
    tries += 1
    -- what the game does: rate-limit, then finally accept
    NC:Notify("Please wait before trying to redeem another Code", 5, nil, "Top")
    if tries >= acceptAt then return true, "Meowl spawned!" end
    return false, "rate limited"
end)

print(("SpamRedeem: start -> %s"):format(tostring(select(2, L.SpamRedeem(true, "mycode")))))
for _ = 1, 40 do H.pump(4000, H.virtualNow() + 0.2) end
H.pump(60000)

print(("attempts made        %d   (server accepts on try %d)"):format(L.SpamAttempts, acceptAt))
print(("still spamming       %s"):format(tostring(L.SpamOn)))
local red, wait = 0, 0
for _, m in ipairs(heard) do
    if m:find("Invalid Code", 1, true) then red += 1 end
    if m:lower():find("please wait", 1, true) then wait += 1 end
end
print(("notifications: %d red 'Invalid Code', %d raw 'Please wait'"):format(red, wait))
print(("red markup used: %s"):format(heard[1] or "(none)"))
R.setInvokeBehaviour(nil)
end
