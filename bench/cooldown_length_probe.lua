local L = (getgenv and getgenv().LUCK) or LUCK
if not L or not L.RedeemRemote or L.RedeemRemoteIsEvent then
    warn("[probe2] need LUCK loaded with a RemoteFunction redeem remote")
    return
end

local rem = L.RedeemRemote
local inv = rem.InvokeServer
local log = {}
local t0 = os.clock()

local function try()
    local ok, a, b = pcall(inv, rem, "LUCK" .. math.random(100000, 999999))
    local t
    if not ok then
        t = "ERROR: " .. tostring(a)
    else
        t = tostring(a) .. (b ~= nil and (" / " .. tostring(b)) or "")
    end
    return t, t:lower():find("wait", 1, true) ~= nil or t:lower():find("cooldown", 1, true) ~= nil
end

local first, blocked = try()
log[#log + 1] = ("t=%.1fs  %s"):format(os.clock() - t0, first)

local freeAt, probes = nil, 0
while os.clock() - t0 < 90 do
    task.wait(1)
    local t, isWait = try()
    probes += 1
    log[#log + 1] = ("t=%.1fs  %s"):format(os.clock() - t0, t)
    if not isWait then freeAt = os.clock() - t0 break end
end

local out = {"LUCK cooldown length probe"}
for i = 1, #log do out[#out + 1] = log[i] end
out[#out + 1] = ("probes after the first: %d"):format(probes)
if freeAt then
    out[#out + 1] = ("cleared after %.1fs of being probed every 1s"):format(freeAt)
    out[#out + 1] = "VERDICT: rejections do NOT reset the cooldown"
else
    out[#out + 1] = "still blocked after 90s while probed every 1s"
    out[#out + 1] = "VERDICT: rejections DO reset it, or the cooldown is over 90s"
end

local report = table.concat(out, "\n")
print(report)
if type(setclipboard) == "function" then
    setclipboard(report)
    print("[probe2] copied to clipboard")
end
