-- Two settings decide how long a redeem packet sits in the outgoing queue before it
-- goes on the wire: the frame clock (the packet leaves on the next network send step)
-- and the signal mode (Deferred parks the handler until the next resumption point,
-- Immediate runs it inside the replication step, in time for this frame's send).
-- Both are set here, on the first line, so nothing that follows is sent under the old
-- ones. They are applied again further down through L.SetFpsCap / L.SetImmediateSignals
-- so the reported state stays honest; these two calls just win back the load time.
if type(setfpscap) == "function" then pcall(setfpscap, 999) end
pcall(function() workspace.SignalBehavior = Enum.SignalBehavior.Immediate end)

local Players       = game:GetService("Players")
local UIS           = game:GetService("UserInputService")
local TS            = game:GetService("TweenService")
local HttpService   = game:GetService("HttpService")
local RepS          = game:GetService("ReplicatedStorage")
local RunS          = game:GetService("RunService")
local LP            = Players.LocalPlayer
local PG            = LP:WaitForChild("PlayerGui")
local IS_MOBILE, IS_PC
do
    local platform
    pcall(function() platform = UIS:GetPlatform() end)
    IS_MOBILE = platform == Enum.Platform.IOS or platform == Enum.Platform.Android
    if platform == nil then IS_MOBILE = UIS.TouchEnabled and not UIS.MouseEnabled end
    IS_PC = not IS_MOBILE
end

local L = {}
L.IsMobile = IS_MOBILE
L.IsPC = IS_PC
local genv
if type(getgenv) == "function" then
    local ok, environment = pcall(getgenv)
    if ok and type(environment) == "table" then genv = environment end
end
if genv then genv.LUCK = L end

local SETTINGS_KEY = "LUCKSettingsV1"
local SETTINGS_FILE = "LUCK/settings.json"
local SETTINGS_DEFAULTS = {
    SpeedIndex = IS_PC and 4 or 1,
    AutoOn = true,
    Threshold = 1,
    ThresholdMode = "preset",
    CustomThreshold = 0,
    LastPreset = 1,
    History = {},
    ActiveTab = "Main",
    LayoutMode = "tabbed",
    PanelWindows = {},
    Minimized = false,
    PanelPosition = nil,
    WebhookOn = true,
    DedupOn = true,
    RainbowStats = true,
    PartTTL = 12,
    DupWindow = 0.15,
    ThemeIndex = 1,
    Keybinds = {Auto = "F", ToggleUI = "G", Stealth = "H"},
    DetectMode = "remote",
    RedeemPath = "remote",
    ViewMode = "standard",
}

do
local function settingInt(value, fallback, minimum, maximum)
    value = tonumber(value)
    if not value then return fallback end
    return math.clamp(math.floor(value + 0.5), minimum, maximum)
end

local function normalizeSettings(source)
    source = type(source) == "table" and source or {}
    local out = {
        SpeedIndex = settingInt(source.SpeedIndex, SETTINGS_DEFAULTS.SpeedIndex, 1, 4),
        AutoOn = type(source.AutoOn) == "boolean" and source.AutoOn
            or SETTINGS_DEFAULTS.AutoOn,
        ThresholdMode = source.ThresholdMode == "custom" and "custom" or "preset",
        CustomThreshold = settingInt(source.CustomThreshold, 0, 0, 50),
        LastPreset = settingInt(source.LastPreset, 1, 1, 5),
        History = {},
        ActiveTab = (source.ActiveTab == "History" or source.ActiveTab == "Performance")
            and source.ActiveTab or "Main",
        LayoutMode = source.LayoutMode == "panels" and "panels" or "tabbed",
        PanelWindows = {},
        Minimized = type(source.Minimized) == "boolean" and source.Minimized or false,
        GuessCode = type(source.GuessCode) == "boolean" and source.GuessCode or false,
        SettingsHidden = type(source.SettingsHidden) == "boolean" and source.SettingsHidden or false,
        RedeemMode = (source.RedeemMode == "both" or source.RedeemMode == "normal")
            and source.RedeemMode or "remote",
        DetectMode = source.DetectMode == "ui" and "ui" or "remote",
        RedeemPath = (source.RedeemPath == "ui" and "ui")
            or (source.RedeemPath == "both" and "both") or "remote",
        WebhookOn = type(source.WebhookOn) == "boolean" and source.WebhookOn or SETTINGS_DEFAULTS.WebhookOn,
        DedupOn = type(source.DedupOn) == "boolean" and source.DedupOn or SETTINGS_DEFAULTS.DedupOn,
        RainbowStats = type(source.RainbowStats) == "boolean" and source.RainbowStats or SETTINGS_DEFAULTS.RainbowStats,
    }
    out.ThemeIndex = settingInt(source.ThemeIndex, SETTINGS_DEFAULTS.ThemeIndex, 1, 6)
    out.Keybinds = {}
    local kb = type(source.Keybinds) == "table" and source.Keybinds or {}
    for action, default in pairs(SETTINGS_DEFAULTS.Keybinds) do
        local v = kb[action]
        out.Keybinds[action] = (type(v) == "string" and #v > 0) and v or default
    end
    out.PartTTL = settingInt(source.PartTTL, SETTINGS_DEFAULTS.PartTTL, 2, 30)
    out.DupWindow = math.clamp(tonumber(source.DupWindow) or SETTINGS_DEFAULTS.DupWindow, 0, 2)
    out.Threshold = settingInt(source.Threshold, SETTINGS_DEFAULTS.Threshold, 0, 50)
    local pos = source.PanelPosition
    if type(pos) == "table" then
        local xs, xo, ys, yo = tonumber(pos.XScale), tonumber(pos.XOffset), tonumber(pos.YScale), tonumber(pos.YOffset)
        if xs and xo and ys and yo then
            out.PanelPosition = {XScale = xs, XOffset = xo, YScale = ys, YOffset = yo}
        end
    end
    if out.ThresholdMode == "preset" then
        out.Threshold = math.clamp(out.Threshold, 1, 5)
        out.LastPreset = out.Threshold
    else
        out.Threshold = out.CustomThreshold
    end
    if type(source.History) == "table" then
        for i = 1, math.min(5, #source.History) do
            local item = source.History[i]
            if type(item) == "table" and type(item.code) == "string" and item.code ~= "" then
                out.History[#out.History + 1] = {
                    code = item.code:sub(1, 50),
                    status = item.status == "success" and "success"
                        or (item.status == "rejected" and "rejected" or "failed"),
                    client = tonumber(item.client),
                }
            end
        end
    end
    if type(source.PanelWindows) == "table" then
        for _, name in ipairs({"Main", "Status", "Preview", "History", "Feed", "Sender"}) do
            local panel = source.PanelWindows[name]
            if type(panel) == "table" then
                local position = panel.Position
                if type(position) == "table" then
                    local xs = tonumber(position.XScale)
                    local xo = tonumber(position.XOffset)
                    local ys = tonumber(position.YScale)
                    local yo = tonumber(position.YOffset)
                    if xs and xo and ys and yo then
                        out.PanelWindows[name] = {
                            Position = {XScale = xs, XOffset = xo, YScale = ys, YOffset = yo},
                            Minimized = panel.Minimized == true,
                        }
                    end
                end
            end
        end
    end
    return out
end

local remembered = genv and genv[SETTINGS_KEY] or nil
if type(remembered) ~= "table" and type(readfile) == "function" then
    local okExists, exists = pcall(function()
        return type(isfile) ~= "function" or isfile(SETTINGS_FILE)
    end)
    if okExists and exists then
        local okRead, raw = pcall(readfile, SETTINGS_FILE)
        if okRead and type(raw) == "string" then
            local okDecode, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
            if okDecode and type(decoded) == "table" then remembered = decoded end
        end
    end
end

L.Settings = normalizeSettings(remembered)
end
if genv then genv[SETTINGS_KEY] = L.Settings end
L.SettingsSaveToken = 0
L.SaveSettings = function()
    if genv then genv[SETTINGS_KEY] = L.Settings end
    if type(writefile) ~= "function" then return end
    L.SettingsSaveToken += 1
    local token = L.SettingsSaveToken
    -- 0.75s, not 0. A save is a full JSONEncode of the settings table plus a synchronous
    -- writefile, and AddHistory calls this on every redeem -- at delay 0 that landed on
    -- the very next frame, which is the frame the result comes back on and the frame a
    -- second code could drop into. Pushed clear of the window instead.
    task.delay(0.75, function()
        if token ~= L.SettingsSaveToken then return end
        local okEncode, body = pcall(HttpService.JSONEncode, HttpService, L.Settings)
        if not okEncode then return end
        pcall(function()
            if type(makefolder) == "function" and (type(isfolder) ~= "function" or not isfolder("LUCK")) then
                makefolder("LUCK")
            end
            writefile(SETTINGS_FILE, body)
        end)
    end)
end

L.Modded = (game.PlaceId ~= 109983668079237)
L.SR = 146/255; L.SG = 255/255; L.SB = 103/255

local T = {
    VOID     = Color3.fromRGB(4, 10, 7),
    BG       = Color3.fromRGB(8, 17, 11),
    SURFACE  = Color3.fromRGB(12, 25, 16),
    RAISED   = Color3.fromRGB(17, 36, 23),
    LINE     = Color3.fromRGB(31, 60, 41),
    ACCENT   = Color3.fromRGB(74, 222, 128),
    HIGH     = Color3.fromRGB(165, 255, 198),
    DEEP     = Color3.fromRGB(22, 163, 74),
    TEXT     = Color3.fromRGB(228, 246, 233),
    MUTED    = Color3.fromRGB(108, 148, 120),
    RED      = Color3.fromRGB(255, 130, 155),
    GREEN    = Color3.fromRGB(146, 255, 103),
    ORANGE   = Color3.fromRGB(255, 190, 120),
    WHITE    = Color3.fromRGB(255, 255, 255),
}

local function safe(fn) local ok,r = pcall(fn); return ok and r or nil end

L.NotifyRemoteName = "gui"

L.DetectMode = (L.Settings.DetectMode == "ui") and "ui" or "remote"
L.RedeemPath = (L.Settings.RedeemPath == "ui") and "ui" or "remote"
L.RedeemRemote, L.NotifyRemote = nil, nil
L.RedeemRemoteIsEvent = false
L.RemoteDetectOn = false

do
    local function unwrap(v)
        if typeof(v) == "Instance" then return v end
        if type(v) == "table" then
            local inner = rawget(v, "Instance") or rawget(v, "instance")
                or rawget(v, "_instance")
            if inner ~= nil then return unwrap(inner) end
        end
        return nil
    end

    local function classOf(inst)
        if inst:IsA("RemoteFunction") then return "function" end
        if inst:IsA("RemoteEvent") then return "event" end
        return nil
    end

    -- The remote list used to be a fresh RepS:GetDescendants() walk on every discovery
    -- tick: thousands of instances, four times a second, for up to a minute. Walk it
    -- once, then let DescendantAdded keep it current. Index order for the initial set
    -- is identical to what the first walk produced, which matters -- the redeem and
    -- notify fallbacks address remotes by position (70 and 146).
    local remoteIndex, remoteIndexBuilt = {}, false
    local function indexRemote(d)
        if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then
            remoteIndex[#remoteIndex + 1] = d
        end
    end
    local function enumerateRemotes()
        if remoteIndexBuilt then return remoteIndex end
        remoteIndexBuilt = true
        for _, d in ipairs(RepS:GetDescendants()) do indexRemote(d) end
        RepS.DescendantAdded:Connect(indexRemote)
        return remoteIndex
    end
    L.RemoteIndex = enumerateRemotes

    local function verifiedNotify()
        if typeof(getconnections) ~= "function" then return nil end
        local getinfo = debug and (debug.getinfo or debug.info)
        if not getinfo then return nil end
        local list = enumerateRemotes()

        local function owned(d)
            local ok, cs = pcall(getconnections, d.OnClientEvent)
            if not ok or type(cs) ~= "table" then return false end
            for _, c in ipairs(cs) do
                local okf, fn = pcall(function() return c.Function end)
                if okf and type(fn) == "function" then
                    local oki, info = pcall(getinfo, fn)
                    local src = oki and tostring(info.short_src or info.source or "") or ""
                    if src:find("NotificationController", 1, true) then return true end
                end
            end
            return false
        end

        -- Packages.Net first when that folder exists: the real one lives there, and
        -- finding it there skips getconnections on every other remote in the place.
        local net = RepS:FindFirstChild("Packages")
        net = net and net:FindFirstChild("Net")
        if net then
            for i = 1, #list do
                local d = list[i]
                if d:IsA("RemoteEvent") and d:IsDescendantOf(net) and owned(d) then
                    return d
                end
            end
        end
        for i = 1, #list do
            local d = list[i]
            if d:IsA("RemoteEvent") and owned(d) then return d end
        end
        return nil
    end

    local function verifiedRedeem()
        if typeof(getconnections) ~= "function" then return nil end
        local ok, found = pcall(function()
            local codes = PG:FindFirstChild("Codes")
            codes = codes and codes:FindFirstChild("Codes")
            local btn = codes and codes:FindFirstChild("Confirm")
            if not btn then return nil end
            local conns = getconnections(btn.Activated)
            local wrapper = conns and conns[1] and conns[1].Function
            if not wrapper then return nil end
            local wa, wb = debug.getupvalue(wrapper, 1)
            local selfT = type(wa) == "table" and wa or wb
            local sig = type(selfT) == "table" and selfT.OnActivated
            local node = sig and rawget(sig, "_handlerListHead")
            while node do
                local fn = rawget(node, "_fn")
                if type(fn) == "function"
                    and tostring(debug.getinfo(fn).source):find("CodesController", 1, true) then
                    for i = 1, 30 do
                        local na, nb = debug.getupvalue(fn, i)
                        if na == nil and nb == nil then break end
                        local v = unwrap(typeof(na) == "Instance" and na
                            or (type(na) == "table" and na or nb))
                        if v and v:IsA("RemoteFunction") then return v end
                    end
                end
                node = rawget(node, "_next")
            end
            return nil
        end)
        return ok and found or nil
    end

    L.ResolveIndexedRemotes = function()
        local ok, list = pcall(enumerateRemotes)
        if not ok or type(list) ~= "table" then return false end
        L.RemoteCount = #list
        if not L.RedeemRemote then
            local redeem = unwrap(list[70])
            if redeem and classOf(redeem) then
                L.RedeemRemote = redeem
                L.RedeemRemoteIsEvent = classOf(redeem) == "event"
                L.RedeemRemoteSource = "index 70"
            end
        end
        if not L.NotifyRemote then
            local notify = unwrap(list[146])
            if notify and classOf(notify) == "event" then
                L.NotifyRemote = notify
                L.NotifyRemoteSource = "index 146"
            end
        end
        return L.RedeemRemote ~= nil
    end

    local function netFallback()
        if L.RedeemRemote and L.NotifyRemote then return end
        local okNet, Net = pcall(function()
            local packages = RepS:FindFirstChild("Packages")
            local net = packages and packages:FindFirstChild("Net")
            return net and require(net) or nil
        end)
        if okNet and type(Net) == "table" then
            if not L.RedeemRemote then
                local okR, r = pcall(function()
                    return Net:RemoteFunction("7d14a912-1040-4867-b005-98838eb9acc4")
                end)
                r = okR and unwrap(r) or nil
                if r and classOf(r) == "function" then
                    L.RedeemRemote, L.RedeemRemoteIsEvent = r, false
                    L.RedeemRemoteSource = "net"
                end
            end
            if not L.NotifyRemote then
                local okN, n = pcall(function()
                    return Net:RemoteEvent("NotificationService/Notify")
                end)
                n = okN and unwrap(n) or nil
                if n and classOf(n) == "event" then
                    L.NotifyRemote, L.NotifyRemoteSource = n, "net"
                end
            end
        end
        if not L.NotifyRemote then
            local n = RepS:FindFirstChild("RE/NotificationService/Notify", true)
            if n and classOf(n) == "event" then
                L.NotifyRemote, L.NotifyRemoteSource = n, "net"
            end
        end
    end

    L.RefreshRemoteStatus = function()
        if L.SyncFast then L.SyncFast() end
        local rs
        if L.RedeemRemote then
            if L.RedeemRemoteTested == true then
                rs = ("tested ok (%s)"):format(L.RedeemRemoteSource or "?")
            elseif L.RedeemRemoteTested == false then
                rs = "test FAILED"
            else
                rs = ("found (%s), testing…"):format(L.RedeemRemoteSource or "?")
            end
        else
            rs = L.RedeemTestFailed and "test failed, using UI" or "searching…"
        end
        local ns
        if L.RemoteDetectOn then
            ns = ("live (%s)"):format(L.NotifyRemoteSource or "?")
        elseif L.NotifyRemote then
            ns = ("found (%s)"):format(L.NotifyRemoteSource or "?")
        else
            ns = "searching…"
        end
        L.RemoteStatusText = ("redeem: %s   ·   notify: %s"):format(rs, ns)
        if L.RemoteStatusLabel then
            L.RemoteStatusLabel.Text = L.RemoteStatusText
        end
    end
    L.RefreshRemoteStatus()

    local function onRemoteNotify(text, _, _, placement)
        if placement == "Top" then
            if L.DetectMode ~= "remote" then return end
            local fast = L.FastPath
            if fast then return fast(text, os.clock()) end
            if type(text) ~= "string" or text == "" then
                text = L.PayloadText and L.PayloadText(text, 0) or nil
                if not text then return end
            end
            L.TextAt = os.clock()
            pcall(L.Dispatch, text)
            return
        end
        if L.OursPending and L.ClaimResult then
            if type(text) ~= "string" or text == "" then
                text = L.PayloadText and L.PayloadText(text, 0) or nil
                if not text then return end
            end
            pcall(L.ClaimResult, text)
        end
    end

    L.ConnectNotifyRemote = function()
        if L.RemoteDetectOn then return true end
        local r = L.NotifyRemote
        if not r then return false end
        local G = (getgenv and getgenv()) or shared
        if G.__LUCKNotifyConn then
            pcall(function() G.__LUCKNotifyConn:Disconnect() end)
            G.__LUCKNotifyConn = nil
        end
        local ok, conn = pcall(function()
            return r.OnClientEvent:Connect(L.FastNotify or onRemoteNotify)
        end)
        if ok and conn then
            G.__LUCKNotifyConn = conn
            L.RemoteDetectOn = true
            if L.DetectMode == "remote" then
                L.NotifyRemoteName = "remote"
                local NC = G.__LumNotifyNC
                if NC and type(G.__LumNotifyReal) == "function" then
                    pcall(function() NC.Notify = G.__LumNotifyReal end)
                    L.NotifyHooked = false
                end
            end
        end
        -- Any successful (re)connect puts us at the back of the list and may leave
        -- handlers that attached since the last sweep still live, so re-hold pole here
        -- rather than only at boost time.
        if ok and conn and L.PoleOn and L.RetakePole then pcall(L.RetakePole) end
        L.RefreshRemoteStatus()
        return ok and conn ~= nil
    end

    local tested = false
    local function testRedeemRemote()
        if tested or not L.RedeemRemote or L.RedeemRemoteIsEvent then return end
        if L.RedeemPath ~= "remote" then return end
        tested = true
        local bogus = "LUCKTEST" .. tostring(math.random(1000, 9999))
        local pok, a, b = pcall(L.RedeemRemote.InvokeServer, L.RedeemRemote, bogus)
        L.RedeemRemoteTested = pok
        L.RedeemRemoteReply = pok
            and (tostring(a) .. (b ~= nil and ("/" .. tostring(b)) or ""))
            or tostring(a)
        if not pok then
            L.RedeemRemote, L.RedeemRemoteSource = nil, nil
            L.RedeemTestFailed = true
        end
        L.RefreshRemoteStatus()
    end
    L.TestRedeemRemote = function()
        tested = false
        L.RedeemRemoteTested = nil
        L.RedeemTestFailed = false
        task.spawn(testRedeemRemote)
    end

    -- Discovery. The old shape was a flat `for 1,240 ... task.wait(0.25)` loop that did
    -- every lookup on every tick and only checked whether it was still needed at the
    -- bottom -- so a place with a big ReplicatedStorage paid two full tree walks plus
    -- getconnections on every RemoteEvent, four times a second, for up to a minute.
    -- Every one of those walks is a frame hitch, and a hitch is a lost send slot.
    --
    -- Now: each lookup is skipped once its own target is resolved, the schedule backs
    -- off, and the two events that can actually turn a failed lookup into a working one
    -- -- a remote replicating in, the Codes GUI appearing -- kick a pass directly
    -- instead of being polled for.
    --
    -- A verified lookup stops once it hits, because its answer is authoritative and
    -- cannot change, and stops anyway after VERIFY_TRIES misses: without that cap a
    -- place where the controller source name never matches would re-scan every remote
    -- on every pass, forever.
    local VERIFY_TRIES = 10
    local notifyVerified, redeemVerified = false, false
    local notifyTries, redeemTries = 0, 0

    local function discoverPass()
        if not (L.NotifyRemote and L.RedeemRemote) then
            if L.Modded then
                if not L.NotifyRemote then
                    local n = RepS:FindFirstChild("RE/NotificationService/Notify", true)
                        or RepS:FindFirstChild("RE/NotificationService", true)
                    if n and classOf(n) == "event" then
                        L.NotifyRemote, L.NotifyRemoteSource = n, "direct name"
                    end
                end
                if not L.RedeemRemote then
                    local r = RepS:FindFirstChild("RF/RequestRedemption", true)
                    if r and classOf(r) then
                        L.RedeemRemote = r
                        L.RedeemRemoteIsEvent = classOf(r) == "event"
                        L.RedeemRemoteSource = "direct name"
                    end
                end
            else
                L.ResolveIndexedRemotes()
                netFallback()
            end
        end

        if not notifyVerified and notifyTries < VERIFY_TRIES then
            notifyTries += 1
            local vn = verifiedNotify()
            if vn then
                notifyVerified = true
                if L.NotifyRemote ~= vn then
                    L.NotifyRemoteSource = L.NotifyRemote
                        and "verified (index was off)" or "verified"
                    L.NotifyRemote = vn
                    -- We were listening on the guessed remote. Drop the flag so the
                    -- ConnectNotifyRemote below moves the connection to the real one;
                    -- the old loop set L.NotifyRemote here and then hit the early
                    -- return in ConnectNotifyRemote, so the correction never landed.
                    L.RemoteDetectOn = false
                end
            end
        end

        if not redeemVerified and redeemTries < VERIFY_TRIES then
            redeemTries += 1
            local vr = verifiedRedeem()
            if vr then
                redeemVerified = true
                if L.RedeemRemote ~= vr then
                    L.RedeemRemoteSource = L.RedeemRemote
                        and "verified (index was off)" or "verified"
                    tested = false
                    L.RedeemRemoteTested = nil
                end
                L.RedeemRemote, L.RedeemRemoteIsEvent = vr, false
            end
        end

        if L.NotifyRemote then L.ConnectNotifyRemote() end
        testRedeemRemote()
        L.RefreshRemoteStatus()
        return L.RedeemRemote ~= nil and L.RemoteDetectOn
            and L.RedeemRemoteTested ~= nil
    end

    local discoverDone, running = false, false
    local kickConns = {}
    local function dropKicks()
        for i = 1, #kickConns do
            local c = kickConns[i]
            pcall(function() c:Disconnect() end)
        end
        kickConns = {}
    end
    local function runDiscovery()
        if discoverDone or running then return end
        running = true
        local ok, done = pcall(discoverPass)
        running = false
        if ok and done then
            discoverDone = true
            L.Discovered = true
            dropKicks()
            if L.OnDiscovered then task.defer(L.OnDiscovered) end
        end
    end
    L.RunDiscovery = runDiscovery

    local kickQueued = false
    local function kick()
        if discoverDone or kickQueued then return end
        kickQueued = true
        -- Debounced: a folder replicating in is hundreds of DescendantAdded fires and
        -- they should cost one pass between them, not hundreds.
        task.delay(0.05, function()
            kickQueued = false
            runDiscovery()
        end)
    end

    kickConns[1] = RepS.DescendantAdded:Connect(function(d)
        if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then kick() end
    end)
    kickConns[2] = PG.ChildAdded:Connect(function(child)
        if child.Name == "Codes" then kick() end
    end)

    task.spawn(function()
        runDiscovery()
        local gap, spent = 0.1, 0
        while not discoverDone and spent < 60 do
            task.wait(gap)
            spent += gap
            runDiscovery()
            if gap < 2 then gap = math.min(gap * 1.6, 2) end
        end
        -- Budget spent. Whatever was going to resolve has resolved; drop the event
        -- hooks so a place that keeps replicating remotes in does not keep waking us.
        dropKicks()
    end)
end

L.FireFast = function(code)
    local path = L.RedeemPath
    if path ~= "ui" then
        local r, inv = L.FastRemote, L.FastInvoke
        if not inv then
            r = L.RedeemRemote
            inv = r and (L.RedeemRemoteIsEvent and r.FireServer or r.InvokeServer)
        end
        if inv then
            if path == "both" then
                task.spawn(inv, r, code)
                local uok = pcall(L.FireNormal, code)
                return true, uok, "sent (both)", true
            end
            if L.RedeemRemoteIsEvent then
                if pcall(inv, r, code) then
                    return true, true, "sent", true
                end
            else
                local pok, a, b = pcall(inv, r, code)
                if pok then
                    if a == nil then return true, true, "sent", true end
                    return true, a, b, false
                end
            end
        end
    end
    local pok = pcall(L.FireNormal, code)
    return pok, pok == true, "sent", true
end

L.RedeemViaRemote = function(code)
    local pok, r1, r2, fireOnly = L.FireFast(code)
    local ok
    if pok then ok = fireOnly and true or (r1 == true) end
    return ok, pok and (r2 or "sent") or "redeem failed",
        {client = 0, server = 0, fireOnly = fireOnly}
end

L.Warming = false
L.WarmCooldownUntil = 0
L.WarmRemote = function()
    if L.Warming then return false end
    local now = os.clock()
    if now < (L.WarmCooldownUntil or 0) then return false end
    local r = L.RedeemRemote
    if not r or L.RedeemRemoteIsEvent then return false end
    L.Warming = true
    task.spawn(function()
        for i = 1, 5 do
            pcall(r.InvokeServer, r, "LUCKWARM" .. tostring(math.random(1000, 9999)))
            if i < 5 then task.wait(5) end
        end
        L.Warming = false
        L.WarmCooldownUntil = os.clock() + 5
        if L.WarmDone then L.WarmDone() end
    end)
    return true
end

L.SpeedModes = {
    {name = "Normal",     clean = true,  filter = true,  recheck = true  },
    {name = "Medium",     clean = true,  filter = false, recheck = false },
    {name = "Fast",       clean = false, filter = false, recheck = false },
    {name = "Lucky",      clean = false, filter = false, recheck = false, raw = true },
}
L.SpeedIndex = math.clamp(L.Settings.SpeedIndex or 1, 1, #L.SpeedModes)
L.Mode = L.SpeedModes[L.SpeedIndex]
L.AutoOn = L.Settings.AutoOn == true
L.ThresholdMode = L.Settings.ThresholdMode
L.CustomThreshold = L.Settings.CustomThreshold
L.LastPreset = L.Settings.LastPreset
L.Threshold = L.Settings.Threshold

L.PacketHooked = false

L.Heard = {}
L.HeardMax = 40

local TEXT_KEYS = {
    "Message", "message", "Content", "content", "Body", "body",
    "Text", "text", "Description", "description", "Code", "code",
    "Value", "value", "Title", "title"
}
local function payloadTextImpl(v, depth)
    local tv = type(v)
    if tv == "string" then return v end
    if tv ~= "table" or depth > 4 then return nil end
    for i = 1, #TEXT_KEYS do
        local item = v[TEXT_KEYS[i]]
        if item ~= nil then
            local r = payloadTextImpl(item, depth + 1)
            if r and r ~= "" then return r end
        end
    end
    for i = 1, #v do
        local r = payloadTextImpl(v[i], depth + 1)
        if r and r ~= "" then return r end
    end
    for key, item in pairs(v) do
        if type(key) == "number" then continue end
        local r = payloadTextImpl(item, depth + 1)
        if r and r ~= "" then return r end
    end
    return nil
end
L.PayloadText = payloadTextImpl

L.IsNotifyMetadata = function(value)
    if type(value) ~= "string" then return false end
    local lower = value:lower()
    return lower:find("rbxassetid://", 1, true) ~= nil
        or lower:find("^sounds?%.") ~= nil
        or lower:find("^sounds?/") ~= nil
        or lower:find("^assets?%.") ~= nil
end

-- Hoisted. This used to be built inside CodeFrom, so every call allocated a 25-key
-- table before it looked at a single word -- and CodeFrom is on the reject-retry path,
-- which runs while a code is live.
local STOP = {
    new = true, code = true, codes = true, released = true, release = true,
    use = true, redeem = true, redeemed = true, the = true, a = true,
    an = true, is = true, now = true, here = true, ["for"] = true, ["and"] = true,
    available = true, out = true, drop = true, dropped = true, alert = true,
    fresh = true, limited = true, time = true, get = true, claim = true,
    free = true, update = true, incoming = true, just = true, live = true,
}

L.CodeFrom = function(raw)
    local n = #raw
    if n == 0 or n > 200 then return nil end
    if n <= 50 and not raw:find("[^%w]") then return raw:upper() end

    local hasTag = raw:find("<", 1, true)
    if not hasTag and raw:find("[%.:/]") and L.IsNotifyMetadata(raw) then return nil end
    if hasTag then
        raw = raw:gsub("<br%s*/>", " "):gsub("<[^>]->", "")
    end
    raw = raw:gsub("^%s+", ""):gsub("%s+$", "")
    if raw == "" then return nil end
    if #raw <= 50 and not raw:find("[^%w]") then return raw:upper() end

    local piece, bestScore
    local fallback, flen = nil, 0
    for run in raw:gmatch("%w+") do
        if #run >= flen then fallback, flen = run, #run end
        if not STOP[run:lower()] then
            local score = #run
            if run:find("%d") then score += 100 end
            if run:find("%a") and run == run:upper() then score += 50 end
            if not bestScore or score >= bestScore then
                piece, bestScore = run, score
            end
        end
    end
    piece = piece or fallback
    if not piece then return nil end
    if #piece > 50 then piece = piece:sub(1, 50) end
    return piece:upper()
end

local codeFrom, payloadText = L.CodeFrom, L.PayloadText

local clock, defer, protected = os.clock, task.defer, pcall

local firedSeen = {}
L.FiredSeen = firedSeen
L.FIRED_TTL = 30

-- One janitor, not two. The fired-code table and the sent-code table each used to run
-- their own 30s task.spawn loop, so the client woke twice per window to do work that
-- fits in a single pass.
task.spawn(function()
    while true do
        task.wait(30)
        local firedCutoff = clock() - L.FIRED_TTL
        for code, at in pairs(firedSeen) do
            if at < firedCutoff then firedSeen[code] = nil end
        end
        local sentCodes = L.SentCodes
        if sentCodes then table.clear(sentCodes) end
    end
end)

L.Buf, L.BufN, L.BufAt = table.create(8), 0, 0
L.PART_TTL = L.Settings.PartTTL or 12

L.GuessCode = false

do
    local arr, n, at, joined = L.Buf, 0, 0, ""
    local partTTL = L.PART_TTL

    L.SyncBuf = function() partTTL = L.PART_TTL or 12 end

    local function reset()
        if n == 0 then return end
        table.clear(arr)
        n, joined = 0, ""
        L.BufN = 0
    end
    L.ResetBuf = reset

    local function push(piece, now)
        if n > 0 and (now - at) > partTTL then
            table.clear(arr); n, joined = 0, ""
        end
        n += 1
        arr[n] = piece
        at = now
        joined = (n == 1) and piece or (joined .. piece)
        L.BufN, L.BufAt = n, now
        return joined
    end

    L.Accumulate = function(piece, now)
        local code = push(piece, now)
        if #code > 50 then code = code:sub(1, 50) end
        return code
    end

    L.Feed = function(piece, now)
        local code = push(piece, now)
        local need = L.Threshold
        if need < 1 then need = 1 end
        if n < need then return nil end
        table.clear(arr)
        n, joined = 0, ""
        L.BufN = 0
        if #code > 50 then code = code:sub(1, 50) end
        return code
    end
end

L.CodeHistory = L.Settings.History
L.HistoryMax = 5
L.LastPreviewCode = nil

L.AddHistory = function(code, ok, timing)
    if not code or code == "" then return end
    local status = ok == true and "success" or (ok == false and "rejected" or "failed")
    table.insert(L.CodeHistory, 1, {
        code = tostring(code):sub(1, 50),
        status = status,
        client = timing and tonumber(timing.client) or nil,
    })
    while #L.CodeHistory > L.HistoryMax do table.remove(L.CodeHistory) end
    L.Settings.History = L.CodeHistory
    L.SaveSettings()
    if L.RefreshHistory then L.RefreshHistory() end
end

L.LogHeard = function(t0, src, code)
    local h = L.Heard
    h[#h + 1] = {at = t0, src = src, text = code, code = code}
    if #h > L.HeardMax then table.remove(h, 1) end
end

L.PostFragment = function(t0, src, code)
    L.LogHeard(t0, src, code)
    if L.RefreshAuto then L.RefreshAuto() end
end

-- The remote's own answer, surfaced as a notification.
--
-- A fire-and-forget remote learns its result from a follow-up announcement,
-- and claimOurs already puts that on screen. A RemoteFunction hands the answer
-- straight back from the invoke, and that reply previously only reached the
-- compact status toast -- so "Meowl spawned!" never showed up in the feed.
-- This closes that path. ResultShown stops the two from doubling up.
L.ResultNotifyOn = true
L.ResultShown = nil
L.ResultNotify = function(code, ok, reply)
    if not L.ResultNotifyOn then return false end
    if L.ResultShown ~= nil and L.ResultShown == code then
        L.ResultShown = nil
        return false      -- claimOurs already showed this one
    end

    local text = reply
    if type(text) ~= "string" then
        text = L.PayloadText and L.PayloadText(reply, 0) or nil
    end
    text = text and (L.Strip and L.Strip(text) or tostring(text)) or ""
    -- "sent" is the placeholder for a fire-and-forget, not an answer
    if text == "" or text:lower() == "sent" then return false end

    local colour = (ok == true and T.GREEN)
        or (ok == false and T.RED)
        or T.ORANGE

    local line = text
    local codeStr = tostring(code or "")
    if codeStr ~= "" and not text:upper():find(codeStr:upper(), 1, true) then
        line = ("%s   ·   %s"):format(text, codeStr)
    end
    if L.Notify then L.Notify(line, colour) end
    L.LastResultText = text
    return true
end

L.PostRedeem = function(t0, src, code, ok, reply, timing)
    if L.ResultNotify then L.ResultNotify(code, ok, reply) end
    if L.ToastResult then L.ToastResult(code, ok, reply) end
    L.LogHeard(t0, src, code)
    L.LastPreviewCode = code
    L.AddHistory(code, ok, timing)
    if L.RefreshAuto then L.RefreshAuto() end
    if L.ReportRedeem then L.ReportRedeem(ok, reply, timing) end
    if L.RefreshPreview then L.RefreshPreview() end
    if L.AutoReport then pcall(L.AutoReport) end
    task.delay(1.25, function()
        if L.RefreshPreview then L.RefreshPreview() end
    end)
end

local logHeard, postFragment, postRedeem, feed =
    L.LogHeard, L.PostFragment, L.PostRedeem, L.Feed
L.PostRedeemBridge = postRedeem

local hotAuto, hotThreshold = false, 1
local hotGuess = false
local hotFiredTTL = 30

L.SyncHot = function()
    if L.SyncBuf then L.SyncBuf() end
    hotFiredTTL  = L.FIRED_TTL or 30
    hotAuto      = L.AutoOn
    hotGuess     = L.GuessCode
    hotThreshold = L.Threshold or 1
    if L.SyncFast then L.SyncFast() end
end
L.SyncHot()

local rawFire

L.RedeemMode = "normal"
L.UIBox = nil
L.UIHandlers = {}

local uiBox, uiHandlers = nil, {}
local uiHandlerN, uiHandler1 = 0, nil
L.BoxAlive = false

L.ResolveUIPath = function()
    local box = safe(function() return PG.Codes.Codes.CodeRedeem.TextBox end)
    local btn = safe(function() return PG.Codes.Codes.Confirm end)
    if box and box ~= uiBox then
        L.UIBox, uiBox = box, box
        L.BoxAlive = box.Parent ~= nil
        box.AncestryChanged:Connect(function(_, parent)
            L.BoxAlive = parent ~= nil
        end)
    elseif box then
        L.BoxAlive = box.Parent ~= nil
    end
    if not btn or typeof(getconnections) ~= "function" then
        return uiBox ~= nil and #uiHandlers > 0
    end

    local found = {}
    for _, sigName in ipairs({"Activated", "MouseButton1Click"}) do
        local sig = btn[sigName]
        if sig then
            local okC, conns = pcall(getconnections, sig)
            if okC and type(conns) == "table" then
                for _, c in ipairs(conns) do
                    local okf, f = pcall(function() return c.Function end)
                    if okf and type(f) == "function" then found[#found + 1] = f end
                end
            end
        end
    end
    if #found > 0 then
        L.UIHandlers, uiHandlers = found, found
        uiHandlerN, uiHandler1 = #found, found[1]
    end
    L.UIButton = btn
    return uiBox ~= nil and #uiHandlers > 0
end

local function fireNormal(code)
    local box = uiBox
    if not L.BoxAlive then
        if not L.ResolveUIPath() then return false end
        box = uiBox
        if not box then return false end
    end
    if L.TextAt then
        L.LastGapMs = (os.clock() - L.TextAt) * 1000
        if not L.BestGapMs or L.LastGapMs < L.BestGapMs then L.BestGapMs = L.LastGapMs end
    end
    box.Text = code

    if uiHandlerN == 1 then
        pcall(uiHandler1)
        return true
    end
    if uiHandlerN == 0 then return false end
    local hs = uiHandlers
    for i = 1, uiHandlerN do pcall(hs[i]) end
    return true
end
L.FireNormal = fireNormal

-- Was a 600 x 0.1s poll that ran getconnections on two button signals every tick,
-- starting before the Codes GUI even existed. WaitForChild parks the thread for free
-- until the GUI actually replicates in, then a short backoff covers handlers that
-- attach a beat after their button does.
task.spawn(function()
    if L.ResolveUIPath() then return end
    pcall(function()
        local codes = PG:WaitForChild("Codes", 60)
        codes = codes and codes:WaitForChild("Codes", 60)
        local redeem = codes and codes:WaitForChild("CodeRedeem", 60)
        if redeem then redeem:WaitForChild("TextBox", 60) end
        if codes then codes:WaitForChild("Confirm", 60) end
    end)
    local gap = 0.05
    for _ = 1, 12 do
        if L.ResolveUIPath() then return end
        task.wait(gap)
        if gap < 1 then gap = math.min(gap * 1.6, 1) end
    end
    L.ResolveUIPath()
end)

local accumulate = L.Accumulate
local killFeed

local function spotlightFromAnnouncement(raw)
    if not L.NotifyRedeem then return end
    local who
    for _, plr in ipairs(Players:GetPlayers()) do
        if raw:find(plr.Name, 1, true)
            or (plr.DisplayName ~= plr.Name and raw:find(plr.DisplayName, 1, true)) then
            who = plr
            break
        end
    end
    if not who then return end
    local code = raw:match('"(%w+)"') or raw:match("`(%w+)`")
        or raw:match("%f[%w](%u[%u%d]+)%f[^%w]") or "?"
    local prize = L.Prize and L.Prize(raw) or nil
    L.NotifyRedeem(code, prize, who)
end

L.OURS_WINDOW = 6

local claimOurs
do
    local WIN  = {"spawned", "redeemed", "claimed", "received", "granted"}
    local FAIL = {"invalid", "expired", "already", "sold out", "failed",
                  "not found", "wrong", "used"}

    local function matchAny(low, list)
        for k = 1, #list do
            if low:find(list[k], 1, true) then return true end
        end
        return false
    end

    claimOurs = function(text)
        if not L.OursPending then return false end
        if (os.clock() - (L.OursAt or 0)) > L.OURS_WINDOW then
            L.OursPending = nil
            return false
        end

        local low  = text:lower()
        local won, lost
        local tint = L.LastLabelColor
        if tint == "win" then
            won = true
        elseif tint == "fail" then
            lost = true
        else
            won  = matchAny(low, WIN)
            lost = (not won) and matchAny(low, FAIL) or false
        end
        if not (won or lost) then return false end

        local code = L.OursPending
        L.OursPending = nil
        local clean = L.Strip and L.Strip(text) or text
        won = won == true
        L.LastOursPrize, L.LastOursOk = clean, won
        L.LastOursTint = tint

        if L.GuessCode then
            if won then L.ResetBuf() end
        end

        L.Notify(clean, won and T.GREEN or T.ORANGE)
        L.ResultShown = code   -- PostRedeem must not repeat this line

        if L.PostOursResult then L.PostOursResult(code, clean, won) end
        return true, won
    end
end
L.ClaimOurs = claimOurs

L.PostOursResult = function(code, text, won)
    local t0     = L.OursT0 or os.clock()
    local timing = L.OursTiming or {client = 0, server = 0, fireOnly = true}
    if L.PostRedeemBridge then
        L.PostRedeemBridge(t0, L.NotifyRemoteName, code, won and true or false, text, timing)
    end
end

killFeed = function(text)
    if not L.NotifyRedeem then return end
    if text:lower():find("redeem", 1, true) then
        spotlightFromAnnouncement(text)
    end
end

L.NotifyHandler = function(a)
    local t0 = clock()

    local text = a
    if type(text) ~= "string" then
        text = payloadText(a, 0)
    end
    if not text then return end

    if L.OursPending and claimOurs(text) then return end

    if L.NotifyRedeem then defer(killFeed, text) end

    if not hotAuto and not hotGuess then return end

    local code = text
    if hotGuess then
        code = accumulate(text, t0)
    elseif hotThreshold > 1 then
        code = feed(text, t0)
        if not code then
            defer(postFragment, t0, L.NotifyRemoteName, text)
            return
        end
    end

    local firedAt = firedSeen[code]
    if firedAt and (t0 - firedAt) <= hotFiredTTL then return end
    firedSeen[code] = t0

    L.OursPending = code
    L.OursAt = t0

    local tCall = clock()
    local pok, r1, r2, fireOnly = L.FireFast(code)
    if not pok then r1, r2 = false, "fire failed" end

    local tDone = clock()

    defer(rawFire, t0, tCall, tDone, text, code, pok, r1, r2, fireOnly)
end

rawFire = function(t0, tCall, tDone, text, code, pok, r1, r2, fireOnly)
    if fireOnly == nil then fireOnly = true end
    local timing = {client = (tCall - t0) * 1000, server = (tDone - tCall) * 1000,
                    fireOnly = fireOnly or nil}
    L.LastTiming = timing
    L.LastDetect, L.RecentRedeem, L.LastSource, L.LastFireAt = t0, t0, L.NotifyRemoteName, t0

    local ok, reply
    if not pok then
        L.LastError = tostring(r1)
        local cleaned = codeFrom(text)
        if cleaned then
            ok, reply = L.RedeemViaRemote(cleaned, t0, true)
        else
            ok, reply = nil, "Request failed"
        end
    elseif fireOnly then
        L.OursT0, L.OursTiming, L.OursCode = t0, timing, code
        if status then
            status.set(("sent  ·  %s  ·  %.3fms detect->send%s"):format(
                code, L.FloorUs and (L.FloorUs / 1000) or L.LastGapMs or 0,
                (L.DetectMode == "remote" and L.RemoteDetectOn) and "  ·  remote"
                    or (L.NotifyHooked and "  ·  notify" or "  ·  label")), T.MUTED)
        end
        task.delay(L.OURS_WINDOW, function()
            if L.OursPending == code then
                L.OursPending = nil
                postRedeem(t0, L.NotifyRemoteName, code, nil, "no result", timing)
            end
        end)
        return
    else
        ok, reply = r1, r2
        L.LastReply = {ok = r1, message = r2}
        L.OursPending = nil
        if ok == true and L.GuessCode then L.ResetBuf() end

        if ok ~= true then
            local cleaned = codeFrom(text)
            if cleaned and cleaned ~= code then
                ok, reply = L.RedeemViaRemote(cleaned, t0, true)
                code = cleaned
            end
        end
    end

    postRedeem(t0, L.NotifyRemoteName, code, ok, reply, timing)
end

do
    local PGx = PG
    local uiFireLegacy = fireNormal

    local uiBox2, submitCode, submitNode, confirmBtn
    local getupv, setupv = debug.getupvalue, debug.setupvalue

    L.UIDirect, L.Unlocked = false, false

    local function resolveUI()
        local ok = pcall(function()
            local box = PGx.Codes.Codes.CodeRedeem.TextBox
            local btn = PGx.Codes.Codes.Confirm
            if not (box and btn) then return end
            uiBox2 = box
            confirmBtn = btn
            if typeof(getconnections) ~= "function" then return end
            local conns = getconnections(btn.Activated)
            local wrapper = conns and conns[1] and conns[1].Function
            if not wrapper then return end
            local selfT = getupv(wrapper, 1)
            local sig = type(selfT) == "table" and selfT.OnActivated
            local node = sig and rawget(sig, "_handlerListHead")
            while node do
                local fn = rawget(node, "_fn")
                if type(fn) == "function" then
                    local src = tostring(debug.getinfo(fn).source)
                    if src:find("CodesController", 1, true) then
                        if type(getupv(fn, 1)) == "boolean" and getupv(fn, 2) == box then
                            submitCode = fn
                            submitNode = node
                            break
                        end
                    end
                end
                node = rawget(node, "_next")
            end
        end)
        L.UIBox, L.UIDirect = uiBox2, submitCode ~= nil
        return ok and uiBox2 ~= nil
    end
    L.ResolveUIDirect = resolveUI

    local warmArmed = false
    local warmLabel, warmLabelText
    local function armWarm()
        if warmArmed then return end
        if not (submitNode and uiBox2) then return end
        warmArmed = true
        warmLabel = confirmBtn and confirmBtn:FindFirstChild("Confirm")
        if warmLabel and warmLabel:IsA("TextLabel") then
            warmLabelText = warmLabel.Text
        else
            warmLabel = nil
        end
        local realFn = submitCode
        rawset(submitNode, "_fn", function()
            if L.Warming or os.clock() < (L.WarmCooldownUntil or 0) then
                return
            end
            local r = L.RedeemRemote
            if not r or L.RedeemRemoteIsEvent then
                return realFn()
            end
            if L.WarmRemote() then
                if warmLabel then warmLabel.Text = "Warming Remote" end
                uiBox2.Active = false
                uiBox2.TextEditable = false
                return
            end
            return realFn()
        end)
        L.WarmDone = function()
            if warmLabel and warmLabelText then warmLabel.Text = warmLabelText end
            if uiBox2 then
                uiBox2.Active = true
                uiBox2.TextEditable = true
            end
        end
    end
    L.ArmWarm = armWarm
    do
        local ok = pcall(resolveUI)
        if ok then pcall(armWarm) end
    end

    local function sanitise(code)
        return (code:gsub("[^%w]", "")):upper():sub(1, 50)
    end

    local function fireUI(code)
        if not submitCode or not uiBox2 then
            if not resolveUI() then return false end
            if not submitCode then return uiFireLegacy(code) end
        end
        local box = uiBox2
        code = sanitise(code)
        if code == "" then return false end

        if L.TextAt then
            L.LastGapMs = (os.clock() - L.TextAt) * 1000
            if not L.BestGapMs or L.LastGapMs < L.BestGapMs then L.BestGapMs = L.LastGapMs end
        end

        if getupv(submitCode, 1) == true then setupv(submitCode, 1, false) end
        if not box.Active then box.Active = true end
        L.Unlocked = true

        box.Text = code
        submitCode()
        return true
    end
    L.FireUI = fireUI

    fireNormal = function(code)
        return fireUI(code) and true or false
    end
    L.FireNormal = fireNormal

    local handle

    local W, BUSY, WN = {}, {}, 4
    local function spawnWorker(i)
        BUSY[i] = false
        W[i] = coroutine.create(function()
            while true do
                local m = coroutine.yield()
                BUSY[i] = true
                handle(m)
                BUSY[i] = false
            end
        end)
        coroutine.resume(W[i])
    end
    for i = 1, WN do spawnWorker(i) end

    L.Dispatch = function(msg)
        for i = 1, WN do
            if not BUSY[i] and coroutine.status(W[i]) == "suspended" then
                if not coroutine.resume(W[i], msg) then spawnWorker(i) end
                return
            end
        end
        task.spawn(handle, msg)
    end

    local payload = L.PayloadText

    L.ClaimResult = function(text)
        if not L.OursPending then return end
        L.LastLabelColor = nil
        protected(claimOurs, text)
    end

    handle = function(msg)
        local t0 = clock()
        local text = msg
        if type(text) ~= "string" then
            text = payload(msg, 0)
            if not text then return end
        end

        if not (L.Mode and L.Mode.raw) then
            L.NotifyHandler(text)
            return
        end
        if not (hotAuto or hotGuess) then
            defer(logHeard, t0, L.NotifyRemoteName, text)
            return
        end
        local code = codeFrom(text)
        if not code then return end

        if hotGuess then
            code = accumulate(code, t0)
        elseif hotThreshold > 1 then
            code = feed(code, t0)
            if not code then
                defer(postFragment, t0, L.NotifyRemoteName, text)
                return
            end
        end

        local was = firedSeen[code]
        if was and (t0 - was) <= hotFiredTTL then return end
        firedSeen[code] = t0

        L.OursPending, L.OursAt = code, t0
        local tCall = clock()
        local pok, r1, r2, fireOnly = L.FireFast(code)
        local tDone = clock()
        defer(rawFire, t0, tCall, tDone, text, code, pok, r1, r2, fireOnly)
    end

    -- Second copy of the same 600 x 0.1s poll, walking the same Confirm connection list
    -- as ResolveUIPath. Same treatment: wait on the instances, then back off.
    if not resolveUI() then
        task.spawn(function()
            pcall(function()
                local codes = PG:WaitForChild("Codes", 60)
                codes = codes and codes:WaitForChild("Codes", 60)
                if codes then codes:WaitForChild("Confirm", 60) end
            end)
            local gap = 0.05
            for _ = 1, 12 do
                if resolveUI() then
                    pcall(armWarm)
                    return
                end
                task.wait(gap)
                if gap < 1 then gap = math.min(gap * 1.6, 1) end
            end
        end)
    end
end

do
    local dispatch = L.Dispatch
    local find = string.find
    local fastRemote, fastInvoke, fastIsEvent, fastSafe = nil, nil, false, false
    local fastReady, fastRaw, fastTime = false, true, false
    local binding = false
    local poleInner
    local sent = {}

    L.SentCodes = sent
    L.Solo = true
    L.RawFire = true
    L.Instrument = false
    L.FloorUs, L.BestFloorUs = nil, nil

    L.SyncFast = function()
        local r = L.RedeemRemote
        if r and L.RedeemPath ~= "ui" then
            fastIsEvent = L.RedeemRemoteIsEvent == true
            fastRemote  = r
            fastInvoke  = fastIsEvent and r.FireServer or r.InvokeServer
            fastSafe    = (not fastIsEvent) and L.RedeemRemoteTested == true
        else
            fastRemote, fastInvoke, fastIsEvent, fastSafe = nil, nil, false, false
        end
        fastRaw  = L.RawFire ~= false
        fastTime = L.Instrument == true or L.RaceArmed == true
        fastReady = fastInvoke ~= nil
            and L.AutoOn == true
            and not L.GuessCode
            and (L.Threshold or 1) <= 1
            and L.RedeemPath ~= "both"
        L.FastRemote, L.FastInvoke, L.FastReady = fastRemote, fastInvoke, fastReady
        if not dispatch then dispatch = L.Dispatch end
        if L.ApplyBinding and not binding then L.ApplyBinding() end
    end
    L.SyncFast()

    task.spawn(function()
        while true do
            task.wait(30)
            table.clear(sent)
        end
    end)

    local function tail(t0, tCall, tDone, text, code, pok, a, b)
        local raw = code
        if type(text) ~= "string" then
            text = payloadText(text, 0) or ""
            code = text
            raw = ""
        end
        L.TextAt = t0
        if fastTime then
            local us = (tCall - t0) * 1e6
            L.FloorUs, L.FloorNs = us, us * 1000
            if not L.BestFloorUs or us < L.BestFloorUs then L.BestFloorUs = us end
        end
        if fastIsEvent then a, b = true, "sent" end
        if a == nil then
            L.OursPending, L.OursAt = code, t0 ~= 0 and t0 or clock()
        end
        if L.Note then L.Note(L.NotifyRemoteName or "remote", code, t0) end
        if L.NotifyRedeem then killFeed(text) end
        rawFire(t0, tCall, tDone, text, raw, pok, a, b, fastIsEvent or a == nil)
    end

    local soloSlow
    local function side(msg)
        if L.OursPending and L.ClaimResult then
            if type(msg) ~= "string" then msg = payloadText(msg, 0) end
            if msg then protected(L.ClaimResult, msg) end
        end
    end

    local function slow(msg)
        L.TextAt, L.FloorUs = clock(), nil
        if type(msg) ~= "string" then
            msg = payloadText(msg, 0)
            if not msg then return end
        end
        return dispatch(msg)
    end

    soloSlow = function(msg, entered)
        if type(msg) ~= "string" then
            msg = payloadText(msg, 0)
            if not msg then return end
        end
        local code = msg
        if not fastRaw and (#msg > 50 or find(msg, "[^%w]")) then
            code = codeFrom(msg)
            if not code then return end
        end
        local t0, tCall = entered, nil
        if t0 then tCall = clock() end
        local pok, a, b
        if fastSafe then
            a, b = fastInvoke(fastRemote, code)
            pok = true
        else
            pok, a, b = protected(fastInvoke, fastRemote, code)
        end
        local tDone = clock()
        if not t0 then t0, tCall = tDone, tDone end
        sent[code] = true
        defer(tail, t0, tCall, tDone, msg, code, pok, a, b)
    end

    local guarded = function(msg, _, _, position)
        if position ~= "Top" then
            if L.OursPending then return side(msg) end
            return
        end
        local entry = fastTime and clock() or nil
        if type(msg) ~= "string" then
            msg = payloadText(msg, 0)
            if not msg then return end
        end

        local code = msg
        if not fastRaw and (#msg > 50 or find(msg, "[^%w]")) then
            code = codeFrom(msg)
            if not code then return end
        end

        if sent[code] then return end
        sent[code] = true

        local t0, tCall = entry, nil
        if t0 then tCall = clock() end
        local pok, a, b
        if fastSafe then
            a, b = fastInvoke(fastRemote, code)
            pok = true
        else
            pok, a, b = protected(fastInvoke, fastRemote, code)
        end
        local tDone = clock()
        if not t0 then t0, tCall = tDone, tDone end

        defer(tail, t0, tCall, tDone, msg, code, pok, a, b)
    end

    local solo = function(msg, _, _, position)
        if position ~= "Top" then
            if L.OursPending then return side(msg) end
            return
        end
        if fastTime or not fastRaw then
            return soloSlow(msg, fastTime and clock() or nil)
        end
        local a, b = fastInvoke(fastRemote, msg)
        sent[msg] = true
        defer(tail, 0, 0, 0, msg, msg, true, a, b)
    end

    -- solo minus the flag test. `fastTime` and `fastRaw` only change inside
    -- SyncFast, which calls ApplyBinding straight afterwards -- so the test
    -- can be answered once at bind time instead of on every packet. Measured
    -- at 12.13 ns, which is 26% of everything that runs before the send.
    -- The Top branch comes first so the hot path falls through instead of
    -- taking a jump: measured at 2.07 ns, free, and semantically identical.
    local soloRaw = function(msg, _, _, position)
        if position == "Top" then
            local a, b = fastInvoke(fastRemote, msg)
            sent[msg] = true
            defer(tail, 0, 0, 0, msg, msg, true, a, b)
            return
        end
        if L.OursPending then return side(msg) end
    end

    local idle = function(msg, _, _, position)
        if position ~= "Top" then
            if L.OursPending then return side(msg) end
            return
        end
        return slow(msg)
    end

    L.Handlers = {solo = solo, soloRaw = soloRaw, guarded = guarded, idle = idle}
    L.FastNotify = solo
    L.HandlerName = "solo"

    L.ApplyBinding = function()
        local want, name
        if not fastReady then
            want, name = idle, "idle"
        elseif L.Solo ~= false and L.RaceArmed ~= true and L.MultiSurface ~= true then
            if fastRaw and not fastTime then
                want, name = soloRaw, "soloRaw"
            else
                want, name = solo, "solo"
            end
        else
            want, name = guarded, "guarded"
        end
        if L.PoleOn and L.Handlers and L.Handlers.pole then
            poleInner = want
            want, name = L.Handlers.pole, "pole"
        end
        if want == L.FastNotify then return name end
        L.FastNotify, L.HandlerName = want, name
        if L.BindFast and L.RemoteDetectOn then
            binding = true
            pcall(L.BindFast)
            binding = false
        end
        return name
    end

    L.FastPath = function(text)
        return L.FastNotify(text, nil, nil, "Top")
    end

    L.BenchNs = nil
    L.Bench = function(n)
        n = tonumber(n) or 20000
        if n < 1000 then n = 1000 end
        if not fastInvoke then return nil, "no redeem remote resolved" end

        local realRemote, realInvoke, realSafe = fastRemote, fastInvoke, fastSafe
        local realTime, realDefer = fastTime, defer
        local hits = 0

        fastRemote = {}
        fastInvoke = function() hits += 1 end
        fastSafe = true
        fastTime = false
        defer = function() end

        local codes = table.create(n)
        for i = 1, n do codes[i] = "LUCKBENCH" .. i end

        local handler = L.Handlers and L.Handlers.solo or L.FastNotify
        local warm = math.min(n, 2000)
        for i = 1, warm do handler(codes[i], 5, nil, "Top") end
        table.clear(sent)

        local chunks = n // 32
        local reference = function(msg, _, _, position)
            if position ~= "Top" then return end
            return fastInvoke(fastRemote, msg)
        end

        local started = clock()
        for c = 0, chunks - 1 do
            local base = c * 32
            for k = 1, 32 do handler(codes[base + k], 5, nil, "Top") end
            table.clear(sent)
        end
        local elapsed = clock() - started

        local refStart = clock()
        for c = 0, chunks - 1 do
            local base = c * 32
            for k = 1, 32 do reference(codes[base + k], 5, nil, "Top") end
        end
        local refElapsed = clock() - refStart
        n = chunks * 32

        fastRemote, fastInvoke, fastSafe = realRemote, realInvoke, realSafe
        fastTime, defer = realTime, realDefer
        table.clear(sent)

        if hits < n then return nil, ("only %d of %d reached the send"):format(hits, n) end
        L.BenchNs = elapsed / n * 1e9
        L.BenchSendNs = refElapsed / n * 1e9
        return L.BenchNs, L.BenchSendNs
    end

    L.BenchPrint = function(n)
        local ns, ref = L.Bench(n)
        if not ns then
            print("[LUCK] bench: " .. tostring(ref))
            return nil
        end
        print(("[LUCK] handler, end to end        %7.1f ns"):format(ns))
        print(("[LUCK] the send call alone        %7.1f ns"):format(ref))
        print(("[LUCK] everything after the send  %7.1f ns   does not delay the packet")
            :format(math.max(ns - ref, 0)))
        print("[LUCK] amortised over the run; one redeem cannot resolve this")
        return ns, ref
    end

    L.Ping = function()
        local ok, ms = pcall(function()
            local stats = game:GetService("Stats")
            return stats.Network.ServerStatsItem["Data Ping"]:GetValue()
        end)
        if ok and type(ms) == "number" and ms > 0 then return ms end
        return nil
    end

    L.Budget = function(pingMs, fps)
        pingMs = tonumber(pingMs) or L.Ping() or 10
        fps = tonumber(fps) or (L.Fps and L.Fps > 1 and L.Fps) or 60

        local frame = 1000 / fps
        local half = pingMs / 2
        local immediate = L.SignalMode == "Immediate"
        local deferred = immediate and 0 or (frame / 2)
        local netStep = frame / 2

        local script = (L.BenchNs or 160) / 1e6

        local total = half + deferred + script + netStep + half
        local rows = {
            {"announcement over the wire", half},
            {immediate and "deferred queue (immediate)" or "deferred queue wait", deferred},
            {"this script", script},
            {"network step wait", netStep},
            {"redeem over the wire", half},
        }

        print(("[LUCK] budget at %.0f ms ping and %.0f fps"):format(pingMs, fps))
        for _, r in ipairs(rows) do
            print(("[LUCK]   %-28s %8.3f ms  %6.2f%%"):format(
                r[1], r[2], r[2] / total * 100))
        end
        print(("[LUCK]   %-28s %8.3f ms"):format("total announce to server", total))

        local faster = half + 0 + script + 0 + half
        local clock_ = total - faster
        print(("[LUCK] floor if the frame clock vanished: %.3f ms"):format(faster))
        print(("[LUCK] frame clock %.3f ms   ·   script %.6f ms   ·   ratio %.0fx")
            :format(clock_, script, script > 0 and (clock_ / script) or 0))
        print(("[LUCK] one dropped frame costs %.3f ms, which is %.0f script passes")
            :format(frame, script > 0 and (frame / script) or 0))
        print("[LUCK] the lever is fps and a clean main thread, not the handler")
        return total, script
    end

    L.PoleOn = false
    L.PoleTaken = nil
    L.ConnIndex = function()
        local r = L.NotifyRemote
        if not r or typeof(getconnections) ~= "function" then return nil, nil end
        local ok, conns = pcall(getconnections, r.OnClientEvent)
        if not ok or type(conns) ~= "table" then return nil, nil end
        local mine
        for i, c in ipairs(conns) do
            local fn
            pcall(function() fn = c.Function end)
            if fn == L.FastNotify then mine = i break end
        end
        return mine, #conns
    end

    local function redispatch(msg, dur, sound, position)
        local taken = L.PoleTaken
        if not taken then return end
        for i = 1, #taken do
            protected(taken[i], msg, dur, sound, position)
        end
    end

    local pole = function(msg, dur, sound, position)
        if position ~= "Top" then
            defer(redispatch, msg, dur, sound, position)
            if L.OursPending then return side(msg) end
            return
        end
        -- poleInner first, always: nothing may run ahead of the send. The game's own
        -- handlers then go on the deferred queue rather than inline, so their GUI and
        -- sound work happens on their own thread instead of ours -- which matters only
        -- if a second code lands while we are still holding this one.
        poleInner(msg, dur, sound, position)
        defer(redispatch, msg, dur, sound, position)
    end

    L.TakePole = function()
        if L.PoleOn then return true, #L.PoleTaken end
        local r = L.NotifyRemote
        if not r then return false, "no notify remote" end
        if typeof(getconnections) ~= "function" then
            return false, "executor has no getconnections"
        end
        local ok, conns = pcall(getconnections, r.OnClientEvent)
        if not ok or type(conns) ~= "table" then return false, "no connection list" end

        local taken, held = {}, {}
        for _, c in ipairs(conns) do
            local fn
            pcall(function() fn = c.Function end)
            if fn and fn ~= L.FastNotify and fn ~= pole then
                local okd = pcall(function() c:Disable() end)
                if okd then
                    taken[#taken + 1] = fn
                    held[#held + 1] = c
                end
            end
        end
        if #taken == 0 then return false, "nothing to take over" end

        L.PoleTaken, L.PoleHeld = taken, held
        L.PoleRemote = r
        L.PoleOn = true
        L.Handlers.pole = pole
        L.SyncFast()
        return true, #taken
    end

    -- Pole used to be a one-shot taken inside Boost and then quietly lost: a rebind
    -- moves our connection to the back of the list, a handler attaching later is never
    -- swept, and a verified correction points NotifyRemote at a different instance
    -- entirely while PoleTaken still holds connections on the old one. Under Immediate
    -- signals any handler we failed to take runs its GUI and sound work synchronously
    -- ahead of our invoke, which is whole milliseconds -- so it has to be re-held, not
    -- just taken once.
    L.RetakePole = function()
        if not L.PoleOn then return false, "pole not held" end
        local r = L.NotifyRemote
        if not r then return false, "no notify remote" end
        if L.PoleRemote ~= r then
            for _, c in ipairs(L.PoleHeld or {}) do
                pcall(function() c:Enable() end)
            end
            L.PoleOn, L.PoleTaken, L.PoleHeld, L.PoleRemote = false, nil, nil, nil
            local okTake, info = L.TakePole()
            -- TakePole returns before SyncFast when there is nothing to take, which
            -- would leave FastNotify pointing at the pole wrapper with no handlers
            -- behind it. Re-pick the handler in that case.
            if not okTake then L.SyncFast() end
            return okTake, info
        end
        if typeof(getconnections) ~= "function" then return false, "no getconnections" end
        local ok, conns = pcall(getconnections, r.OnClientEvent)
        if not ok or type(conns) ~= "table" then return false, "no connection list" end
        local taken, held = L.PoleTaken, L.PoleHeld
        local added = 0
        for _, c in ipairs(conns) do
            local fn
            pcall(function() fn = c.Function end)
            if fn and fn ~= L.FastNotify and fn ~= pole then
                local known = false
                for i = 1, #taken do
                    if taken[i] == fn then known = true break end
                end
                if not known and pcall(function() c:Disable() end) then
                    taken[#taken + 1] = fn
                    held[#held + 1] = c
                    added += 1
                end
            end
        end
        return true, added
    end

    L.DropPole = function()
        if not L.PoleOn then return true end
        for _, c in ipairs(L.PoleHeld or {}) do
            pcall(function() c:Enable() end)
        end
        L.PoleOn, L.PoleTaken, L.PoleHeld = false, nil, nil
        L.SyncFast()
        return true
    end

    L.BindFast = function()
        if not L.NotifyRemote then return false end
        L.RemoteDetectOn = false
        -- ConnectNotifyRemote re-holds pole itself on a successful connect.
        return L.ConnectNotifyRemote()
    end
    if L.RemoteDetectOn then L.BindFast() end
end

do
    local upper, find = string.upper, string.find
    local surfaces, raceSeen = {}, {}
    local sentCodes = L.SentCodes

    L.Surfaces = surfaces
    L.RaceLog = {}
    L.RaceMax = 12
    L.ArmedRemotes = 0
    L.ArmedValues = 0

    local function surface(name)
        local s = surfaces[name]
        if not s then
            s = {name = name, sights = 0, wins = 0, live = false,
                 lateSum = 0, lateN = 0, lateBest = nil}
            surfaces[name] = s
        end
        return s
    end
    L.Surface = surface
    surface("remote").live = true
    surface("notify").live = true
    surface("gui").live = true

    L.Promote = function(name)
        surface(name).live = true
        if name ~= "remote" and name ~= "notify" and name ~= "gui" then
            L.MultiSurface = true
        end
        L.SyncFast()
        return true
    end
    L.Demote = function(name)
        surface(name).live = false
        return true
    end

    L.Note = function(name, code, at)
        local s = surface(name)
        s.sights += 1
        local first = raceSeen[code]
        if not first then
            raceSeen[code] = {at = at, who = name}
            s.wins += 1
            table.insert(L.RaceLog, 1, {code = code, winner = name, at = at, late = {}})
            while #L.RaceLog > L.RaceMax do table.remove(L.RaceLog) end
            return true
        end
        local ms = (at - first.at) * 1000
        s.lateSum += ms
        s.lateN += 1
        if not s.lateBest or ms < s.lateBest then s.lateBest = ms end
        for i = 1, #L.RaceLog do
            local entry = L.RaceLog[i]
            if entry.code == code then
                if entry.late[name] == nil then entry.late[name] = ms end
                break
            end
        end
        return false
    end

    local function shaped(s)
        if type(s) ~= "string" then return nil end
        local n = #s
        if n < 4 or n > 30 then return nil end
        if find(s, "[^%w]") then return nil end
        if s ~= upper(s) then return nil end
        return s
    end
    L.Shaped = shaped

    L.Sight = function(name, code, at)
        at = at or clock()
        local won = L.Note(name, code, at)
        if not won then return false end
        if not surfaces[name].live then return false end
        if sentCodes[code] then return false end
        local inv, rem = L.FastInvoke, L.FastRemote
        if not inv or L.AutoOn ~= true then return false end
        sentCodes[code] = true
        L.OursPending, L.OursAt = code, at
        local pok, a, b = protected(inv, rem, code)
        local tDone = clock()
        defer(rawFire, at, at, tDone, code, code, pok, a, b, a == nil)
        return true
    end

    L.SightArgs = function(name, a1, a2, a3, a4)
        local hit = shaped(a1) or shaped(a2) or shaped(a3) or shaped(a4)
        if hit then L.Sight(name, hit, clock()) end
    end

    L.ArmRemotes = function()
        local n = 0
        for _, d in ipairs(RepS:GetDescendants()) do
            if d:IsA("RemoteEvent") and d ~= L.NotifyRemote then
                local name = "re:" .. d.Name
                surface(name)
                local ok = pcall(function()
                    d.OnClientEvent:Connect(function(...)
                        L.SightArgs(name, ...)
                    end)
                end)
                if ok then n += 1 end
            end
        end
        L.ArmedRemotes = n
        return n
    end

    L.ArmValues = function()
        local n = 0
        local function watch(d)
            local ok = pcall(function()
                if d:IsA("StringValue") then
                    local name = "value:" .. d.Name
                    surface(name)
                    d:GetPropertyChangedSignal("Value"):Connect(function()
                        local hit = shaped(d.Value)
                        if hit then L.Sight(name, hit, clock()) end
                    end)
                    n += 1
                end
            end)
            return ok
        end
        for _, d in ipairs(RepS:GetDescendants()) do watch(d) end
        pcall(function()
            surface("descendant")
            RepS.DescendantAdded:Connect(function(d)
                local at = clock()
                local hit = shaped(d.Name)
                if hit then L.Sight("descendant", hit, at) end
                watch(d)
            end)
            surface("attribute")
            RepS.AttributeChanged:Connect(function(key)
                local at = clock()
                local hit = shaped(key) or shaped(RepS:GetAttribute(key))
                if hit then L.Sight("attribute", hit, at) end
            end)
        end)
        L.ArmedValues = n
        return n
    end

    L.RaceOn = function()
        if L.RaceArmed then return L.ArmedRemotes, L.ArmedValues end
        L.RaceArmed = true
        L.SyncFast()
        local a = L.ArmRemotes()
        local b = L.ArmValues()
        return a, b
    end

    L.RaceReport = function()
        local rows = {}
        for name, s in pairs(surfaces) do
            if s.sights > 0 then
                rows[#rows + 1] = {
                    name = name, sights = s.sights, wins = s.wins,
                    live = s.live,
                    avgLate = s.lateN > 0 and (s.lateSum / s.lateN) or nil,
                    bestLate = s.lateBest,
                }
            end
        end
        table.sort(rows, function(x, y)
            if x.wins ~= y.wins then return x.wins > y.wins end
            return (x.avgLate or 0) < (y.avgLate or 0)
        end)
        return rows
    end

    L.RacePrint = function()
        print("[LUCK] surface            wins  sights  live   avg late   best late")
        for _, r in ipairs(L.RaceReport()) do
            print(("[LUCK] %-18s %5d %7d  %-5s %9s %11s"):format(
                r.name, r.wins, r.sights, tostring(r.live),
                r.avgLate and ("%.3fms"):format(r.avgLate) or "-",
                r.bestLate and ("%.3fms"):format(r.bestLate) or "-"))
        end
        return L.RaceReport()
    end

    L.FpsCap = nil
    L.SetFpsCap = function(n)
        if type(setfpscap) ~= "function" then return false end
        local ok = pcall(setfpscap, n)
        if ok then L.FpsCap = n end
        return ok
    end
    L.SetFpsCap(999)
end

L.RaceOff = function()
    L.RaceArmed = false
    L.SyncFast()
    return true
end

L.Fps = 0
do
    -- The per-frame callback is now a single increment. It used to also read os.clock()
    -- twice and do the divide test every frame -- at an uncapped frame rate that is a
    -- thousand of those a second, on the same thread the redeem goes out on. The
    -- arithmetic moved to a once-a-second task loop, which is where it belonged.
    local frames = 0
    RunS.Heartbeat:Connect(function()
        frames += 1
    end)
    task.spawn(function()
        local since = os.clock()
        while true do
            task.wait(1)
            local now = os.clock()
            local span = now - since
            if span > 0 then L.Fps = frames / span end
            frames, since = 0, now
        end
    end)
end

L.TurboOn = false
L.TurboApplied = {}
do
    local Lighting = game:GetService("Lighting")

    local saved = {}
    local function remember(key, getter)
        if saved[key] == nil then
            local ok, value = pcall(getter)
            saved[key] = ok and value or false
        end
    end

    local steps = {
        {
            name = "3d rendering",
            off = function()
                remember("render3d", function() return true end)
                RunS:Set3dRenderingEnabled(false)
            end,
            on = function() RunS:Set3dRenderingEnabled(true) end,
        },
        {
            name = "quality level",
            off = function()
                local s = settings()
                remember("quality", function() return s.Rendering.QualityLevel end)
                s.Rendering.QualityLevel = Enum.QualityLevel.Level01
            end,
            on = function()
                local s = settings()
                if saved.quality then s.Rendering.QualityLevel = saved.quality end
            end,
        },
        {
            name = "shadows",
            off = function()
                remember("shadows", function() return Lighting.GlobalShadows end)
                Lighting.GlobalShadows = false
            end,
            on = function()
                if saved.shadows ~= nil and saved.shadows ~= false then
                    Lighting.GlobalShadows = saved.shadows
                end
            end,
        },
        {
            name = "lighting technology",
            off = function()
                remember("tech", function() return Lighting.Technology end)
                Lighting.Technology = Enum.Technology.Compatibility
            end,
            -- This used to be an empty function, so turning turbo back off left the
            -- lighting permanently downgraded with no way back short of a rejoin.
            on = function()
                if saved.tech and saved.tech ~= false then
                    Lighting.Technology = saved.tech
                end
            end,
        },
    }

    L.SetTurbo = function(on)
        local applied = {}
        for _, step in ipairs(steps) do
            local ok = pcall(on and step.off or step.on)
            applied[step.name] = ok
        end
        applied["fps cap"] = L.SetFpsCap(on and 999 or 240)
        L.TurboApplied = applied
        L.TurboOn = on and true or false
        return applied
    end

    -- Blanking the 3D view is the single biggest fps win and also the most intrusive
    -- thing this script can do to your screen, so it is opt-in and reversible on its
    -- own, without dragging quality and lighting along with it.
    L.Blind = function(on)
        local ok = pcall(function()
            RunS:Set3dRenderingEnabled(not on)
        end)
        L.BlindOn = ok and (on and true or false) or L.BlindOn
        return ok, L.BlindOn
    end

    L.TurboReport = function()
        print(("[LUCK] turbo %s   fps %.0f   cap %s   signals %s"):format(
            L.TurboOn and "on" or "off", L.Fps or 0,
            tostring(L.FpsCap), tostring(L.SignalMode)))
        for name, ok in pairs(L.TurboApplied) do
            print(("[LUCK]   %-22s %s"):format(name, ok and "applied" or "refused"))
        end
        return L.TurboApplied
    end
end

L.SignalMode = "unknown"
do
    local function readMode()
        local ok, mode = pcall(function() return workspace.SignalBehavior end)
        L.SignalMode = ok and tostring(mode):gsub("^Enum%.SignalBehavior%.", "")
            or "unreadable"
        return L.SignalMode
    end
    readMode()

    L.SetImmediateSignals = function(on)
        local ok = pcall(function()
            workspace.SignalBehavior = on and Enum.SignalBehavior.Immediate
                or Enum.SignalBehavior.Deferred
        end)
        local now = readMode()
        L.ImmediateSignals = now == "Immediate"
        return ok and L.ImmediateSignals == (on and true or false), now
    end

    L.SetImmediateSignals(true)
end

L.ClassifyColor = function(c, text)
    if text and text:find("#92ff67", 1, true) then return "win" end
    if text then
        local hex = text:match("<font%s+color%s*=%s*[\"\']#(%x%x%x%x%x%x)")
        if hex then
            local r = tonumber(hex:sub(1, 2), 16) / 255
            local g = tonumber(hex:sub(3, 4), 16) / 255
            local b = tonumber(hex:sub(5, 6), 16) / 255
            c = {R = r, G = g, B = b}
        end
    end
    if not c then return nil end
    local r, g, b = c.R, c.G, c.B
    if not (r and g and b) then return nil end

    if math.abs(r - L.SR) < 0.16 and math.abs(g - L.SG) < 0.16
       and math.abs(b - L.SB) < 0.25 then return "win" end
    if r > 0.55 and g < 0.62 and (r - g) > 0.18 then return "fail" end
    return nil
end

L.GuiHooked = false
L.WatchedLabels = 0

do
    local watched = setmetatable({}, {__mode = "k"})

    local function dispatchText(obj, t)
        if t == "" then return end
        if L.DetectMode == "remote" and L.RemoteDetectOn then return end
        if L.NotifyHooked then return end
        L.TextAt = os.clock()

        if L.OursPending then
            L.LastLabelColor = L.ClassifyColor(obj.TextColor3, t)
            L.Dispatch(t)
            L.LastLabelColor = nil
        else
            L.Dispatch(t)
        end
    end

    local function readLabel(obj)
        dispatchText(obj, obj.Text)
    end

    local function watchLabel(obj)
        if watched[obj] then return end
        if not (obj and (obj:IsA("TextLabel") or obj:IsA("TextButton")
                or obj:IsA("TextBox"))) then return end
        watched[obj] = true
        L.WatchedLabels += 1
        readLabel(obj)
        obj:GetPropertyChangedSignal("Text"):Connect(function() readLabel(obj) end)
    end
    L.WatchLabel = watchLabel

    L.HookGui = function()
        local top = PG:FindFirstChild("TopNotification")
        local root = top and (top:FindFirstChild("TopNotification") or top)
        if not root then return false end

        L.GuiHooked, L.PacketHooked = true, true
        L.NotifyRoot = root
        watchLabel(root)
        for _, d in ipairs(root:GetDescendants()) do watchLabel(d) end
        root.DescendantAdded:Connect(watchLabel)
        return true
    end
end

L.NotifyHooked = false
do
    local function hookNotify()
        if L.NotifyHooked then return true end
        if L.DetectMode == "remote" and L.RemoteDetectOn then return true end
        local ctrl = RepS and RepS:FindFirstChild("Controllers")
        local mod = ctrl and ctrl:FindFirstChild("NotificationController")
        if not mod then return false end
        local okReq, NC = pcall(require, mod)
        if not okReq or type(NC) ~= "table" or type(NC.Notify) ~= "function" then
            return false
        end
        local G = (getgenv and getgenv()) or shared
        if type(G.__LumNotifyReal) == "function" then
            NC.Notify = G.__LumNotifyReal
        end
        local real = NC.Notify
        G.__LumNotifyReal = real
        G.__LumNotifyNC = NC
        NC.Notify = function(self, msg, dur, sound, position, ...)
            if type(msg) == "string" and msg ~= "" then
                local uiActive = L.DetectMode ~= "remote" or not L.RemoteDetectOn
                if position == "Top" then
                    if uiActive then
                        local fast = L.FastPath
                        if fast then
                            protected(fast, msg, clock())
                        else
                            L.TextAt = os.clock()
                            protected(L.Dispatch, msg)
                        end
                    end
                elseif uiActive and L.OursPending and L.ClaimResult then
                    protected(L.ClaimResult, msg)
                end
            end
            return real(self, msg, dur, sound, position, ...)
        end
        L.NotifyHooked, L.GuiHooked, L.PacketHooked = true, true, true
        L.NotifyRemoteName = "notify"
        return true
    end
    L.HookNotify = hookNotify

    -- Was a 600 x 0.1s poll of two FindFirstChild calls. The module either exists or it
    -- replicates in, and WaitForChild tells us the moment it does, for free.
    if not hookNotify() then
        task.spawn(function()
            pcall(function()
                local ctrl = RepS:WaitForChild("Controllers", 60)
                if ctrl then ctrl:WaitForChild("NotificationController", 60) end
            end)
            local gap = 0.05
            for _ = 1, 12 do
                if hookNotify() then return end
                task.wait(gap)
                if gap < 1 then gap = math.min(gap * 1.6, 1) end
            end
        end)
    end
end

-- The GUI-label fallback: only wanted if the remote never comes up. This used to burn a
-- 60-tick poll and then call HookGui -- a FindFirstChild -- on every single Heartbeat
-- for 1200 frames. WaitForChild does the same job without touching a frame.
task.spawn(function()
    for _ = 1, 60 do
        if L.RemoteDetectOn then return end
        task.wait(0.1)
    end
    if L.HookGui() then return end
    pcall(function() PG:WaitForChild("TopNotification", 30) end)
    if L.RemoteDetectOn then return end
    local gap = 0.05
    for _ = 1, 12 do
        if L.RemoteDetectOn or L.HookGui() then return end
        task.wait(gap)
        if gap < 1 then gap = math.min(gap * 1.6, 1) end
    end
end)

L.BoostApplied = {}
L.Boost = function(blind)
    local got = {}

    local okSig = L.SetImmediateSignals(true)
    got["immediate signals"] = (L.SignalMode == "Immediate") and "on"
        or ("refused, still " .. tostring(L.SignalMode))

    got["fps cap"] = L.SetFpsCap(999) and "999" or "no setfpscap"

    if blind then
        local steps = L.SetTurbo(true)
        for name, ok in pairs(steps) do
            got[name] = ok and "on" or "refused"
        end
    else
        local ok1 = pcall(function()
            settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
        end)
        local ok2 = pcall(function()
            game:GetService("Lighting").GlobalShadows = false
        end)
        got["quality level"] = ok1 and "minimum" or "refused"
        got["shadows"] = ok2 and "off" or "refused"
        got["3d rendering"] = "left on -- LUCK.Blind(true) to blank it"
    end

    if L.SignalMode == "Immediate" then
        local mine, total = L.ConnIndex()
        if mine and total and mine > 1 then
            local ok, n = L.TakePole()
            got["pole position"] = ok
                and ("taken from %d handler(s)"):format(n)
                or ("not taken: " .. tostring(n))
        elseif mine == 1 then
            got["pole position"] = "already first"
        else
            got["pole position"] = "connection list unreadable"
        end
    else
        got["pole position"] = "not needed while signals are deferred"
    end

    L.BoostApplied = got
    return got
end

L.BoostPrint = function(blind)
    local got = L.Boost(blind)
    print("[LUCK] boost")
    for name, state in pairs(got) do
        print(("[LUCK]   %-20s %s"):format(name, state))
    end
    if L.BenchPrint then L.BenchPrint(8000) end
    if L.Budget then L.Budget() end
    return got
end

-- Splitting a real redeem, rather than benching the handler in a loop.
--
-- BenchNs answers "how long does the handler take with nothing else going on", which
-- is nanoseconds and is not what a redeem costs. These two answer the question that
-- matters: of the wall time between the announcement landing and the answer coming
-- back, how much was this script and how much was the wire.
--
-- Measure() flips L.Instrument, which moves the binding from soloRaw to solo. solo
-- timestamps handler entry and the moment before the invoke; soloRaw deliberately does
-- not, because reading the clock is work and work does not go ahead of the send. So
-- measuring is not free -- turn it off again when you have your number.
L.Measure = function(on)
    on = on ~= false
    L.Instrument = on
    L.SyncFast()
    print(("[LUCK] instrumentation %s   ·   handler now '%s'")
        :format(on and "on" or "off", tostring(L.HandlerName)))
    return L.HandlerName
end

-- Self-measuring, because you should not have to type anything to find out where the
-- time is going. The first few redeems run instrumented and report their own split on
-- screen and in the console; after that instrumentation switches itself off and the
-- binding drops back to soloRaw, which does not read the clock at all.
--
-- The cost while armed is two clock reads before the invoke, so tens of nanoseconds,
-- on the first three redeems only. Set LUCK.AutoMeasure = false to skip it entirely.
L.AutoMeasure = true
L.AutoMeasureLeft = 3

L.AutoReport = function()
    local left = L.AutoMeasureLeft
    if not left or left <= 0 then return end
    local t = L.LastTiming
    if not t then return end
    L.AutoMeasureLeft = left - 1

    local scriptMs = tonumber(t.client) or 0
    local wireMs   = tonumber(t.server) or 0
    pcall(L.Split)

    if L.Notify then
        local share = (scriptMs + wireMs) > 0
            and (scriptMs / (scriptMs + wireMs) * 100) or 0
        L.Notify(("script %.3fms  ·  wire %.0fms  ·  script is %.2f%% of it")
            :format(scriptMs, wireMs, share), T.HIGH)
    end

    if L.AutoMeasureLeft <= 0 then
        L.Instrument = false
        if L.SyncFast then L.SyncFast() end
        print("[LUCK] measuring done -- back on soloRaw, nothing ahead of the send")
        if L.Notify then
            L.Notify("measuring done · back on soloRaw", T.MUTED)
        end
    end
end

L.Split = function()
    local t = L.LastTiming
    if not t then
        print("[LUCK] no redeem recorded yet")
        return nil
    end
    local scriptMs = tonumber(t.client) or 0
    local wireMs   = tonumber(t.server) or 0
    local fps      = (L.Fps and L.Fps > 1) and L.Fps or nil
    local ping     = L.Ping()

    print("[LUCK] ---- last redeem ----")
    if scriptMs <= 0 and wireMs <= 0 then
        print("[LUCK] all zero -- that is soloRaw, which does not timestamp.")
        print("[LUCK] run LUCK.Measure() and catch another code.")
        return nil
    end
    print(("[LUCK]   detect -> invoke call    %9.4f ms   this script"):format(scriptMs))
    print(("[LUCK]   invoke call -> reply     %9.1f ms   wire + server"):format(wireMs))
    print(("[LUCK]   total                    %9.1f ms"):format(scriptMs + wireMs))
    print(("[LUCK] fps %s   frame %s   ping %s   signals %s")
        :format(fps and ("%.0f"):format(fps) or "?",
                fps and ("%.1f ms"):format(1000 / fps) or "?",
                ping and ("%.0f ms"):format(ping) or "?",
                tostring(L.SignalMode)))
    print(("[LUCK] route: detect %s   redeem %s   handler %s   remote %s")
        :format(tostring(L.DetectMode), tostring(L.RedeemPath),
                tostring(L.HandlerName), tostring(L.RedeemRemoteSource)))
    if t.fireOnly then
        print("[LUCK] fire-and-forget: the reply figure is not a round trip")
    end
    if ping and wireMs > ping * 1.5 then
        print(("[LUCK] the reply took %.0f ms more than a round trip -- that is the")
            :format(wireMs - ping))
        print("[LUCK] server thinking, or a cold remote. try LUCK.WarmRemote()")
    end
    if L.RedeemPath == "ui" or L.HandlerName == "idle" then
        print("[LUCK] you are on the UI path, not the remote -- that adds the game's")
        print("[LUCK] own controller to every redeem. LUCK.Diag() shows why.")
    end
    return scriptMs, wireMs
end

-- Arm it. This runs after SyncFast exists, so the binding actually moves.
if L.AutoMeasure and L.AutoMeasureLeft > 0 then
    L.Instrument = true
    if L.SyncFast then L.SyncFast() end
end

L.Diag = function()
    local function yn(v) return v and "yes" or "no" end
    print("[LUCK] ---- diagnostics ----")
    print(("[LUCK] place %s   modded %s   platform %s"):format(
        tostring(game.PlaceId), yn(L.Modded), L.IsMobile and "mobile" or "pc"))
    print(("[LUCK] redeem  %s   source %s   tested %s   reply %s"):format(
        L.RedeemRemote and L.RedeemRemote.Name or "none",
        tostring(L.RedeemRemoteSource), tostring(L.RedeemRemoteTested),
        tostring(L.RedeemRemoteReply)))
    print(("[LUCK] notify  %s   source %s   live %s   name %s"):format(
        L.NotifyRemote and L.NotifyRemote.Name or "none",
        tostring(L.NotifyRemoteSource), yn(L.RemoteDetectOn),
        tostring(L.NotifyRemoteName)))
    local mine, total
    if L.ConnIndex then mine, total = L.ConnIndex() end
    print(("[LUCK] handler %s   conn %s of %s   pole %s"):format(
        tostring(L.HandlerName), tostring(mine), tostring(total), yn(L.PoleOn)))
    print(("[LUCK] detect %s   redeem %s   raw %s   solo %s   instrument %s"):format(
        tostring(L.DetectMode), tostring(L.RedeemPath), yn(L.RawFire),
        yn(L.Solo), yn(L.Instrument)))
    print(("[LUCK] auto %s   threshold %s   guess %s   parts %s"):format(
        yn(L.AutoOn), tostring(L.Threshold), yn(L.GuessCode), tostring(L.BufN)))
    print(("[LUCK] signals %s   fps %.0f   cap %s   turbo %s"):format(
        tostring(L.SignalMode), L.Fps or 0, tostring(L.FpsCap), yn(L.TurboOn)))
    print(("[LUCK] bench %s ns   send %s ns   floor %s ns"):format(
        L.BenchNs and ("%.1f"):format(L.BenchNs) or "-",
        L.BenchSendNs and ("%.1f"):format(L.BenchSendNs) or "-",
        L.FloorNs and ("%.1f"):format(L.FloorNs) or "-"))
    local ping = L.Ping()
    print(("[LUCK] ping %s ms   notify hook %s   gui hook %s   labels %s"):format(
        ping and ("%.0f"):format(ping) or "?", yn(L.NotifyHooked),
        yn(L.GuiHooked), tostring(L.WatchedLabels)))
    local n = 0
    for _ in pairs(L.SentCodes or {}) do n += 1 end
    print(("[LUCK] sent this window %d   history %d   race %s"):format(
        n, #(L.CodeHistory or {}), yn(L.RaceArmed)))
    for i, h in ipairs(L.CodeHistory or {}) do
        print(("[LUCK]   %d. %-20s %s"):format(i, h.code, h.status))
    end
    return true
end

-- Boost the moment discovery lands instead of polling for it every 100ms for 20s. The
-- delayed fallback still fires on a place where discovery never resolves, so the fps cap
-- and the signal mode get applied either way.
do
    local boosted = false
    local function boostOnce()
        if boosted then return end
        boosted = true
        -- Not blind. The old call passed true here, which routed through SetTurbo and
        -- ran Set3dRenderingEnabled(false) -- your whole screen goes white and the game
        -- stops drawing. That is a legitimate AFK-sniper setup and it is the biggest
        -- single fps win available, but it is not something to do to someone's screen
        -- without being asked. LUCK.Blind(true) turns it on, LUCK.Blind(false) off.
        pcall(L.Boost)
    end
    L.OnDiscovered = boostOnce
    if L.Discovered or L.RemoteDetectOn then
        task.defer(boostOnce)
    else
        task.delay(20, boostOnce)
    end
end

L.ToastOn = true
L.Toast = function(text, colour)
    if not L.ToastOn or type(text) ~= "string" or text == "" then return false end
    local body = colour and ('<font color="%s">%s</font>'):format(colour, text) or text
    local G = (getgenv and getgenv()) or shared
    local NC, real = G.__LumNotifyNC, G.__LumNotifyReal
    if NC and type(real) == "function" then
        return (pcall(real, NC, body, 4, nil, nil))
    end
    return (pcall(function()
        local controllers = RepS:FindFirstChild("Controllers")
        local mod = controllers and controllers:FindFirstChild("NotificationController")
        local c = mod and require(mod)
        if c and type(c.Notify) == "function" then
            c:Notify(body, 4, nil, nil)
        end
    end))
end

L.ToastResult = function(code, ok, reply)
    if not L.ToastOn then return end
    local mark = ok == true and "+" or (ok == false and "x" or "?")
    local colour = ok == true and "#92ff67" or (ok == false and "#ff829b" or "#ffbe78")
    local tail = L.Strip and L.Strip(reply or "") or tostring(reply or "")
    if #tail > 120 then tail = tail:sub(1, 120) end
    -- the result reads first; the code is the footnote, not the headline
    local line
    if tail ~= "" and tail ~= "sent" then
        line = ("%s %s   ·   %s"):format(mark, tail, tostring(code))
    else
        line = ("LUCK %s %s"):format(mark, tostring(code))
    end
    L.Toast(line, colour)
end

L.Strip = function(t)
    t = tostring(t or "")
    t = t:gsub("<br%s*/>", "\n"):gsub("<[^>]->", "")
    return (t:gsub("^%s+",""):gsub("%s+$",""))
end
L.Prize = function(msg)
    local clean = L.Strip(msg)
    clean = clean:gsub("%s*spawned!?%s*$", ""):gsub("%s*redeemed!?%s*$", "")
    return clean ~= "" and clean or L.Strip(msg)
end

do
    local gp = (function()
        if typeof(gethui) == "function" then
            local ok, hui = pcall(gethui)
            if ok and hui then return hui end
        end
        local ok, core = pcall(function() return game:GetService("CoreGui") end)
        if ok and core then return core end
        return PG
    end)()
    L.GuiParent = gp
    L.GuiStealth = gp ~= PG
    for _, root in ipairs({gp, PG}) do
        for _, d in ipairs(root:GetChildren()) do
            if d:IsA("ScreenGui") and (d.Name == "LUCKUI" or d.Name == "LuminosityUI"
                or d.Name:match("^LUCK_%d+$")) then
                pcall(function() d:Destroy() end)
            end
        end
    end
end

local uiOK, uiErr = pcall(function()
    local function New(cls, props)
        local i = Instance.new(cls)
        for k, v in pairs(props or {}) do i[k] = v end
        return i
    end
    local function Corner(p, r)
        return New("UICorner", {CornerRadius = UDim.new(0, r or 10), Parent = p})
    end
    local function Stroke(p, c, t)
        return New("UIStroke", {Color = c or T.LINE, Thickness = t or 1,
            Transparency = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
            Parent = p})
    end
    local function tw(inst, t, goal, style)
        TS:Create(inst, TweenInfo.new(t or 0.22,
            style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal):Play()
    end
    local function hover(btn, base, stroke)
        local over = base:Lerp(T.WHITE, 0.08)
        btn.MouseEnter:Connect(function()
            tw(btn, 0.15, {BackgroundColor3 = over})
            if stroke then tw(stroke, 0.15, {Transparency = 0.25}) end
        end)
        btn.MouseLeave:Connect(function()
            tw(btn, 0.15, {BackgroundColor3 = base})
            if stroke then tw(stroke, 0.15, {Transparency = 0.45}) end
        end)
    end

    local reveal = {}
    local function rev(inst, prop, target)
        reveal[#reveal + 1] = {inst, prop, target}
    end

    L.IntroDone = false
    L.ViewMode = (L.Settings.ViewMode == "advanced") and "advanced" or "standard"

    local Gui = New("ScreenGui", {
        Name = "LUCK_" .. tostring(math.random(100000, 999999)),
        ResetOnSpawn = false, IgnoreGuiInset = true,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = 9999, Parent = L.GuiParent or PG,
    })

    local panels = {}
    local function savePanel(name)
        local p = panels[name]
        if not p then return end
        local pos = p.frame.Position
        L.Settings.PanelWindows[name] = {
            Position = {XScale = pos.X.Scale, XOffset = pos.X.Offset,
                        YScale = pos.Y.Scale, YOffset = pos.Y.Offset},
            Minimized = p.minimized,
        }
        L.SaveSettings()
    end

    -- One InputChanged handler for every panel, not one per panel. createPanel used to
    -- connect its own, so six panels meant six global handlers waking on every mouse
    -- move and every touch move -- main-thread work, six times over, for a drag that is
    -- almost never happening.
    local dragActive = nil
    UIS.InputChanged:Connect(function(input)
        local d = dragActive
        if not d then return end
        local kind = input.UserInputType
        if kind ~= Enum.UserInputType.MouseMovement
            and kind ~= Enum.UserInputType.Touch then return end
        local delta = input.Position - d.start
        local o = d.origin
        d.frame.Position = UDim2.new(o.X.Scale, o.X.Offset + delta.X,
                                     o.Y.Scale, o.Y.Offset + delta.Y)
    end)

    local function createPanel(name, w, h, pos, display)
        local saved = L.Settings.PanelWindows[name]
        local startPos = pos
        if saved and saved.Position then
            local sp = saved.Position
            startPos = UDim2.new(sp.XScale, sp.XOffset, sp.YScale, sp.YOffset)
        end
        local frame = New("Frame", {Size = UDim2.new(0, w, 0, h),
            Position = startPos, BackgroundColor3 = T.BG,
            BackgroundTransparency = 1, BorderSizePixel = 0,
            ClipsDescendants = true, Visible = false, Parent = Gui})
        Corner(frame, 14)
        local stroke = Stroke(frame, T.ACCENT, 1)
        rev(frame, "BackgroundTransparency", 0.15)
        rev(stroke, "Transparency", 0.55)
        New("UIGradient", {Rotation = 90, Parent = frame,
            Color = ColorSequence.new({
                ColorSequenceKeypoint.new(0, T.SURFACE),
                ColorSequenceKeypoint.new(1, T.BG)}),
            Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 0.35),
                NumberSequenceKeypoint.new(1, 0.1)})})

        local header = New("TextButton", {Size = UDim2.new(1, 0, 0, 30),
            BackgroundTransparency = 1, Text = "", AutoButtonColor = false,
            Parent = frame})
        local dot = New("Frame", {Size = UDim2.new(0, 7, 0, 7),
            Position = UDim2.new(0, 12, 0.5, -3), BackgroundColor3 = T.ACCENT,
            BackgroundTransparency = 1, BorderSizePixel = 0, Parent = header})
        Corner(dot, 4)
        rev(dot, "BackgroundTransparency", 0)
        local title = New("TextLabel", {Size = UDim2.new(1, -110, 1, 0),
            Position = UDim2.new(0, 26, 0, 0), BackgroundTransparency = 1,
            Text = display or name, TextColor3 = T.HIGH, Font = Enum.Font.GothamBold,
            TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
            TextTransparency = 1, Parent = header})
        rev(title, "TextTransparency", 0)
        local function hBtn(txt, xoff, col)
            local b = New("TextButton", {Size = UDim2.new(0, 20, 0, 20),
                Position = UDim2.new(1, xoff, 0.5, -10),
                BackgroundColor3 = T.RAISED, BackgroundTransparency = 1,
                Text = txt, TextColor3 = col, Font = Enum.Font.GothamBold,
                TextSize = 11, TextTransparency = 1, AutoButtonColor = false,
                Parent = header})
            Corner(b, 6)
            rev(b, "BackgroundTransparency", 0)
            rev(b, "TextTransparency", 0)
            return b
        end
        local closeBtn = hBtn("×", -26, T.RED)
        local minBtn = hBtn("–", -50, T.ACCENT)

        local content = New("Frame", {Size = UDim2.new(1, 0, 1, -30),
            Position = UDim2.new(0, 0, 0, 30), BackgroundTransparency = 1,
            Parent = frame})

        local p = {frame = frame, content = content, header = header,
                   normalH = h, minimized = saved and saved.Minimized == true}
        panels[name] = p

        if p.minimized then
            frame.Size = UDim2.new(0, w, 0, 30)
            content.Visible = false
            minBtn.Text = "+"
        end
        minBtn.MouseButton1Click:Connect(function()
            p.minimized = not p.minimized
            minBtn.Text = p.minimized and "+" or "–"
            if p.minimized then
                content.Visible = false
                tw(frame, 0.2, {Size = UDim2.new(0, w, 0, 30)},
                    Enum.EasingStyle.Quart)
            else
                tw(frame, 0.2, {Size = UDim2.new(0, w, 0, p.normalH)},
                    Enum.EasingStyle.Quart)
                task.delay(0.08, function()
                    if not p.minimized then content.Visible = true end
                end)
            end
            savePanel(name)
        end)
        closeBtn.MouseButton1Click:Connect(function()
            frame.Visible = false
        end)

        header.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch then
                local drag = {frame = frame, start = input.Position,
                              origin = frame.Position}
                dragActive = drag
                input.Changed:Connect(function()
                    if input.UserInputState == Enum.UserInputState.End then
                        if dragActive == drag then dragActive = nil end
                        savePanel(name)
                    end
                end)
            end
        end)
        return frame, content, header
    end

    local function smallTag(parent, text, x, y)
        local l = New("TextLabel", {Size = UDim2.new(1, -x - 8, 0, 11),
            Position = UDim2.new(0, x, 0, y), BackgroundTransparency = 1,
            Text = text, TextColor3 = T.MUTED, Font = Enum.Font.GothamSemibold,
            TextSize = 8, TextXAlignment = Enum.TextXAlignment.Left,
            TextTransparency = 1, Parent = parent})
        rev(l, "TextTransparency", 0)
        return l
    end

    local function makeSwitch(parent, x, y, label)
        local l = New("TextLabel", {Size = UDim2.new(1, -x - 56, 0, 22),
            Position = UDim2.new(0, x, 0, y), BackgroundTransparency = 1,
            Text = label, TextColor3 = T.MUTED, Font = Enum.Font.GothamSemibold,
            TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left,
            TextTransparency = 1, Parent = parent})
        rev(l, "TextTransparency", 0)
        local sw = New("TextButton", {Size = UDim2.new(0, 38, 0, 20),
            Position = UDim2.new(1, -x - 38, 0, y + 1),
            BackgroundColor3 = T.RAISED, BackgroundTransparency = 1, Text = "",
            AutoButtonColor = false, Parent = parent})
        Corner(sw, 10)
        local swStroke = Stroke(sw)
        rev(sw, "BackgroundTransparency", 0)
        rev(swStroke, "Transparency", 0.5)
        local knob = New("Frame", {Size = UDim2.new(0, 14, 0, 14),
            Position = UDim2.new(0, 3, 0.5, -7), BackgroundColor3 = T.MUTED,
            BackgroundTransparency = 1, BorderSizePixel = 0, Parent = sw})
        Corner(knob, 7)
        rev(knob, "BackgroundTransparency", 0)
        return l, sw, swStroke, knob
    end
    local function paintSwitch(lbl, sw, swStroke, knob, on)
        tw(sw, 0.18, {BackgroundColor3 = on and T.ACCENT or T.RAISED})
        tw(swStroke, 0.18, {Color = on and T.HIGH or T.LINE})
        TS:Create(knob, TweenInfo.new(0.25, Enum.EasingStyle.Back,
            Enum.EasingDirection.Out), {
            Position = on and UDim2.new(1, -17, 0.5, -7) or UDim2.new(0, 3, 0.5, -7),
            BackgroundColor3 = on and T.WHITE or T.MUTED}):Play()
        tw(lbl, 0.18, {TextColor3 = on and T.TEXT or T.MUTED})
    end

    local P_Main, C_Main, H_Main = createPanel("Main", 300, 342,
        UDim2.new(1, -316, 0.5, -171), "🍀 LUCK")

    local stdBtn = New("TextButton", {Size = UDim2.new(0, 32, 0, 20),
        Position = UDim2.new(1, -110, 0.5, -10), BackgroundColor3 = T.RAISED,
        BackgroundTransparency = 1, Text = "STD", TextColor3 = T.MUTED,
        Font = Enum.Font.GothamBold, TextSize = 9, TextTransparency = 1,
        AutoButtonColor = false, Parent = H_Main})
    Corner(stdBtn, 6)
    rev(stdBtn, "BackgroundTransparency", 0)
    rev(stdBtn, "TextTransparency", 0)
    local advBtn = New("TextButton", {Size = UDim2.new(0, 32, 0, 20),
        Position = UDim2.new(1, -76, 0.5, -10), BackgroundColor3 = T.RAISED,
        BackgroundTransparency = 1, Text = "ADV", TextColor3 = T.MUTED,
        Font = Enum.Font.GothamBold, TextSize = 9, TextTransparency = 1,
        AutoButtonColor = false, Parent = H_Main})
    Corner(advBtn, 6)
    rev(advBtn, "BackgroundTransparency", 0)
    rev(advBtn, "TextTransparency", 0)

    local CodeBox = New("TextBox", {Size = UDim2.new(1, -20, 0, 28),
        Position = UDim2.new(0, 10, 0, 6), BackgroundColor3 = T.SURFACE,
        BackgroundTransparency = 1, Text = "", PlaceholderText = "enter code…",
        PlaceholderColor3 = T.MUTED, TextColor3 = T.TEXT,
        Font = Enum.Font.GothamSemibold, TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left, ClearTextOnFocus = false,
        TextTransparency = 1, Parent = C_Main})
    Corner(CodeBox, 9)
    New("UIPadding", {PaddingLeft = UDim.new(0, 8), Parent = CodeBox})
    local CodeStroke = Stroke(CodeBox)
    rev(CodeBox, "BackgroundTransparency", 0)
    rev(CodeBox, "TextTransparency", 0)
    rev(CodeStroke, "Transparency", 0.5)
    local RedeemBtn = New("TextButton", {Size = UDim2.new(1, -96, 0, 30),
        Position = UDim2.new(0, 10, 0, 40), BackgroundColor3 = T.ACCENT,
        BackgroundTransparency = 1, Text = "REDEEM", TextColor3 = T.VOID,
        Font = Enum.Font.GothamBold, TextSize = 12, TextTransparency = 1,
        AutoButtonColor = false, ClipsDescendants = true, Parent = C_Main})
    Corner(RedeemBtn, 9)
    New("UIGradient", {Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, T.DEEP),
        ColorSequenceKeypoint.new(0.5, T.ACCENT),
        ColorSequenceKeypoint.new(1, T.HIGH)}),
        Rotation = 90, Parent = RedeemBtn})
    rev(RedeemBtn, "BackgroundTransparency", 0)
    rev(RedeemBtn, "TextTransparency", 0)

    local WarmBtn = New("TextButton", {Size = UDim2.new(0, 66, 0, 30),
        Position = UDim2.new(1, -76, 0, 40), BackgroundColor3 = T.RAISED,
        BackgroundTransparency = 1, Text = "WARM", TextColor3 = T.ACCENT,
        Font = Enum.Font.GothamBold, TextSize = 11, TextTransparency = 1,
        AutoButtonColor = false, Parent = C_Main})
    Corner(WarmBtn, 9)
    local WarmStroke = Stroke(WarmBtn, T.ACCENT, 1)
    rev(WarmBtn, "BackgroundTransparency", 0)
    rev(WarmBtn, "TextTransparency", 0)
    rev(WarmStroke, "Transparency", 0.45)
    WarmBtn.MouseButton1Click:Connect(function()
        if L.WarmRemote and L.WarmRemote() then
            WarmBtn.Text = "WARMING…"
            WarmBtn.TextColor3 = T.ORANGE
            L.Notify("warming remote (5 pings, 5s apart)…", T.MUTED)
            local prevDone = L.WarmDone
            L.WarmDone = function()
                if prevDone then prevDone() end
                WarmBtn.Text = "WARM"
                WarmBtn.TextColor3 = T.ACCENT
                L.Notify("remote warm — redeem is hot", T.HIGH)
            end
        else
            WarmBtn.Text = L.Warming and "WARMING…" or "COOLDOWN"
            task.delay(1, function()
                if not L.Warming then WarmBtn.Text = "WARM" end
            end)
        end
    end)
    hover(WarmBtn, T.RAISED, WarmStroke)

    local AutoLbl, AutoSw, AutoSwStroke, AutoKnob =
        makeSwitch(C_Main, 10, 78, "Auto Redeem")
    local GuessLbl, GuessSw, GuessSwStroke, GuessKnob =
        makeSwitch(C_Main, 10, 102, "Guess Code")

    local function paintSwitches()
        paintSwitch(AutoLbl, AutoSw, AutoSwStroke, AutoKnob, L.AutoOn)
        paintSwitch(GuessLbl, GuessSw, GuessSwStroke, GuessKnob, L.GuessCode)
    end
    local function setAuto(v)
        L.AutoOn = v and true or false
        L.Settings.AutoOn = L.AutoOn
        L.SaveSettings()
        L.SyncHot()
        paintSwitches()
    end
    L.SetAuto = setAuto
    L.SetGuess = function(v)
        L.GuessCode = v and true or false
        L.Settings.GuessCode = L.GuessCode
        L.SaveSettings()
        L.SyncHot()
        paintSwitches()
    end
    AutoSw.MouseButton1Click:Connect(function() setAuto(not L.AutoOn) end)
    GuessSw.MouseButton1Click:Connect(function() L.SetGuess(not L.GuessCode) end)

    smallTag(C_Main, "PARTS PER CODE", 10, 132)
    local PartBtns = {}
    for i = 1, 5 do
        local b = New("TextButton", {Size = UDim2.new(0, 34, 0, 22),
            Position = UDim2.new(0, 10 + (i - 1) * 38, 0, 146),
            BackgroundColor3 = T.RAISED, BackgroundTransparency = 1,
            Text = tostring(i), TextColor3 = T.MUTED,
            Font = Enum.Font.GothamBold, TextSize = 11, TextTransparency = 1,
            AutoButtonColor = false, Parent = C_Main})
        Corner(b, 7)
        rev(b, "BackgroundTransparency", 0)
        rev(b, "TextTransparency", 0)
        PartBtns[i] = b
    end
    local CustomBtn = New("TextButton", {Size = UDim2.new(0, 76, 0, 22),
        Position = UDim2.new(0, 10 + 5 * 38, 0, 146),
        BackgroundColor3 = T.RAISED, BackgroundTransparency = 1,
        Text = "Custom", TextColor3 = T.MUTED, Font = Enum.Font.GothamBold,
        TextSize = 10, TextTransparency = 1, AutoButtonColor = false,
        Parent = C_Main})
    Corner(CustomBtn, 7)
    rev(CustomBtn, "BackgroundTransparency", 0)
    rev(CustomBtn, "TextTransparency", 0)

    local CustomRow = New("Frame", {Size = UDim2.new(1, -20, 0, 22),
        Position = UDim2.new(0, 10, 0, 172), BackgroundTransparency = 1,
        Visible = false, Parent = C_Main})
    local CustomMinus = New("TextButton", {Size = UDim2.new(0, 30, 1, 0),
        BackgroundColor3 = T.RAISED, BackgroundTransparency = 1, Text = "−",
        TextColor3 = T.HIGH, Font = Enum.Font.GothamBold, TextSize = 14,
        TextTransparency = 1, AutoButtonColor = false, Parent = CustomRow})
    Corner(CustomMinus, 7)
    local CustomCount = New("TextLabel", {Size = UDim2.new(0, 50, 1, 0),
        Position = UDim2.new(0.5, -25, 0, 0), BackgroundTransparency = 1,
        Text = tostring(L.CustomThreshold or 0), TextColor3 = T.TEXT,
        Font = Enum.Font.GothamBold, TextSize = 13, TextTransparency = 1,
        Parent = CustomRow})
    local CustomPlus = New("TextButton", {Size = UDim2.new(0, 30, 1, 0),
        Position = UDim2.new(1, -30, 0, 0), BackgroundColor3 = T.RAISED,
        BackgroundTransparency = 1, Text = "+", TextColor3 = T.HIGH,
        Font = Enum.Font.GothamBold, TextSize = 14, TextTransparency = 1,
        AutoButtonColor = false, Parent = CustomRow})
    Corner(CustomPlus, 7)
    rev(CustomMinus, "BackgroundTransparency", 0)
    rev(CustomMinus, "TextTransparency", 0)
    rev(CustomCount, "TextTransparency", 0)
    rev(CustomPlus, "BackgroundTransparency", 0)
    rev(CustomPlus, "TextTransparency", 0)

    local function paintParts()
        local custom = L.ThresholdMode == "custom"
        local cur = math.clamp(L.Threshold or 1, 1, 5)
        for j = 1, 5 do
            local on = (not custom) and j == cur
            tw(PartBtns[j], 0.15, {
                BackgroundColor3 = on and T.ACCENT or T.RAISED,
                TextColor3 = on and T.VOID or T.MUTED})
        end
        tw(CustomBtn, 0.15, {
            BackgroundColor3 = custom and T.ACCENT or T.RAISED,
            TextColor3 = custom and T.VOID or T.MUTED})
        CustomRow.Visible = custom
        CustomCount.Text = tostring(L.CustomThreshold or 0)
    end
    local function setPreset(i)
        L.ThresholdMode = "preset"
        L.Threshold = i
        L.Settings.ThresholdMode = "preset"
        L.Settings.Threshold = i
        L.Settings.LastPreset = i
        L.SaveSettings()
        L.SyncHot()
        paintParts()
        if L.RefreshPreview then L.RefreshPreview() end
    end
    local function setCustom(n)
        n = math.clamp(n, 0, 50)
        L.CustomThreshold = n
        L.ThresholdMode = "custom"
        L.Threshold = n
        L.Settings.CustomThreshold = n
        L.Settings.ThresholdMode = "custom"
        L.Settings.Threshold = n
        L.SaveSettings()
        L.SyncHot()
        paintParts()
        if L.RefreshPreview then L.RefreshPreview() end
    end
    for i = 1, 5 do
        PartBtns[i].MouseButton1Click:Connect(function() setPreset(i) end)
    end
    CustomBtn.MouseButton1Click:Connect(function()
        if L.ThresholdMode == "custom" then
            setPreset(math.clamp(L.LastPreset or 1, 1, 5))
        else
            setCustom(L.CustomThreshold or 0)
        end
    end)
    CustomMinus.MouseButton1Click:Connect(function()
        setCustom((L.CustomThreshold or 0) - 1)
    end)
    CustomPlus.MouseButton1Click:Connect(function()
        setCustom((L.CustomThreshold or 0) + 1)
    end)

    smallTag(C_Main, "SPEED", 10, 202)
    local SpeedBtns = {}
    local speedNames = {"Normal", "Medium", "Fast", "Lucky"}
    for i = 1, 4 do
        local b = New("TextButton", {Size = UDim2.new(0, 62, 0, 22),
            Position = UDim2.new(0, 10 + (i - 1) * 67, 0, 216),
            BackgroundColor3 = T.RAISED, BackgroundTransparency = 1,
            Text = speedNames[i], TextColor3 = T.MUTED,
            Font = Enum.Font.GothamBold, TextSize = 10, TextTransparency = 1,
            AutoButtonColor = false, Parent = C_Main})
        Corner(b, 7)
        rev(b, "BackgroundTransparency", 0)
        rev(b, "TextTransparency", 0)
        SpeedBtns[i] = b
    end
    local function paintSpeed()
        for j = 1, 4 do
            local on = j == L.SpeedIndex
            tw(SpeedBtns[j], 0.15, {
                BackgroundColor3 = on and T.ACCENT or T.RAISED,
                TextColor3 = on and T.VOID or T.MUTED})
        end
    end
    L.SetSpeed = function(idx, silent)
        idx = math.clamp(idx or 1, 1, #L.SpeedModes)
        L.SpeedIndex = idx
        L.Mode = L.SpeedModes[idx]
        L.Settings.SpeedIndex = idx
        L.SaveSettings()
        L.SyncHot()
        paintSpeed()
        if not silent then L.Notify("Speed » " .. L.Mode.name, T.MUTED) end
    end
    for i = 1, 4 do
        SpeedBtns[i].MouseButton1Click:Connect(function() L.SetSpeed(i) end)
    end

    local StatusLine = New("TextLabel", {Size = UDim2.new(1, -20, 0, 12),
        Position = UDim2.new(0, 10, 1, -32), BackgroundTransparency = 1,
        Text = "ready", TextColor3 = T.MUTED, Font = Enum.Font.GothamSemibold,
        TextSize = 8, TextXAlignment = Enum.TextXAlignment.Left,
        TextTransparency = 1, TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = C_Main})
    rev(StatusLine, "TextTransparency", 0)
    status = { set = function(t, c)
        if not L.IntroDone then return end
        StatusLine.Text = tostring(t)
        StatusLine.TextColor3 = c or T.MUTED
    end }

    local P_Status, C_Status = createPanel("Status", 280, 148,
        UDim2.new(0, 16, 0, 16))
    smallTag(C_Status, "REMOTES", 10, 4)
    local SysLabel = New("TextLabel", {Size = UDim2.new(1, -20, 0, 12),
        Position = UDim2.new(0, 10, 0, 17), BackgroundTransparency = 1,
        Text = L.RemoteStatusText or "redeem: searching… · notify: searching…",
        TextColor3 = T.ORANGE, Font = Enum.Font.GothamSemibold, TextSize = 8,
        TextXAlignment = Enum.TextXAlignment.Left, TextTransparency = 1,
        TextTruncate = Enum.TextTruncate.AtEnd, Parent = C_Status})
    rev(SysLabel, "TextTransparency", 0)
    L.RemoteStatusLabel = SysLabel
    if L.RefreshRemoteStatus then L.RefreshRemoteStatus() end

    local function routeRow(y, label)
        local l = New("TextLabel", {Size = UDim2.new(0, 66, 0, 22),
            Position = UDim2.new(0, 10, 0, y), BackgroundTransparency = 1,
            Text = label, TextColor3 = T.MUTED, Font = Enum.Font.GothamSemibold,
            TextSize = 10, TextXAlignment = Enum.TextXAlignment.Left,
            TextTransparency = 1, Parent = C_Status})
        rev(l, "TextTransparency", 0)
        local track = New("Frame", {Size = UDim2.new(1, -88, 0, 22),
            Position = UDim2.new(0, 80, 0, y), BackgroundColor3 = T.SURFACE,
            BackgroundTransparency = 1, BorderSizePixel = 0, Parent = C_Status})
        Corner(track, 8)
        rev(track, "BackgroundTransparency", 0)
        local bUI = New("TextButton", {Size = UDim2.new(0.5, -2, 1, -4),
            Position = UDim2.new(0, 2, 0, 2), BackgroundColor3 = T.RAISED,
            BackgroundTransparency = 1, Text = "UI", TextColor3 = T.MUTED,
            Font = Enum.Font.GothamBold, TextSize = 10, TextTransparency = 1,
            AutoButtonColor = false, Parent = track})
        Corner(bUI, 6)
        local bRem = New("TextButton", {Size = UDim2.new(0.5, -2, 1, -4),
            Position = UDim2.new(0.5, 0, 0, 2), BackgroundColor3 = T.RAISED,
            BackgroundTransparency = 1, Text = "REMOTE", TextColor3 = T.MUTED,
            Font = Enum.Font.GothamBold, TextSize = 10, TextTransparency = 1,
            AutoButtonColor = false, Parent = track})
        Corner(bRem, 6)
        rev(bUI, "BackgroundTransparency", 0)
        rev(bUI, "TextTransparency", 0)
        rev(bRem, "BackgroundTransparency", 0)
        rev(bRem, "TextTransparency", 0)
        return bUI, bRem
    end
    smallTag(C_Status, "ROUTES", 10, 34)
    local dUI, dRemote = routeRow(47, "Detection")
    local rUI, rRemote = routeRow(73, "Redeem")
    local SrcLabel = New("TextLabel", {Size = UDim2.new(1, -20, 0, 12),
        Position = UDim2.new(0, 10, 0, 100), BackgroundTransparency = 1,
        Text = "", TextColor3 = T.MUTED, Font = Enum.Font.GothamSemibold,
        TextSize = 8, TextXAlignment = Enum.TextXAlignment.Left,
        TextTransparency = 1, TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = C_Status})
    rev(SrcLabel, "TextTransparency", 0)

    local function paintPill(btnUI, btnRemote, current)
        local uiOn = current == "ui"
        tw(btnUI, 0.15, {BackgroundColor3 = uiOn and T.ACCENT or T.RAISED,
                         TextColor3 = uiOn and T.VOID or T.MUTED})
        tw(btnRemote, 0.15, {BackgroundColor3 = (not uiOn) and T.ACCENT or T.RAISED,
                             TextColor3 = (not uiOn) and T.VOID or T.MUTED})
    end
    local function paintModes()
        paintPill(dUI, dRemote, L.DetectMode)
        paintPill(rUI, rRemote, L.RedeemPath)
        SrcLabel.Text = ("source: %s  ·  gui: %s"):format(
            L.NotifyRemoteName or "?",
            L.GuiStealth and "hidden" or "playergui")
    end
    L.PaintModes = paintModes
    L.SetDetectMode = function(m)
        L.DetectMode = (m == "remote") and "remote" or "ui"
        L.Settings.DetectMode = L.DetectMode
        L.SaveSettings()
        if L.DetectMode == "remote" then
            L.ConnectNotifyRemote()
        elseif L.HookNotify then
            L.HookNotify()
        end
        L.NotifyRemoteName = (L.DetectMode == "remote" and L.RemoteDetectOn)
            and "remote" or (L.NotifyHooked and "notify" or "gui")
        paintModes()
    end
    L.SetRedeemPath = function(m)
        L.RedeemPath = (m == "remote" and "remote") or (m == "both" and "both") or "ui"
        L.Settings.RedeemPath = L.RedeemPath
        L.SaveSettings()
        if L.SyncFast then L.SyncFast() end
        if L.RedeemPath == "remote" and L.RedeemRemote
            and L.RedeemRemoteTested == nil and L.TestRedeemRemote then
            L.TestRedeemRemote()
        end
        paintModes()
    end
    dUI.MouseButton1Click:Connect(function() L.SetDetectMode("ui") end)
    dRemote.MouseButton1Click:Connect(function() L.SetDetectMode("remote") end)
    rUI.MouseButton1Click:Connect(function() L.SetRedeemPath("ui") end)
    rRemote.MouseButton1Click:Connect(function() L.SetRedeemPath("remote") end)

    local P_Prev, C_Prev = createPanel("Live Preview", 280, 116,
        UDim2.new(0, 16, 0, 172))
    local PrevCode = New("TextLabel", {Size = UDim2.new(1, -20, 0, 20),
        Position = UDim2.new(0, 10, 0, 8), BackgroundTransparency = 1,
        Text = "waiting for code…", TextColor3 = T.MUTED,
        Font = Enum.Font.GothamBold, TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Left, TextTransparency = 1,
        TextTruncate = Enum.TextTruncate.AtEnd, Parent = C_Prev})
    rev(PrevCode, "TextTransparency", 0)
    local PrevMeta = New("TextLabel", {Size = UDim2.new(1, -20, 0, 12),
        Position = UDim2.new(0, 10, 0, 30), BackgroundTransparency = 1,
        Text = "", TextColor3 = T.MUTED, Font = Enum.Font.GothamSemibold,
        TextSize = 8, TextXAlignment = Enum.TextXAlignment.Left,
        TextTransparency = 1, Parent = C_Prev})
    rev(PrevMeta, "TextTransparency", 0)
    local PrevVerdict = New("TextLabel", {Size = UDim2.new(1, -20, 0, 14),
        Position = UDim2.new(0, 10, 0, 46), BackgroundTransparency = 1,
        Text = "", TextColor3 = T.ORANGE, Font = Enum.Font.GothamSemibold,
        TextSize = 10, TextXAlignment = Enum.TextXAlignment.Left,
        TextTransparency = 1, TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = C_Prev})
    rev(PrevVerdict, "TextTransparency", 0)

    L.RefreshPreview = function()
        local code = L.LastPreviewCode
        PrevCode.Text = code or "waiting for code…"
        PrevCode.TextColor3 = code and T.TEXT or T.MUTED
        PrevMeta.Text = ("buffer %d/%d  ·  mode %s  ·  source %s"):format(
            L.BufN or 0, L.Threshold or 1,
            L.Mode and L.Mode.name or "?", L.NotifyRemoteName or "?")
    end
    L.ReportRedeem = function(ok, reply, timing)
        if not L.IntroDone then return end
        local t = tostring(reply or (ok == nil and "no result") or "?")
        local ms = ""
        if timing and timing.server and timing.server > 0 then
            ms = ("  ·  %.1fms"):format(timing.server)
        end
        PrevVerdict.Text = (t .. ms):sub(1, 72)
        PrevVerdict.TextColor3 = ok == true and T.GREEN
            or (ok == false and T.RED or T.ORANGE)
        L.RefreshPreview()
    end

    local P_Hist, C_Hist = createPanel("History", 280, 104,
        UDim2.new(0, 16, 0, 296))
    local HistRows = {}
    for i = 1, 5 do
        local l = New("TextLabel", {Size = UDim2.new(1, -20, 0, 13),
            Position = UDim2.new(0, 10, 0, 6 + (i - 1) * 14),
            BackgroundTransparency = 1, Text = "", TextColor3 = T.MUTED,
            Font = Enum.Font.GothamSemibold, TextSize = 10,
            TextXAlignment = Enum.TextXAlignment.Left, TextTransparency = 1,
            Parent = C_Hist})
        rev(l, "TextTransparency", 0)
        HistRows[i] = l
    end
    L.RefreshHistory = function()
        for i = 1, 5 do
            local item = L.CodeHistory[i]
            if item then
                local mark = item.status == "success" and "✓"
                    or (item.status == "rejected" and "×" or "!")
                local ms = item.client and ("  ·  %.0fms"):format(item.client) or ""
                HistRows[i].Text = mark .. "  " .. tostring(item.code) .. ms
                HistRows[i].TextColor3 = item.status == "success" and T.GREEN
                    or (item.status == "rejected" and T.RED or T.ORANGE)
            else
                HistRows[i].Text = ""
            end
        end
    end

    local P_Feed, C_Feed = createPanel("Feed", 280, 150,
        UDim2.new(0, 16, 0, 408))
    local FeedScroll = New("ScrollingFrame", {Size = UDim2.new(1, -16, 1, -12),
        Position = UDim2.new(0, 8, 0, 6), BackgroundTransparency = 1,
        BorderSizePixel = 0, ScrollBarThickness = 2,
        ScrollBarImageColor3 = T.LINE, CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = C_Feed})
    New("UIListLayout", {Padding = UDim.new(0, 3),
        SortOrder = Enum.SortOrder.LayoutOrder, Parent = FeedScroll})
    local feedOrder = 0
    -- A FIFO of our own instead of a GetChildren() walk per line. The old version
    -- allocated the whole child array and scanned it looking for the lowest LayoutOrder
    -- every time a line was written -- and lines get written while a code is live.
    local feedRows = {}
    local function feedLine(text, color)
        feedOrder = feedOrder + 1
        local l = New("TextLabel", {Size = UDim2.new(1, -4, 0, 13),
            BackgroundTransparency = 1, Text = tostring(text),
            TextColor3 = color, Font = Enum.Font.GothamSemibold, TextSize = 9,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            LayoutOrder = feedOrder, Parent = FeedScroll})
        feedRows[#feedRows + 1] = l
        while #feedRows > 30 do
            local old = table.remove(feedRows, 1)
            if old then pcall(function() old:Destroy() end) end
        end
        return l
    end
    local P_Sender, C_Sender = createPanel("Sender", 280, 108,
        UDim2.new(0, 312, 0, 408))
    local SendBox = New("TextBox", {Size = UDim2.new(1, -20, 0, 28),
        Position = UDim2.new(0, 10, 0, 6), BackgroundColor3 = T.SURFACE,
        BackgroundTransparency = 1, Text = "",
        PlaceholderText = "type a word or message…",
        PlaceholderColor3 = T.MUTED, TextColor3 = T.TEXT,
        Font = Enum.Font.GothamSemibold, TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left, ClearTextOnFocus = false,
        TextTransparency = 1, Parent = C_Sender})
    Corner(SendBox, 9)
    New("UIPadding", {PaddingLeft = UDim.new(0, 8), Parent = SendBox})
    local SendBoxStroke = Stroke(SendBox)
    rev(SendBox, "BackgroundTransparency", 0)
    rev(SendBox, "TextTransparency", 0)
    rev(SendBoxStroke, "Transparency", 0.5)
    local function fireFake(txt)
        txt = (txt or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if txt == "" then return end
        local r = L.NotifyRemote
        if not (r and typeof(firesignal) == "function") then
            L.Notify("no notify remote / firesignal", T.RED)
            return
        end
        pcall(firesignal, r.OnClientEvent, txt, 5.5,
            "Sounds.Sfx.Blop", "Top", 2678001507)
        L.Notify("sent fake: " .. txt, T.MUTED)
    end
    local SendBtn = New("TextButton", {Size = UDim2.new(1, -102, 0, 30),
        Position = UDim2.new(0, 10, 0, 42), BackgroundColor3 = T.ACCENT,
        BackgroundTransparency = 1, Text = "SEND", TextColor3 = T.VOID,
        Font = Enum.Font.GothamBold, TextSize = 12, TextTransparency = 1,
        AutoButtonColor = false, ClipsDescendants = true, Parent = C_Sender})
    Corner(SendBtn, 9)
    New("UIGradient", {Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, T.DEEP),
        ColorSequenceKeypoint.new(0.5, T.ACCENT),
        ColorSequenceKeypoint.new(1, T.HIGH)}),
        Rotation = 90, Parent = SendBtn})
    rev(SendBtn, "BackgroundTransparency", 0)
    rev(SendBtn, "TextTransparency", 0)
    local TestBtn = New("TextButton", {Size = UDim2.new(0, 82, 0, 30),
        Position = UDim2.new(1, -92, 0, 42), BackgroundColor3 = T.RAISED,
        BackgroundTransparency = 1, Text = "TEST CODE", TextColor3 = T.ACCENT,
        Font = Enum.Font.GothamBold, TextSize = 10, TextTransparency = 1,
        AutoButtonColor = false, Parent = C_Sender})
    Corner(TestBtn, 9)
    local TestStroke = Stroke(TestBtn, T.ACCENT, 1)
    rev(TestBtn, "BackgroundTransparency", 0)
    rev(TestBtn, "TextTransparency", 0)
    rev(TestStroke, "Transparency", 0.45)
    SendBtn.MouseButton1Click:Connect(function()
        fireFake(SendBox.Text)
        SendBox.Text = ""
        SendBox:CaptureFocus()
    end)
    SendBox.FocusLost:Connect(function(enter)
        if enter then
            fireFake(SendBox.Text)
            SendBox.Text = ""
            SendBox:CaptureFocus()
        end
    end)
    TestBtn.MouseButton1Click:Connect(function()
        fireFake("TESTCODE" .. tostring(math.random(1000, 9999)))
    end)
    hover(TestBtn, T.RAISED, TestStroke)

    local ToastHolder = New("Frame", {Size = UDim2.new(0, 340, 1, -60),
        Position = UDim2.new(0.5, -170, 0, 14), BackgroundTransparency = 1,
        Parent = Gui})
    New("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder,
        HorizontalAlignment = Enum.HorizontalAlignment.Center,
        Padding = UDim.new(0, 6), Parent = ToastHolder})
    local toastOrder = 0
    local toastRows = {}
    local function toast(text, color)
        toastOrder += 1
        local t = New("TextLabel", {Size = UDim2.new(1, 0, 0, 30),
            BackgroundColor3 = T.BG, BackgroundTransparency = 0.15,
            Text = tostring(text), TextColor3 = color or T.TEXT,
            Font = Enum.Font.GothamSemibold, TextSize = 12,
            TextTransparency = 1, BorderSizePixel = 0,
            LayoutOrder = toastOrder, Parent = ToastHolder})
        Corner(t, 9)
        local ts = Stroke(t, T.ACCENT, 1)
        ts.Transparency = 0.6
        t.BackgroundTransparency = 1
        tw(t, 0.25, {BackgroundTransparency = 0.15, TextTransparency = 0})
        task.delay(3.5, function()
            tw(t, 0.4, {BackgroundTransparency = 1, TextTransparency = 1})
            task.wait(0.45)
            t:Destroy()
        end)
        -- Same FIFO treatment as the feed: no GetChildren() walk per toast. Note the
        -- old walk trimmed by child order, which is creation order, so it destroyed the
        -- newest ones past four rather than the oldest. This drops the oldest.
        toastRows[#toastRows + 1] = t
        while #toastRows > 4 do
            local old = table.remove(toastRows, 1)
            if old then pcall(function() old:Destroy() end) end
        end
    end

    L.Notify = function(text, color)
        if not L.IntroDone then return end
        feedLine("» " .. tostring(text), color or T.TEXT)
        toast("» " .. tostring(text), color or T.TEXT)
    end
    L.NotifyRedeem = function(code, prize, who)
        if not L.IntroDone then return end
        local nm = (who and who.Name) or "?"
        local msg = ("⚔ %s sniped %s%s"):format(nm, tostring(code or "?"),
            prize and ("  (" .. tostring(prize) .. ")") or "")
        feedLine(msg, T.ORANGE)
        toast(msg, T.ORANGE)
    end

    local function runManual()
        local code = CodeBox.Text:gsub("[^%w]", ""):upper():sub(1, 50)
        if code == "" then return end
        CodeBox.Text = ""
        task.spawn(function()
            local ok, reply, timing = L.RedeemViaRemote(code)
            L.PostRedeem(os.clock(), "manual", code, ok, reply, timing)
        end)
    end
    RedeemBtn.MouseButton1Click:Connect(runManual)
    CodeBox.FocusLost:Connect(function(enter)
        if enter then runManual() end
    end)

    L.RefreshAuto = function()
        L.RefreshPreview()
    end

    local function paintViewSwitch()
        local adv = L.ViewMode == "advanced"
        tw(stdBtn, 0.15, {BackgroundColor3 = (not adv) and T.ACCENT or T.RAISED,
                          TextColor3 = (not adv) and T.VOID or T.MUTED})
        tw(advBtn, 0.15, {BackgroundColor3 = adv and T.ACCENT or T.RAISED,
                          TextColor3 = adv and T.VOID or T.MUTED})
    end
    local function applyViewMode()
        local adv = L.ViewMode == "advanced"
        for name, p in pairs(panels) do
            if name ~= "Main" then
                p.frame.Visible = adv and L.IntroDone == true
            end
        end
        paintViewSwitch()
    end
    L.SetViewMode = function(m)
        L.ViewMode = (m == "advanced") and "advanced" or "standard"
        L.Settings.ViewMode = L.ViewMode
        L.SaveSettings()
        applyViewMode()
    end
    stdBtn.MouseButton1Click:Connect(function() L.SetViewMode("standard") end)
    advBtn.MouseButton1Click:Connect(function() L.SetViewMode("advanced") end)

    local Fab = New("TextButton", {Size = UDim2.new(0, 46, 0, 46),
        Position = UDim2.new(0, 18, 1, -64), BackgroundColor3 = T.BG,
        BackgroundTransparency = 1, Text = "🍀", TextSize = 24,
        Font = Enum.Font.GothamBold, TextTransparency = 1,
        AutoButtonColor = false, Visible = false, Parent = Gui})
    Corner(Fab, 14)
    local FabStroke = Stroke(Fab, T.ACCENT)
    rev(Fab, "BackgroundTransparency", 0.06)
    rev(Fab, "TextTransparency", 0)
    rev(FabStroke, "Transparency", 0.45)

    local mainShown = true
    local function toggleAll()
        mainShown = not mainShown
        panels["Main"].frame.Visible = mainShown and L.IntroDone == true
        if mainShown then applyViewMode() else
            for name, p in pairs(panels) do
                if name ~= "Main" then p.frame.Visible = false end
            end
        end
    end
    Fab.MouseButton1Click:Connect(toggleAll)

    local function keycode(name)
        local ok, kc = pcall(function() return Enum.KeyCode[name] end)
        return ok and kc or nil
    end
    local kbAuto = keycode(L.Settings.Keybinds.Auto) or Enum.KeyCode.F
    local kbUI = keycode(L.Settings.Keybinds.ToggleUI) or Enum.KeyCode.G
    UIS.InputBegan:Connect(function(input, gpe)
        if gpe then return end
        if input.KeyCode == kbAuto then
            setAuto(not L.AutoOn)
        elseif input.KeyCode == kbUI then
            toggleAll()
        end
    end)

    paintModes()
    paintSwitches()
    paintParts()
    paintSpeed()
    paintViewSwitch()
    L.RefreshHistory()

    task.spawn(function()
        L.IntroDone = true
        Fab.Visible = true
        panels["Main"].frame.Visible = true
        applyViewMode()
        for _, p in pairs(panels) do
            if p.frame.Visible then
                local sc = New("UIScale", {Scale = 0.92, Parent = p.frame})
                tw(sc, 0.25, {Scale = 1})
                task.delay(0.3, function() sc:Destroy() end)
            end
        end
        for _, e in ipairs(reveal) do
            tw(e[1], 0.35, {[e[2]] = e[3]})
        end
        task.delay(0.4, function()
            L.Notify("🍀 LUCK online", T.HIGH)
            if status then
                status.set("ready  ·  detect " .. L.DetectMode
                    .. "  ·  redeem " .. L.RedeemPath, T.MUTED)
            end
        end)
    end)
end)
if not uiOK then
    warn("[LUCK] UI failed to build: " .. tostring(uiErr))
end
