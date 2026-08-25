do
local R = RIG
local H = R.H
H.pump(40000)
local L = R.genvTable.LUCK
local RepS = R.RepS

-- The test sender's resolveRemote, verbatim.
local Net = RepS:FindFirstChild("Packages"):FindFirstChild("Net")
local function senderResolve()
    if _G.PhiNotifyRemote then return _G.PhiNotifyRemote end
    local getinfo = debug and (debug.getinfo or debug.info)
    if getinfo then
        if getconnections then
            for _, d in ipairs(Net:GetDescendants()) do
                if d:IsA("RemoteEvent") then
                    local ok, cs = pcall(getconnections, d.OnClientEvent)
                    if ok then
                        for _, c in ipairs(cs) do
                            local f, fn = pcall(function() return c.Function end)
                            if f and type(fn) == "function" then
                                local i, info = pcall(getinfo, fn)
                                if i and tostring(info.short_src or info.source or ""):find("NotificationController", 1, true) then
                                    return d
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

local fails, checks = {}, 0
local function check(n, c, d) checks += 1; if not c then fails[#fails+1] = n .. (d and ("  -- "..d) or "") end end

local sender = senderResolve()
print("LUCK notify   :", L.NotifyRemote and L.NotifyRemote.Name, "source", L.NotifyRemoteSource)
print("sender picks  :", sender and sender.Name)
print("_G.Phi        :", _G.PhiNotifyRemote and _G.PhiNotifyRemote.Name or "nil")
print("byIndex       :", L.NotifyByIndex and L.NotifyByIndex.Name or "none", "count", L.RemoteCount)
print("differs note  :", L.NotifyVerifiedDiffers and L.NotifyVerifiedDiffers.Name or "no")

check("sender resolves something", sender ~= nil)
check("LUCK and the sender agree", sender == L.NotifyRemote,
    tostring(sender and sender.Name) .. " vs " .. tostring(L.NotifyRemote and L.NotifyRemote.Name))
check("it is the real notify remote, not the decoy", L.NotifyRemote == R.notifyRemote)
check("_G.PhiNotifyRemote published", _G.PhiNotifyRemote == R.notifyRemote)
check("the verified lookup actually ran", _G.PhiNotifyRemote ~= nil,
    "nothing was published, so verifiedNotify never returned")

-- end to end: an announcement on the resolved remote still redeems exactly once
local before = R.invokeCount()
R.notifyRemote.OnClientEvent:FireAll("SENDERCODE1", 5.5, "Sounds.Sfx.Blop", "Top")
H.pump(60000)
check("one announcement -> one redeem", R.invokeCount() - before == 1,
    "sends=" .. tostring(R.invokeCount() - before))

-- the decoy must NOT be what we listen on
local b2 = R.invokeCount()
R.decoyNotify.OnClientEvent:FireAll("DECOYCODE1", 5.5, "Sounds.Sfx.Blop", "Top")
H.pump(60000)
check("decoy traffic is ignored", R.invokeCount() - b2 == 0,
    "sends=" .. tostring(R.invokeCount() - b2))

print(("checks: %d   failures: %d"):format(checks, #fails))
for _, f in ipairs(fails) do print("  FAIL  " .. f) end
print(("runtime errors: %d"):format(H.errors and #H.errors or 0))
end
