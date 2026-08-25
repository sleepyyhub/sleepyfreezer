do
local R = RIG local H = R.H local notifyRemote = R.notifyRemote
H.pump(40000)
local L = R.genvTable.LUCK
L.AutoOn, L.GuessCode, L.Threshold, L.RedeemPath = true, false, 1, "remote"
L.EagerRedispatch = false
L.SyncHot(); H.pump(20000)

local CLOCK_NS
do local n=200000 local t=os.clock() for _=1,n do local _=os.clock() end
   CLOCK_NS=(os.clock()-t)/n*1e9 end

local fused = L.Handlers.poleLateRaw
local function bind(useFused)
    L.Handlers.poleLateRaw = useFused and fused or nil
    L.SyncFast(); H.pump(20000)
    return tostring(L.HandlerName)
end

local function measure(n, tag)
    local codes = table.create(n)
    for i=1,n do codes[i] = tag..i end
    for i=1,300 do notifyRemote.OnClientEvent:FireAll(codes[i],5.5,nil,"Top") end
    H.pump(40000)
    local acc,hits = 0,0
    for i=1,n do
        R.clearStamp()
        local t0=os.clock()
        notifyRemote.OnClientEvent:FireAll(codes[i],5.5,nil,"Top")
        local t1=R.invokeStamp()
        if t1 then acc+=(t1-t0); hits+=1 end
        if i%400==0 then H.pump(20000) end
    end
    H.pump(60000)
    return hits>0 and (acc/hits*1e9 - CLOCK_NS) or nil
end

local sumA,sumB,rounds = 0,0,6
print("interleaved A/B, 2500 announcements per cell")
for r=1,rounds do
    local nb = bind(false); local b = measure(2500,"B"..r)
    local na = bind(true);  local a = measure(2500,"A"..r)
    sumB += b; sumA += a
    print(("  round %d   %-12s %6.0f ns    %-12s %6.0f ns"):format(r, nb, b, na, a))
end
print(("  ------------------------------------------------------------"))
print(("  two frames (poleLate)     mean %6.0f ns"):format(sumB/rounds))
print(("  one frame  (poleLateRaw)  mean %6.0f ns"):format(sumA/rounds))
print(("  saved                          %6.0f ns  (%.0f%%)")
    :format(sumB/rounds - sumA/rounds, (1 - (sumA/sumB))*100))
end
