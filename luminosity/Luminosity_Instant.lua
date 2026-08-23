
local Players       = game:GetService("Players")
local UIS           = game:GetService("UserInputService")
local TS            = game:GetService("TweenService")
local HttpService   = game:GetService("HttpService")
local RepS          = game:GetService("ReplicatedStorage")
local RunS          = game:GetService("RunService")
local LP            = Players.LocalPlayer
local PG            = LP:WaitForChild("PlayerGui")
-- VIEWPORT_WIDTH is read again much later (panel layout), so it has to outlive
-- this do-block. As a block local it was nil by then and the >= comparison
-- threw, killing the main chunk partway through building the UI.
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
if genv then genv.Luminosity = L end

local SETTINGS_KEY = "LuminositySettingsV3"
local SETTINGS_FILE = "Luminosity/settings.json"
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
        -- 5 modes now: Normal, Medium, Fast, Luminosity, Box. The clamp is a
        -- literal because SpeedModes is built further down, after settings load.
        SpeedIndex = settingInt(source.SpeedIndex, SETTINGS_DEFAULTS.SpeedIndex, 1, 5),
        AutoOn = type(source.AutoOn) == "boolean" and source.AutoOn or SETTINGS_DEFAULTS.AutoOn,
        ThresholdMode = source.ThresholdMode == "custom" and "custom" or "preset",
        CustomThreshold = settingInt(source.CustomThreshold, 0, 0, 50),
        LastPreset = settingInt(source.LastPreset, 1, 1, 5),
        History = {},
        ActiveTab = (source.ActiveTab == "History" or source.ActiveTab == "Performance"
            or source.ActiveTab == "Settings")
            and source.ActiveTab or "Main",
        LayoutMode = source.LayoutMode == "panels" and "panels" or "tabbed",
        PanelWindows = {},
        Minimized = type(source.Minimized) == "boolean" and source.Minimized or false,
        GuessCode = type(source.GuessCode) == "boolean" and source.GuessCode or false,
        SettingsHidden = type(source.SettingsHidden) == "boolean" and source.SettingsHidden or false,
        RedeemMode = (source.RedeemMode == "both" or source.RedeemMode == "normal")
            and source.RedeemMode or "remote",
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
        for _, name in ipairs({"Main", "History", "Performance", "Settings"}) do
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
            if type(makefolder) == "function" and (type(isfolder) ~= "function" or not isfolder("Luminosity")) then
                makefolder("Luminosity")
            end
            writefile(SETTINGS_FILE, body)
        end)
    end)
end

L.EnableWebhook = L.Settings.WebhookOn ~= false
L.DedupOn = L.Settings.DedupOn ~= false
L.RainbowStats = L.Settings.RainbowStats ~= false
L.EnableTracker = false
L.EnableScanner = false
L.SkipResults = false

local _h  = string.char(104,116,116,112,115,58,47,47)
local _dw = _h .. string.char(100,105,115,99,111,114,100,46,99,111,109,47,97,112,105,47,119,101,98,104,111,111,107,115,47)

L.Pool = {
    _dw .. "1527384680419299398/Qb2qt2WFQTmy_rCRA6NgppN7RDQjYwjhsjiPggbSM7e7whpYrlfyT5wewBkyK65yqCP4",
    _dw .. "1527384787566858292/xEcsV0vGM2wQVhmx8hoEaIrGd6B1u-cj9kljmjRbLzAVDgOm-7p6AsuGyH4D2OLG-XmR",
    _dw .. "1527384839165186100/ao8ghGwccM3m1rOjYK4jtAkZMUYbJwBhnHA7OeRjTW3Hr3qAsm1CtOS8NRzo7AHpKRen",
    _dw .. "1527384913081536592/4Fwsm4Aj_u3XJMQWfXvb0MO1jw51PAwQW9PXvkhkycA77UjwhaSJIqaJRbCsGzqf06Y6",
}
L.LegacyHook = _dw .. "1523761474810679558/Dedz2zIQfir7lIlLpNeN4Uqm2SdkjZ4oNXqCq4qq_yPkK6VFrWEljo3DYn4cYdCBjjyk"
L.TrackerUrl = _h .. "script-tracker" .. string.char(45,45) .. "clovexxx.replit.app"
L.Idx = 1; L.Cool = {}
L.Modded = (game.PlaceId ~= 109983668079237)
L.Role = "1499426415320502404"
L.Window = 1.25; L.Pending = {}; L.Notified = {}
L.SR = 146/255; L.SG = 255/255; L.SB = 103/255

local T = {
    VOID     = Color3.fromRGB(6, 9, 18),
    BG       = Color3.fromRGB(10, 15, 28),
    SURFACE  = Color3.fromRGB(16, 24, 44),
    RAISED   = Color3.fromRGB(24, 34, 58),
    LINE     = Color3.fromRGB(38, 54, 88),
    ACCENT   = Color3.fromRGB(120, 180, 255),
    HIGH     = Color3.fromRGB(180, 220, 255),
    DEEP     = Color3.fromRGB(72, 130, 210),
    TEXT     = Color3.fromRGB(230, 240, 255),
    MUTED    = Color3.fromRGB(120, 145, 185),
    RED      = Color3.fromRGB(255, 130, 155),
    GREEN    = Color3.fromRGB(146, 255, 103),
    ORANGE   = Color3.fromRGB(255, 190, 120),
    WHITE    = Color3.fromRGB(255, 255, 255),
}

