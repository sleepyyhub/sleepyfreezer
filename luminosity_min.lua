local Players = game:GetService("Players")
local UIS     = game:GetService("UserInputService")
local RepS    = game:GetService("ReplicatedStorage")
local LP      = Players.LocalPlayer

local L = {}
local genv = (type(getgenv) == "function") and select(2, pcall(getgenv)) or nil
if genv then genv.Luminosity = L end

L.Auto      = true
L.Threshold = 1
L.Sent      = 0
L.Redeems   = 0
L.ToggleKey = Enum.KeyCode.RightControl
L.Status    = "starting"

local Net = RepS:WaitForChild("Packages", 10)
Net = Net and Net:WaitForChild("Net", 10)

L.EXPECTED_INDEX = 70
L.EXPECTED_NOTIFY_INDEX = 146
L.SkipResults = false

local function isHashed(n) return #n == 67 and n:match("^RF/%x+$") ~= nil end
local function isBait(n)   return n:match("^RF/%x+%-%x+%-%x+%-%x+%-%x+$") ~= nil end
local function isHashedRE(n) return #n == 67 and n:match("^RE/%x+$") ~= nil end

L.FindNotify = function()
    if not Net then return nil end
    local seen = 0
    for _, c in ipairs(Net:GetChildren()) do
        if c:IsA("RemoteEvent") and isHashedRE(c.Name) then
            seen += 1
            if seen == L.EXPECTED_NOTIFY_INDEX then return c, seen end
        end
    end
    return nil
end

L.FindRedeem = function()
    if not Net then return nil end
    local last, idx, seen = nil, nil, 0
    for _, c in ipairs(Net:GetChildren()) do
        if c:IsA("RemoteFunction") then
            seen += 1
            if isBait(c.Name) then
            elseif isHashed(c.Name) then
                last, idx = c, seen
            elseif last then
                return last, idx
            end
        end
    end
    return nil
end

L.RF = nil
L.NotifyRE = nil

L.Resolve = function()
    if not (L.RF and L.RF.Parent) then
        local inst, idx = L.FindRedeem()
        if inst then
            L.RF, L.Index = inst, idx
            L.IndexOk = (idx == L.EXPECTED_INDEX)
        end
    end
    if not (L.NotifyRE and L.NotifyRE.Parent) and Net then
        local inst, idx = L.FindNotify()
        if inst then
            L.NotifyRE, L.NotifyIndex = inst, idx
            L.NotifyIndexOk = true
        else
            L.NotifyRE = Net:FindFirstChild("RE/NotificationService/Notify")
            L.NotifyIndexOk = false
        end
    end
    return L.RF
end

L.Sanitize = function(code)
    if not code or code == "" then return nil end
    if code:find("<", 1, true) then
        code = code:gsub("<br%s*/>"," "):gsub("<[^>]->","")
        code = code:gsub("^%s+",""):gsub("%s+$","")
    end
    if #code > 50 or code:find("[^%w]") then
        code = code:gsub("[^%w]","")
        if #code == 0 then return nil end
        if #code > 50 then code = code:sub(1,50) end
    end
    return code
end

L.Redeem = function(code, t0, preclean)
    t0 = t0 or os.clock()

    local r = L.RF
    if not r or r.Parent == nil then
        r = L.Resolve()
        if not r then return nil, "Remote unavailable" end
    end

    if not preclean then
        if not code or code == "" then return nil, "No code" end
        if #code > 50 or code:find("[^%w]") then
            code = L.Sanitize(code)
            if not code or code == "" then return nil, "No code" end
        end
    end

    local tCall = os.clock()
    local ok, a, b = pcall(r.InvokeServer, r, code)
    local tDone = os.clock()

    local timing = {client = (tCall - t0) * 1000, server = (tDone - tCall) * 1000}
    if not ok then
        L.Last = {ok = nil, code = code, message = tostring(a),
                  client = timing.client, server = timing.server}
        return nil, a, timing
    end

    if a then L.Redeems += 1 end
    L.Last = {ok = a, code = code, message = b,
              client = timing.client, server = timing.server}
    return a, b, timing
end

local RESULT_WORDS = {
    spawned = true, redeemed = true, invalid = true,
    expired = true, already = true, failed = true,
}

L.Seen = {}
L.Hooked = false

L.Hook = function()
    if L.Hooked then return end
    L.Resolve()
    local re = L.NotifyRE
    if not re then return end
    L.Hooked = true

    re.OnClientEvent:Connect(function(message, duration, sound, position)
        local t0 = os.clock()
        if not L.Auto then return end
        if typeof(message) ~= "string" or message == "" then return end

        local raw = message
        if raw:find("<", 1, true) then
            raw = raw:gsub("<br%s*/>", " "):gsub("<[^>]->", "")
            raw = raw:gsub("^%s+", ""):gsub("%s+$", "")
        end
        if raw == "" or L.Seen[raw] then return end
        if L.SkipResults and RESULT_WORDS[raw:lower()] then return end

        L.Seen[raw] = t0
        L.LastHeard = {text = raw, pos = position, at = t0}

        if L.Threshold > 1 then
            local w = 0
            for _ in raw:gmatch("%S+") do w += 1 end
            L.Sent += w
            if L.Sent < L.Threshold then return end
            L.Sent = 0
        end

        L.Redeem(raw, t0, true)
    end)
end

task.spawn(function()
    for _ = 1, 80 do
        L.Resolve()
        L.Hook()
        if L.RF and L.Hooked then break end
        task.wait(0.25)
    end
    if L.RF and L.Hooked then
        L.Status = "armed"
    elseif L.RF then
        L.Status = "remote ok, notify missing"
    else
        L.Status = "remote not found"
    end
end)

UIS.InputBegan:Connect(function(i, gpe)
    if gpe then return end
    if i.KeyCode == L.ToggleKey then
        L.Auto = not L.Auto
    end
end)
