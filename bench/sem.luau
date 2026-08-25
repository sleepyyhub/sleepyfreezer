do
local R = RIG local H = R.H local notifyRemote = R.notifyRemote
H.pump(40000)
local L = R.genvTable.LUCK
L.AutoOn = true; L.SyncHot(); H.pump(20000)
local function n(f) local b = R.invokeCount(); f(); H.pump(40000); return R.invokeCount() - b end
print(("1 announcement                      -> %d redeem"):format(
  n(function() notifyRemote.OnClientEvent:FireAll("S1", 5.5, nil, "Top") end)))
print(("20 announcements, same code         -> %d redeems"):format(
  n(function() for i=1,20 do notifyRemote.OnClientEvent:FireAll("S2", 5.5, nil, "Top") end end)))
print(("20 announcements, distinct codes    -> %d redeems"):format(
  n(function() for i=1,20 do notifyRemote.OnClientEvent:FireAll("S3"..i, 5.5, nil, "Top") end end)))
pcall(L.Fake, true) H.pump(20000)
print(("FAKE ON: 1 announcement             -> %d redeems (FakeBurst=%s)"):format(
  n(function() notifyRemote.OnClientEvent:FireAll("S4", 5.5, nil, "Top") end), tostring(L.FakeBurst)))
pcall(L.Fake, false) H.pump(20000)
print(("FAKE OFF: 1 announcement            -> %d redeem"):format(
  n(function() notifyRemote.OnClientEvent:FireAll("S5", 5.5, nil, "Top") end)))
end