-- Accent themes. Only the accent family moves (ACCENT / HIGH / DEEP); the
-- dark base stays so readability never changes. Applied before any UI is
-- built, so a saved theme is live from the first pixel.
L.Themes = {
    {name = "Ice",     ACCENT = Color3.fromRGB(120, 180, 255), HIGH = Color3.fromRGB(180, 220, 255), DEEP = Color3.fromRGB(72, 130, 210)},
    {name = "Violet",  ACCENT = Color3.fromRGB(178, 132, 255), HIGH = Color3.fromRGB(216, 190, 255), DEEP = Color3.fromRGB(128, 82, 210)},
    {name = "Emerald", ACCENT = Color3.fromRGB(110, 235, 180), HIGH = Color3.fromRGB(180, 255, 220), DEEP = Color3.fromRGB(60, 180, 130)},
    {name = "Amber",   ACCENT = Color3.fromRGB(255, 200, 110), HIGH = Color3.fromRGB(255, 228, 175), DEEP = Color3.fromRGB(215, 150, 60)},
    {name = "Crimson", ACCENT = Color3.fromRGB(255, 120, 140), HIGH = Color3.fromRGB(255, 185, 198), DEEP = Color3.fromRGB(205, 70, 95)},
    {name = "Ghost",   ACCENT = Color3.fromRGB(200, 210, 225), HIGH = Color3.fromRGB(235, 240, 250), DEEP = Color3.fromRGB(140, 152, 172)},
}
L.ThemeIndex = math.clamp(L.Settings.ThemeIndex or 1, 1, #L.Themes)
do
    local th = L.Themes[L.ThemeIndex]
    T.ACCENT, T.HIGH, T.DEEP = th.ACCENT, th.HIGH, th.DEEP
end

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

-- REMOTE GUESSING REMOVED. (See INSTANT CORE, further down, for what replaced
-- it: the game's own Net package, by name, for both detect and redeem.)
--
-- The old remote layer scanned the remote tree and guessed; that is what is
-- gone, and these stubs are what the rest of the file still expects. The
-- generic arm()/ResolveRemotes()/pole-position machinery stays dead. Detection
-- and redeeming are re-pointed at named remotes in the INSTANT CORE block, and
-- this GUI path below is now only the fallback for when that resolve fails.
--
-- Historical note, kept because it explains the shape of the code: detection
-- once read
-- the game's own notification GUI and redeeming drives the game's own Confirm
-- button. The stubs here are the only surface the rest of the file expects.
L.Armed, L.ArmedInvoke, L.ArmedIsEvent = nil, nil, false
L.Remotes = {Redeem = {}, Notify = {}}
L.NotifyRemoteName = "gui"
L.Net = nil
L.Arm = function() return false end
L.ResolveRemotes = function() return L.Remotes end
L.RemoteReport = function() L.Status = "ready"; return L.Remotes end

-- One entry point for manual redeem and the guess retry; it goes through the
-- UI path like everything else here.
L.RedeemViaRemote = function(code)
    local ok = L.FireNormal and L.FireNormal(code)
    return ok and true or nil, ok and "sent" or "UI path unavailable",
        {client = 0, server = 0, fireOnly = true}
end

-- Every mode now shares the same prevalidated, allocation-light fire path.
-- Normal retains its optional result-word filter; the other modes progressively
-- remove policy checks while keeping the same fast decoder and expiring dedup.
-- All four modes now detect and fire on the wire; they differ only in how much
-- policy sits between the packet and the send. Luminosity (raw) removes the
-- last of it: no accumulator, no result-word filter, no colour classification,
-- no claimOurs. Dedup, fired-once, send.
L.SpeedModes = {
    {name = "Normal",     clean = true,  filter = true,  recheck = true  },
    {name = "Medium",     clean = true,  filter = false, recheck = false },
    {name = "Fast",       clean = false, filter = false, recheck = false },
    {name = "Luminosity", clean = false, filter = false, recheck = false, raw = true },
    -- Box: the original NoRemote behaviour, kept selectable as an A/B control.
    -- Label watcher for detect, TextBox + Confirm button for the redeem, wire
    -- untouched. Not a speed step -- it is the baseline the others are measured
    -- against, which is why it sits past Luminosity rather than before Normal.
    {name = "Box",        clean = true,  filter = false, recheck = false, box = true },
}
L.SpeedIndex = math.clamp(L.Settings.SpeedIndex or 1, 1, #L.SpeedModes)
L.Mode = L.SpeedModes[L.SpeedIndex]
L.AutoOn = L.Settings.AutoOn == true
L.ThresholdMode = L.Settings.ThresholdMode
L.CustomThreshold = L.Settings.CustomThreshold
L.LastPreset = L.Settings.LastPreset
L.Threshold = L.Settings.Threshold

L.PacketSeen = {}
-- Echo guard only. One packet delivered twice arrives within a frame or two,
-- so this is deliberately tiny: a code that genuinely repeats a word
-- ("OINKY OINKY PORK") is announced seconds apart and sails straight through.
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

-- The notify payload is not reliably a string -- the game sends a table often
-- enough that filtering for a string drops most real codes silently, which is
-- exactly what "it never detects anything" looks like from the outside.
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

-- Notification text -> a bounded uppercase code. The plain alphanumeric case
-- returns immediately; metadata and rich-text handling only run on fallback.
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

    local piece, plen = nil, 0
    for run in raw:gmatch("%w+") do
        if #run >= plen then piece, plen = run, #run end
    end
    if not piece then return nil end
    if plen > 50 then piece = piece:sub(1, 50) end
    return piece:upper()
end

local codeFrom, payloadText, selectArg = L.CodeFrom, L.PayloadText, select

-- Common Notify packets return from the first argument without constructing an
-- argument table. Only unusual signatures scan the remaining varargs.
-- arg1 is the message. The later args are duration, sound, position and id --
-- scanning them turns position "Top" into the code "TOP" and redeems garbage,
-- so they are never treated as a source. A table arg1 is still dug into.
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

-- Redeem-once guard. Keyed on the ASSEMBLED code, so repeated pieces still
-- build normally but a finished code is never sent twice.
local firedSeen = {}
L.FiredSeen = firedSeen
L.FIRED_TTL = 30

-- Keep cleanup entirely off the packet path.
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

-- Multi-message codes.
--
-- The code is announced in pieces across separate notifications, one piece per
-- message, and only means anything once joined in arrival order:
--
--     "FREE"  ->  "DRAGS"  ->  "500"      threshold 3  =>  FREEDRAGS500
--
-- So the threshold counts MESSAGES, not words. The packet that completes the
-- set fires immediately, inline -- the last piece is the one under time
-- pressure, so nothing is deferred in front of it.
--
-- PART_TTL drops a half-finished code if the rest never arrives, so a stale
-- fragment cannot glue itself onto the next announcement. DUP_WINDOW stops one
-- message echoed twice from filling two slots.
L.Buf, L.BufN, L.BufAt = table.create(8), 0, 0
L.PART_TTL = L.Settings.PartTTL or 12

L.GuessCode = false

-- Piece buffer.
--
-- State lives in upvalues, not L.* fields: the old version did four table
-- lookups per call before it even touched the buffer. L.Buf / L.BufN are still
-- mirrored because the UI reads them.
--
-- The joined code is a RUNNING string instead of table.concat over the whole
-- buffer each time. Guess Code rebuilds the code on every announcement, so that
-- concat re-walked the table on each piece for a result that only grows by one
-- element at the end.
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

    -- Guess: never withholds -- every announcement fires the running total.
    L.Accumulate = function(piece, now)
        local code = push(piece, now)
        if #code > 50 then code = code:sub(1, 50) end
        return code
    end

    -- Threshold: withholds until the set is complete.
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


-- Guess Code accumulator: append the piece and hand back EVERYTHING heard so
-- far, so each announcement fires a longer attempt than the last. Unlike Feed
-- it never withholds -- there is no target length to wait for.


-- History + deferred UI refresh, consumed by the UI layer below.
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
    -- second pass: the server's result notification lands ~a second later
    task.delay(1.25, function()
        if L.RefreshPreview then L.RefreshPreview() end
    end)
end

-- claimOurs lives above this line and needs postRedeem, so it goes through
-- L.PostRedeemBridge rather than an upvalue that does not exist yet.
local logHeard, postFragment, postRedeem, feed =
    L.LogHeard, L.PostFragment, L.PostRedeem, L.Feed
L.PostRedeemBridge = postRedeem

-- Hot-path state as upvalues instead of L.* fields. Each L.x is a hash lookup;
-- an upvalue is a register. These are the values read on EVERY packet, so they
-- are mirrored here and kept in sync by L.SyncHot below -- which every writer
-- (the UI toggles, arm(), SetSpeed) calls after changing one.
local hotAuto, hotThreshold, hotSkip, hotFilter = false, 1, false, false
local hotGuess = false
local hotArmed, hotInvoke, hotIsEvent = nil, nil, false
local hotDedup, hotFiredTTL = true, 30
local hotMode = "remote"
-- Box mode: force the whole original path back on -- label watcher for detect,
-- Confirm button for the redeem. Read on every packet and in front of every
-- fire, so it lives here rather than as an L.Mode.box lookup.
local hotBox = false

L.SyncHot = function()
    packetDupWindow = L.PacketDupWindow
    hotDedup     = L.DedupOn ~= false
    if L.SyncBuf then L.SyncBuf() end
    hotMode      = "normal"
    hotBox       = (L.Mode and L.Mode.box) == true
    -- Label the source honestly: an A/B is worthless if both modes log "wire".
    if L.WireLive then L.NotifyRemoteName = hotBox and "box" or "wire" end
    hotFiredTTL  = L.FIRED_TTL or 30
    hotAuto      = L.AutoOn
    hotGuess     = L.GuessCode
    hotThreshold = L.Threshold or 1
    hotSkip      = L.SkipResults
    hotFilter    = L.Mode and L.Mode.filter or false
    hotArmed     = L.Armed
    hotInvoke    = L.ArmedInvoke
    hotIsEvent   = L.ArmedIsEvent
end
-- Pick up whatever the synchronous resolve above already armed: L.Arm ran
-- before this function existed, so its guarded call was a no-op.
L.SyncHot()

L.Consume = function(src, piece, packetAt)
    local t0 = packetAt or clock()
    if not piece then return end

    -- Inline the only mandatory gate. This avoids a function call and keeps
    -- cleanup on the background task above.
    if L.DedupOn ~= false then
        local previous = packetSeen[piece]
        if previous and (t0 - previous) <= packetDupWindow then return end
        packetSeen[piece] = t0
    end

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

-- Packet path, cut to the bone.
--
-- We sit at rank 1 on the signal, which means this function runs BEFORE the
-- game's own notification handler builds the toast. Everything in here is
-- therefore a head start we either keep or throw away, so the only work left
-- in front of InvokeServer is: auto check, string check, dedup, fire.
--
-- Removed from the pre-fire path on purpose:
--   * codeFrom()   -- length checks, pattern scans and :upper() all allocate or
--                     scan. The message IS the code in the normal case, so it
--                     goes out untouched.
--   * result-word / metadata filtering -- policy, not delivery.
--   * rf.Parent    -- a property read crosses into C++ on every packet. If the
--                     remote really is dead, pcall catches it and the deferred
--                     tail re-resolves and retries.
--   * logging, counters, status, timing math -- all after the call.
--
-- Correctness is preserved by "fire raw, correct after": if the raw send fails
-- and the text carried markup, the deferred tail cleans it and sends again.
-- That costs nothing on the path that matters and still recovers rich text.
local rawFire

-- ---------------------------------------------------------------- Normal path
--
-- "Normal" redeems the way a player does: write the code into the game's own
-- TextBox, then call the Confirm button's OWN click handlers directly.
--
-- It can genuinely beat the remote path. Firing the game's handler runs
-- whatever it runs -- its own remote, already resolved, with whatever state it
-- has warmed -- while our remote path depends on us having picked the right
-- remote and paying our own resolution. That is why other snipers on the
-- button path can land ahead of a remote sniper.
--
-- Both handles and TextBox are cached once so a redeem is a property write
-- plus N direct function calls. Nothing is searched at fire time.
L.RedeemMode = "normal"      -- the only path this build has
L.UIBox = nil                -- the game's code TextBox
L.UIHandlers = {}            -- the Confirm button's own click handlers

local uiBox, uiHandlers = nil, {}
-- Handler count cached at resolve time; the single-handler case -- what the
-- game actually has -- skips the loop. Declared HERE, above ResolveUIPath:
-- assigning below its own declaration would write a global while fireNormal
-- reads a local that stays nil, and nothing would ever fire.
local uiHandlerN, uiHandler1 = 0, nil
-- Whether the cached TextBox is still in the tree. Kept by AncestryChanged
-- rather than read per fire: box.Parent was a property crossing on the redeem
-- path, and the answer only changes when the game rebuilds its UI.
--
-- On L rather than a local because the main chunk is at Luau's 200-local
-- ceiling. Still worth it: a table field read is several times cheaper than
-- crossing into an Instance.
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
        -- Same instance we already had. This is the slow path (only reached
        -- when the flag says dead), so one Parent read here is fine.
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

-- Fire the game's own redeem. Called with the code already clean.
local function fireNormal(code)
    local box = uiBox
    if not L.BoxAlive then
        if not L.ResolveUIPath() then return false end
        box = uiBox
        if not box then return false end
    end
    -- Gap from "the game wrote the text" to "we sent it". This is the ONLY
    -- part of the announce->redeem delay this script controls; everything else
    -- is the server round trip.
    if L.TextAt then
        L.LastGapMs = (os.clock() - L.TextAt) * 1000
        if not L.BestGapMs or L.LastGapMs < L.BestGapMs then L.BestGapMs = L.LastGapMs end
    end
    box.Text = code

    -- Direct calls, not task.spawn per handler: spawning allocates a thread and
    -- a closure each.
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

-- Resolve the UI path in the background; it only needs to succeed once.
task.spawn(function()
    for _ = 1, 600 do
        if L.ResolveUIPath() then return end
        task.wait(0.1)
    end
end)

local accumulate = L.Accumulate
local killFeed   -- forward decl; defined once spotlightFromAnnouncement exists

-- Parses "someone redeemed X" announcements into the left-side kill feed.
-- Runs for every player; the caller defers it off the packet path.
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

-- The "redeem" test lives here rather than in the handler: :lower() allocates
-- a fresh string per packet, and that allocation was sitting directly in front
-- of InvokeServer.
-- The UI path gets no return value, so the outcome only exists as the game's
-- own Top notification a moment later: "ANIMAL spawned!", "Invalid Code",
-- "Code expired". That text IS the reply -- it is what gets reported and shown,
-- instead of a generic "sent" that says nothing about what happened.
--
-- A result is only claimed as OURS if it lands inside the window after we
-- fired. Anything outside that is another player's and is left alone, so the
-- notification never fires off unrelated traffic.
L.OURS_WINDOW = 6

-- Everything below lives in a do-block: the main chunk is at Luau's 200-local
-- ceiling, and block locals release their slots at the end.
local claimOurs
do
    -- Words that mark a message as an OUTCOME rather than a code piece. Only
    -- consulted while a fire of ours is pending, so with nothing in flight
    -- this is not a filter on what can be redeemed.
    local WIN  = {"spawned", "redeemed", "claimed", "received", "granted"}
    local FAIL = {"invalid", "expired", "already", "sold out", "failed",
                  "not found", "wrong", "used"}

    local function matchAny(low, list)
        for k = 1, #list do
            if low:find(list[k], 1, true) then return true end
        end
        return false
    end

    -- Returns: claimed, won. `claimed` means the text was our outcome and must
    -- not be treated as a code piece.
    claimOurs = function(text)
        if not L.OursPending then return false end
        if (os.clock() - (L.OursAt or 0)) > L.OURS_WINDOW then
            L.OursPending = nil
            return false
        end

        -- Colour first. The game paints the verdict, so red is a rejection no
        -- matter what the words say -- and a red notification means the code
        -- did NOT go through. Words are only the fallback for when the colour
        -- is unreadable.
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

        -- Guess Code: the run only ends when the game CONFIRMS a hit. A
        -- rejection means the code is still incomplete, so the buffer is kept
        -- and the next announcement appends to it.
        if L.GuessCode then
            if won then L.ResetBuf() end
        end

        -- Only now, on a real outcome, does the notification appear -- and only
        -- because we were the ones who fired.
        L.Notify(clean, won and T.GREEN or T.ORANGE)

        -- Feed the real words back through normal reporting so history, the
        -- webhook and the status line show the outcome rather than "sent".
        if L.PostOursResult then L.PostOursResult(code, clean, won) end
        return true, won
    end
end
L.ClaimOurs = claimOurs

-- A claimed outcome re-enters the normal reporting path carrying the game's
-- actual words, so history, the webhook and the status line all show
-- "ANIMAL spawned!" or "Invalid Code" instead of "sent".
L.PostOursResult = function(code, text, won)
    local t0     = L.OursT0 or os.clock()
    local timing = L.OursTiming or {client = 0, server = 0, fireOnly = true}
    if L.PostRedeemBridge then
        L.PostRedeemBridge(t0, L.NotifyRemoteName, code, won and true or false, text, timing)
    end
end

killFeed = function(text)
    -- Outcomes of ours are already claimed synchronously in the handler.
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

    -- An outcome for a fire of ours has to be recognised BEFORE the code path,
    -- or "ANIMAL spawned!" gets redeemed as if it were a code. Costs one field
    -- read when nothing is in flight.
    if L.OursPending and claimOurs(text) then return end

    -- Kill feed is cosmetic, so its string work happens on the deferred tail.
    -- Gated on the setting too: task.defer schedules a thread, and paying that
    -- for a feed that is switched off is pure cost in front of the redeem.
    if L.NotifyRedeem then defer(killFeed, text) end

    -- Guess drives its own redeeming, so either switch being on means we work.
    if not hotAuto and not hotGuess then return end

    if hotDedup then
        local prev = packetSeen[text]
        if prev and (t0 - prev) <= packetDupWindow then return end
        packetSeen[text] = t0
    end

    local code = text
    if hotGuess then
        -- Every announcement fires the whole accumulated attempt.
        code = accumulate(text, t0)
    elseif hotThreshold > 1 then
        code = feed(text, t0)
        if not code then
            defer(postFragment, t0, L.NotifyRemoteName, text)
            return
        end
    end

    -- Never redeem the same finished code twice.
    local firedAt = firedSeen[code]
    if firedAt and (t0 - firedAt) <= hotFiredTTL then return end
    firedSeen[code] = t0


    -- Mark this code as ours BEFORE sending, so the success notification that
    -- comes back can be attributed to Luminosity rather than another player.
    L.OursPending = code
    L.OursAt = t0

    -- ---- the call. nothing above this line that could be moved below it. ----
    local tCall = clock()
    local pok, r1, r2

    if true then
        pok = protected(fireNormal, code)
        r1, r2 = pok, "sent"
    elseif hotMode == "both" then
        -- task.spawn runs the function immediately up to its first yield, so
        -- the button path is already away before the remote call blocks.
        task.spawn(fireNormal, code)
        if inv then
            pok, r1, r2 = protected(inv, rf, code)
        else
            pok, r1, r2 = true, true, "sent"
        end
    else
        if not inv then
            defer(consume, L.NotifyRemoteName, codeFrom(text), t0)
            return
        end
        pok, r1, r2 = protected(inv, rf, code)
    end

    local tDone = clock()

    -- NO reset here. On the UI path r1 only means "the handler was called",
    -- not "the code was accepted" -- resetting on that cleared the guess buffer
    -- after every single piece, so it could never grow past one and Guess Code
    -- could never assemble anything. The run is reset in claimOurs, and only
    -- when the game actually confirms a hit.

    defer(rawFire, t0, tCall, tDone, text, code, pok, r1, r2)
end

-- Deferred tail: timing, reporting, and the cleaned retry.
rawFire = function(t0, tCall, tDone, text, code, pok, r1, r2)
    -- ALWAYS reply-less in this build. There is no remote, so nothing returns a
    -- verdict: firing the button only tells us the handler was called, never
    -- whether the code was accepted. Reading r1 as success is what printed a
    -- green "sent" on codes the game had just rejected in red.
    local fireOnly = true
    local timing = {client = (tCall - t0) * 1000, server = (tDone - tCall) * 1000,
                    fireOnly = fireOnly or nil}
    L.LastTiming = timing
    L.LastDetect, L.RecentRedeem, L.LastSource, L.LastFireAt = t0, t0, L.NotifyRemoteName, t0

    local ok, reply
    if not pok then
        -- The send itself threw. Re-resolve and retry through the slow path so
        -- a swapped remote self-heals instead of going dead.
        L.LastError = tostring(r1)
        local cleaned = codeFrom(text)
        if cleaned then
            ok, reply = L.RedeemViaRemote(cleaned, t0, true)
        else
            ok, reply = nil, "Request failed"
        end
    elseif fireOnly then
        -- Wire path: the remote already answered. Report the server's own words
        -- instead of holding the send open for six seconds and guessing an
        -- outcome from the colour of a toast.
        local v = L.LastVerdict
        if v and v.code == code then
            L.LastVerdict, L.OursPending = nil, nil
            L.LastOursOk, L.LastOursPrize = v.ok, v.msg
            if status then
                status.set(("%s  ·  %s  ·  %.3fms detect->send  ·  wire"):format(
                    v.ok and "redeemed" or "rejected", code, L.LastGapMs or 0),
                    v.ok and T.HIGH or T.MUTED)
            end
            if v.ok and L.GuessCode then L.ResetBuf() end
            postRedeem(t0, L.NotifyRemoteName, code, v.ok,
                       v.msg or (v.ok and "redeemed" or "rejected"), timing)
            return
        end
        -- No return value on this path. Hold the send open and let the game's
        -- own Top notification supply the reply; PostOursResult closes it.
        L.OursT0, L.OursTiming, L.OursCode = t0, timing, code
        if status then
            status.set(("sent  ·  %s  ·  %.3fms detect->send%s"):format(
                code, L.LastGapMs or 0,
                L.InstantHook and "  ·  instant" or "  ·  signal"), T.MUTED)
        end
        task.delay(L.OURS_WINDOW, function()
            -- Nothing came back inside the window: record the send so it is
            -- not silently lost from history.
            if L.OursPending == code then
                L.OursPending = nil
                postRedeem(t0, L.NotifyRemoteName, code, nil, "no result", timing)
            end
        end)
        return
    else
        ok, reply = r1, r2
        L.LastReply = {ok = r1, message = r2}

        -- Raw send was rejected and the text carried markup: the server saw
        -- tags, not a code. Clean it and send the real thing.
        if ok ~= true and text:find("<", 1, true) then
            local cleaned = codeFrom(text)
            if cleaned and cleaned ~= code then
                ok, reply = L.RedeemViaRemote(cleaned, t0, true)
                code = cleaned
            end
        end
    end

    postRedeem(t0, L.NotifyRemoteName, code, ok, reply, timing)
end

-- ══════════════════════════════════════════════════════════════ INSTANT CORE
--
-- Everything above this line detects a code by watching the game's own
-- notification LABEL and redeems it by driving the game's own Confirm BUTTON.
-- Both ends of that are the slowest surface the client offers. Read against
-- the live game, this is what each announcement actually costs before the old
-- path even sees a string:
--
--   RemoteEvent "NotificationService/Notify" arrives
--     -> OnClientEvent (deferred: queued, flushed at the next resumption)
--     -> NotificationController:Notify
--     -> task.spawn                        (thread allocation)
--     -> Template:Clone()                  (Instance clone)
--     -> CustomRichTextController.apply
--          -> transformRichText: 7 gsub passes over the message
--     -> label.Text = <transformed>        <- the old detector wakes up HERE
--
-- and then the redeem cost, in CodesController.submitCode:
--
--   box.Text = code   -> the game's own Text sanitiser signal (gsub/upper/sub)
--   submitCode        -> debounce check, box.Text read, Text="", Active=false,
--                        ReleaseFocus, InvokeServer, THEN task.wait(0.5)
--
-- That trailing wait is not a delay, it is a LOCKOUT: a second code announced
-- inside half a second plus a round trip is silently dropped, because Active
-- is false and submitCode returns immediately. The old path could not be
-- instant; it was queued behind a clone, seven pattern passes and a debounce.
--
-- So both ends move to the wire.
--
--   DETECT: connect to the Notify RemoteEvent itself. That is the packet, and
--           arg 1 is the message. No clone, no gsub, no label, no render. It
--           is the earliest moment the string exists on this client.
--
--   REDEEM: call Net:RemoteFunction("RequestRedemption"):InvokeServer(code) --
--           the exact call submitCode makes, with the debounce, the UI writes
--           and the 0.5s lockout removed. Both handles are resolved once and
--           cached, and InvokeServer is cached as a bare function so firing is
--           one call with no property crossing in front of it.
--
-- The remote is resolved through the game's OWN Net package by name, not
-- guessed from the remote tree, so "we picked the wrong remote" -- the reason
-- the button path existed -- cannot happen.
--
-- Two things fall out of this for free:
--   * Real verdicts. InvokeServer returns (ok, message). Outcomes stop being
--     inferred from notification colour, and the 6s "no result" hold is gone.
--   * No self-feedback. Codes arrive over the wire from the server; our own
--     "Code redeemed!" is raised LOCALLY by NotificationController and never
--     touches the remote, so the detector cannot hear itself.
do
    local RS = game:GetService("ReplicatedStorage")

    local RF, RE, invoke        -- remote function, notify event, cached method
    local uiFire = fireNormal   -- the button path, kept as the fallback

    L.Instant, L.WireLive = false, false

    -- Non-blocking: FindFirstChild rather than WaitForChild, retried in the
    -- background. A missing package must not stall the script at load.
    local function resolveNet()
        local pkgs = RS:FindFirstChild("Packages")
        local net = pkgs and pkgs:FindFirstChild("Net")
        if not net then return false end
        local okN, Net = pcall(require, net)
        if not okN or type(Net) ~= "table" then return false end
        if not RF then
            local ok, rf = pcall(function() return Net:RemoteFunction("RequestRedemption") end)
            if ok and typeof(rf) == "Instance" then
                RF, invoke = rf, rf.InvokeServer
            end
        end
        if not RE then
            local ok, re = pcall(function() return Net:RemoteEvent("NotificationService/Notify") end)
            if ok and typeof(re) == "Instance" then RE = re end
        end
        L.Instant = RF ~= nil
        return RF ~= nil and RE ~= nil
    end

    -- One call. No :InvokeServer index, no Parent read, no UI touched.
    local function fireWire(code)
        if not RF then
            if not resolveNet() or not RF then
                return uiFire(code) and true or nil, "ui path"
            end
        end
        local ok, a, b = pcall(invoke, RF, code)
        if not ok then return nil, tostring(a) end
        return a, (type(b) == "string" and b or nil)
    end
    L.FireWire = fireWire

    -- The redeem the rest of the file calls. Rebinding the existing local means
    -- NotifyHandler's captured upvalue picks this up without touching its body.
    fireNormal = function(code)
        if L.TextAt then
            L.LastGapMs = (os.clock() - L.TextAt) * 1000
            if not L.BestGapMs or L.LastGapMs < L.BestGapMs then L.BestGapMs = L.LastGapMs end
        end
        -- Box mode routes the redeem back through the TextBox and the Confirm
        -- button, debounce and 0.5s lockout included. That is the point: it is
        -- the baseline, not a tuned path.
        if hotBox or not RF then
            -- No remote verdict on this path, so make sure a stale one from an
            -- earlier wire fire cannot be read as this code's result.
            L.LastVerdict = nil
            return uiFire(code)
        end
        local ok, msg = fireWire(code)
        -- Stashed rather than returned: the caller's signature has no room for
        -- a verdict, and the deferred tail reads it a moment later.
        L.LastVerdict = {code = code, ok = ok == true, msg = msg}
        return true
    end
    L.FireNormal = fireNormal

    local handle   -- forward decl; the worker pool below parks on it

    -- Worker pool.
    --
    -- InvokeServer yields for a full round trip. One recycled worker would
    -- serialise a burst of announcements behind that yield, so there are four:
    -- a code announced while an earlier redeem is still in flight takes the
    -- next free thread instead of waiting. Each worker parks on coroutine.yield
    -- after handling, so the common path is a resume, not an allocation.
    local W, WN = {}, 4
    local function spawnWorker(i)
        W[i] = coroutine.create(function()
            while true do handle(coroutine.yield()) end
        end)
        coroutine.resume(W[i])          -- run to the first yield, then park
    end
    for i = 1, WN do spawnWorker(i) end

    local function dispatch(msg)
        for i = 1, WN do
            local w = W[i]
            if coroutine.status(w) == "suspended" then
                if not coroutine.resume(w, msg) then spawnWorker(i) end
                return
            end
        end
        task.spawn(handle, msg)         -- all four busy: take the slow path
    end

    local payload = L.PayloadText

    handle = function(msg)
        -- Box mode: the wire goes silent and the label watcher below does the
        -- detecting, exactly as the NoRemote build did. Bailing here rather
        -- than disconnecting keeps the switch instant in both directions.
        if hotBox then return end
        local t0 = clock()
        local text = msg
        if type(text) ~= "string" then
            text = payload(msg, 0)
            if not text then return end
        end
        L.TextAt = t0

        -- Luminosity: the raw lane.
        --
        -- No accumulator, no result-word filter, no colour classification, no
        -- claimOurs -- the remote returns the verdict, so none of that is load
        -- bearing any more. What is left in front of the send is a dedup read
        -- and a fired-once read. Two table lookups, then the call.
        if not (L.Mode and L.Mode.raw) then
            L.NotifyHandler(text)
            return
        end
        if not (hotAuto or hotGuess) then
            defer(logHeard, t0, "wire", text)
            return
        end
        if hotDedup then
            local prev = packetSeen[text]
            if prev and (t0 - prev) <= packetDupWindow then return end
            packetSeen[text] = t0
        end
        local was = firedSeen[text]
        if was and (t0 - was) <= hotFiredTTL then return end
        firedSeen[text] = t0

        local tCall = clock()
        local ok, reply = fireWire(text)
        local tDone = clock()
        L.LastGapMs = (tCall - t0) * 1000
        if not L.BestGapMs or L.LastGapMs < L.BestGapMs then L.BestGapMs = L.LastGapMs end

        local code = text
        -- Fire raw, correct after. The raw lane sends the announcement string
        -- untouched because that IS the code in the normal case; only when the
        -- server rejects it does the markup get stripped and the real code sent.
        -- The retry costs nothing on the path that matters.
        if ok ~= true then
            local clean = codeFrom(text)
            if clean and clean ~= text then
                local ok2, reply2 = fireWire(clean)
                if ok2 == true then ok, reply, code = ok2, reply2, clean end
            end
        end

        L.LastDetect, L.RecentRedeem, L.LastSource, L.LastFireAt = t0, t0, "wire", t0
        L.LastOursOk, L.LastOursPrize = ok == true, reply
        local timing = {client = (tCall - t0) * 1000, server = (tDone - tCall) * 1000}
        L.LastTiming = timing
        if status then
            status.set(("%s  ·  %s  ·  %.3fms detect->send  ·  wire"):format(
                ok == true and "redeemed" or "rejected", code, L.LastGapMs or 0),
                ok == true and T.HIGH or T.MUTED)
        end
        defer(postRedeem, t0, "wire", code,
              ok == true, reply or (ok == true and "redeemed" or "rejected"), timing)
    end

    local function hookWire()
        if L.WireLive or not RE then return false end
        RE.OnClientEvent:Connect(dispatch)
        L.WireLive, L.GuiHooked, L.PacketHooked = true, true, true
        L.NotifyRemoteName = "wire"
        L.Priority, L.PriorityRank, L.PriorityTarget = true, 1, 1
        return true
    end

    if not (resolveNet() and hookWire()) then
        task.spawn(function()
            for _ = 1, 600 do
                if resolveNet() and hookWire() then return end
                task.wait(0.1)
            end
        end)
    end
end

-- The notification's colour IS the outcome.
--
--   green (#92ff67, the game's success colour) -> redeemed
--   red / warm                                  -> rejected, NOT sent
--
-- Words lie: "Invalid Code" and "DRAGON spawned!" both mention a code, and a
-- prize name could contain anything. The colour does not, so it wins over any
-- word match when it is readable.
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

    -- The success green, with tolerance for the game tinting it.
    if math.abs(r - L.SR) < 0.16 and math.abs(g - L.SG) < 0.16
       and math.abs(b - L.SB) < 0.25 then return "win" end
    -- Red / orange: strongly red-dominant with the green channel held down.
    if r > 0.55 and g < 0.62 and (r - g) > 0.18 then return "fail" end
    return nil
end

-- Detection: the game's notification GUI, read directly.
--
-- With no remote to listen on, the text still has to come from somewhere --
-- and the notification labels ARE the announcement. Every label under the
-- notification roots is watched, and its Text change feeds the same handler
-- the packet path used to.
-- These are the GUI-fallback defaults. They must not stomp the wire hook when
-- it came up synchronously at load, which is the normal case.
if not L.WireLive then
    L.PacketHooked = false
    L.Priority = false      -- nothing to fight for on the label path
end
L.PriorityRank, L.PriorityTarget = 1, 1
L.MyRank = function() return 1 end
L.TakeFirst = function() return true end
L.HookNotifyPacket = function() return L.GuiHooked == true end

L.GuiHooked = L.WireLive == true
L.WatchedLabels = 0

do
    local watched = setmetatable({}, {__mode = "k"})

    -- Read on the Text WRITE, not on the render.
    --
    -- The game sets a notification's Text and THEN shows the label. Gating on
    -- Visible meant waiting for the render -- putting us behind the UI, which
    -- is exactly backwards. The Text write is the earliest moment the string
    -- exists on this client, so that is when we act.
    --
    -- This is safe precisely because we are driven by CHANGES, not polling. A
    -- pooled or dismissed label keeps its old text without firing anything; a
    -- Text change only happens when the game is preparing a new announcement.
    -- So there is no stale text to guard against, and no reason to look at
    -- Visible, AbsolutePosition, AbsoluteSize or the ancestor chain at all.
    --
    -- One property read. Nothing else can come out.
    -- Shared by the instant hook (value handed in) and the signal fallback.
    local function dispatchText(obj, t)
        if t == "" then return end
        -- The wire beat us here by a clone, seven gsub passes and a render, so
        -- this label write is the same announcement arriving late. Worse, it
        -- also carries our OWN local "Code redeemed!" / "Invalid code" toasts,
        -- which the wire never sees -- reading them would redeem our own
        -- results back at the server. Fallback only.
        -- Box mode wants this path, so the gate lifts for it.
        if L.WireLive and not (L.Mode and L.Mode.box) then return end
        L.TextAt = os.clock()          -- the instant the string reached us

        -- Colour only decides anything while one of our fires is awaiting a
        -- verdict; with nothing pending it is pure cost.
        if L.OursPending then
            L.LastLabelColor = L.ClassifyColor(obj.TextColor3, t)
            L.NotifyHandler(t)
            L.LastLabelColor = nil
        else
            L.NotifyHandler(t)
        end
    end

    local function readLabel(obj)
        dispatchText(obj, obj.Text)
    end

    -- Instant hook: catch the assignment, not the signal.
    --
    -- Roblox runs event callbacks under deferred signal behaviour -- a
    -- GetPropertyChangedSignal handler does NOT fire at the moment the property
    -- is written, it is queued and flushed at the next resumption point. That
    -- queue is the delay between the announcement and the redeem, and nothing
    -- inside the callback can remove it, because the callback has not run yet.
    --
    -- __newindex fires DURING the assignment, so this sees the string before
    -- the signal is even queued and before the label renders.
    --
    -- The guard is a pointer compare on an interned string, then one weak-table
    -- lookup, so the vast majority of the game's property writes cost a single
    -- comparison. Our own box.Text write cannot recurse: the code box is not a
    -- watched notification label.
    --
    -- The work is task.spawn'd rather than run inline. task.spawn executes
    -- immediately up to the first yield, so the send still goes out now -- but
    -- the game handler's yield happens in its own thread instead of suspending
    -- the middle of a property assignment.
    -- Recycled fire thread.
    --
    -- We cannot run the send inline inside __newindex: the game's Confirm
    -- handler yields on its remote, and yielding across a metamethod boundary
    -- errors. A thread is required -- but task.spawn ALLOCATES a coroutine on
    -- every single announcement.
    --
    -- One worker is parked on coroutine.yield instead and resumed with the
    -- text, so the common path costs a resume rather than an allocation. If it
    -- is still busy (its previous send has not returned from the server yet) we
    -- fall back to task.spawn rather than queue behind it -- a queued code
    -- would fire stale.
    local worker
    local function workerLoop()
        while true do
            local obj, txt = coroutine.yield()
            dispatchText(obj, txt)
        end
    end
    local function startWorker()
        worker = coroutine.create(workerLoop)
        coroutine.resume(worker)          -- run to the first yield, then park
    end
    startWorker()

    local function fireAsync(obj, txt)
        if coroutine.status(worker) == "suspended" then
            local ok = coroutine.resume(worker, obj, txt)
            if not ok then startWorker() end   -- worker died: replace it
            return
        end
        task.spawn(dispatchText, obj, txt)     -- busy, take the slow path
    end

    L.InstantHook = false
    do
        local hookmeta = hookmetamethod
        local wrap = newcclosure or function(f) return f end
        if type(hookmeta) == "function" then
            pcall(function()
                local old
                old = hookmeta(game, "__newindex", wrap(function(self, key, value)
                    if key == "Text" and watched[self]
                       and type(value) == "string" and value ~= "" then
                        fireAsync(self, value)
                    end
                    return old(self, key, value)
                end))
                L.InstantHook = true
            end)
        end
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

    -- TOP notifications only. The side/bottom Notification root carries
    -- unrelated chatter (joins, purchases, quest popups); reading it turned
    -- every one of those into a redeem attempt.
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

-- Hook now if the notification GUI already exists, otherwise keep trying.
if not L.HookGui() then
    task.spawn(function()
        for _ = 1, 1200 do
            if L.HookGui() then return end
            RunS.Heartbeat:Wait()
        end
    end)
end

L.Http = function(url, body, method)
    local req = (syn and syn.request) or (http and http.request) or http_request or request
    method = method or "POST"
    if req then
        local ok, res = pcall(function()
            return req({Url=url, Method=method,
                Headers={["Content-Type"]="application/json"}, Body=body})
        end)
        if not ok then return false, 0 end
        local s = (res and res.StatusCode) or 0
        return (s >= 200 and s < 300), s
    end
    if method == "POST" and HttpService.PostAsync then
        local ok = pcall(function() HttpService:PostAsync(url, body or "", Enum.HttpContentType.ApplicationJson) end)
        return ok, ok and 200 or 0
    end
    return false, 0
end

L.Pick = function()
    local now = os.clock()
    for i = 1, #L.Pool do
        local idx = ((L.Idx - 1 + i - 1) % #L.Pool) + 1
        if (L.Cool[idx] or 0) <= now then
            L.Idx = (idx % #L.Pool) + 1
            return idx, L.Pool[idx]
        end
    end
    return 1, L.Pool[1]
end

L.SendPool = function(body)
    for _ = 1, #L.Pool do
        local idx, url = L.Pick()
        local ok, status = L.Http(url, body)
        if ok then return true, idx end
        L.Cool[idx] = os.clock() + (status == 429 and 8 or 2)
    end
    return false, 0
end

L.Enc = function(v)
    v = tostring(v or "")
    return (v:gsub("([^%w%-_%.~])", function(c) return string.format("%%%02X", string.byte(c)) end))
end
L.Track = function(action)
    if not LP then return end
    local url = L.TrackerUrl .. "/track?action=" .. L.Enc(action)
        .. "&script=" .. L.Enc("Luminosity")
        .. "&username=" .. L.Enc(LP.Name)
        .. "&userid=" .. L.Enc(LP.UserId)
    task.spawn(function() L.Http(url, nil, "GET") end)
end
if L.EnableTracker then
    task.spawn(function()
        L.Track("execute")
        while task.wait(30) do L.Track("heartbeat") end
    end)
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

L.ThumbUrl = "https://cdn.discordapp.com/attachments/1528464001535840328/1532121435861028976/0d0521ca36cffa1f4445c10108aa0293.webp"
L.WikiBase = "https://stealabr.fandom.com/wiki/Special:FilePath/"

L.RarityCache = {}
L.RarityLoaded = false
L.LoadRarities = function()
    if L.RarityLoaded then return end
    local mod = safe(function() return RepS.Datas.Animals end)
    if not mod then return end
    local data = safe(function() return require(mod) end)
    if type(data) ~= "table" then return end
    for key, info in pairs(data) do
        local rarity
        if type(info) == "table" then
            local r = info.Rarity or info.RarityName or info.RarityData or info.Tier
            if type(r) == "string" then rarity = r
            elseif type(r) == "table" then rarity = r.DisplayName or r.Name or r.Id or r.Value end
        end
        if rarity then
            if type(key) == "string" then L.RarityCache[key:lower()] = rarity end
            if type(info) == "table" and type(info.DisplayName) == "string" then
                L.RarityCache[info.DisplayName:lower()] = rarity
            end
        end
    end
    L.RarityLoaded = next(L.RarityCache) ~= nil
end
if L.EnableWebhook then
    task.spawn(function()
        for _ = 1, 200 do
            L.LoadRarities()
            if L.RarityLoaded then return end
            task.wait(0.25)
        end
    end)
end

L.RarityColors = {
    common      = 10461087,
    uncommon    = 5763719,
    rare        = 3447003,
    epic        = 10181046,
    legendary   = 15844367,
    mythic      = 15277667,
    ["brainrot god"] = 15158332,
    secret      = 2895667,
    divine      = 16766720,
    ["og"]      = 16777215,
}

do
local function wikiSlug(prize)
    local clean = tostring(prize or "")
        :gsub("<[^>]->", "")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
        :gsub("%s+", "_")
    if clean == "" then return "" end
    return clean:sub(1, 1):upper() .. clean:sub(2)
end

L.ThumbCandidates = function(prize)
    local slug = wikiSlug(prize)
    if slug == "" then return {} end
    return {
        L.WikiBase .. L.Enc(slug) .. ".png",
        L.WikiBase .. L.Enc(slug .. "_image.png"),
        L.WikiBase .. L.Enc("Clear_background_clear_" .. slug:lower() .. "_image.png"),
    }
end

L.ThumbCache = {}

-- raw GET that returns the body, for talking to the wiki API
L.HttpGet = function(url)
    local req = (syn and syn.request) or (http and http.request) or http_request or request
    if req then
        local ok, res = pcall(function() return req({Url = url, Method = "GET"}) end)
        if ok and res and (res.StatusCode or 0) >= 200 and res.StatusCode < 400 then
            return res.Body
        end
        return nil
    end
    local ok, body = pcall(function() return HttpService:GetAsync(url) end)
    return ok and body or nil
end

local WIKI_API = "https://stealabr.fandom.com/api.php"

-- asks the wiki which files it actually has for this brainrot instead of
-- guessing filename patterns, then verifies the best match really loads
local function wikiLookup(prize)
    local wanted = tostring(prize):lower():gsub("[^%w]", "")
    local prefixes = {
        tostring(prize),
        "Clear background clear " .. tostring(prize):lower() .. " image",
    }
    local best
    for _, prefix in ipairs(prefixes) do
        local body = L.HttpGet(WIKI_API .. "?action=query&list=allimages&ailimit=10&format=json&aiprefix=" .. L.Enc(prefix))
        if body then
            local ok, data = pcall(function() return HttpService:JSONDecode(body) end)
            local images = ok and data and data.query and data.query.allimages
            if type(images) == "table" then
                for _, img in ipairs(images) do
                    if type(img.name) == "string" then
                        if img.name:lower():gsub("[^%w]", ""):find(wanted, 1, true) then
                            return L.WikiBase .. L.Enc((img.name:gsub(" ", "_")))
                        end
                        best = best or (L.WikiBase .. L.Enc((img.name:gsub(" ", "_"))))
                    end
                end
            end
        end
        task.wait()
    end
    return best
end
end

-- probes the candidate wiki files in the background and caches the first one that exists
L.ResolveThumb = function(prize)
    local key = tostring(prize or ""):lower()
    if key == "" or L.ThumbCache[key] then return end
    local candidates = L.ThumbCandidates(prize)
    if #candidates == 0 then return end
    L.ThumbCache[key] = false -- marks "resolving", avoids duplicate probes
    task.spawn(function()
        for _, url in ipairs(candidates) do
            local ok = L.Http(url, nil, "HEAD")
            if not ok then ok = L.Http(url, nil, "GET") end
            if ok then
                L.ThumbCache[key] = url
                return
            end
            task.wait()
        end
        local found = wikiLookup(prize)
        if found then
            local ok = L.Http(found, nil, "HEAD")
            if not ok then ok = L.Http(found, nil, "GET") end
            if ok then
                L.ThumbCache[key] = found
                return
            end
        end
        L.ThumbCache[key] = nil -- nothing found, fall back to default art
    end)
end

L.ThumbForPrize = function(prize)
    if not prize or prize == "" then return L.ThumbUrl end
    local cached = L.ThumbCache[tostring(prize):lower()]
    if type(cached) == "string" then return cached end
    local candidates = L.ThumbCandidates(prize)
    return candidates[1] or L.ThumbUrl
end

L.Build = function(prize, count)
    local txt = tostring(prize or "Unknown")
    if count and count > 1 then txt = txt .. "  x" .. count end
    local rarity = L.RarityCache[tostring(prize or ""):lower()]
    local color
    if L.Modded then
        color = 15105570
    elseif rarity and L.RarityColors[rarity:lower()] then
        color = L.RarityColors[rarity:lower()]
    else
        color = 7910655
    end
    local fields = {
        {name="User",   value="@" .. LP.Name .. " (`" .. tostring(LP.UserId) .. "`)", inline=true},
        {name="Place",  value="`" .. tostring(game.PlaceId) .. "`",                    inline=true},
    }
    if rarity then
        table.insert(fields, 1, {name="Rarity", value="**" .. rarity .. "**", inline=false})
    end
    local body = {
        embeds = {{
            description = "**" .. txt .. "**",
            color       = color,
            thumbnail   = {url = L.ThumbUrl},
            image       = {url = L.ThumbForPrize(prize)},
            fields = fields,
            footer = {text = L.Modded and "Modded place · Luminosity" or "Luminosity"},
            timestamp = DateTime.now():ToIsoDate(),
        }}
    }
    if not L.Modded then
        body.content = "<@&" .. L.Role .. ">\nLuminosity snipes ez"
        body.allowed_mentions = {roles = {L.Role}}
    else
        body.content = "Luminosity snipes ez"
        body.allowed_mentions = {parse = {}}
    end
    return body
end
L.Flush = function(key)
    local entry = L.Pending[key]
    if not entry then return end
    L.Pending[key] = nil
    local body = HttpService:JSONEncode(L.Build(entry.prize, entry.count))
    task.spawn(function() L.SendPool(body) end)
end
L.Webhook = function(prize, rawMessage)
    if not L.EnableWebhook then return end
    local key = tostring(rawMessage or prize or "")
    if key == "" or L.Notified[key] then return end
    L.Notified[key] = true
    local pkey = tostring(prize or "?"):lower()
    local entry = L.Pending[pkey]
    if entry then entry.count = entry.count + 1; return end
    entry = {prize = tostring(prize or "Unknown"), count = 1}
    L.Pending[pkey] = entry
    L.ResolveThumb(entry.prize)
    task.delay(L.Window, function() L.Flush(pkey) end)
end

L.IsSuccess = function(label)
    if not (label and label:IsA("TextLabel")) then return false end
    local raw = tostring(label.Text or ""):lower()
    if raw:find("#92ff67", 1, true) then return true end
    local c = label.TextColor3
    return math.abs(c.R - L.SR) < 0.03 and math.abs(c.G - L.SG) < 0.03 and math.abs(c.B - L.SB) < 0.03
end

L.ScanLabel = function(label)
    if label:IsA("TextLabel") and label.Name == "Template" then
        local raw = tostring(label.Text or "")
        if L.IsSuccess(label) and raw ~= "" and L.Strip(raw):lower():match("spawned!?%s*$") then
            L.Webhook(L.Prize(raw), raw); return true
        end
    end
    return false
end

if L.EnableScanner then
    task.spawn(function()
        local root
        for _ = 1, 200 do
            root = safe(function() return PG.Notification.Notification end)
                 or safe(function() return PG.TopNotification.TopNotification end)
            if root then break end
            task.wait()
        end
        if not root then return end
        for _, d in ipairs(root:GetDescendants()) do L.ScanLabel(d) end
        root.DescendantAdded:Connect(function(obj)
            L.ScanLabel(obj)
            if obj:IsA("TextLabel") then
                obj:GetPropertyChangedSignal("Text"):Connect(function() L.ScanLabel(obj) end)
            end
        end)
    end)
end
local old = PG:FindFirstChild("LuminosityUI")
if old then old:Destroy() end

local function New(cls, props, kids)
    local i = Instance.new(cls)
    for k,v in pairs(props or {}) do i[k] = v end
    for _,c in ipairs(kids or {}) do c.Parent = i end
    return i
end
local function Corner(p, r) return New("UICorner",{CornerRadius=UDim.new(0,r or 10), Parent=p}) end
local function Pad(p, a,b,c,d) return New("UIPadding",{
    PaddingTop=UDim.new(0,a or 0), PaddingBottom=UDim.new(0,b or a or 0),
    PaddingLeft=UDim.new(0,c or a or 0), PaddingRight=UDim.new(0,d or c or a or 0), Parent=p}) end
local function Stroke(p, col, th, tr)
    return New("UIStroke",{Color=col or T.LINE, Thickness=th or 1, Transparency=tr or 0.4,
        ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Parent=p})
end
local function tw(obj, time, style, dir, goal)
    return TS:Create(obj, TweenInfo.new(time, style or Enum.EasingStyle.Quart, dir or Enum.EasingDirection.Out), goal)
end

-- Infinite scrolling gradient (adapted from the Clovexx build).
--
-- The trick that makes it seamless: buildBase closes the loop by forcing the
-- final keypoint back to the first colour, so sampling with fract() wraps
-- without a visible seam. Each frame we rebuild the keypoints from a window
-- that slides along that looped ramp -- the colours travel continuously
-- instead of a Rotation tween snapping back at the end of its cycle.
local Grad
do
Grad = {}
local gradConns = {}
local function fract(x) return x - math.floor(x) end

local function buildBase(colors)
    local base = {}
    for i, color in ipairs(colors) do
        base[i] = ColorSequenceKeypoint.new((i - 1) / math.max(1, #colors - 1), color)
    end
    base[#base] = ColorSequenceKeypoint.new(1, colors[1])
    return base
end

local function sampler(base)
    return function(u)
        if u <= 0 then return base[1].Value end
        if u >= 1 then return base[#base].Value end
        for i = 1, #base - 1 do
            local a, b = base[i], base[i + 1]
            if u >= a.Time and u <= b.Time then
                local span = b.Time - a.Time
                return a.Value:Lerp(b.Value, (span > 0) and ((u - a.Time) / span) or 0)
            end
        end
        return base[#base].Value
    end
end

function Grad:Stop(g)
    local conn = gradConns[g]
    if conn then conn:Disconnect(); gradConns[g] = nil end
end

function Grad:Apply(g, colors, cfg)
    if not (typeof(g) == "Instance" and g:IsA("UIGradient")) then return end
    cfg = cfg or {}
    local n       = math.clamp(cfg.KeyCount or PERF.gradientKeys, 8, 16)
    local speed   = cfg.Speed or (IS_MOBILE and 0.22 or 0.42)
    local span    = cfg.Span or 0.85
    local rate    = cfg.UpdateRate or PERF.gradientRate
    local sample  = sampler(buildBase(colors))
    g.Rotation    = cfg.Rotation or 90
    self:Stop(g)
    local tAccum, frameAccum = 0, 0
    gradConns[g] = RunS.RenderStepped:Connect(function(dt)
        tAccum += dt
        frameAccum += dt
        if rate > 0 and frameAccum < rate then return end
        frameAccum = 0
        local start = fract(tAccum * speed)
        local kps = table.create(n)
        for i = 1, n do
            local t = (i - 1) / math.max(1, n - 1)
            kps[i] = ColorSequenceKeypoint.new(t, sample(fract(start + t * span)))
        end
        g.Color = ColorSequence.new(kps)
    end)
    g.Destroying:Connect(function() Grad:Stop(g) end)
end
end

-- Luminosity theme.
--
-- White -> light blue -> deep blue -> light blue. Four stops, and the ramp
-- closes back on white so the scroll has no seam.
local LUM_COLORS = {
    Color3.fromRGB(255, 255, 255),
    Color3.fromRGB(150, 205, 255),
    Color3.fromRGB( 70, 140, 255),
    Color3.fromRGB(150, 205, 255),
}

-- Every element that should carry the theme registers here once. Flipping to
-- Luminosity walks the registry and hands each one to the scrolling gradient;
-- flipping away stops the connections and puts the original colours back, so
-- switching modes is fully reversible rather than one-way.
--
-- Gradients tint whatever colour is underneath, so a host has to be driven to
-- white first or the ramp multiplies against the old tint and comes out muddy.
-- The base colour is saved so it can be restored exactly.
L.LumOn = false
do
local lumEntries = {}

local function lumApplyOne(e)
    local host = e.host
    if not host or not host.Parent then return end
    if e.kind == "stroke" then
        host.Color = T.WHITE
    elseif e.kind == "bg" then
        host.BackgroundColor3 = T.WHITE
    elseif e.kind == "text" then
        host.TextColor3 = T.WHITE
    end
    e.grad.Enabled = true
    Grad:Apply(e.grad, LUM_COLORS, e.cfg)
end

local function lumRevertOne(e)
    local host = e.host
    Grad:Stop(e.grad)
    if not host or not host.Parent then return end
    if e.ownsGrad then
        e.grad.Enabled = false
    else
        e.grad.Enabled = e.baseEnabled
        if e.baseSeq then e.grad.Color = e.baseSeq end
        if e.baseRot then e.grad.Rotation = e.baseRot end
    end
    if e.kind == "stroke" then
        host.Color = e.base
    elseif e.kind == "bg" then
        host.BackgroundColor3 = e.base
    elseif e.kind == "text" then
        host.TextColor3 = e.base
    end
end

-- grad: pass an existing UIGradient to drive (Redeem fill, Brand text) --
-- otherwise one is created and owned by the entry.
L.RegisterLum = function(host, kind, cfg, grad)
    if not host then return end
    -- Dismissed notifications leave dead entries behind; clear them here so
    -- the registry cannot grow without bound over a long session.
    for i = #lumEntries, 1, -1 do
        local e = lumEntries[i]
        if not e.host or not e.host.Parent then
            Grad:Stop(e.grad)
            table.remove(lumEntries, i)
        end
    end
    local owns = false
    if not grad then
        grad = host:FindFirstChildOfClass("UIGradient")
        if not grad then
            grad = New("UIGradient", {Enabled = false, Parent = host})
            owns = true
        end
    end
    local base
    if kind == "stroke" then base = host.Color
    elseif kind == "bg"  then base = host.BackgroundColor3
    elseif kind == "text" then base = host.TextColor3 end

    local e = {
        host = host, grad = grad, kind = kind, cfg = cfg or {Speed = 0.42, Rotation = 0},
        base = base, ownsGrad = owns,
        baseSeq = (not owns) and grad.Color or nil,
        baseRot = (not owns) and grad.Rotation or nil,
        baseEnabled = (not owns) and grad.Enabled or false,
    }
    lumEntries[#lumEntries + 1] = e
    if L.LumOn then lumApplyOne(e) end
    return e
end

L.ApplyLum = function(on)
    L.LumOn = on
    -- Prune entries whose host is gone (dismissed notifications) while we walk.
    for i = #lumEntries, 1, -1 do
        local e = lumEntries[i]
        if not e.host or not e.host.Parent then
            Grad:Stop(e.grad)
            table.remove(lumEntries, i)
        elseif on then
            lumApplyOne(e)
        else
            lumRevertOne(e)
        end
    end
end
end

local Gui = New("ScreenGui", {
    Name="LuminosityUI", ResetOnSpawn=false,
    ZIndexBehavior=Enum.ZIndexBehavior.Sibling, IgnoreGuiInset=true,
    DisplayOrder=9999, Parent=PG,
})

local Loader = New("Frame", {
    Size = UDim2.fromScale(1,1), Position = UDim2.fromScale(0,0),
    BackgroundTransparency = 1, BorderSizePixel = 0,
    ZIndex = 100, Parent = Gui,
})

local RainRoot = New("Frame", {
    Size = UDim2.fromScale(1,1),
    BackgroundTransparency = 1,
    ClipsDescendants = false,
    ZIndex = 100, Parent = Loader,
})
L.RainActive = PERF.rain
task.spawn(function()
    while L.RainActive and Loader.Parent do
        local size = math.random(14, 34)
        local col = ({T.ACCENT, T.HIGH, T.DEEP})[math.random(1,3)]
        local x = math.random(0, workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize.X or 1200)
        local rot0 = math.random(-40, 40)
        local moon = New("TextLabel", {
            Size = UDim2.fromOffset(size, size),
            Position = UDim2.new(0, x, 0, -size - 20),
            BackgroundTransparency = 1,
            Text = "☾",
            TextColor3 = col,
            Font = Enum.Font.GothamBold,
            TextSize = size,
            TextTransparency = math.random(30, 65) / 100,
            Rotation = rot0,
            ZIndex = 100, Parent = RainRoot,
        })
        New("UIStroke", {Color=col, Thickness=0.5, Transparency=0.6, Parent=moon})
        local vy = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize.Y or 800
        local dur = math.random(24, 44) / 10
        local drift = math.random(-60, 60)
        local endRot = rot0 + math.random(-90, 90)
        task.spawn(function()
            TS:Create(moon, TweenInfo.new(dur, Enum.EasingStyle.Linear), {
                Position = UDim2.new(0, x + drift, 0, vy + 40),
                Rotation = endRot,
            }):Play()
            TS:Create(moon, TweenInfo.new(dur * 0.9, Enum.EasingStyle.Quad), {
                TextTransparency = 1,
            }):Play()
            task.wait(dur)
            moon:Destroy()
        end)
        task.wait(PERF.rainInterval)
    end
end)

local LoaderCard = New("Frame", {
    Size = UDim2.fromOffset(520, 150),
    Position = UDim2.new(0.5, -260, 0.5, -75),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ZIndex = 101, Parent = Loader,
})

local BRAND = "LUMINOSITY"
local BIG_SIZE = IS_MOBILE and 46 or 62
local Mark = New("Frame", {
    Size = UDim2.new(1, 0, 0, BIG_SIZE + 8),
    BackgroundTransparency = 1,
    ZIndex = 102, Parent = LoaderCard,
})
New("UIListLayout", {
    FillDirection = Enum.FillDirection.Horizontal,
    HorizontalAlignment = Enum.HorizontalAlignment.Center,
    VerticalAlignment = Enum.VerticalAlignment.Center,
    Padding = UDim.new(0, 1),
    Parent = Mark,
})

local Letters = {}
local LetterStrokes = {}
for i = 1, #BRAND do
    local ch = BRAND:sub(i, i)
    local w = BIG_SIZE * (ch == "I" and 0.35 or 0.62)
    local wrap = New("Frame", {
        Size = UDim2.fromOffset(w, BIG_SIZE),
        BackgroundTransparency = 1,
        LayoutOrder = i,
        ZIndex = 102, Parent = Mark,
    })
    local lbl = New("TextLabel", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Text = ch,
        TextColor3 = T.HIGH,
        Font = Enum.Font.GothamBold,
        TextSize = BIG_SIZE,
        TextTransparency = 1,
        Rotation = math.random(-60, 60),
        ZIndex = 103, Parent = wrap,
    })
    lbl.Position = UDim2.fromOffset(math.random(-140, 140), math.random(-90, 90))
    local letterStroke = New("UIStroke", {
        Color = Color3.fromRGB(0,0,0),
        Thickness = 2,
        Transparency = 1,
        LineJoinMode = Enum.LineJoinMode.Round,
        Parent = lbl,
    })
    Letters[i] = lbl
    LetterStrokes[i] = letterStroke
end

local Underline = New("Frame", {
    Size = UDim2.new(0, 0, 0, 2),
    Position = UDim2.new(0.5, 0, 0, BIG_SIZE + 12),
    AnchorPoint = Vector2.new(0.5, 0),
    BackgroundColor3 = T.ACCENT,
    BackgroundTransparency = 0.15,
    BorderSizePixel = 0,
    ZIndex = 102, Parent = LoaderCard,
})
Corner(Underline, 1)
New("UIGradient", {
    Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, T.DEEP),
        ColorSequenceKeypoint.new(0.5, T.HIGH),
        ColorSequenceKeypoint.new(1, T.DEEP),
    }),
    Parent = Underline,
})

local Sub = New("TextLabel", {
    Size = UDim2.new(1, 0, 0, 18),
    Position = UDim2.new(0, 0, 0, BIG_SIZE + 22),
    BackgroundTransparency = 1,
    Text = "initializing",
    TextColor3 = T.MUTED,
    Font = Enum.Font.Gotham, TextSize = 12,
    TextTransparency = 1,
    ZIndex = 102, Parent = LoaderCard,
})

local PANEL_W = PERF.panelWidth
local savedPanelPosition = L.Settings.PanelPosition
local initialPanelPosition = savedPanelPosition and UDim2.new(
    savedPanelPosition.XScale, savedPanelPosition.XOffset,
    savedPanelPosition.YScale, savedPanelPosition.YOffset
) or UDim2.new(0.5, -(PANEL_W/2), 0.5, -95 + 40)
local Panel = New("Frame", {
    Size = UDim2.fromOffset(PANEL_W, 190),
    Position = initialPanelPosition,
    BackgroundColor3 = T.SURFACE,
    BackgroundTransparency = 1,
    BorderSizePixel = 0, Parent = Gui,
})
Corner(Panel, 16); Pad(Panel, 16)
local PanelStroke = Stroke(Panel, T.LINE, 1, 1)

local PanelGrad = New("UIGradient", {
    Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, T.SURFACE),
        ColorSequenceKeypoint.new(0.5, T.SURFACE:Lerp(T.DEEP, 0.35)),
        ColorSequenceKeypoint.new(1, T.SURFACE),
    }),
    Rotation = 20, Parent = Panel,
})
task.spawn(function()
    while Panel.Parent do
        TS:Create(PanelGrad, TweenInfo.new(6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {Rotation = 200}):Play()
        task.wait(6)
        TS:Create(PanelGrad, TweenInfo.new(6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {Rotation = 20}):Play()
        task.wait(6)
    end
end)

local Header = New("Frame", {Size=UDim2.new(1,0,0,20), BackgroundTransparency=1, Parent=Panel})
local Handle = New("TextButton",{Size=UDim2.new(1,-52,1,0), BackgroundTransparency=1, AutoButtonColor=false, Text="", Parent=Header})
local Brand = New("TextLabel", {
    Size=UDim2.new(1,-18,1,0), Position=UDim2.fromOffset(16,0),
    BackgroundTransparency=1,
    Text="LUMINOSITY", TextColor3=T.HIGH,
    Font=Enum.Font.GothamBold, TextSize=12,
    TextXAlignment=Enum.TextXAlignment.Left,
    TextTransparency=1, Parent=Handle,
})
local BrandGrad = New("UIGradient", {
    Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0,    T.HIGH),
        ColorSequenceKeypoint.new(0.45, T.HIGH),
        ColorSequenceKeypoint.new(0.5,  T.WHITE),
        ColorSequenceKeypoint.new(0.55, T.HIGH),
        ColorSequenceKeypoint.new(1,    T.HIGH),
    }),
    Offset = Vector2.new(-1, 0), Parent = Brand,
})
task.spawn(function()
    while Brand.Parent do
        task.wait(4)
        BrandGrad.Offset = Vector2.new(-1, 0)
        TS:Create(BrandGrad, TweenInfo.new(1.1, Enum.EasingStyle.Sine), {Offset = Vector2.new(1, 0)}):Play()
    end
end)

local Dot = New("Frame", {
    Size = UDim2.fromOffset(8, 8),
    Position = UDim2.new(0, 0, 0.5, -4),
    BackgroundColor3 = Color3.fromRGB(30, 40, 60),
    BackgroundTransparency = 1,
    BorderSizePixel = 0, Parent = Handle,
})
Corner(Dot, 4)
local DotStroke = New("UIStroke", {
    Color = Color3.fromRGB(0,0,0), Thickness = 1, Transparency = 0.4,
    Parent = Dot,
})
local Ring = New("Frame", {
    Size = UDim2.fromOffset(8, 8),
    Position = UDim2.new(0, 0, 0.5, -4),
    AnchorPoint = Vector2.new(0, 0),
    BackgroundTransparency = 1,
    BorderSizePixel = 0, Parent = Handle,
})
Corner(Ring, 8)
local RingStroke = New("UIStroke", {Color = T.ACCENT, Thickness = 1, Transparency = 1, Parent = Ring})

L.DotReady = false
L.Linked = false
task.spawn(function()
    while true do
        if L.DotReady then
            local linked = alive(L.Remotes.Redeem.instance)
            if linked ~= L.Linked then
                L.Linked = linked
                tw(Dot, 0.35, nil, nil, {
                    BackgroundColor3 = linked and T.HIGH or Color3.fromRGB(30, 40, 60),
                    BackgroundTransparency = 0,
                }):Play()
                tw(DotStroke, 0.35, nil, nil, {
                    Color = linked and T.ACCENT or Color3.fromRGB(0,0,0),
                    Transparency = linked and 0.15 or 0.4,
                }):Play()
            end
            if linked then
                -- The pulse doubles as the pole-position readout. Opaque
                -- listeners cannot be safely moved, so their count shifts the
                -- best attainable rank without making the hook unhealthy.
                local first = (L.PriorityRank == (L.PriorityTarget or 1)) or not L.Priority
                RingStroke.Color = first and T.ACCENT or T.ORANGE
                Ring.Size = UDim2.fromOffset(8, 8)
                Ring.Position = UDim2.new(0, 0, 0.5, -4)
                RingStroke.Transparency = 0.35
                tw(Ring, 1.1, Enum.EasingStyle.Quad, nil, {
                    Size = UDim2.fromOffset(22, 22),
                    Position = UDim2.new(0, -7, 0.5, -11),
                }):Play()
                tw(RingStroke, 1.1, Enum.EasingStyle.Quad, nil, {Transparency = 1}):Play()
            end
        end
        task.wait(1.2)
    end
end)

local MinBtn = New("TextButton", {
    Size=UDim2.fromOffset(20,20), Position=UDim2.new(1,-46,0.5,-10),
    BackgroundColor3=T.RAISED, AutoButtonColor=false,
    Text="—", TextColor3=T.MUTED, Font=Enum.Font.GothamBold, TextSize=11,
    BackgroundTransparency=1, TextTransparency=1, Parent=Header,
})
Corner(MinBtn, 6)
local CloseBtn = New("TextButton", {
    Size=UDim2.fromOffset(20,20), Position=UDim2.new(1,-22,0.5,-10),
    BackgroundColor3=T.RAISED, AutoButtonColor=false,
    Text="×", TextColor3=T.MUTED, Font=Enum.Font.GothamBold, TextSize=13,
    BackgroundTransparency=1, TextTransparency=1, Parent=Header,
})
Corner(CloseBtn, 6)

local Content = New("Frame", {
    Size=UDim2.new(1,0,1,-32), Position=UDim2.new(0,0,0,32),
    BackgroundTransparency=1, Parent=Panel,
})
-- Status strip: brand + device + live fps/ping in one gradient bar across the
-- top. Double-tap it and the whole interface folds away (L.MinimizeAll).
local StatusFade = {}
local StatusBar = New("TextButton", {
    Size = UDim2.fromOffset(0, 26),
    AutomaticSize = Enum.AutomaticSize.X,
    AnchorPoint = Vector2.new(0.5, 0),
    Position = UDim2.new(0.5, 0, 0, 12),
    BackgroundColor3 = T.SURFACE, BackgroundTransparency = 1,
    BorderSizePixel = 0, AutoButtonColor = false, Text = "",
    ClipsDescendants = true, Parent = Gui,
})
Corner(StatusBar, 8)
Pad(StatusBar, 0, 0, 12, 12)
local StatusStroke = Stroke(StatusBar, T.LINE, 1, 1)
local StatusGrad = New("UIGradient", {
    Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, T.SURFACE),
        ColorSequenceKeypoint.new(0.5, T.SURFACE:Lerp(T.DEEP, 0.45)),
        ColorSequenceKeypoint.new(1, T.SURFACE),
    }),
    Rotation = 20, Parent = StatusBar,
})
task.spawn(function()
    while StatusBar.Parent do
        TS:Create(StatusGrad, TweenInfo.new(5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {Rotation = 200}):Play()
        task.wait(5)
        TS:Create(StatusGrad, TweenInfo.new(5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {Rotation = 20}):Play()
        task.wait(5)
    end
end)
New("UIListLayout", {
    FillDirection = Enum.FillDirection.Horizontal,
    HorizontalAlignment = Enum.HorizontalAlignment.Center,
    VerticalAlignment = Enum.VerticalAlignment.Center,
    Padding = UDim.new(0, 7),
    SortOrder = Enum.SortOrder.LayoutOrder, Parent = StatusBar,
})
local function statusText(text, color, bold, order)
    local lbl = New("TextLabel", {
        AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromScale(0, 1),
        BackgroundTransparency = 1, Text = text,
        TextColor3 = color, Font = bold and Enum.Font.GothamBold or Enum.Font.GothamSemibold,
        TextSize = 10, TextTransparency = 1,
        LayoutOrder = order, Parent = StatusBar,
    })
    StatusFade[#StatusFade + 1] = lbl
    return lbl
end
local StatusBrand  = statusText("LUMINOSITY", T.HIGH, true, 1)
statusText("|", T.LINE, false, 2)
local StatusDevice = statusText(IS_PC and "PC" or "MOBILE", T.TEXT, true, 3)
statusText("|", T.LINE, false, 4)
local StatusFps    = statusText("-- FPS", T.MUTED, false, 5)
statusText("|", T.LINE, false, 6)
local StatusPing   = statusText("-- MS", T.MUTED, false, 7)
StatusFade[#StatusFade + 1] = StatusBar
do
    local lastTap = 0
    StatusBar.InputBegan:Connect(function(i)
        if i.UserInputType ~= Enum.UserInputType.MouseButton1
            and i.UserInputType ~= Enum.UserInputType.Touch then return end
        local now = os.clock()
        if now - lastTap < 0.35 then
            lastTap = 0
            if L.MinimizeAll then L.MinimizeAll() end
        else
            lastTap = now
        end
    end)
end

local TabNames = {"Main", "History", "Performance", "Settings"}
local TabBar = New("Frame", {
    Size = UDim2.new(1, 0, 0, 40),
    BackgroundColor3 = T.BG, BackgroundTransparency = 1,
    ClipsDescendants = true, Parent = Content,
})
Corner(TabBar, 10)
local TabStroke = Stroke(TabBar, T.LINE, 1, 1)
local TabPill = New("Frame", {
    Size = UDim2.new(1 / #TabNames, -6, 1, -6), Position = UDim2.fromOffset(3, 3),
    BackgroundColor3 = T.DEEP, BackgroundTransparency = 1,
    BorderSizePixel = 0, ZIndex = 1, Parent = TabBar,
})
Corner(TabPill, 8)

local TabButtons = {}
for i, name in ipairs(TabNames) do
    local button = New("TextButton", {
        Size = UDim2.new(1 / #TabNames, 0, 1, 0),
        Position = UDim2.new((i - 1) / #TabNames, 0, 0, 0),
        BackgroundTransparency = 1, AutoButtonColor = false,
        Text = name:upper(), TextColor3 = T.MUTED,
        Font = Enum.Font.GothamSemibold, TextSize = IS_MOBILE and 10 or 11,
        TextTransparency = 1, ZIndex = 2, Parent = TabBar,
    })
    TabButtons[i] = button
end

local PageHost = New("Frame", {
    Size = UDim2.new(1, 0, 0, 200), Position = UDim2.fromOffset(0, 50),
    BackgroundTransparency = 1, ClipsDescendants = true, Parent = Content,
})
local Pages, PageLists = {}, {}
for _, name in ipairs(TabNames) do
    -- Settings has the most rows by far; letting it grow the whole panel made
    -- it unwieldy to move and read. It scrolls inside a capped height instead.
    local scrolls = (name == "Settings")
    local page = New(scrolls and "ScrollingFrame" or "Frame", scrolls and {
        Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
        Visible = false, Parent = PageHost,
        BorderSizePixel = 0,
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        ScrollBarThickness = 4,
        ScrollBarImageColor3 = T.ACCENT,
        ScrollBarImageTransparency = 0.4,
        ElasticBehavior = Enum.ElasticBehavior.WhenScrollable,
        ClipsDescendants = true,
    } or {
        Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
        Visible = false, Parent = PageHost,
    })
    local list = New("UIListLayout", {
        Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder,
        Parent = page,
    })
    Pages[name], PageLists[name] = page, list
end
local MainPage = Pages.Main
local HistoryPage = Pages.History
local PerformancePage = Pages.Performance

local NOTIF_W = PERF.notificationWidth
local NotifRoot = New("Frame", {
    AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, -14, 0, 14),
    Size = UDim2.fromOffset(NOTIF_W, 0),
    AutomaticSize = Enum.AutomaticSize.Y,
    BackgroundTransparency = 1,
    Parent = Gui,
})
New("UIListLayout", {
    SortOrder = Enum.SortOrder.LayoutOrder,
    HorizontalAlignment = Enum.HorizontalAlignment.Right,
    Padding = UDim.new(0, 8),
    Parent = NotifRoot,
})

L.Notifs = {}
L.NotifOrder = 0

local function destroyNotif(state)
    if state.dead then return end
    state.dead = true
    L.Notifs[state.key] = nil
    tw(state.frame, 0.26, Enum.EasingStyle.Quart, nil, {
        Position = UDim2.fromOffset(NOTIF_W + 40, 0),
        BackgroundTransparency = 1,
    }):Play()
    for _, o in ipairs(state.fade) do
        tw(o, 0.22, nil, nil, o:IsA("UIStroke") and {Transparency = 1}
            or (o:IsA("Frame") and {BackgroundTransparency = 1} or {TextTransparency = 1})):Play()
    end
    task.delay(0.3, function() if state.frame then state.frame:Destroy() end end)
end

L.Notify = function(msg, color, timing)
    msg = tostring(msg or "")
    if msg == "" then return end
    color = color or T.HIGH

    local existing = L.Notifs[msg]
    if existing and not existing.dead then
        existing.count += 1
        existing.badge.Text = "×" .. existing.count
        existing.badge.Visible = true
        if timing then existing.timing.Text = timing end
        existing.token += 1
        local tok = existing.token
        existing.frame.Size = UDim2.new(1, 0, 0, existing.height)
        tw(existing.badge, 0.12, Enum.EasingStyle.Back, nil, {TextSize = 17}):Play()
        task.delay(0, function()
            if existing.dead then return end
            tw(existing.badge, 0.16, Enum.EasingStyle.Back, nil, {TextSize = 13}):Play()
        end)
        task.delay(15, function()
            if existing.dead or existing.token ~= tok then return end
            destroyNotif(existing)
        end)
        return
    end

    L.NotifOrder += 1
    local height = timing and 72 or 52

    local frame = New("Frame", {
        Size = UDim2.new(1, 0, 0, height),
        Position = UDim2.fromOffset(NOTIF_W + 40, 0),
        BackgroundColor3 = T.SURFACE,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ClipsDescendants = true,
        LayoutOrder = L.NotifOrder,
        Parent = NotifRoot,
    })
    Corner(frame, 12)
    local stroke = Stroke(frame, T.LINE, 1, 1)

    local bar = New("Frame", {
        Size = UDim2.new(0, 4, 1, -16),
        Position = UDim2.new(0, 8, 0, 8),
        BackgroundColor3 = color,
        BackgroundTransparency = 1,
        BorderSizePixel = 0, Parent = frame,
    })
    Corner(bar, 2)

    local body = New("TextLabel", {
        Size = UDim2.new(1, -58, 0, timing and 22 or 52),
        Position = UDim2.new(0, 20, 0, timing and 11 or 0),
        BackgroundTransparency = 1,
        Text = msg,
        TextColor3 = color,
        Font = Enum.Font.GothamBold, TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = timing and Enum.TextYAlignment.Top or Enum.TextYAlignment.Center,
        TextTruncate = Enum.TextTruncate.AtEnd,
        TextTransparency = 1, Parent = frame,
    })

    local timingLbl = New("TextLabel", {
        Size = UDim2.new(1, -58, 0, 30),
        Position = UDim2.new(0, 20, 0, 35),
        BackgroundTransparency = 1,
        Text = timing or "",
        TextColor3 = T.MUTED,
        Font = Enum.Font.Gotham, TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        TextWrapped = true,
        Visible = timing ~= nil,
        TextTransparency = 1, Parent = frame,
    })

    local life = New("Frame", {
        Size = UDim2.new(1, 0, 0, 3), Position = UDim2.new(0, 0, 1, -3),
        BackgroundColor3 = color, BackgroundTransparency = 1,
        BorderSizePixel = 0, Parent = frame,
    })
    Corner(life, 2)

    local badge = New("TextLabel", {
        Size = UDim2.fromOffset(32, 20),
        Position = UDim2.new(1, -40, 0, 9),
        BackgroundTransparency = 1,
        Text = "",
        TextColor3 = T.WHITE,
        Font = Enum.Font.GothamBold, TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Right,
        Visible = false,
        TextTransparency = 1, Parent = frame,
    })

    local state = {
        key = msg, frame = frame, badge = badge, timing = timingLbl,
        count = 1, token = 0, height = height, dead = false,
        fade = {body, timingLbl, badge, bar, life, stroke},
    }
    L.Notifs[msg] = state

    -- Notifications are built on demand, so they opt into the theme here.
    -- RegisterLum applies immediately when Luminosity is already active, so a
    -- toast that appears mid-mode comes up themed rather than plain.
    if L.RegisterLum then
        L.RegisterLum(stroke, "stroke", {Speed = 0.45, Rotation = 0})
        L.RegisterLum(bar,    "bg",     {Speed = 0.60, Rotation = 0})
    end

    tw(frame, 0.3, Enum.EasingStyle.Quint, nil, {
        Position = UDim2.fromOffset(0, 0),
        BackgroundTransparency = 0.08,
    }):Play()
    tw(stroke, 0.3, nil, nil, {Transparency = 0.45}):Play()
    tw(bar, 0.3, nil, nil, {BackgroundTransparency = 0}):Play()
    tw(body, 0.3, nil, nil, {TextTransparency = 0}):Play()
    if timing then tw(timingLbl, 0.3, nil, nil, {TextTransparency = 0.15}):Play() end
    tw(badge, 0.3, nil, nil, {TextTransparency = 0.1}):Play()
    tw(life, 0.3, nil, nil, {BackgroundTransparency = 0}):Play()
    tw(life, 15, Enum.EasingStyle.Linear, nil, {Size = UDim2.new(0, 0, 0, 3)}):Play()

    local tok = state.token
    task.delay(15, function()
        if state.dead or state.token ~= tok then return end
        destroyNotif(state)
    end)
end

-- Redeem spotlights. Separate lane from the right-side toasts: these slide in
-- from the left, carry your headshot, and read like a kill feed -- who, what
-- code, and the prize it landed on the second line.
do
local LeftRoot = New("Frame", {
    AnchorPoint = Vector2.new(0, 0),
    Position = UDim2.new(0, 14, 0, 14),
    Size = UDim2.fromOffset(NOTIF_W, 0),
    AutomaticSize = Enum.AutomaticSize.Y,
    BackgroundTransparency = 1,
    Parent = Gui,
})
New("UIListLayout", {
    SortOrder = Enum.SortOrder.LayoutOrder,
    HorizontalAlignment = Enum.HorizontalAlignment.Left,
    Padding = UDim.new(0, 8),
    Parent = LeftRoot,
})

local headshots = {}
local function headshotFor(userId)
    if headshots[userId] ~= nil then return headshots[userId] or nil end
    headshots[userId] = false
    task.spawn(function()
        local ok, url = pcall(function()
            return Players:GetUserThumbnailAsync(userId,
                Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
        end)
        headshots[userId] = ok and url or false
    end)
    return nil
end
headshotFor(LP.UserId)

-- suppresses double cards when our own redeem reply and the game's global
-- announcement describe the same redeem
L.SpotlightSeen = {}

local function hex(c)
    return string.format("#%02X%02X%02X",
        math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end

L.NotifyRedeem = function(code, prize, plr)
    if not code or code == "" then return end
    plr = plr or LP
    local key = tostring(plr.Name) .. ":" .. tostring(code)
    local now = os.clock()
    if L.SpotlightSeen[key] and now - L.SpotlightSeen[key] < 5 then return end
    L.SpotlightSeen[key] = now
    L.NotifOrder += 1

    local frame = New("Frame", {
        Size = UDim2.new(1, 0, 0, 64),
        Position = UDim2.fromOffset(-(NOTIF_W + 40), 0),
        BackgroundColor3 = T.SURFACE,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ClipsDescendants = true,
        LayoutOrder = L.NotifOrder,
        Parent = LeftRoot,
    })
    Corner(frame, 12)
    local stroke = Stroke(frame, T.LINE, 1, 1)

    local avatar = New("ImageLabel", {
        Size = UDim2.fromOffset(40, 40),
        Position = UDim2.new(0, 10, 0.5, -20),
        BackgroundColor3 = T.BG, BackgroundTransparency = 1,
        Image = headshotFor(plr.UserId) or "", ImageTransparency = 1,
        BorderSizePixel = 0, Parent = frame,
    })
    Corner(avatar, 20)
    if avatar.Image == "" then
        task.delay(0.5, function()
            if frame.Parent and avatar.Image == "" then
                avatar.Image = headshotFor(plr.UserId) or ""
            end
        end)
    end

    local line1 = New("TextLabel", {
        Size = UDim2.new(1, -64, 0, 22), Position = UDim2.new(0, 58, 0, 9),
        BackgroundTransparency = 1, RichText = true,
        Text = string.format('<font color="%s">%s</font><font color="%s"> redeemed </font><font color="%s">%s</font>',
            hex(T.HIGH), tostring(plr.Name), hex(T.MUTED), hex(T.ACCENT), tostring(code)),
        TextColor3 = T.TEXT, Font = Enum.Font.GothamSemibold, TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        TextTransparency = 1, Parent = frame,
    })
    local line2 = New("TextLabel", {
        Size = UDim2.new(1, -64, 0, 20), Position = UDim2.new(0, 58, 0, 33),
        BackgroundTransparency = 1, RichText = true,
        Text = string.format('<font color="%s">%s!</font>',
            hex(T.GREEN), tostring(prize or "Unknown")),
        TextColor3 = T.TEXT, Font = Enum.Font.GothamBold, TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        TextTransparency = 1, Parent = frame,
    })

    if L.RegisterLum then
        L.RegisterLum(stroke, "stroke", {Speed = 0.45, Rotation = 0})
    end

    -- disappearance bar: drains over the 15s lifetime, then the card leaves
    local life = New("Frame", {
        Size = UDim2.new(1, 0, 0, 3), Position = UDim2.new(0, 0, 1, -3),
        BackgroundColor3 = T.ACCENT, BackgroundTransparency = 1,
        BorderSizePixel = 0, Parent = frame,
    })
    Corner(life, 2)

    tw(frame, 0.32, Enum.EasingStyle.Quint, nil, {
        Position = UDim2.fromOffset(0, 0),
        BackgroundTransparency = 0.08,
    }):Play()
    tw(stroke, 0.3, nil, nil, {Transparency = 0.45}):Play()
    tw(avatar, 0.3, nil, nil, {BackgroundTransparency = 0.4, ImageTransparency = 0}):Play()
    tw(line1, 0.3, nil, nil, {TextTransparency = 0}):Play()
    tw(line2, 0.3, nil, nil, {TextTransparency = 0}):Play()
    tw(life, 0.3, nil, nil, {BackgroundTransparency = 0}):Play()
    tw(life, 15, Enum.EasingStyle.Linear, nil, {Size = UDim2.new(0, 0, 0, 3)}):Play()

    task.delay(15, function()
        tw(frame, 0.26, Enum.EasingStyle.Quart, nil, {
            Position = UDim2.fromOffset(-(NOTIF_W + 40), 0),
            BackgroundTransparency = 1,
        }):Play()
        tw(stroke, 0.22, nil, nil, {Transparency = 1}):Play()
        tw(avatar, 0.22, nil, nil, {ImageTransparency = 1}):Play()
        tw(line1, 0.22, nil, nil, {TextTransparency = 1}):Play()
        tw(line2, 0.22, nil, nil, {TextTransparency = 1}):Play()
        task.delay(0.3, function() if frame then frame:Destroy() end end)
    end)
end
end

local BoxFrame = New("Frame", {
    Size = UDim2.new(1, 0, 0, 36),
    BackgroundColor3 = T.BG,
    BackgroundTransparency = 1,
    LayoutOrder = 1, Parent = MainPage,
})
Corner(BoxFrame, 10); Pad(BoxFrame, 0, 0, 10, 10)
local BoxStroke = Stroke(BoxFrame, T.LINE, 1, 1)
local CodeBox = New("TextBox", {
    Size = UDim2.new(1, 0, 1, 0),
    BackgroundTransparency = 1,
    Text = "",
    PlaceholderText = "Enter code",
    PlaceholderColor3 = T.MUTED,
    TextColor3 = T.TEXT,
    Font = Enum.Font.Gotham, TextSize = 13,
    TextXAlignment = Enum.TextXAlignment.Left,
    ClearTextOnFocus = false,
    TextTransparency = 1, Parent = BoxFrame,
})
CodeBox.Focused:Connect(function()
    tw(BoxStroke, 0.18, nil, nil, {Color = T.ACCENT, Transparency = 0.3}):Play()
end)
CodeBox.FocusLost:Connect(function()
    tw(BoxStroke, 0.22, nil, nil, {Color = T.LINE, Transparency = 0.5}):Play()
end)

-- Speed selector: one track, four segments, a single indicator that slides
-- between them. Sliding one pill reads as a mode changing; cross-fading four
-- separate buttons reads as four things blinking.
local SPEED_H = 30
local SpeedBox = New("Frame", {
    Size = UDim2.new(1, 0, 0, SPEED_H),
    BackgroundColor3 = T.BG,
    BackgroundTransparency = 1,
    ClipsDescendants = true,
    LayoutOrder = 1, Parent = PerformancePage,
})
Corner(SpeedBox, 10)
local SpeedStroke = Stroke(SpeedBox, T.LINE, 1, 1)

-- The moving pill. Parented under the labels so text stays readable on top.
local SpeedPill = New("Frame", {
    Size = UDim2.new(1 / #L.SpeedModes, -6, 1, -6),
    Position = UDim2.new(0, 3, 0, 3),
    BackgroundColor3 = T.RAISED,
    BackgroundTransparency = 1,
    BorderSizePixel = 0, ZIndex = 2, Parent = SpeedBox,
})
Corner(SpeedPill, 8)
local PillStroke = New("UIStroke", {
    Color = T.ACCENT, Thickness = 1, Transparency = 1,
    ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = SpeedPill,
})
-- Lives on the pill's stroke, so in Luminosity mode the colours travel
-- around the outline itself rather than washing the fill.
local PillGrad = New("UIGradient", {Enabled = false, Parent = PillStroke})

local SpeedBtns = {}
for i, m in ipairs(L.SpeedModes) do
    local b = New("TextButton", {
        Size = UDim2.new(1 / #L.SpeedModes, 0, 1, 0),
        Position = UDim2.new((i - 1) / #L.SpeedModes, 0, 0, 0),
        BackgroundTransparency = 1,
        AutoButtonColor = false,
        Text = m.name,
        TextColor3 = T.MUTED,
        Font = Enum.Font.GothamSemibold,
        TextSize = IS_MOBILE and 9 or 10,
        TextTransparency = 1,
        ZIndex = 3, Parent = SpeedBox,
    })
    SpeedBtns[i] = b
end

L.SetSpeed = function(idx, silent)
    idx = math.clamp(idx, 1, #L.SpeedModes)
    L.SpeedIndex = idx
    L.Mode = L.SpeedModes[idx]
    L.SyncHot()
    if L.Settings.SpeedIndex ~= idx then
        L.Settings.SpeedIndex = idx
        L.SaveSettings()
    end
    local lum = L.Mode.raw == true

    tw(SpeedPill, 0.3, Enum.EasingStyle.Quint, nil, {
        Position = UDim2.new((idx - 1) / #L.SpeedModes, 3, 0, 3),
        BackgroundTransparency = 0.1,
    }):Play()

    for i, b in ipairs(SpeedBtns) do
        tw(b, 0.22, nil, nil, {
            TextColor3 = (i == idx) and (lum and T.WHITE or T.HIGH) or T.MUTED,
        }):Play()
    end

    if lum then
        -- Hand the stroke over to the scrolling gradient. Colour has to be
        -- white first, or the gradient multiplies against a tint.
        PillStroke.Color = T.WHITE
        PillGrad.Enabled = true
        Grad:Apply(PillGrad, LUM_COLORS, {
            Speed = 0.5, Rotation = 0,
            KeyCount = PERF.gradientKeys,
            UpdateRate = PERF.gradientRate,
        })
        tw(PillStroke, 0.25, nil, nil, {Transparency = 0, Thickness = 2}):Play()
    else
        Grad:Stop(PillGrad)
        PillGrad.Enabled = false
        tw(PillStroke, 0.25, nil, nil, {Transparency = 0.25, Thickness = 1}):Play()
        tw(PillStroke, 0.25, nil, nil, {Color = T.ACCENT}):Play()
    end

    -- Sweep the theme across the whole interface, notifications included.
    if L.ApplyLum then L.ApplyLum(lum) end

    if not silent and L.Notify then
        if L.Mode.box then
            -- Say what it actually switched to. "Speed: Box" reads like a
            -- faster setting, and it is the opposite of one.
            L.Notify("Baseline: label + button", T.MUTED)
        else
            L.Notify("Speed: " .. L.Mode.name, lum and T.WHITE or T.HIGH)
        end
    end
end

for i, b in ipairs(SpeedBtns) do
    b.MouseButton1Click:Connect(function() L.SetSpeed(i) end)
    b.MouseEnter:Connect(function()
        if L.SpeedIndex ~= i then tw(b, 0.12, nil, nil, {TextColor3 = T.TEXT}):Play() end
    end)
    b.MouseLeave:Connect(function()
        if L.SpeedIndex ~= i then tw(b, 0.16, nil, nil, {TextColor3 = T.MUTED}):Play() end
    end)
end

-- scrolling rainbow text for flex-worthy stats (sub-20 ping, 144+ fps).
-- keypoints wrap red->red so the offset loop is seamless; TextColor3 must be
-- white or the gradient multiplies against the tint.
local function rainbowSequence()
    local keys = {}
    for i = 0, 6 do
        keys[i + 1] = ColorSequenceKeypoint.new(i / 6, Color3.fromHSV(i / 6, 0.65, 1))
    end
    return ColorSequence.new(keys)
end

local PingGrad = New("UIGradient", {Enabled = false, Color = rainbowSequence(), Parent = StatusPing})
local FpsGrad = New("UIGradient", {Enabled = false, Color = rainbowSequence(), Parent = StatusFps})
local rainbowConns = {}

local function setRainbow(label, grad, on)
    if on then
        if rainbowConns[label] then return end
        label.TextColor3 = T.WHITE
        grad.Enabled = true
        local t = 0
        rainbowConns[label] = RunS.RenderStepped:Connect(function(dt)
            t += dt * 0.45
            grad.Offset = Vector2.new(t % 1, 0)
        end)
    else
        local conn = rainbowConns[label]
        if conn then conn:Disconnect() rainbowConns[label] = nil end
        grad.Enabled = false
        label.TextColor3 = T.MUTED
    end
end

task.spawn(function()
    local Stats = game:GetService("Stats")
    local fpsSmooth = 60
    RunS.RenderStepped:Connect(function(dt)
        fpsSmooth = fpsSmooth + (1 / math.max(dt, 1e-4) - fpsSmooth) * 0.08
    end)
    while StatusBar.Parent do
        -- Data Ping is the real server round-trip; GetNetworkPing as fallback
        local ping
        local ok, value = pcall(function()
            return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
        end)
        if ok and type(value) == "number" and value > 0 then
            ping = value
        else
            local ok2, rt = pcall(function() return LP:GetNetworkPing() end)
            if ok2 and type(rt) == "number" then ping = rt * 1000 end
        end
        local fps = math.floor(fpsSmooth + 0.5)
        StatusPing.Text = ping and string.format("%d MS", math.floor(ping + 0.5)) or "-- MS"
        StatusFps.Text = string.format("%d FPS", fps)
        setRainbow(StatusPing, PingGrad, L.RainbowStats ~= false and ping ~= nil and ping < 20)
        setRainbow(StatusFps, FpsGrad, L.RainbowStats ~= false and fps >= 144)
        task.wait(0.25)
    end
end)

L.LayoutUI = {}
L.LayoutUI.Box = New("Frame", {
    Size = UDim2.new(1, 0, 0, 50),
    BackgroundColor3 = T.RAISED, BackgroundTransparency = 1,
    LayoutOrder = 3, Parent = PerformancePage,
})
Corner(L.LayoutUI.Box, 12); Pad(L.LayoutUI.Box, 0, 0, 12, 12)
L.LayoutUI.Stroke = Stroke(L.LayoutUI.Box, T.LINE, 1, 1)
L.LayoutUI.Tag = New("TextLabel", {
    Size = UDim2.new(0.32, 0, 1, 0),
    BackgroundTransparency = 1, Text = "UI LAYOUT",
    TextColor3 = T.MUTED, Font = Enum.Font.GothamSemibold, TextSize = 9,
    TextXAlignment = Enum.TextXAlignment.Left, TextTransparency = 1,
    Parent = L.LayoutUI.Box,
})
L.LayoutUI.Track = New("Frame", {
    Size = UDim2.new(0.68, -4, 0, 30), Position = UDim2.new(0.32, 4, 0.5, -15),
    BackgroundColor3 = T.BG, BackgroundTransparency = 1,
    ClipsDescendants = true, Parent = L.LayoutUI.Box,
})
Corner(L.LayoutUI.Track, 9)
L.LayoutUI.TrackStroke = Stroke(L.LayoutUI.Track, T.LINE, 1, 1)
L.LayoutUI.Pill = New("Frame", {
    Size = UDim2.new(0.5, -4, 1, -6), Position = UDim2.fromOffset(3, 3),
    BackgroundColor3 = T.DEEP, BackgroundTransparency = 1,
    BorderSizePixel = 0, ZIndex = 1, Parent = L.LayoutUI.Track,
})
Corner(L.LayoutUI.Pill, 7)
L.LayoutUI.Tabbed = New("TextButton", {
    Size = UDim2.new(0.5, 0, 1, 0), BackgroundTransparency = 1,
    Text = "Tabbed", TextColor3 = T.WHITE,
    Font = Enum.Font.GothamSemibold, TextSize = 10,
    TextTransparency = 1, AutoButtonColor = false, ZIndex = 2,
    Parent = L.LayoutUI.Track,
})
L.LayoutUI.Panels = New("TextButton", {
    Size = UDim2.new(0.5, 0, 1, 0), Position = UDim2.fromScale(0.5, 0),
    BackgroundTransparency = 1, Text = "Panels", TextColor3 = T.MUTED,
    Font = Enum.Font.GothamSemibold, TextSize = 10,
    TextTransparency = 1, AutoButtonColor = false, ZIndex = 2,
    Parent = L.LayoutUI.Track,
})
L.LayoutMode = L.Settings.LayoutMode

local RedeemBtn = New("TextButton", {
    Size = UDim2.new(1, 0, 0, 48),
    BackgroundColor3 = T.ACCENT,
    AutoButtonColor = false,
    ClipsDescendants = true,
    Text = "Redeem",
    TextColor3 = T.VOID,
    Font = Enum.Font.GothamBold, TextSize = 16,
    BackgroundTransparency = 1, TextTransparency = 1,
    LayoutOrder = 2, Parent = MainPage,
})
Corner(RedeemBtn, 12)
local RedeemGrad = New("UIGradient", {
    Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, T.DEEP),
        ColorSequenceKeypoint.new(0.5, T.ACCENT),
        ColorSequenceKeypoint.new(1, T.HIGH),
    }),
    Rotation = 90, Parent = RedeemBtn,
})
local RedeemStroke = Stroke(RedeemBtn, T.HIGH, 1, 1)

local AutoBox = New("Frame", {
    Size = UDim2.new(1, 0, 0, 48),
    BackgroundColor3 = T.RAISED,
    BackgroundTransparency = 1,
    LayoutOrder = 5, Parent = MainPage,
})
Corner(AutoBox, 12); Pad(AutoBox, 0, 0, 12, 12)
local AutoStroke = Stroke(AutoBox, T.LINE, 1, 1)
New("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
    VerticalAlignment=Enum.VerticalAlignment.Center,
    HorizontalAlignment=Enum.HorizontalAlignment.Left, Parent=AutoBox})

local AutoTag = New("TextLabel", {
    Size = UDim2.new(1, -50, 1, 0),
    BackgroundTransparency = 1,
    Text = "Auto Redeem",
    TextColor3 = T.MUTED,
    Font = Enum.Font.GothamSemibold, TextSize = 13,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextTransparency = 1, LayoutOrder = 1, Parent = AutoBox,
})

local Switch = New("TextButton", {
    Size = UDim2.fromOffset(38, 20),
    BackgroundColor3 = T.SURFACE,
    AutoButtonColor = false,
    Text = "",
    BackgroundTransparency = 1,
    LayoutOrder = 2, Parent = AutoBox,
})
Corner(Switch, 10)
local SwitchStroke = Stroke(Switch, T.LINE, 1, 1)
local Knob = New("Frame", {
    Size = UDim2.fromOffset(14, 14),
    Position = UDim2.new(0, 3, 0.5, -7),
    BackgroundColor3 = T.MUTED,
    BackgroundTransparency = 1,
    BorderSizePixel = 0, Parent = Switch,
})
Corner(Knob, 7)

local ThresholdBox = New("Frame", {
    Size = UDim2.new(1, 0, 0, 38),
    BackgroundColor3 = T.BG,
    BackgroundTransparency = 1,
    ClipsDescendants = true,
    LayoutOrder = 7, Parent = MainPage,
})
Corner(ThresholdBox, 10)
local ThresholdStroke = Stroke(ThresholdBox, T.LINE, 1, 1)

local PresetRow = New("Frame", {
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    Parent = ThresholdBox,
})
local PresetBtns = {}
local presetWidths = {0.12, 0.12, 0.12, 0.12, 0.12, 0.40}
local presetNames = {"1", "2", "3", "4", "5", "Custom"}
local presetX = 0
for i, name in ipairs(presetNames) do
    local button = New("TextButton", {
        Size = UDim2.new(presetWidths[i], -3, 1, -6),
        Position = UDim2.new(presetX, 2, 0, 3),
        BackgroundColor3 = T.SURFACE,
        BackgroundTransparency = 1,
        AutoButtonColor = false,
        Text = name,
        TextColor3 = T.MUTED,
        Font = Enum.Font.GothamSemibold,
        TextSize = IS_MOBILE and 9 or 10,
        TextTransparency = 1,
        Parent = PresetRow,
    })
    Corner(button, 7)
    PresetBtns[i] = button
    presetX += presetWidths[i]
end

local CustomRow = New("Frame", {
    Size = UDim2.fromScale(1, 1),
    Position = UDim2.new(1, 8, 0, 0),
    BackgroundTransparency = 1,
    Visible = false,
    Parent = ThresholdBox,
})
local CustomBack = New("TextButton", {
    Size = UDim2.fromOffset(62, 28), Position = UDim2.fromOffset(3, 3),
    BackgroundColor3 = T.SURFACE, AutoButtonColor = false,
    Text = "‹ Presets", TextColor3 = T.MUTED,
    Font = Enum.Font.GothamSemibold, TextSize = 9,
    BackgroundTransparency = 1, TextTransparency = 1, Parent = CustomRow,
})
Corner(CustomBack, 7)
local CustomTag = New("TextLabel", {
    Size = UDim2.fromOffset(64, 28), Position = UDim2.fromOffset(69, 3),
    BackgroundTransparency = 1, Text = "Custom",
    TextColor3 = T.HIGH, Font = Enum.Font.GothamSemibold, TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left, TextTransparency = 1, Parent = CustomRow,
})
local CustomMinus = New("TextButton", {
    Size = UDim2.fromOffset(28, 28), Position = UDim2.new(1, -106, 0, 3),
    BackgroundColor3 = T.SURFACE, AutoButtonColor = false,
    Text = "−", TextColor3 = T.HIGH, Font = Enum.Font.GothamBold, TextSize = 16,
    BackgroundTransparency = 1, TextTransparency = 1,
    Parent = CustomRow,
})
Corner(CustomMinus, 7)
local CustomCount = New("TextLabel", {
    Size = UDim2.fromOffset(42, 28), Position = UDim2.new(1, -76, 0, 3),
    BackgroundTransparency = 1, Text = "0",
    TextColor3 = T.TEXT, Font = Enum.Font.GothamBold, TextSize = 14,
    TextTransparency = 1,
    Parent = CustomRow,
})
local CustomPlus = New("TextButton", {
    Size = UDim2.fromOffset(28, 28), Position = UDim2.new(1, -31, 0, 3),
    BackgroundColor3 = T.SURFACE, AutoButtonColor = false,
    Text = "+", TextColor3 = T.HIGH, Font = Enum.Font.GothamBold, TextSize = 16,
    BackgroundTransparency = 1, TextTransparency = 1,
    Parent = CustomRow,
})
Corner(CustomPlus, 7)

local SendBtn = New("TextButton", {
    Size = UDim2.new(1, 0, 0, 34),
    BackgroundColor3 = T.RAISED, AutoButtonColor = false,
    ClipsDescendants = true,
    Text = "Paste from clipboard",
    TextColor3 = T.MUTED,
    Font = Enum.Font.GothamSemibold, TextSize = 11,
    BackgroundTransparency = 1, TextTransparency = 1,
    LayoutOrder = 3, Parent = MainPage,
})
Corner(SendBtn, 10)

-- Main-tab rows: Redeem Path (order 4, above Auto) and Guess Code (order 6,
-- directly under Auto). Wrapped in do...end because the main chunk is at
-- Luau's 200-local ceiling -- block locals release their slots at the end.
do
    -- No Redeem Path row: this build only has one path.
    ------------------------------------------------ Guess Code (under Auto)
    local gbox = New("Frame", {
        Size = UDim2.new(1, 0, 0, 48),
        BackgroundColor3 = T.RAISED, BackgroundTransparency = 0,
        LayoutOrder = 6, Parent = MainPage,
    })
    Corner(gbox, 12); Pad(gbox, 0, 0, 12, 12)
    local gboxStroke = Stroke(gbox, T.LINE, 1, 0.5)
    New("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal,
        VerticalAlignment = Enum.VerticalAlignment.Center,
        HorizontalAlignment = Enum.HorizontalAlignment.Left, Parent = gbox})

    local gtag = New("TextLabel", {
        Size = UDim2.new(1, -50, 1, 0), BackgroundTransparency = 1,
        Text = "Guess Code", TextColor3 = T.MUTED,
        Font = Enum.Font.GothamSemibold, TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
        LayoutOrder = 1, Parent = gbox,
    })
    local gsw = New("TextButton", {
        Size = UDim2.fromOffset(38, 20), BackgroundColor3 = T.SURFACE,
        AutoButtonColor = false, Text = "", LayoutOrder = 2, Parent = gbox,
    })
    Corner(gsw, 10)
    local gswStroke = Stroke(gsw, T.LINE, 1, 0.5)
    local gknob = New("Frame", {
        Size = UDim2.fromOffset(14, 14), Position = UDim2.new(0, 3, 0.5, -7),
        BackgroundColor3 = T.MUTED, BorderSizePixel = 0, Parent = gsw,
    })
    Corner(gknob, 7)

    local function paintGuess()
        local on = L.GuessCode == true
        tw(gsw, 0.18, nil, nil, {BackgroundColor3 = on and T.ACCENT or T.SURFACE}):Play()
        tw(gswStroke, 0.18, nil, nil, {Color = on and T.HIGH or T.LINE,
                                       Transparency = on and 0.3 or 0.5}):Play()
        TS:Create(gknob, TweenInfo.new(0.26, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
            Position = on and UDim2.new(1, -17, 0.5, -7) or UDim2.new(0, 3, 0.5, -7),
            BackgroundColor3 = on and T.WHITE or T.MUTED,
        }):Play()
        tw(gtag, 0.18, nil, nil, {TextColor3 = on and T.TEXT or T.MUTED}):Play()
        tw(gboxStroke, 0.18, nil, nil, {Color = on and T.ACCENT or T.LINE,
                                        Transparency = on and 0.35 or 0.5}):Play()
    end
    L.PaintGuessRow = paintGuess

    gsw.MouseButton1Click:Connect(function()
        L.SetGuess(not L.GuessCode)
        paintGuess()
    end)
    paintGuess()
end

local PreviewBox = New("Frame", {
    Size = UDim2.new(1, 0, 0, 76),
    BackgroundColor3 = T.RAISED,
    BackgroundTransparency = 1,
    LayoutOrder = 8, Parent = MainPage,
})
Corner(PreviewBox, 11); Pad(PreviewBox, 0, 0, 11, 11)
local PreviewStroke = Stroke(PreviewBox, T.LINE, 1, 1)
local PreviewTag = New("TextLabel", {
    Size = UDim2.new(0.65, 0, 0, 18), Position = UDim2.fromOffset(11, 7),
    BackgroundTransparency = 1,
    Text = ("LIVE PREVIEW · %dMS"):format(math.floor(PERF.previewDelay * 1000 + 0.5)),
    TextColor3 = T.MUTED, Font = Enum.Font.GothamSemibold, TextSize = 9,
    TextXAlignment = Enum.TextXAlignment.Left, TextTransparency = 1,
    Parent = PreviewBox,
})
local PreviewCount = New("TextLabel", {
    Size = UDim2.new(0.35, -22, 0, 18), Position = UDim2.new(0.65, 11, 0, 7),
    BackgroundTransparency = 1, Text = "0 / 1",
    TextColor3 = T.HIGH, Font = Enum.Font.GothamSemibold, TextSize = 9,
    TextXAlignment = Enum.TextXAlignment.Right, TextTransparency = 1,
    Parent = PreviewBox,
})
local PreviewText = New("TextLabel", {
    Size = UDim2.new(1, -22, 0, 24), Position = UDim2.fromOffset(11, 25),
    BackgroundTransparency = 1, Text = "Waiting for Notify...",
    TextColor3 = T.TEXT, Font = Enum.Font.GothamSemibold, TextSize = 12,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd, TextTransparency = 1,
    Parent = PreviewBox,
})
local PreviewTrack = New("Frame", {
    Size = UDim2.new(1, -22, 0, 3), Position = UDim2.new(0, 11, 1, -11),
    BackgroundColor3 = T.SURFACE, BackgroundTransparency = 1,
    BorderSizePixel = 0, Parent = PreviewBox,
})
Corner(PreviewTrack, 2)
local PreviewFill = New("Frame", {
    Size = UDim2.new(0, 0, 1, 0),
    BackgroundColor3 = T.ACCENT, BackgroundTransparency = 1,
    BorderSizePixel = 0, Parent = PreviewTrack,
})
Corner(PreviewFill, 2)

local HistoryBox = New("Frame", {
    Size = UDim2.new(1, 0, 0, 112),
    BackgroundColor3 = T.RAISED,
    BackgroundTransparency = 1,
    LayoutOrder = 1, Parent = HistoryPage,
})
Corner(HistoryBox, 11); Pad(HistoryBox, 0, 0, 11, 11)
local HistoryStroke = Stroke(HistoryBox, T.LINE, 1, 1)
local HistoryTag = New("TextLabel", {
    Size = UDim2.new(1, -64, 0, 18), Position = UDim2.fromOffset(11, 6),
    BackgroundTransparency = 1, Text = "LAST CODES",
    TextColor3 = T.MUTED, Font = Enum.Font.GothamSemibold, TextSize = 9,
    TextXAlignment = Enum.TextXAlignment.Left, TextTransparency = 1,
    Parent = HistoryBox,
})
local HistoryClear = New("TextButton", {
    Size = UDim2.fromOffset(48, 18), Position = UDim2.new(1, -59, 0, 6),
    BackgroundTransparency = 1, AutoButtonColor = false,
    Text = "Clear", TextColor3 = T.MUTED,
    Font = Enum.Font.GothamSemibold, TextSize = 9,
    TextXAlignment = Enum.TextXAlignment.Right, TextTransparency = 1,
    Parent = HistoryBox,
})
local HistoryRows = {}
for i = 1, 5 do
    local row = New("TextLabel", {
        Size = UDim2.new(1, -22, 0, 16), Position = UDim2.fromOffset(11, 23 + (i - 1) * 17),
        BackgroundTransparency = 1, Text = i == 1 and "No codes yet" or "",
        TextColor3 = T.MUTED, Font = Enum.Font.Gotham, TextSize = 9,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd, TextTransparency = 1,
        Parent = HistoryBox,
    })
    HistoryRows[i] = row
end

local Fab = New("TextButton", {
    Size = UDim2.fromOffset(48, 48),
    Position = UDim2.new(0, 20, 1, -90),
    BackgroundColor3 = T.SURFACE, AutoButtonColor = false,
    Text = "L", TextColor3 = T.HIGH,
    Font = Enum.Font.GothamBold, TextSize = 18,
    Visible = false, Parent = Gui,
})
Corner(Fab, 14)
local FabStroke = Stroke(Fab, T.ACCENT, 1, 0.5)
task.spawn(function()
    while Fab.Parent do
        if Fab.Visible then
            tw(FabStroke, 1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, {Transparency = 0.85, Thickness = 2}):Play()
            task.wait(1.1)
            tw(FabStroke, 1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, {Transparency = 0.35, Thickness = 1}):Play()
            task.wait(1.1)
        else
            task.wait()
        end
    end
end)

-- Everything that carries the Luminosity theme. Registered once, after all of
-- it exists; notifications add themselves as they are built.
L.RegisterLum(PanelStroke,  "stroke", {Speed = 0.30, Rotation = 0})
L.RegisterLum(TabStroke,    "stroke", {Speed = 0.40, Rotation = 0})
L.RegisterLum(TabPill,      "bg",     {Speed = 0.46, Rotation = 0})
L.RegisterLum(BoxStroke,    "stroke", {Speed = 0.42, Rotation = 0})
L.RegisterLum(SpeedStroke,  "stroke", {Speed = 0.42, Rotation = 0})
L.RegisterLum(L.LayoutUI.Stroke, "stroke", {Speed = 0.42, Rotation = 0})
L.RegisterLum(L.LayoutUI.TrackStroke, "stroke", {Speed = 0.46, Rotation = 0})
L.RegisterLum(L.LayoutUI.Pill, "bg", {Speed = 0.46, Rotation = 0})
L.RegisterLum(AutoStroke,   "stroke", {Speed = 0.42, Rotation = 0})
L.RegisterLum(ThresholdStroke, "stroke", {Speed = 0.42, Rotation = 0})
L.RegisterLum(PreviewStroke, "stroke", {Speed = 0.42, Rotation = 0})
L.RegisterLum(HistoryStroke, "stroke", {Speed = 0.42, Rotation = 0})
L.RegisterLum(SwitchStroke, "stroke", {Speed = 0.55, Rotation = 0})
L.RegisterLum(RedeemStroke, "stroke", {Speed = 0.50, Rotation = 0})
L.RegisterLum(FabStroke,    "stroke", {Speed = 0.50, Rotation = 0})
L.RegisterLum(DotStroke,    "stroke", {Speed = 0.60, Rotation = 0})
L.RegisterLum(PreviewFill,  "bg",     {Speed = 0.55, Rotation = 0})
-- Fill and text ride their existing gradients so the decorative sweeps that
-- already drive them keep working; only the colour ramp is taken over.
L.RegisterLum(RedeemBtn,    "bg",   {Speed = 0.50, Rotation = 90}, RedeemGrad)
L.RegisterLum(Brand,        "text", {Speed = 0.42, Rotation = 0},  BrandGrad)

local startMinimized = L.Settings.Minimized
local minimized = false
local ActiveTab = L.Settings.ActiveTab
local PageMinimumHeight = {Main = 330, History = 112, Performance = 100, Settings = 716}

-- Tall enough to show several rows, short enough that the panel stays easy to
-- drag and read. Settings scrolls past this; every other tab still auto-sizes.
-- Parked on L, not a local: the main chunk is at Luau's 200-local ceiling and
-- one more would refuse to compile.
L.SETTINGS_MAX_H = IS_MOBILE and 300 or 360

local function activePageHeight()
    local list = PageLists[ActiveTab]
    local h = math.max(PageMinimumHeight[ActiveTab] or 1,
        list and list.AbsoluteContentSize.Y or 1)
    if ActiveTab == "Settings" and h > L.SETTINGS_MAX_H then h = L.SETTINGS_MAX_H end
    return h
end

local function fit(instant)
    if minimized then return end
    if L.PanelMode and L.PanelMode.Ready and L.LayoutMode == "panels" then
        if L.PanelMode.UpdateAll then L.PanelMode.UpdateAll(instant) end
        return
    end
    local pageHeight = activePageHeight()
    PageHost.Size = UDim2.new(1, 0, 0, pageHeight)
    local h = pageHeight + 104
    if instant then
        Panel.Size = UDim2.fromOffset(PANEL_W, h)
    else
        tw(Panel, 0.28, Enum.EasingStyle.Quart, nil, {Size = UDim2.fromOffset(PANEL_W, h)}):Play()
    end
end
for _, list in pairs(PageLists) do
    list:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function() fit(false) end)
end

L.SetTab = function(name, animate, skipSave)
    local index
    for i, tabName in ipairs(TabNames) do
        if tabName == name then
            index = i
            break
        end
    end
    if not index then name, index = "Main", 1 end

    -- The pill rides the VISIBLE slot, which stops matching the raw index the
    -- moment a tab is hidden.
    local slotIndex, slotCount = index, #TabNames
    if L.VisibleTabs then
        slotCount = #L.VisibleTabs
        for slot, entry in ipairs(L.VisibleTabs) do
            if entry.i == index then slotIndex = slot break end
        end
        if slotCount < 1 then slotCount = 1 end
    end

    local oldName = ActiveTab
    ActiveTab = name
    local panelsActive = L.PanelMode and L.PanelMode.Ready and L.LayoutMode == "panels"
    for tabName, page in pairs(Pages) do
        page.Visible = panelsActive or tabName == name
    end
    local page = Pages[name]
    if animate and oldName ~= name then
        page.Position = UDim2.fromOffset(IS_MOBILE and 10 or 18, 0)
        tw(page, 0.24, Enum.EasingStyle.Quint, Enum.EasingDirection.Out, {
            Position = UDim2.fromOffset(0, 0),
        }):Play()
    else
        page.Position = UDim2.fromOffset(0, 0)
    end

    tw(TabPill, animate and 0.28 or 0.01, Enum.EasingStyle.Quint, Enum.EasingDirection.Out, {
        Position = UDim2.new((slotIndex - 1) / slotCount, 3, 0, 3),
    }):Play()
    for i, button in ipairs(TabButtons) do
        tw(button, 0.16, nil, nil, {
            TextColor3 = i == index and T.WHITE or T.MUTED,
        }):Play()
    end
    if not skipSave and L.Settings.ActiveTab ~= name then
        L.Settings.ActiveTab = name
        L.SaveSettings()
    end
    fit(not animate)
end

-- Hide the Settings tab, remembered across sessions the way Minimized is.
-- The remaining tabs re-flow to fill the bar so it never looks like a gap.
L.SettingsHidden = L.Settings.SettingsHidden == true

L.ApplyTabVisibility = function(animate)
    local visible = {}
    for i, name in ipairs(TabNames) do
        if not (name == "Settings" and L.SettingsHidden) then
            visible[#visible + 1] = {i = i, name = name}
        end
    end
    local n = #visible
    for _, b in ipairs(TabButtons) do b.Visible = false end
    for slot, entry in ipairs(visible) do
        local b = TabButtons[entry.i]
        b.Visible = true
        b.Size = UDim2.new(1 / n, 0, 1, 0)
        b.Position = UDim2.new((slot - 1) / n, 0, 0, 0)
    end
    TabPill.Size = UDim2.new(1 / n, -6, 1, -6)
    L.VisibleTabs = visible
    -- Standing on a tab that just disappeared would leave a blank page.
    if L.SettingsHidden and ActiveTab == "Settings" then
        L.SetTab("Main", animate == true, false)
    else
        L.SetTab(ActiveTab or "Main", false, true)
    end
end

L.SetSettingsHidden = function(on, silent)
    L.SettingsHidden = on == true
    L.Settings.SettingsHidden = L.SettingsHidden
    L.SaveSettings()
    L.ApplyTabVisibility(true)
    if not silent then
        L.Notify(L.SettingsHidden
            and ("Settings hidden · " .. (L.Keybinds.Settings or "F4") .. " to bring it back")
            or "Settings shown", L.SettingsHidden and T.MUTED or T.GREEN)
    end
end

-- Escape hatch, so hiding it is never a one-way door.
L.ShowSettings = function() L.SetSettingsHidden(false) end

for i, button in ipairs(TabButtons) do
    button.MouseButton1Click:Connect(function() L.SetTab(TabNames[i], true, false) end)
    button.MouseEnter:Connect(function()
        if ActiveTab ~= TabNames[i] then tw(button, 0.12, nil, nil, {TextColor3 = T.TEXT}):Play() end
    end)
    button.MouseLeave:Connect(function()
        local selected = ActiveTab == TabNames[i]
        tw(button, 0.15, nil, nil, {TextColor3 = selected and T.WHITE or T.MUTED}):Play()
    end)
end

-- Apply the remembered Settings-tab visibility now that tabs are wired.
L.ApplyTabVisibility(false)
L.SetTab(ActiveTab, false, true)

local function draggable(frame, handle, onStop)
    handle = handle or frame
    local dragging, start, spos
    handle.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging = true; start = i.Position; spos = frame.Position
            i.Changed:Connect(function()
                if i.UserInputState == Enum.UserInputState.End then
                    dragging = false
                    if onStop then onStop(frame.Position) end
                end
            end)
        end
    end)
    UIS.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
            local d = i.Position - start
            frame.Position = UDim2.new(spos.X.Scale, spos.X.Offset + d.X, spos.Y.Scale, spos.Y.Offset + d.Y)
        end
    end)
end
draggable(Panel, Handle, function(position)
    L.Settings.PanelPosition = {
        XScale = position.X.Scale, XOffset = position.X.Offset,
        YScale = position.Y.Scale, YOffset = position.Y.Offset,
    }
    L.SaveSettings()
end)
draggable(Fab, Fab)
draggable(StatusBar, StatusBar)

L.PanelMode = {
    Ready = false,
    Frames = {},
    Contents = {},
    Strokes = {},
    Titles = {},
    Dots = {},
    MinButtons = {},
    ResetButtons = {},
    Minimized = {},
    Defaults = {},
    Layer = 20,
    Wide = VIEWPORT_WIDTH >= 780,
}

do
    local function positionFromSettings(name, fallback)
        local saved = L.Settings.PanelWindows[name]
        local position = saved and saved.Position
        if type(position) ~= "table" then return fallback end
        return UDim2.new(position.XScale, position.XOffset, position.YScale, position.YOffset)
    end

    local function panelSpec(name)
        local width = name == "Main" and PANEL_W or math.min(PANEL_W, 340)
        local height = (PageMinimumHeight[name] or 120) + 54
        local position
        if L.PanelMode.Wide then
            if name == "Main" then
                position = UDim2.new(0.5, -400, 0.5, -210)
            elseif name == "History" then
                position = UDim2.new(0.5, 56, 0.5, -210)
            else
                position = UDim2.new(0.5, 56, 0.5, -22)
            end
        else
            local offset = name == "Main" and 0 or (name == "History" and 12 or 24)
            position = UDim2.new(0.5, -(width / 2) + offset, 0.5, -(height / 2) + offset)
        end
        return width, height, position
    end

    L.PanelMode.Save = function(name)
        local frame = L.PanelMode.Frames[name]
        if not frame then return end
        local position = frame.Position
        L.Settings.PanelWindows[name] = {
            Position = {
                XScale = position.X.Scale, XOffset = position.X.Offset,
                YScale = position.Y.Scale, YOffset = position.Y.Offset,
            },
            Minimized = L.PanelMode.Minimized[name] == true,
        }
        L.SaveSettings()
    end

    L.PanelMode.BringToFront = function(name)
        local frame = L.PanelMode.Frames[name]
        if not frame then return end
        L.PanelMode.Layer += 1
        frame.ZIndex = L.PanelMode.Layer
    end

    L.PanelMode.Update = function(name, instant)
        local frame = L.PanelMode.Frames[name]
        local content = L.PanelMode.Contents[name]
        if not frame or not content then return end
        local minimizedPanel = L.PanelMode.Minimized[name] == true
        local height = minimizedPanel and 42
            or math.max(PageMinimumHeight[name] or 1, PageLists[name].AbsoluteContentSize.Y) + 54
        -- let the collapse tween finish before hiding content so it doesn't pop
        if minimizedPanel then
            task.delay(0, function()
                if L.PanelMode.Minimized[name] and content.Parent then
                    content.Visible = false
                end
            end)
        else
            content.Visible = true
        end
        L.PanelMode.MinButtons[name].Text = minimizedPanel and "+" or "—"
        local target = UDim2.fromOffset(frame.Size.X.Offset, height)
        if instant then
            frame.Size = target
        else
            tw(frame, 0.26, Enum.EasingStyle.Quart, Enum.EasingDirection.Out, {Size = target}):Play()
        end
    end

    L.PanelMode.UpdateAll = function(instant)
        for _, name in ipairs(TabNames) do L.PanelMode.Update(name, instant) end
    end

    L.PanelMode.Reset = function()
        for _, name in ipairs(TabNames) do
            local frame = L.PanelMode.Frames[name]
            local default = L.PanelMode.Defaults[name]
            if frame and default then
                frame.Position = default.Position
                L.PanelMode.Minimized[name] = false
                L.PanelMode.Update(name, false)
                L.PanelMode.Save(name)
            end
        end
    end

    L.PanelMode.Create = function(name)
        local width, height, defaultPosition = panelSpec(name)
        local state = L.Settings.PanelWindows[name] or {}
        local frame = New("Frame", {
            Name = "Luminosity" .. name .. "Panel",
            Size = UDim2.fromOffset(width, height),
            Position = positionFromSettings(name, defaultPosition),
            BackgroundColor3 = T.SURFACE, BackgroundTransparency = 1,
            BorderSizePixel = 0, ClipsDescendants = true,
            Visible = false, ZIndex = L.PanelMode.Layer,
            Parent = Gui,
        })
        Corner(frame, 15)
        local stroke = Stroke(frame, T.LINE, 1, 1)
        local gradient = New("UIGradient", {
            Color = ColorSequence.new({
                ColorSequenceKeypoint.new(0, T.SURFACE),
                ColorSequenceKeypoint.new(0.55, T.SURFACE:Lerp(T.DEEP, 0.25)),
                ColorSequenceKeypoint.new(1, T.SURFACE),
            }),
            Rotation = 25, Parent = frame,
        })
        local header = New("Frame", {
            Size = UDim2.new(1, -24, 0, 26), Position = UDim2.fromOffset(12, 9),
            BackgroundTransparency = 1, ZIndex = 3, Parent = frame,
        })
        local handle = New("TextButton", {
            Size = UDim2.new(1, name == "Performance" and -64 or -34, 1, 0), BackgroundTransparency = 1,
            Text = "", AutoButtonColor = false, ZIndex = 3, Parent = header,
        })
        local dot = New("Frame", {
            Size = UDim2.fromOffset(7, 7), Position = UDim2.new(0, 0, 0.5, -3),
            BackgroundColor3 = T.ACCENT, BackgroundTransparency = 1,
            BorderSizePixel = 0, ZIndex = 4, Parent = header,
        })
        Corner(dot, 4)
        local title = New("TextLabel", {
            Size = UDim2.new(1, -16, 1, 0), Position = UDim2.fromOffset(15, 0),
            BackgroundTransparency = 1, Text = name:upper(),
            TextColor3 = T.TEXT, Font = Enum.Font.GothamBold, TextSize = 11,
            TextXAlignment = Enum.TextXAlignment.Left, TextTransparency = 1,
            ZIndex = 4, Parent = handle,
        })
        local minimize = New("TextButton", {
            Size = UDim2.fromOffset(24, 24), Position = UDim2.new(1, -24, 0, 1),
            BackgroundColor3 = T.RAISED, BackgroundTransparency = 1,
            Text = "—", TextColor3 = T.MUTED,
            Font = Enum.Font.GothamBold, TextSize = 11,
            TextTransparency = 1, AutoButtonColor = false,
            ZIndex = 4, Parent = header,
        })
        Corner(minimize, 7)
        local reset
        if name == "Performance" then
            reset = New("TextButton", {
                Size = UDim2.fromOffset(24, 24), Position = UDim2.new(1, -54, 0, 1),
                BackgroundColor3 = T.RAISED, BackgroundTransparency = 1,
                Text = "↺", TextColor3 = T.MUTED,
                Font = Enum.Font.GothamBold, TextSize = 13,
                TextTransparency = 1, AutoButtonColor = false,
                ZIndex = 4, Parent = header,
            })
            Corner(reset, 7)
        end
        local content = New("Frame", {
            Size = UDim2.new(1, -24, 1, -50), Position = UDim2.fromOffset(12, 42),
            BackgroundTransparency = 1, ZIndex = 2, Parent = frame,
        })

        L.PanelMode.Frames[name] = frame
        L.PanelMode.Contents[name] = content
        L.PanelMode.Strokes[name] = stroke
        L.PanelMode.Titles[name] = title
        L.PanelMode.Dots[name] = dot
        L.PanelMode.MinButtons[name] = minimize
        L.PanelMode.ResetButtons[name] = reset
        L.PanelMode.Minimized[name] = state.Minimized == true
        L.PanelMode.Defaults[name] = {Position = defaultPosition, Size = UDim2.fromOffset(width, height)}

        L.RegisterLum(stroke, "stroke", {Speed = 0.38, Rotation = 0})
        L.RegisterLum(dot, "bg", {Speed = 0.52, Rotation = 0})
        draggable(frame, handle, function() L.PanelMode.Save(name) end)
        handle.InputBegan:Connect(function() L.PanelMode.BringToFront(name) end)
        frame.InputBegan:Connect(function() L.PanelMode.BringToFront(name) end)
        minimize.MouseButton1Click:Connect(function()
            L.PanelMode.Minimized[name] = not L.PanelMode.Minimized[name]
            L.PanelMode.Update(name, false)
            L.PanelMode.Save(name)
        end)
        minimize.MouseEnter:Connect(function()
            tw(minimize, 0.14, nil, nil, {BackgroundColor3 = T.RAISED:Lerp(T.ACCENT, 0.18), TextColor3 = T.HIGH}):Play()
        end)
        minimize.MouseLeave:Connect(function()
            tw(minimize, 0.18, nil, nil, {BackgroundColor3 = T.RAISED, TextColor3 = T.MUTED}):Play()
        end)
        if reset then
            reset.MouseButton1Click:Connect(L.PanelMode.Reset)
            reset.MouseEnter:Connect(function()
                tw(reset, 0.14, nil, nil, {BackgroundColor3 = T.RAISED:Lerp(T.ACCENT, 0.18), TextColor3 = T.HIGH}):Play()
            end)
            reset.MouseLeave:Connect(function()
                tw(reset, 0.18, nil, nil, {BackgroundColor3 = T.RAISED, TextColor3 = T.MUTED}):Play()
            end)
        end

        task.defer(function()
            local camera = workspace.CurrentCamera
            local viewport = camera and camera.ViewportSize
            if not viewport then return end
            local position = frame.AbsolutePosition
            local size = frame.AbsoluteSize
            local offscreen = position.X > viewport.X - 44
                or position.Y > viewport.Y - 44
                or position.X + size.X < 44
                or position.Y + 42 < 0
            if offscreen then
                frame.Position = defaultPosition
                L.PanelMode.Save(name)
            end
        end)

        task.spawn(function()
            while gradient.Parent do
                if frame.Visible and L.LayoutMode == "panels" then
                    tw(gradient, 7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, {Rotation = 205}):Play()
                    task.wait(7)
                    tw(gradient, 7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, {Rotation = 25}):Play()
                    task.wait(7)
                else
                    task.wait(0.5)
                end
            end
        end)
    end

    for _, name in ipairs(TabNames) do L.PanelMode.Create(name) end

    L.RefreshLayoutMode = function(instant)
        local panels = L.LayoutMode == "panels"
        tw(L.LayoutUI.Pill, instant and 0.01 or 0.26, Enum.EasingStyle.Quint, Enum.EasingDirection.Out, {
            Position = UDim2.new(panels and 0.5 or 0, 3, 0, 3),
        }):Play()
        tw(L.LayoutUI.Tabbed, 0.16, nil, nil, {TextColor3 = panels and T.MUTED or T.WHITE}):Play()
        tw(L.LayoutUI.Panels, 0.16, nil, nil, {TextColor3 = panels and T.WHITE or T.MUTED}):Play()
    end

    L.SetLayoutMode = function(mode, animate, skipSave)
        mode = mode == "panels" and "panels" or "tabbed"
        L.LayoutMode = mode
        L.RefreshLayoutMode(not animate)
        if not skipSave and L.Settings.LayoutMode ~= mode then
            L.Settings.LayoutMode = mode
            L.SaveSettings()
        end
        if not L.PanelMode.Ready then return end

        local panels = mode == "panels"
        Fab.Visible = false

        if panels then
            -- fade the tabbed shell out before hiding it
            if animate and Panel.Visible then
                tw(Panel, 0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In, {BackgroundTransparency = 1}):Play()
                tw(PanelStroke, 0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In, {Transparency = 1}):Play()
                task.delay(0, function()
                    if L.LayoutMode == "panels" then
                        PageHost.Visible = false
                        Panel.Visible = false
                    end
                end)
            else
                PageHost.Visible = false
                Panel.Visible = false
            end
            for i, name in ipairs(TabNames) do
                local page = Pages[name]
                local frame = L.PanelMode.Frames[name]
                page.Parent = L.PanelMode.Contents[name]
                page.Position = UDim2.fromOffset(0, 0)
                page.Size = UDim2.fromScale(1, 1)
                page.Visible = true
                local targetPos = frame.Position
                frame.Visible = true
                if animate then
                    frame.BackgroundTransparency = 1
                    L.PanelMode.Strokes[name].Transparency = 1
                    L.PanelMode.Titles[name].TextTransparency = 1
                    L.PanelMode.Dots[name].BackgroundTransparency = 1
                    L.PanelMode.MinButtons[name].BackgroundTransparency = 1
                    L.PanelMode.MinButtons[name].TextTransparency = 1
                    if L.PanelMode.ResetButtons[name] then
                        L.PanelMode.ResetButtons[name].BackgroundTransparency = 1
                        L.PanelMode.ResetButtons[name].TextTransparency = 1
                    end
                    frame.Position = UDim2.new(targetPos.X.Scale, targetPos.X.Offset,
                                               targetPos.Y.Scale, targetPos.Y.Offset + 14)
                end
                L.PanelMode.Update(name, true)
                -- staggered fade + slide-in, resting at the same 0.7 transparency as the tabbed panel
                task.delay(0, function()
                    if not frame.Parent then return end
                    tw(frame, animate and 0.32 or 0.01, Enum.EasingStyle.Quart, Enum.EasingDirection.Out, {
                        BackgroundTransparency = 0.7,
                        Position = targetPos,
                    }):Play()
                    tw(L.PanelMode.Strokes[name], animate and 0.32 or 0.01, nil, nil, {Transparency = 0.35}):Play()
                    tw(L.PanelMode.Titles[name], 0.24, nil, nil, {TextTransparency = 0}):Play()
                    tw(L.PanelMode.Dots[name], 0.24, nil, nil, {BackgroundTransparency = 0}):Play()
                    tw(L.PanelMode.MinButtons[name], 0.24, nil, nil, {BackgroundTransparency = 0, TextTransparency = 0}):Play()
                    if L.PanelMode.ResetButtons[name] then
                        tw(L.PanelMode.ResetButtons[name], 0.24, nil, nil, {BackgroundTransparency = 0, TextTransparency = 0}):Play()
                    end
                end)
            end
            L.PanelMode.BringToFront("Performance")
        else
            -- fade the floating panels out, then bring the tabbed shell back
            for _, name in ipairs(TabNames) do
                local page = Pages[name]
                local frame = L.PanelMode.Frames[name]
                page.Parent = PageHost
                page.Position = UDim2.fromOffset(0, 0)
                page.Size = UDim2.fromScale(1, 1)
                page.Visible = name == ActiveTab
                if animate and frame.Visible then
                    local restPos = frame.Position
                    tw(frame, 0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In, {
                        BackgroundTransparency = 1,
                        Position = UDim2.new(restPos.X.Scale, restPos.X.Offset,
                                             restPos.Y.Scale, restPos.Y.Offset + 10),
                    }):Play()
                    tw(L.PanelMode.Strokes[name], 0.16, nil, nil, {Transparency = 1}):Play()
                    tw(L.PanelMode.Titles[name], 0.12, nil, nil, {TextTransparency = 1}):Play()
                    tw(L.PanelMode.Dots[name], 0.12, nil, nil, {BackgroundTransparency = 1}):Play()
                    tw(L.PanelMode.MinButtons[name], 0.12, nil, nil, {BackgroundTransparency = 1, TextTransparency = 1}):Play()
                    if L.PanelMode.ResetButtons[name] then
                        tw(L.PanelMode.ResetButtons[name], 0.12, nil, nil, {BackgroundTransparency = 1, TextTransparency = 1}):Play()
                    end
                    task.delay(0, function()
                        if frame.Parent and L.LayoutMode == "tabbed" then
                            frame.Visible = false
                            frame.Position = restPos
                        end
                    end)
                else
                    frame.Visible = false
                end
            end
            Content.Visible = not minimized
            Panel.BackgroundTransparency = 1
            PanelStroke.Transparency = 1
            PageHost.Visible = true
            Panel.Visible = true
            tw(Panel, animate and 0.3 or 0.01, Enum.EasingStyle.Quart, Enum.EasingDirection.Out, {BackgroundTransparency = 0.7}):Play()
            tw(PanelStroke, animate and 0.3 or 0.01, nil, nil, {Transparency = 0.35}):Play()
            L.SetTab(ActiveTab, animate, true)
            fit(not animate)
        end
    end

    L.LayoutUI.Tabbed.MouseButton1Click:Connect(function() L.SetLayoutMode("tabbed", true, false) end)
    L.LayoutUI.Panels.MouseButton1Click:Connect(function() L.SetLayoutMode("panels", true, false) end)
    L.RefreshLayoutMode(true)
end

-- Settings page: every knob worth touching, live and persisted. Toggles use
-- the same switch anatomy as Auto Redeem; steppers use the custom-threshold
-- anatomy, so the page reads as native to the rest of the UI. Scoped in its
-- own block so the builders don't eat main-chunk locals.
L.SettingsFade = {}
do
local SettingsPage = Pages.Settings
local SettingsFade = L.SettingsFade
local function sfade(inst, goal)
    SettingsFade[#SettingsFade + 1] = {inst = inst, goal = goal}
end

local function makeRow(height, order)
    local box = New("Frame", {
        Size = UDim2.new(1, 0, 0, height),
        BackgroundColor3 = T.RAISED, BackgroundTransparency = 1,
        LayoutOrder = order, Parent = SettingsPage,
    })
    Corner(box, 12); Pad(box, 0, 0, 12, 12)
    sfade(box, {BackgroundTransparency = 0})
    sfade(Stroke(box, T.LINE, 1, 1), {Transparency = 0.5})
    return box
end

local function rowLabel(box, text)
    local lbl = New("TextLabel", {
        Size = UDim2.new(1, -130, 1, 0), Position = UDim2.fromOffset(12, 0),
        BackgroundTransparency = 1, Text = text,
        TextColor3 = T.MUTED, Font = Enum.Font.GothamSemibold, TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left, TextTransparency = 1,
        Parent = box,
    })
    sfade(lbl, {TextTransparency = 0})
    return lbl
end

local function makeToggle(order, label, get, set)
    local box = makeRow(56, order)
    local lbl = rowLabel(box, label)
    lbl.TextSize = 13
    local sw = New("TextButton", {
        Size = UDim2.fromOffset(48, 26), Position = UDim2.new(1, -62, 0.5, -13),
        BackgroundColor3 = T.SURFACE, AutoButtonColor = false, Text = "",
        BackgroundTransparency = 1, Parent = box,
    })
    Corner(sw, 13)
    local swStroke = Stroke(sw, T.LINE, 1, 1)
    local knob = New("Frame", {
        Size = UDim2.fromOffset(18, 18), Position = UDim2.new(0, 4, 0.5, -9),
        BackgroundColor3 = T.MUTED, BackgroundTransparency = 1,
        BorderSizePixel = 0, Parent = sw,
    })
    Corner(knob, 9)
    sfade(sw, {BackgroundTransparency = 0})
    sfade(swStroke, {Transparency = 0.5})
    sfade(knob, {BackgroundTransparency = 0})
    local function paint(on)
        tw(sw, 0.18, nil, nil, {BackgroundColor3 = on and T.ACCENT or T.SURFACE}):Play()
        tw(swStroke, 0.18, nil, nil, {Color = on and T.HIGH or T.LINE}):Play()
        TS:Create(knob, TweenInfo.new(0.26, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
            Position = on and UDim2.new(1, -22, 0.5, -9) or UDim2.new(0, 4, 0.5, -9),
            BackgroundColor3 = on and T.WHITE or T.MUTED,
        }):Play()
        tw(lbl, 0.18, nil, nil, {TextColor3 = on and T.TEXT or T.MUTED}):Play()
    end
    local handle = {paint = paint, label = label, guard = nil}
    sw.MouseButton1Click:Connect(function()
        -- A guard lets one toggle veto another (Guess Code owns the redeem
        -- loop, so Auto must not be switchable while it is on).
        if handle.guard then
            local blocked, why = handle.guard()
            if blocked then
                L.Notify(why or (label .. " is locked"), T.ORANGE)
                paint(get())
                return
            end
        end
        local on = not get()
        set(on)
        paint(on)
        L.Notify(label .. (on and " on" or " off"), on and T.GREEN or T.MUTED)
    end)
    paint(get())
    return handle
end

local function makeStepper(order, label, get, set, min, max, step, fmt)
    local box = makeRow(56, order)
    rowLabel(box, label)
    local minus = New("TextButton", {
        Size = UDim2.fromOffset(28, 28), Position = UDim2.new(1, -106, 0.5, -14),
        BackgroundColor3 = T.SURFACE, AutoButtonColor = false,
        Text = "-", TextColor3 = T.HIGH, Font = Enum.Font.GothamBold, TextSize = 16,
        BackgroundTransparency = 1, TextTransparency = 1, Parent = box,
    })
    Corner(minus, 7)
    local count = New("TextLabel", {
        Size = UDim2.fromOffset(44, 28), Position = UDim2.new(1, -76, 0.5, -14),
        BackgroundTransparency = 1, Text = "",
        TextColor3 = T.TEXT, Font = Enum.Font.GothamBold, TextSize = 12,
        TextTransparency = 1, Parent = box,
    })
    local plus = New("TextButton", {
        Size = UDim2.fromOffset(28, 28), Position = UDim2.new(1, -30, 0.5, -14),
        BackgroundColor3 = T.SURFACE, AutoButtonColor = false,
        Text = "+", TextColor3 = T.HIGH, Font = Enum.Font.GothamBold, TextSize = 16,
        BackgroundTransparency = 1, TextTransparency = 1, Parent = box,
    })
    Corner(plus, 7)
    sfade(minus, {BackgroundTransparency = 0, TextTransparency = 0})
    sfade(count, {TextTransparency = 0})
    sfade(plus, {BackgroundTransparency = 0, TextTransparency = 0})
    local function bump(dir)
        local v = math.clamp(get() + dir * step, min, max)
        v = math.floor(v * 100 + 0.5) / 100 -- kill float drift
        set(v)
        count.Text = fmt(v)
    end
    minus.MouseButton1Click:Connect(function() bump(-1) end)
    plus.MouseButton1Click:Connect(function() bump(1) end)
    count.Text = fmt(get())
    return {refresh = function() count.Text = fmt(get()) end}
end

local function persist(key, v)
    return function(val)
        L[key] = val
        L.Settings[key] = val
        L.SaveSettings()
    end
end

local AutoToggle = makeToggle(1, "Auto Redeem",
    function() return L.AutoOn end,
    function(on) L.SetAuto(on, true, false) end)
AutoToggle.guard = function()
    if L.GuessCode then return true, "Turn Guess Code off first" end
    return false
end

-- Guess Code: fire on every announcement with everything heard so far.
--   FREE  -> "FREE"          rejected
--   DRAGS -> "FREEDRAGS"     rejected
--   500   -> "FREEDRAGS500"  accepted, run resets
-- It drives its own redeeming, so it takes over from Auto rather than
-- stacking with it.
local GuessToggle
L.SetGuess = function(on, silent)
    L.GuessCode = on
    L.ResetBuf()                     -- never carry a half-guess across a toggle
    if on and L.AutoOn then
        L.SetAuto(false, true, false) -- forced off, persisted, repainted below
        if AutoToggle then AutoToggle.paint(false) end
    end
    L.Settings.GuessCode = on
    L.SaveSettings()
    L.SyncHot()
    if GuessToggle then GuessToggle.paint(on) end
    if L.PaintGuessRow then L.PaintGuessRow() end
    if not silent then
        L.Notify(on and "Guess Code on · Auto disabled" or "Guess Code off",
            on and T.GREEN or T.MUTED)
    end
end

GuessToggle = makeToggle(2, "Guess Code",
    function() return L.GuessCode end,
    function(on) L.SetGuess(on, true) end)

makeToggle(3, "Webhook",
    function() return L.EnableWebhook end,
    persist("WebhookOn") and function(on)
        L.EnableWebhook = on
        L.Settings.WebhookOn = on
        L.SaveSettings()
    end)
makeToggle(4, "Packet Dedup",
    function() return L.DedupOn end,
    function(on)
        L.DedupOn = on
        L.Settings.DedupOn = on
        L.SaveSettings()
        L.SyncHot()
    end)
makeToggle(5, "Rainbow Stats",
    function() return L.RainbowStats end,
    function(on)
        L.RainbowStats = on
        L.Settings.RainbowStats = on
        L.SaveSettings()
    end)
-- No redeem cooldown. It gated the hot path and dropped codes that landed
-- inside its window -- in Guess Code that silently ate pieces of the run.
makeStepper(7, "Part Lifetime",
    function() return L.PART_TTL end,
    function(v) L.PART_TTL = v; L.Settings.PartTTL = v; L.SaveSettings() end,
    2, 30, 1, function(v) return string.format("%ds", v) end)
-- No Redeem Path setting: this build has only the UI path.

makeToggle(9, "Hide Settings Tab",
    function() return L.SettingsHidden end,
    function(on) L.SetSettingsHidden(on, true) end)

makeStepper(8, "Dup Window",
    function() return L.PacketDupWindow end,
    function(v) L.PacketDupWindow = v; L.Settings.DupWindow = v; L.SaveSettings(); L.SyncHot() end,
    0, 2, 0.05, function(v) return string.format("%.2fs", v) end)

-- repaints every accent-baked element after a theme swap: the refresh suite
-- covers anything stateful, the explicit list covers the statics.
local function repaintTheme()
    TabPill.BackgroundColor3 = T.DEEP
    L.LayoutUI.Pill.BackgroundColor3 = T.DEEP
    PreviewFill.BackgroundColor3 = T.ACCENT
    FabStroke.Color = T.ACCENT
    for _, dot in pairs(L.PanelMode.Dots) do dot.BackgroundColor3 = T.ACCENT end
    L.SetAuto(L.AutoOn, true, true)
if L.Settings.GuessCode then L.SetGuess(true, true) end
L.RedeemMode = "normal"
L.SyncHot()
task.spawn(L.ResolveUIPath)
    L.SetSpeed(L.SpeedIndex, true)
    L.RefreshThresholdButtons()
    L.SetTab(ActiveTab, false, true)
    if L.RefreshPreview then L.RefreshPreview() end
end

-- theme cycler: same row anatomy, tap to walk the preset list
do
    local box = makeRow(56, 8)
    local lbl = rowLabel(box, "Theme")
    lbl.TextSize = 13
    local swatch = New("Frame", {
        Size = UDim2.fromOffset(18, 18), Position = UDim2.new(1, -118, 0.5, -9),
        BackgroundColor3 = T.ACCENT, BackgroundTransparency = 1,
        BorderSizePixel = 0, Parent = box,
    })
    Corner(swatch, 9)
    sfade(swatch, {BackgroundTransparency = 0})
    local cycle = New("TextButton", {
        Size = UDim2.fromOffset(88, 28), Position = UDim2.new(1, -92, 0.5, -14),
        BackgroundColor3 = T.SURFACE, AutoButtonColor = false,
        Text = "", TextColor3 = T.TEXT, Font = Enum.Font.GothamBold, TextSize = 12,
        BackgroundTransparency = 1, TextTransparency = 1, Parent = box,
    })
    Corner(cycle, 7)
    sfade(cycle, {BackgroundTransparency = 0, TextTransparency = 0})
    local function render()
        local th = L.Themes[L.ThemeIndex]
        cycle.Text = "< " .. th.name .. " >"
        swatch.BackgroundColor3 = th.ACCENT
    end
    cycle.MouseButton1Click:Connect(function()
        L.ThemeIndex = (L.ThemeIndex % #L.Themes) + 1
        L.Settings.ThemeIndex = L.ThemeIndex
        L.SaveSettings()
        local th = L.Themes[L.ThemeIndex]
        T.ACCENT, T.HIGH, T.DEEP = th.ACCENT, th.HIGH, th.DEEP
        repaintTheme()
        render()
        L.Notify("Theme: " .. th.name, th.ACCENT)
    end)
    render()
end

-- keybind rows: click, then press the key you want. gpe-guarded so typing in
-- chat never binds anything.
L.Keybinds = L.Settings.Keybinds
L.CaptureKeybind = nil

local function makeKeybindRow(order, label, action)
    local box = makeRow(56, order)
    local lbl = rowLabel(box, label)
    lbl.TextSize = 13
    local btn = New("TextButton", {
        Size = UDim2.fromOffset(88, 28), Position = UDim2.new(1, -92, 0.5, -14),
        BackgroundColor3 = T.SURFACE, AutoButtonColor = false,
        Text = L.Keybinds[action], TextColor3 = T.HIGH,
        Font = Enum.Font.GothamBold, TextSize = 12,
        BackgroundTransparency = 1, TextTransparency = 1, Parent = box,
    })
    Corner(btn, 7)
    sfade(btn, {BackgroundTransparency = 0, TextTransparency = 0})
    btn.MouseButton1Click:Connect(function()
        if L.CaptureKeybind then return end
        L.CaptureKeybind = action
        btn.Text = "..."
        local conn
        conn = UIS.InputBegan:Connect(function(input, gpe)
            if gpe or input.UserInputType ~= Enum.UserInputType.Keyboard then return end
            conn:Disconnect()
            L.CaptureKeybind = nil
            L.Keybinds[action] = input.KeyCode.Name
            L.Settings.Keybinds[action] = input.KeyCode.Name
            L.SaveSettings()
            btn.Text = input.KeyCode.Name
            L.Notify(label .. " -> " .. input.KeyCode.Name, T.HIGH)
        end)
    end)
end

makeKeybindRow(9,  "Toggle Auto Redeem", "Auto")
makeKeybindRow(10, "Show / Hide Panel",  "ToggleUI")
makeKeybindRow(11, "Stealth Mode",       "Stealth")
end

-- global keybinds. ignored while typing (gpe) and while a capture is armed.
UIS.InputBegan:Connect(function(input, gpe)
    if gpe or L.CaptureKeybind then return end
    if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
    local name = input.KeyCode.Name
    if name == L.Keybinds.Auto then
        if L.GuessCode then
            L.Notify("Turn Guess Code off first", T.ORANGE)
        else
            L.SetAuto(not L.AutoOn)
        end
    elseif name == L.Keybinds.ToggleUI then
        if Panel.Visible then
            Panel.Visible = false
            StatusBar.Visible = false
            Fab.Visible = true
            Fab.Rotation = -90
            Fab.Size = UDim2.fromOffset(0, 0)
            tw(Fab, 0.3, Enum.EasingStyle.Back, nil, {Rotation = 0, Size = UDim2.fromOffset(48, 48)}):Play()
        elseif Fab.Visible then
            Fab.Visible = false
            Fab.Rotation = 0
            Fab.Size = UDim2.fromOffset(48, 48)
            Panel.Visible = true
            StatusBar.Visible = true
        end
    elseif name == (L.Keybinds.Settings or "F4") then
        L.SetSettingsHidden(not L.SettingsHidden)
    elseif name == L.Keybinds.Stealth then
        Gui.Enabled = not Gui.Enabled
    end
end)

local function ripple(btn, tint)
    btn.MouseButton1Down:Connect(function(x, y)
        local abs = btn.AbsolutePosition
        local size = math.max(btn.AbsoluteSize.X, btn.AbsoluteSize.Y) * 2
        local r = New("Frame", {
            Size = UDim2.fromOffset(0, 0),
            Position = UDim2.fromOffset(x - abs.X, y - abs.Y),
            AnchorPoint = Vector2.new(0.5, 0.5),
            BackgroundColor3 = tint or T.WHITE,
            BackgroundTransparency = 0.75,
            BorderSizePixel = 0, ZIndex = 10, Parent = btn,
        })
        Corner(r, 999)
        tw(r, 0.45, Enum.EasingStyle.Quad, nil, {Size = UDim2.fromOffset(size, size), BackgroundTransparency = 1}):Play()
        task.delay(0.5, function() r:Destroy() end)
    end)
end

local function press(btn, sink)
    btn.MouseButton1Down:Connect(function()
        tw(btn, 0.08, Enum.EasingStyle.Quad, nil, {Size = btn.Size - UDim2.fromOffset(0,2)}):Play()
    end)
    local function up()
        tw(btn, 0.16, Enum.EasingStyle.Back, nil, {Size = sink}):Play()
    end
    btn.MouseButton1Up:Connect(up); btn.MouseLeave:Connect(up)
end
press(RedeemBtn, UDim2.new(1,0,0,48))
press(SendBtn,   UDim2.new(1,0,0,34))
press(CustomBack, UDim2.fromOffset(62,28))
press(CustomMinus, UDim2.fromOffset(28,28))
press(CustomPlus,  UDim2.fromOffset(28,28))
ripple(RedeemBtn, T.VOID)
ripple(SendBtn, T.ACCENT)

local function hoverFill(btn, base, hover)
    btn.MouseEnter:Connect(function()
        tw(btn, 0.15, nil, nil, {BackgroundColor3 = hover}):Play()
    end)
    btn.MouseLeave:Connect(function()
        tw(btn, 0.2, nil, nil, {BackgroundColor3 = base}):Play()
    end)
end
hoverFill(SendBtn, T.RAISED, T.RAISED:Lerp(T.ACCENT, 0.1))
hoverFill(CustomMinus, T.SURFACE, T.RAISED)
hoverFill(CustomPlus,  T.SURFACE, T.RAISED)
hoverFill(CustomBack,  T.SURFACE, T.RAISED)
hoverFill(MinBtn,  T.RAISED,  T.RAISED:Lerp(T.ACCENT, 0.2))
hoverFill(CloseBtn,T.RAISED,  Color3.fromRGB(50, 22, 34))
hoverFill(Fab,     T.SURFACE, T.RAISED)

for i, button in ipairs(PresetBtns) do
    button.MouseEnter:Connect(function()
        local selected = (L.ThresholdMode == "preset" and i == L.Threshold)
            or (L.ThresholdMode == "custom" and i == 6)
        if not selected then
            tw(button, 0.12, nil, nil, {BackgroundColor3 = T.RAISED, TextColor3 = T.TEXT}):Play()
        end
    end)
    button.MouseLeave:Connect(function()
        if L.RefreshThresholdButtons then L.RefreshThresholdButtons() end
    end)
end
HistoryClear.MouseEnter:Connect(function()
    tw(HistoryClear, 0.12, nil, nil, {TextColor3 = T.HIGH}):Play()
end)
HistoryClear.MouseLeave:Connect(function()
    tw(HistoryClear, 0.16, nil, nil, {TextColor3 = T.MUTED}):Play()
end)

RedeemBtn.MouseEnter:Connect(function()
    tw(RedeemStroke, 0.15, nil, nil, {Transparency = 0.15, Thickness = 2}):Play()
    tw(RedeemGrad, 0.3, nil, nil, {Rotation = 45}):Play()
end)
RedeemBtn.MouseLeave:Connect(function()
    tw(RedeemStroke, 0.25, nil, nil, {Transparency = 0.6, Thickness = 1}):Play()
    tw(RedeemGrad, 0.3, nil, nil, {Rotation = 90}):Play()
end)

L.ReportRedeem = function(ok, reply, t)
    local line
    if t then
        if not L.BestClient or t.client < L.BestClient then L.BestClient = t.client end
        if t.fireOnly then
            -- No round trip on this path, so only the send cost is real.
            -- Phrased without naming why.
            line = ("client %s (best %s)"):format(fmt(t.client), fmt(L.BestClient))
        else
            line = ("client %s (best %s) · server %s · total %s")
                :format(fmt(t.client), fmt(L.BestClient), fmt(t.server), fmt(t.client + t.server))
        end
    end

    local text = render(reply)
    if ok == nil then
        L.Notify(text or "Request failed", T.RED, line)
    elseif ok then
        L.Notify(text or "Code redeemed", T.GREEN, line)
        -- The event path has no prize name in its (nonexistent) reply, so
        -- there is nothing meaningful to push to the webhook.
        if text and text ~= "" and not (t and t.fireOnly) then
            local prize = L.Prize(text)
            task.spawn(function() L.Webhook(prize, text) end)
            pcall(L.NotifyRedeem, L.LastPreviewCode, prize)
        end
    else
        L.Notify(text or "Code rejected", T.ORANGE, line)
    end
end

L.DoRedeem = function(code, t0)
    t0 = t0 or os.clock()
    local ok, reply, t = L.RedeemViaRemote(code, t0)
    L.LastPreviewCode = code
    L.PreviewFlashUntil = clock() + 1.2
    L.AddHistory(code, ok, t)
    L.RequestUIRefresh()
    if L.RefreshPreview then L.RefreshPreview() end
    task.delay(1.25, function()
        if L.RefreshPreview then L.RefreshPreview() end
    end)
    L.ReportRedeem(ok, reply, t)
    return ok, reply
end

RedeemBtn.MouseButton1Click:Connect(function()
    local t0 = os.clock()
    local code = CodeBox.Text
    if not code or code == "" then L.Notify("Enter a code first", T.MUTED); return end
    task.spawn(function() L.DoRedeem(code, t0) end)
    CodeBox.Text = ""
end)
CodeBox.FocusLost:Connect(function(enter)
    if not enter then return end
    local t0 = os.clock()
    local code = CodeBox.Text
    if not code or code == "" then return end
    task.spawn(function() L.DoRedeem(code, t0) end)
    CodeBox.Text = ""
end)

L.AutoOn = L.Settings.AutoOn
L.ThresholdMode = L.Settings.ThresholdMode
L.CustomThreshold = L.Settings.CustomThreshold
L.LastPreset = L.Settings.LastPreset
L.Threshold = L.Settings.Threshold
L.Sent = 0
L.RecentRedeem = 0
L.SyncHot()

L.ExtractCode = function(raw)
    if not raw or raw == "" then return nil end
    local low = raw:lower()
    if low:find("spawned", 1, true) or low:find("redeemed", 1, true)
       or low:find("invalid", 1, true) or low:find("expired", 1, true)
       or low:find("already", 1, true) or low:find("failed",  1, true)
       or low:find("sold out", 1, true) then
        return nil
    end
    local best
    for token in raw:gmatch("([%w%-_]+)") do
        if #token >= 3 and #token <= 40 then
            if token == token:upper() and token:match("[A-Z]") then
                best = token
            elseif not best and token:match("%u") then
                best = token
            end
        end
    end
    if best then return best end
    local whole = raw:gsub("%s+", " "):gsub("^%s+",""):gsub("%s+$","")
    if #whole >= 3 then return whole end
    return nil
end

local thresholdViewToken = 0

local function showPresetControls()
    for _, button in ipairs(PresetBtns) do
        tw(button, 0.2, nil, nil, {BackgroundTransparency = 0, TextTransparency = 0}):Play()
    end
end

local function showCustomControls()
    tw(CustomBack, 0.2, nil, nil, {BackgroundTransparency = 0, TextTransparency = 0}):Play()
    tw(CustomMinus, 0.2, nil, nil, {BackgroundTransparency = 0, TextTransparency = 0}):Play()
    tw(CustomPlus, 0.2, nil, nil, {BackgroundTransparency = 0, TextTransparency = 0}):Play()
    tw(CustomTag, 0.2, nil, nil, {TextTransparency = 0}):Play()
    tw(CustomCount, 0.2, nil, nil, {TextTransparency = 0}):Play()
end

L.RefreshThresholdButtons = function()
    for i, button in ipairs(PresetBtns) do
        local selected = (L.ThresholdMode == "preset" and i == L.Threshold)
            or (L.ThresholdMode == "custom" and i == 6)
        tw(button, 0.16, nil, nil, {
            BackgroundColor3 = selected and T.DEEP or T.SURFACE,
            TextColor3 = selected and T.WHITE or T.MUTED,
        }):Play()
    end
    CustomCount.Text = tostring(L.CustomThreshold)
    tw(CustomCount, 0.16, nil, nil, {
        TextColor3 = L.CustomThreshold > 0 and T.HIGH or T.MUTED,
    }):Play()
end

L.RefreshPreview = function()
    local threshold = L.Threshold
    local countText, body, ratio, color
    local flashing = L.PreviewFlashUntil and clock() < L.PreviewFlashUntil and L.LastPreviewCode

    if flashing then
        countText = threshold > 0 and (tostring(threshold) .. " / " .. tostring(threshold)) or "SENT"
        body = "Sent  " .. L.LastPreviewCode
        ratio, color = 1, T.GREEN
    elseif not L.AutoOn then
        countText, body, ratio, color = "OFF", "Auto Redeem is off", 0, T.MUTED
    elseif threshold < 1 then
        countText, body, ratio, color = "0 / 0", "Custom amount is 0 · paused", 0, T.ORANGE
    elseif L.BufN > 0 then
        local parts = table.create(L.BufN)
        for i = 1, L.BufN do parts[i] = L.Buf[i] end
        countText = tostring(L.BufN) .. " / " .. tostring(threshold)
        body = table.concat(parts, "  +  ")
        ratio, color = math.clamp(L.BufN / threshold, 0, 1), T.HIGH
    else
        countText = "0 / " .. tostring(threshold)
        body, ratio, color = "Waiting for Notify...", 0, T.TEXT
    end

    PreviewCount.Text = countText
    PreviewText.Text = body
    tw(PreviewCount, 0.15, nil, nil, {TextColor3 = color}):Play()
    tw(PreviewText, 0.15, nil, nil, {TextColor3 = color}):Play()
    tw(PreviewFill, 0.22, Enum.EasingStyle.Quart, nil, {
        Size = UDim2.new(ratio, 0, 1, 0),
        BackgroundColor3 = color,
    }):Play()
end

L.RefreshHistory = function()
    for i, row in ipairs(HistoryRows) do
        local item = L.CodeHistory[i]
        if item then
            local mark = item.status == "success" and "✓"
                or (item.status == "rejected" and "×" or "!")
            local timing = item.client and ("  ·  " .. fmt(item.client)) or ""
            row.Text = mark .. "  " .. item.code .. timing
            row.TextColor3 = item.status == "success" and T.GREEN
                or (item.status == "rejected" and T.ORANGE or T.RED)
        else
            row.Text = (i == 1) and "No codes yet" or ""
            row.TextColor3 = T.MUTED
        end
    end
end

L.RefreshAuto = function()
    L.RefreshThresholdButtons()
    L.RefreshPreview()
end

local function persistThreshold()
    L.Settings.ThresholdMode = L.ThresholdMode
    L.Settings.Threshold = L.Threshold
    L.Settings.CustomThreshold = L.CustomThreshold
    L.Settings.LastPreset = L.LastPreset
    L.SaveSettings()
end

L.SetThresholdMode = function(mode, animate, resetCustom, skipSave)
    thresholdViewToken += 1
    local token = thresholdViewToken
    L.ThresholdMode = mode == "custom" and "custom" or "preset"
    if L.ThresholdMode == "custom" then
        if resetCustom then L.CustomThreshold = 0 end
        L.Threshold = L.CustomThreshold
    else
        L.Threshold = L.LastPreset
    end
    L.ResetBuf()
    L.SyncHot()
    if not skipSave then persistThreshold() end
    L.RefreshAuto()

    if not animate then
        local custom = L.ThresholdMode == "custom"
        PresetRow.Visible = not custom
        PresetRow.Position = custom and UDim2.new(-1, -8, 0, 0) or UDim2.fromScale(0, 0)
        CustomRow.Visible = custom
        CustomRow.Position = custom and UDim2.fromScale(0, 0) or UDim2.new(1, 8, 0, 0)
        return
    end

    if L.ThresholdMode == "custom" then
        CustomRow.Visible = true
        CustomRow.Position = UDim2.new(1, 8, 0, 0)
        showCustomControls()
        tw(PresetRow, 0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.Out, {
            Position = UDim2.new(-1, -8, 0, 0),
        }):Play()
        tw(CustomRow, 0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.Out, {
            Position = UDim2.fromScale(0, 0),
        }):Play()
        task.delay(0, function()
            if token == thresholdViewToken then PresetRow.Visible = false end
        end)
    else
        PresetRow.Visible = true
        PresetRow.Position = UDim2.new(-1, -8, 0, 0)
        showPresetControls()
        tw(CustomRow, 0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.Out, {
            Position = UDim2.new(1, 8, 0, 0),
        }):Play()
        tw(PresetRow, 0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.Out, {
            Position = UDim2.fromScale(0, 0),
        }):Play()
        task.delay(0, function()
            if token == thresholdViewToken then CustomRow.Visible = false end
        end)
    end
end

L.SetAuto = function(on, silent, skipSave)
    L.AutoOn = on == true
    L.ResetBuf()
    L.SyncHot()
    if not skipSave then
        L.Settings.AutoOn = L.AutoOn
        L.SaveSettings()
    end
    tw(Switch, 0.18, nil, nil, {BackgroundColor3 = L.AutoOn and T.ACCENT or T.SURFACE}):Play()
    tw(SwitchStroke, 0.18, nil, nil, {Color = L.AutoOn and T.HIGH or T.LINE, Transparency = L.AutoOn and 0.3 or 0.5}):Play()
    TS:Create(Knob, TweenInfo.new(0.26, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
        Position = L.AutoOn and UDim2.new(1, -17, 0.5, -7) or UDim2.new(0, 3, 0.5, -7),
        BackgroundColor3 = L.AutoOn and T.WHITE or T.MUTED,
    }):Play()
    tw(AutoTag, 0.18, nil, nil, {TextColor3 = L.AutoOn and T.TEXT or T.MUTED}):Play()
    tw(AutoStroke, 0.18, nil, nil, {Color = L.AutoOn and T.ACCENT or T.LINE, Transparency = L.AutoOn and 0.35 or 0.5}):Play()
    L.RefreshAuto()
    if not silent then
        L.Notify(L.AutoOn and "Auto redeem enabled" or "Auto redeem disabled", L.AutoOn and T.GREEN or T.MUTED)
    end
end

Switch.MouseButton1Click:Connect(function()
    if L.GuessCode then
        L.Notify("Turn Guess Code off first", T.ORANGE)
        return
    end
    L.SetAuto(not L.AutoOn)
end)
for i, button in ipairs(PresetBtns) do
    button.MouseButton1Click:Connect(function()
        if i == 6 then
            L.SetThresholdMode("custom", true, true)
            return
        end
        L.LastPreset = i
        L.Threshold = i
        L.ThresholdMode = "preset"
        L.ResetBuf()
        L.SyncHot()
        persistThreshold()
        L.RefreshAuto()
    end)
end
CustomBack.MouseButton1Click:Connect(function()
    L.SetThresholdMode("preset", true, false)
end)
CustomMinus.MouseButton1Click:Connect(function()
    L.CustomThreshold = math.max(0, L.CustomThreshold - 1)
    L.Threshold = L.CustomThreshold
    L.ResetBuf(); persistThreshold(); L.SyncHot(); L.RefreshAuto()
end)
CustomPlus.MouseButton1Click:Connect(function()
    L.CustomThreshold = math.min(50, L.CustomThreshold + 1)
    L.Threshold = L.CustomThreshold
    L.ResetBuf(); persistThreshold(); L.SyncHot(); L.RefreshAuto()
end)
HistoryClear.MouseButton1Click:Connect(function()
    table.clear(L.CodeHistory)
    L.Settings.History = L.CodeHistory
    L.SaveSettings()
    L.RefreshHistory()
end)

L.SetThresholdMode(L.ThresholdMode, false, false, true)
L.SetAuto(L.AutoOn, true, true)
L.RefreshHistory()

SendBtn.MouseButton1Click:Connect(function()
    local getClip = (getclipboard or (Clipboard and Clipboard.get) or nil)
    if not getClip then L.Notify("Clipboard unavailable", T.RED); return end
    local ok, txt = pcall(getClip)
    if not (ok and typeof(txt) == "string" and #txt > 0) then L.Notify("Clipboard is empty", T.RED); return end
    local cur = CodeBox.Text or ""
    CodeBox.Text = (cur ~= "" and cur .. " " .. txt) or txt
    L.Notify("Pasted from clipboard", T.HIGH)
end)

L.SetMinimized = function(on)
    on = on == true
    if minimized == on then return end
    minimized = on
    L.Settings.Minimized = minimized
    L.SaveSettings()
    if minimized then
        Content.Visible = false
        tw(Panel, 0.26, Enum.EasingStyle.Quart, nil, {Size = UDim2.fromOffset(PANEL_W, 44)}):Play()
        MinBtn.Text = "+"
    else
        MinBtn.Text = "—"
        fit(false)
        task.delay(0, function() if not minimized then Content.Visible = true end end)
    end
end

MinBtn.MouseButton1Click:Connect(function() L.SetMinimized(not minimized) end)

-- double-tap on the status strip: fold everything, whichever layout is live
L.MinimizeAll = function()
    if L.LayoutMode == "panels" and L.PanelMode.Ready then
        for _, name in ipairs(TabNames) do
            if not L.PanelMode.Minimized[name] then
                L.PanelMode.Minimized[name] = true
                L.PanelMode.Update(name, false)
                L.PanelMode.Save(name)
            end
        end
    else
        L.SetMinimized(true)
    end
end

CloseBtn.MouseButton1Click:Connect(function()
    tw(Panel, 0.2, Enum.EasingStyle.Quart, nil, {
        BackgroundTransparency = 1,
        Size = UDim2.fromOffset(PANEL_W * 0.9, Panel.Size.Y.Offset * 0.9),
    }):Play()
    task.delay(0, function()
        Panel.Visible = false
        StatusBar.Visible = false
        Panel.BackgroundTransparency = 0.7
        fit(true)
        Fab.Visible = true
        Fab.Rotation = -90
        Fab.Size = UDim2.fromOffset(0, 0)
        tw(Fab, 0.3, Enum.EasingStyle.Back, nil, {Rotation = 0, Size = UDim2.fromOffset(48, 48)}):Play()
    end)
end)
Fab.MouseButton1Click:Connect(function()
    tw(Fab, 0.18, Enum.EasingStyle.Quart, nil, {Rotation = 90, Size = UDim2.fromOffset(0, 0)}):Play()
    task.delay(0, function()
        Fab.Visible = false
        Fab.Rotation = 0
        Fab.Size = UDim2.fromOffset(48, 48)
        Panel.Visible = true
        StatusBar.Visible = true
    end)
end)


task.spawn(function()
    for i, lbl in ipairs(Letters) do
        task.delay((i - 1) * 0.055, function()
            TS:Create(lbl, TweenInfo.new(0.7, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
                Position = UDim2.fromOffset(0, 0),
                Rotation = 0,
                TextTransparency = 0,
            }):Play()
            local letterStroke = LetterStrokes[i]
            if letterStroke then
                tw(letterStroke, 0.3, nil, nil, {Transparency = 0.1}):Play()
            end
        end)
    end
    task.wait(0.055 * #Letters + 0.35)

    tw(Underline, 0.55, Enum.EasingStyle.Quart, nil, {Size = UDim2.new(0.72, 0, 0, 2)}):Play()
    task.wait(0.15)
    tw(Sub, 0.4, nil, nil, {TextTransparency = 0}):Play()

    local steps = { "starting", "preparing", "almost there", "ready" }
    for _, s in ipairs(steps) do
        Sub.Text = s
        task.wait(0.26)
    end
    task.wait(0.18)

    for i, lbl in ipairs(Letters) do
        TS:Create(lbl, TweenInfo.new(0.35), {TextTransparency = 1}):Play()
        local letterStroke = LetterStrokes[i]
        if letterStroke then
            tw(letterStroke, 0.2, nil, nil, {Transparency = 1}):Play()
        end
    end
    tw(Sub, 0.3, nil, nil, {TextTransparency = 1}):Play()
    tw(Underline, 0.35, nil, nil, {Size = UDim2.new(0, 0, 0, 2), BackgroundTransparency = 1}):Play()
    task.wait(0.4)

    L.RainActive = false
    Loader.Visible = false
    Loader:Destroy()

    L.PanelMode.Ready = true
    L.SetLayoutMode(L.LayoutMode, false, true)
    fit(true)
    local target = startMinimized and UDim2.fromOffset(PANEL_W, 44) or Panel.Size
    if startMinimized then
        minimized = true
        Content.Visible = false
        MinBtn.Text = "+"
    end
    Panel.Size = UDim2.fromOffset(PANEL_W, math.floor(target.Y.Offset * 0.86))
    Panel.Position = UDim2.new(Panel.Position.X.Scale, Panel.Position.X.Offset,
                               Panel.Position.Y.Scale, Panel.Position.Y.Offset + 24)
    TS:Create(Panel, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
        BackgroundTransparency = 0.7,
        Size = target,
        Position = UDim2.new(Panel.Position.X.Scale, Panel.Position.X.Offset,
                             Panel.Position.Y.Scale, Panel.Position.Y.Offset - 24),
    }):Play()
    tw(PanelStroke, 0.42, nil, nil, {Transparency = 0.35}):Play()
    tw(Brand, 0.4, nil, nil, {TextTransparency = 0}):Play()
    tw(Dot, 0.4, nil, nil, {BackgroundTransparency = 0}):Play()
    tw(MinBtn, 0.4, nil, nil, {BackgroundTransparency = 0, TextTransparency = 0}):Play()
    tw(CloseBtn, 0.4, nil, nil, {BackgroundTransparency = 0, TextTransparency = 0}):Play()
    tw(TabBar, 0.4, nil, nil, {BackgroundTransparency = 0}):Play()
    tw(TabStroke, 0.4, nil, nil, {Transparency = 0.5}):Play()
    tw(TabPill, 0.4, nil, nil, {BackgroundTransparency = 0.08}):Play()
    for _, button in ipairs(TabButtons) do
        tw(button, 0.35, nil, nil, {TextTransparency = 0}):Play()
    end

    task.delay(0.05, function()
        tw(RedeemBtn, 0.4, nil, nil, {BackgroundTransparency = 0, TextTransparency = 0}):Play()
        tw(RedeemStroke, 0.4, nil, nil, {Transparency = 0.6}):Play()
    end)
    task.delay(0.12, function()
        tw(AutoBox, 0.4, nil, nil, {BackgroundTransparency = 0}):Play()
        tw(AutoStroke, 0.4, nil, nil, {Transparency = 0.5}):Play()
        tw(SwitchStroke, 0.4, nil, nil, {Transparency = 0.5}):Play()
    end)
    task.delay(0.14, function()
        tw(AutoTag, 0.3, nil, nil, {TextTransparency = 0}):Play()
        tw(Switch, 0.3, nil, nil, {BackgroundTransparency = 0}):Play()
        tw(Knob, 0.3, nil, nil, {BackgroundTransparency = 0}):Play()
        tw(ThresholdBox, 0.35, nil, nil, {BackgroundTransparency = 0}):Play()
        tw(ThresholdStroke, 0.35, nil, nil, {Transparency = 0.5}):Play()
        if L.ThresholdMode == "custom" then showCustomControls() else showPresetControls() end
    end)
    task.delay(0.16, function()
        tw(SpeedBox, 0.4, nil, nil, {BackgroundTransparency = 0}):Play()
        tw(SpeedStroke, 0.4, nil, nil, {Transparency = 0.5}):Play()
        for _, b in ipairs(SpeedBtns) do
            tw(b, 0.4, nil, nil, {TextTransparency = 0}):Play()
        end
        for _, lbl in ipairs(StatusFade) do
            if lbl == StatusBar then
                tw(StatusBar, 0.4, nil, nil, {BackgroundTransparency = 0}):Play()
                tw(StatusStroke, 0.4, nil, nil, {Transparency = 0.5}):Play()
            else
                tw(lbl, 0.35, nil, nil, {TextTransparency = 0}):Play()
            end
        end
        tw(L.LayoutUI.Box, 0.4, nil, nil, {BackgroundTransparency = 0}):Play()
        tw(L.LayoutUI.Stroke, 0.4, nil, nil, {Transparency = 0.5}):Play()
        tw(L.LayoutUI.Tag, 0.35, nil, nil, {TextTransparency = 0}):Play()
        tw(L.LayoutUI.Track, 0.35, nil, nil, {BackgroundTransparency = 0}):Play()
        tw(L.LayoutUI.TrackStroke, 0.35, nil, nil, {Transparency = 0.5}):Play()
        tw(L.LayoutUI.Pill, 0.35, nil, nil, {BackgroundTransparency = 0.08}):Play()
        tw(L.LayoutUI.Tabbed, 0.35, nil, nil, {TextTransparency = 0}):Play()
        tw(L.LayoutUI.Panels, 0.35, nil, nil, {TextTransparency = 0}):Play()
        -- silent: the "online" notification is enough on boot
        L.SetSpeed(L.SpeedIndex, true)
    end)
    task.delay(0.19, function()
        tw(SendBtn, 0.4, nil, nil, {BackgroundTransparency = 0, TextTransparency = 0}):Play()
    end)
    task.delay(0.22, function()
        tw(PreviewBox, 0.4, nil, nil, {BackgroundTransparency = 0}):Play()
        tw(PreviewStroke, 0.4, nil, nil, {Transparency = 0.5}):Play()
        tw(PreviewTag, 0.35, nil, nil, {TextTransparency = 0}):Play()
        tw(PreviewCount, 0.35, nil, nil, {TextTransparency = 0}):Play()
        tw(PreviewText, 0.35, nil, nil, {TextTransparency = 0}):Play()
        tw(PreviewTrack, 0.35, nil, nil, {BackgroundTransparency = 0}):Play()
        tw(PreviewFill, 0.35, nil, nil, {BackgroundTransparency = 0}):Play()
    end)
    task.delay(0.25, function()
        tw(HistoryBox, 0.4, nil, nil, {BackgroundTransparency = 0}):Play()
        tw(HistoryStroke, 0.4, nil, nil, {Transparency = 0.5}):Play()
        tw(HistoryTag, 0.35, nil, nil, {TextTransparency = 0}):Play()
        tw(HistoryClear, 0.35, nil, nil, {TextTransparency = 0}):Play()
        for _, row in ipairs(HistoryRows) do
            tw(row, 0.35, nil, nil, {TextTransparency = 0}):Play()
        end
    end)
    task.delay(0.29, function()
        tw(BoxFrame, 0.4, nil, nil, {BackgroundTransparency = 0}):Play()
        tw(BoxStroke, 0.4, nil, nil, {Transparency = 0.5}):Play()
        tw(CodeBox, 0.4, nil, nil, {TextTransparency = 0}):Play()
    end)
    task.delay(0.16, function()
        for _, e in ipairs(L.SettingsFade) do
            tw(e.inst, 0.35, nil, nil, e.goal):Play()
        end
    end)
    task.delay(0.6, function() L.DotReady = true end)
    task.delay(0.7, function() L.Notify("Luminosity online", T.HIGH) end)
end)
