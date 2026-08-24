local Players       = game:GetService("Players")
local UIS           = game:GetService("UserInputService")
local TS            = game:GetService("TweenService")
local HttpService   = game:GetService("HttpService")
local RepS          = game:GetService("ReplicatedStorage")
local RunS          = game:GetService("RunService")
local LP            = Players.LocalPlayer
local PG            = LP:WaitForChild("PlayerGui")
local IS_MOBILE, IS_PC, MOBILE_PANEL_WIDTH, VIEWPORT_WIDTH
do
    local viewportWidth = 800
    pcall(function()
        local camera = workspace.CurrentCamera
        if camera and camera.ViewportSize.X > 0 then viewportWidth = camera.ViewportSize.X end
    end)
    local platform
    pcall(function() platform = UIS:GetPlatform() end)
    IS_MOBILE = platform == Enum.Platform.IOS or platform == Enum.Platform.Android
    if platform == nil then IS_MOBILE = UIS.TouchEnabled and not UIS.MouseEnabled end
    IS_PC = not IS_MOBILE
    MOBILE_PANEL_WIDTH = math.floor(math.clamp(viewportWidth - 24, 300, 360))
    VIEWPORT_WIDTH = viewportWidth
end
local PERF = IS_MOBILE and {
    name = "Mobile", poll = 0, health = 0.25,
    previewDelay = 0, gradientKeys = 9, gradientRate = 0.14,
    rain = false, rainInterval = 0.30, panelWidth = MOBILE_PANEL_WIDTH,
    notificationWidth = math.min(320, MOBILE_PANEL_WIDTH - 8),
} or {
    name = "Desktop", poll = 0, health = 0.1,
    previewDelay = 0, gradientKeys = 14, gradientRate = 0.035,
    rain = true, rainInterval = 0.10, panelWidth = 440, notificationWidth = 380,
}

