--[[  LUMINOSITY — MINIMAL  ]]--
-- Steal a Brainrot — code sniper, straight remote path only.
-- Executor: anything that can run a LocalScript chunk. No executor globals are
--   required at all: no getconnections, getgc, firesignal, hookmetamethod,
--   newcclosure, VirtualInputManager, and no HTTP function.
--
-- This is the stripped build. Everything that was not on the line between
-- "packet arrives" and "InvokeServer" is gone:
--
--   removed  the entire GUI            — loader, moon rain, letter intro,
--                                        panel, notifications, FAB, and the
--                                        four permanent tween loops they ran
--   removed  the Discord webhook pool  — embed builder, rarity cache, thumb
--                                        resolution, JSON encode, HTTP POST
--   removed  the script-tracker beacon — fired HTTP on execute and every 30s
--   removed  the prize scanner         — DescendantAdded on the notification
--                                        tree plus a Text listener per label
--   removed  the clipboard paste path
--
-- What is left is three things: resolve the remote by layout, listen on the
-- notify RemoteEvent, invoke. Output goes to the console.
--
-- CONTROL
--   getgenv().Luminosity.Auto      = true/false   -- arm the sniper
--   getgenv().Luminosity.Threshold = 1            -- words before firing
--   Luminosity.Redeem("CODE")                     -- fire one by hand
--   RightControl                                  -- toggle Auto in game
--
-- DETECTION
-- Nothing is hooked, wrapped or patched. The redeem remote is found by walking
-- Packages.Net and taking the last hash-named RemoteFunction before the first
-- plaintext one, skipping uuid-shaped bait — the game plants
-- "RF/7d14a912-1040-4867-b005-98838eb9acc4" and
-- "RF/a0e78691-cb9b-4efc-ac08-9c06fea70059", and calling either is what kicks
-- you. Verified at RF-index 70 across servers, matching a Cobalt dump of the
-- real remote. The notify listener is an ordinary :Connect on an event the
-- client already subscribes to.

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
L.Verbose   = true
L.ToggleKey = Enum.KeyCode.RightControl

local function log(...)
    if L.Verbose then print("[Luminosity]", ...) end
end

----------------------------------------------------------------------
-- REMOTE RESOLUTION
----------------------------------------------------------------------
local Net = RepS:WaitForChild("Packages", 10)
Net = Net and Net:WaitForChild("Net", 10)

L.EXPECTED_INDEX = 70

local function isHashed(n) return #n == 67 and n:match("^RF/%x+$") ~= nil end
local function isBait(n)   return n:match("^RF/%x+%-%x+%-%x+%-%x+%-%x+$") ~= nil end

L.FindRedeem = function()
    if not Net then return nil end
    local last, idx, seen = nil, nil, 0
    for _, c in ipairs(Net:GetChildren()) do
        if c:IsA("RemoteFunction") then
            seen += 1
            if isBait(c.Name) then
                -- never a candidate
            elseif isHashed(c.Name) then
                last, idx = c, seen
            elseif last then
                return last, idx
            end
        end
    end
    return nil
end

L.RF = nil          -- redeem RemoteFunction, hot cache
L.NotifyRE = nil    -- notify RemoteEvent

L.Resolve = function()
    if not (L.RF and L.RF.Parent) then
        local inst, idx = L.FindRedeem()
        if inst then
            L.RF, L.Index = inst, idx
            if idx ~= L.EXPECTED_INDEX then
                warn(("[Luminosity] redeem remote at index %d, expected %d — verify before trusting it")
                    :format(idx, L.EXPECTED_INDEX))
            end
        end
    end
    if not (L.NotifyRE and L.NotifyRE.Parent) and Net then
        L.NotifyRE = Net:FindFirstChild("RE/NotificationService/Notify")
    end
    return L.RF
end

