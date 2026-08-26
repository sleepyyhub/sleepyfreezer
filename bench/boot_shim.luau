-- Sits between the fake place and LUCK. Wraps Instance.new so the moment the UI starts
-- being built can be observed, along with everything the script had resolved by then.
do
    local realNew = Instance.new
    local created, snap = 0, nil
    Instance = setmetatable({}, {__index = function(_, k)
        if k ~= "new" then return nil end
        return function(cls, ...)
            created += 1
            if cls == "ScreenGui" and not snap then
                local L = (getgenv and getgenv().LUCK) or nil
                snap = {
                    at            = created,
                    ready         = L and L.Ready,
                    readyBy       = L and L.ReadyBy,
                    detectOn      = L and L.RemoteDetectOn,
                    redeem        = L and L.RedeemRemote ~= nil,
                    redeemTested  = L and L.RedeemRemoteTested,
                    notify        = L and L.NotifyRemote ~= nil,
                    pole          = L and L.PoleOn,
                    discovered    = L and L.Discovered,
                }
            end
            return realNew(cls, ...)
        end
    end})
    BOOT = {
        created = function() return created end,
        snapshot = function() return snap end,
    }
end