local L = {}
L.IsMobile = IS_MOBILE
L.IsPC = IS_PC
L.PerformanceProfile = PERF
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
    AutoOn = false,
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
        AutoOn = type(source.AutoOn) == "boolean" and source.AutoOn or SETTINGS_DEFAULTS.AutoOn,
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
    task.delay(0, function()
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

L.EnableWebhook = false
L.DedupOn = L.Settings.DedupOn ~= false
L.RainbowStats = L.Settings.RainbowStats ~= false
L.EnableTracker = false
L.EnableScanner = false
L.SkipResults = false

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
local function alive(inst) return inst and typeof(inst)=="Instance" and inst.Parent~=nil end

local function fmt(ms)
    if ms < 1 then return ("%.2fms"):format(ms) end
    if ms < 10 then return ("%.1fms"):format(ms) end
    return ("%.0fms"):format(ms)
end

local function render(v, depth)
    local t = typeof(v)
    if t == "string" then
        if v:find("<", 1, true) then
            v = v:gsub("<br%s*/>", " "):gsub("<[^>]->", "")
        end
        return (v:gsub("^%s+", ""):gsub("%s+$", ""))
    elseif t == "nil" then
        return nil
    elseif t == "table" then
        if (depth or 0) > 2 then return "{...}" end
        local parts = {}
        for k, val in pairs(v) do
            parts[#parts + 1] = ("%s=%s"):format(tostring(k), render(val, (depth or 0) + 1) or "nil")
            if #parts >= 6 then parts[#parts + 1] = "..."; break end
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return tostring(v)
end

L.Armed, L.ArmedInvoke, L.ArmedIsEvent = nil, nil, false
L.Remotes = {Redeem = {}, Notify = {}}
L.NotifyRemoteName = "gui"
L.Net = nil
L.Arm = function() return false end
L.ResolveRemotes = function() return L.Remotes end
L.RemoteReport = function() L.Status = "ready"; return L.Remotes end

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

    local function enumerateRemotes()
        local out = {}
        for _, d in ipairs(RepS:GetDescendants()) do
            if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then
                out[#out + 1] = d
            end
        end
        return out
    end

    local function verifiedNotify()
        if typeof(getconnections) ~= "function" then return nil end
        local getinfo = debug and (debug.getinfo or debug.info)
        if not getinfo then return nil end
        local function scan(root)
            for _, d in ipairs(root:GetDescendants()) do
                if d:IsA("RemoteEvent") then
                    local ok, cs = pcall(getconnections, d.OnClientEvent)
                    if ok and type(cs) == "table" then
                        for _, c in ipairs(cs) do
                            local okf, fn = pcall(function() return c.Function end)
                            if okf and type(fn) == "function" then
                                local oki, info = pcall(getinfo, fn)
                                local src = oki and tostring(info.short_src or info.source or "") or ""
                                if src:find("NotificationController", 1, true) then
                                    return d
                                end
                            end
                        end
                    end
                end
            end
            return nil
        end
        local net = RepS:FindFirstChild("Packages")
        net = net and net:FindFirstChild("Net")
        if net then
            local hit = scan(net)
            if hit then return hit end
        end
        return scan(RepS)
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

    task.spawn(function()
        for _ = 1, 240 do
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
            local vn = verifiedNotify()
            if vn then
                if L.NotifyRemote and L.NotifyRemote ~= vn then
                    L.NotifyRemoteSource = "verified (index was off)"
                elseif not L.NotifyRemote then
                    L.NotifyRemoteSource = "verified"
                end
                L.NotifyRemote = vn
            end
            local vr = verifiedRedeem()
            if vr then
                if L.RedeemRemote and L.RedeemRemote ~= vr then
                    L.RedeemRemoteSource = "verified (index was off)"
                    tested = false
                    L.RedeemRemoteTested = nil
                elseif not L.RedeemRemote then
                    L.RedeemRemoteSource = "verified"
                end
                L.RedeemRemote, L.RedeemRemoteIsEvent = vr, false
            end
            if L.NotifyRemote then L.ConnectNotifyRemote() end
            testRedeemRemote()
            L.RefreshRemoteStatus()
            if L.RedeemRemote and L.RemoteDetectOn and L.RedeemRemoteTested ~= nil then
                return
            end
            task.wait(0.25)
        end
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

L.PacketSeen = {}
L.PacketDupWindow = L.Settings.DupWindow or 0.15
L.PacketHooked = false
L.Priority = true
L.PriorityHz = 0
L.PriorityRank = -1
L.PriorityTarget = 1

local RESULT_WORDS = {
    SPAWNED = true, REDEEMED = true, INVALID = true,
    EXPIRED = true, ALREADY = true, FAILED = true,
}

L.Heard = {}
L.HeardMax = 40
L.Channels = 0

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

    local STOP = {
        new = true, code = true, codes = true, released = true, release = true,
        use = true, redeem = true, redeemed = true, the = true, a = true,
        an = true, is = true, now = true, here = true, ["for"] = true, ["and"] = true,
        available = true, out = true, drop = true, dropped = true, alert = true,
        fresh = true, limited = true, time = true, get = true, claim = true,
        free = true, update = true, incoming = true, just = true, live = true,
    }
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

local codeFrom, payloadText, selectArg = L.CodeFrom, L.PayloadText, select

L.NotifyMessage = function(...)
    local first = selectArg(1, ...)
    local primary = type(first) == "string" and first or payloadText(first, 0)
    if not primary then return nil end
    return codeFrom(primary)
end

local clock, defer, protected = os.clock, task.defer, pcall
local packetSeen = L.PacketSeen
local packetDupWindow = L.PacketDupWindow

L.SeenPacket = function(key, now)
    if L.DedupOn == false then return false end
    local previous = packetSeen[key]
    if previous and (now - previous) <= packetDupWindow then return true end
    packetSeen[key] = now
    return false
end

local firedSeen = {}
L.FiredSeen = firedSeen
L.FIRED_TTL = 30

task.spawn(function()
    while true do
        task.wait(30)
        local now = clock()
        local cutoff = now - 30
        for packet, at in pairs(packetSeen) do
            if at < cutoff then packetSeen[packet] = nil end
        end
        local firedCutoff = now - L.FIRED_TTL
        for code, at in pairs(firedSeen) do
            if at < firedCutoff then firedSeen[code] = nil end
        end
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
L.PreviewDelay = 0
L.UIRefreshQueued = false
L.LastPreviewCode = nil

L.RequestUIRefresh = function()
    if L.UIRefreshQueued then return end
    L.UIRefreshQueued = true
    task.delay(L.PreviewDelay, function()
        L.UIRefreshQueued = false
        if L.RefreshAuto then L.RefreshAuto() end
    end)
end

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

L.PostRedeem = function(t0, src, code, ok, reply, timing)
    L.LogHeard(t0, src, code)
    L.LastPreviewCode = code
    L.PreviewFlashUntil = clock() + 1.2
    L.AddHistory(code, ok, timing)
    if L.RefreshAuto then L.RefreshAuto() end
    if L.ReportRedeem then L.ReportRedeem(ok, reply, timing) end
    if L.RefreshPreview then L.RefreshPreview() end
    task.delay(1.25, function()
        if L.RefreshPreview then L.RefreshPreview() end
    end)
end

local logHeard, postFragment, postRedeem, feed =
    L.LogHeard, L.PostFragment, L.PostRedeem, L.Feed
L.PostRedeemBridge = postRedeem

local hotAuto, hotThreshold, hotSkip, hotFilter = false, 1, false, false
local hotGuess = false
local hotArmed, hotInvoke, hotIsEvent = nil, nil, false
local hotFiredTTL = 30
local hotMode = "remote"

L.SyncHot = function()
    if L.SyncBuf then L.SyncBuf() end
    hotMode      = "normal"
    hotFiredTTL  = L.FIRED_TTL or 30
    hotAuto      = L.AutoOn
    hotGuess     = L.GuessCode
    hotThreshold = L.Threshold or 1
    hotSkip      = L.SkipResults
    hotFilter    = L.Mode and L.Mode.filter or false
    hotArmed     = L.Armed
    hotInvoke    = L.ArmedInvoke
    hotIsEvent   = L.ArmedIsEvent
    if L.SyncFast then L.SyncFast() end
end
L.SyncHot()

L.Consume = function(src, piece, packetAt)
    local t0 = packetAt or clock()
    if not piece then return end

    if hotSkip and hotFilter and RESULT_WORDS[piece] then return end

    if not hotAuto then
        defer(logHeard, t0, src, piece)
        return
    end

    local code = piece
    if hotThreshold > 1 then
        code = feed(piece, t0)
        if not code then
            defer(postFragment, t0, src, piece)
            return
        end
    end

    local ok, reply, timing
    local rf, inv = hotArmed, hotInvoke
    if inv and rf and rf.Parent then
        local tCall = clock()
        local pok, a, b
        local fireOnly = hotIsEvent
        if fireOnly then
            pok, a = protected(inv, rf, code)
            if pok then a, b = true, "sent" end
        else
            pok, a, b = protected(inv, rf, code)
        end
        local tDone = clock()
        timing = {client = (tCall - t0) * 1000, server = (tDone - tCall) * 1000,
                  fireOnly = fireOnly or nil}
        L.LastTiming = timing
        if pok then
            L.LastReply = {ok = a, message = b}
            ok, reply = a, b
        else
            ok, reply = nil, tostring(a)
        end
    else
        ok, reply, timing = L.RedeemViaRemote(code, t0, true)
    end

    L.LastDetect = t0
    L.RecentRedeem = t0
    L.LastSource = src
    defer(postRedeem, t0, src, code, ok, reply, timing)
end

local notifyMessage, consume = L.NotifyMessage, L.Consume

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

task.spawn(function()
    for _ = 1, 600 do
        if L.ResolveUIPath() then return end
        task.wait(0.1)
    end
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

    if not resolveUI() then
        task.spawn(function()
            for _ = 1, 600 do
                if resolveUI() then return end
                task.wait(0.1)
            end
        end)
    end
end

do
    local dispatch = L.Dispatch
    local find = string.find
    local fastRemote, fastInvoke, fastIsEvent, fastSafe = nil, nil, false, false
    local fastReady, fastRaw, fastTime = false, true, false
    local sent = {}

    L.SentCodes = sent
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
        fastTime = L.Instrument == true
        fastReady = fastInvoke ~= nil
            and L.AutoOn == true
            and not L.GuessCode
            and (L.Threshold or 1) <= 1
            and L.RedeemPath ~= "both"
        L.FastRemote, L.FastInvoke, L.FastReady = fastRemote, fastInvoke, fastReady
        if not dispatch then dispatch = L.Dispatch end
    end
    L.SyncFast()

    task.spawn(function()
        while true do
            task.wait(30)
            table.clear(sent)
        end
    end)

    local function tail(t0, tCall, tDone, text, code, pok, a, b)
        L.TextAt = t0
        if fastTime then
            local us = (tCall - t0) * 1e6
            L.FloorUs = us
            if not L.BestFloorUs or us < L.BestFloorUs then L.BestFloorUs = us end
        end
        if fastIsEvent then a, b = true, "sent" end
        if a == nil then L.OursPending, L.OursAt = code, t0 end
        if L.NotifyRedeem then killFeed(text) end
        rawFire(t0, tCall, tDone, text, code, pok, a, b, fastIsEvent or a == nil)
    end

    L.FastNotify = function(msg, _, _, position)
        if position ~= "Top" then
            if L.OursPending and L.ClaimResult then
                if type(msg) ~= "string" then msg = payloadText(msg, 0) end
                if msg then protected(L.ClaimResult, msg) end
            end
            return
        end
        if not fastReady then
            L.TextAt, L.FloorUs = clock(), nil
            if type(msg) ~= "string" then
                msg = payloadText(msg, 0)
                if not msg then return end
            end
            return dispatch(msg)
        end
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

        local t0, tCall
        if fastTime then t0 = clock() tCall = clock() end
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

    L.FastPath = function(text)
        return L.FastNotify(text, nil, nil, "Top")
    end

    L.BindFast = function()
        if not L.NotifyRemote then return false end
        L.RemoteDetectOn = false
        return L.ConnectNotifyRemote()
    end
    if L.RemoteDetectOn then L.BindFast() end
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

L.PacketHooked = false
L.Priority = false
L.PriorityRank, L.PriorityTarget = 1, 1
L.MyRank = function() return 1 end
L.TakeFirst = function() return true end
L.HookNotifyPacket = function() return L.GuiHooked == true end

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

    if not hookNotify() then
        task.spawn(function()
            for _ = 1, 600 do
                if hookNotify() then return end
                task.wait(0.1)
            end
        end)
    end
end

if not L.HookGui() then
    task.spawn(function()
        for _ = 1, 1200 do
            if L.HookGui() then return end
            RunS.Heartbeat:Wait()
        end
    end)
end

L.Webhook = function() return false end
L.Track = function() end
L.Flush = function() end

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

        local dragging, dragStart, startP
        header.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch then
                dragging = true
                dragStart = input.Position
                startP = frame.Position
                input.Changed:Connect(function()
                    if input.UserInputState == Enum.UserInputState.End then
                        dragging = false
                        savePanel(name)
                    end
                end)
            end
        end)
        UIS.InputChanged:Connect(function(input)
            if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
                or input.UserInputType == Enum.UserInputType.Touch) then
                local d = input.Position - dragStart
                frame.Position = UDim2.new(startP.X.Scale, startP.X.Offset + d.X,
                                           startP.Y.Scale, startP.Y.Offset + d.Y)
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
    local function feedLine(text, color)
        feedOrder = feedOrder + 1
        local l = New("TextLabel", {Size = UDim2.new(1, -4, 0, 13),
            BackgroundTransparency = 1, Text = tostring(text),
            TextColor3 = color, Font = Enum.Font.GothamSemibold, TextSize = 9,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            LayoutOrder = feedOrder, Parent = FeedScroll})
        local n = 0
        local oldest, oldestOrder = nil, math.huge
        for _, c in ipairs(FeedScroll:GetChildren()) do
            if c:IsA("TextLabel") then
                n = n + 1
                if c.LayoutOrder < oldestOrder then
                    oldest, oldestOrder = c, c.LayoutOrder
                end
            end
        end
        if n > 30 and oldest then oldest:Destroy() end
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
        local n = 0
        for _, c in ipairs(ToastHolder:GetChildren()) do
            if c:IsA("TextLabel") then
                n += 1
                if n > 4 then c:Destroy() end
            end
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