----------------------------------------------------------------------
-- REDEEM
--
-- preclean: the caller already proved the string is bare alphanumeric and in
-- range, so the sanitize pass is skipped. The packet path knows this for free.
----------------------------------------------------------------------
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

    -- pcall(r.InvokeServer, r, code) rather than pcall(function() ... end):
    -- the closure form allocates a function object on every call.
    local tCall = os.clock()
    local ok, a, b = pcall(r.InvokeServer, r, code)
    local tDone = os.clock()

    local client, server = (tCall - t0) * 1000, (tDone - tCall) * 1000
    if not ok then
        log(("FAIL  %s  —  %s"):format(code, tostring(a)))
        return nil, a, {client = client, server = server}
    end

    if a then L.Redeems += 1 end
    L.Last = {ok = a, message = b, client = client, server = server}
    log(("%s  %s  —  %s   (client %.3fms · server %.0fms)")
        :format(a and "OK  " or "NO  ", code, tostring(b), client, server))
    return a, b, {client = client, server = server}
end

----------------------------------------------------------------------
-- PACKET PATH
--
-- OnClientEvent is the earliest any client code can see an announcement; the
-- notification UI only exists a frame or more later, once the controller has
-- cloned its template and parented a label.
--
-- Nothing that is not needed to decide "fire or not" runs before InvokeServer.
-- Classification comes first, because proving the message is a single bare
-- alphanumeric token also proves it needs no sanitizing downstream — one test
-- doing two jobs. The word count only runs when a threshold above 1 asks for
-- it. There is no UI to repaint, so nothing is deferred either.
----------------------------------------------------------------------
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

    re.OnClientEvent:Connect(function(message)
        local t0 = os.clock()
        if not L.Auto then return end
        if typeof(message) ~= "string" or message == "" then return end

        local raw = message
        if raw:find("<", 1, true) then
            raw = raw:gsub("<br%s*/>", " "):gsub("<[^>]->", "")
            raw = raw:gsub("^%s+", ""):gsub("%s+$", "")
        end
        if raw == "" or L.Seen[raw] then return end

        local code, preclean
        local n = #raw
        if n >= 3 and n <= 50 and not raw:find("[^%w]") then
            if RESULT_WORDS[raw:lower()] then return end
            code, preclean = raw, true
        else
            if raw:find("[Ss]pawned") or raw:find("[Rr]edeemed") or raw:find("[Ii]nvalid")
               or raw:find("[Ee]xpired") or raw:find("[Aa]lready") or raw:find("[Ff]ailed") then
                return
            end
            code = raw:match("[%u%d][%u%d][%u%d]+")
            if not code then return end
            preclean = false
        end
        L.Seen[raw] = t0

        if L.Threshold > 1 then
            local w = 0
            for _ in code:gmatch("%S+") do w += 1 end
            L.Sent += w
            if L.Sent < L.Threshold then return end
            L.Sent = 0
        end

        -- ---- WIRE ----
        -- This handler already owns a thread, so yielding here costs nothing
        -- and skips a thread + closure allocation.
        L.Redeem(code, t0, preclean)
    end)
    log("packet path active")
end

----------------------------------------------------------------------
-- START
----------------------------------------------------------------------
task.spawn(function()
    for _ = 1, 80 do
        L.Resolve()
        L.Hook()
        if L.RF and L.Hooked then break end
        task.wait(0.25)
    end
    if L.RF then
        log(("remote %s @ index %d"):format(L.RF.Name, L.Index or -1))
    else
        warn("[Luminosity] redeem remote not found — Net layout may have moved")
    end
    log(("armed: Auto=%s Threshold=%d  (RightControl toggles)")
        :format(tostring(L.Auto), L.Threshold))
end)

UIS.InputBegan:Connect(function(i, gpe)
    if gpe then return end
    if i.KeyCode == L.ToggleKey then
        L.Auto = not L.Auto
        log("Auto " .. (L.Auto and "ON" or "OFF"))
    end
end)
