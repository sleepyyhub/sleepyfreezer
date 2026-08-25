local N = 50
local L = (getgenv and getgenv().LUCK) or LUCK
if not L or not L.RedeemRemote or L.RedeemRemoteIsEvent then
    warn("[probe] need LUCK loaded with a RemoteFunction redeem remote")
    return
end

local rem = L.RedeemRemote
local inv = rem.InvokeServer
local res, done = table.create(N), 0

for i = 1, N do
    task.spawn(function()
        local ok, a, b = pcall(inv, rem, "LUCK" .. math.random(100000, 999999))
        local t
        if not ok then
            t = "ERROR: " .. tostring(a)
        else
            t = tostring(a) .. (b ~= nil and (" / " .. tostring(b)) or "")
        end
        res[i] = t
        done += 1
    end)
end

local deadline = os.clock() + 20
while done < N and os.clock() < deadline do task.wait(0.05) end

local counts, order, wait, past, none = {}, {}, 0, 0, 0
for i = 1, N do
    local t = res[i]
    if not t then
        none += 1
    else
        if t:lower():find("wait", 1, true) or t:lower():find("cooldown", 1, true) then
            wait += 1
        else
            past += 1
        end
        counts[t] = (counts[t] or 0) + 1
        if counts[t] == 1 then order[#order + 1] = t end
    end
end

local out = {("LUCK cooldown probe  -  %d invokes, one frame, remote %s"):format(N, rem.Name)}
for _, t in ipairs(order) do
    out[#out + 1] = ("%3d x  %s"):format(counts[t], t)
end
out[#out + 1] = ("cooldown %d   past %d   no reply %d"):format(wait, past, none)
if past > 1 then
    out[#out + 1] = "VERDICT: gap is real"
elseif past == 1 then
    out[#out + 1] = "VERDICT: only the first got through, no race"
else
    out[#out + 1] = "VERDICT: all cooldown, atomic"
end

local report = table.concat(out, "\n")
print(report)
if type(setclipboard) == "function" then
    setclipboard(report)
    print("[probe] copied to clipboard")
else
    warn("[probe] no setclipboard on this executor")
end
