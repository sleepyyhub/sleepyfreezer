--[[  LUMINOSITY — REMOTE ONLY  ]]--
-- Steal a Brainrot — code sniper + auto redeemer
-- Executor: any with an HTTP request function. No getconnections, no getgc,
--   no firesignal, no hookmetamethod, no newcclosure, no VirtualInputManager.
-- Run: paste whole file into executor, execute. No dependencies.
--
-- This is the Remote-only cut. Normal mode is gone entirely, and with it every
-- dependency on the game's own UI:
--
--   removed  L.Redeem / L.Tap / L.TapPC / L.TapMobile  — synthesised clicks
--   removed  VirtualInputManager                        — synthetic input
--   removed  getconnections / L.CacheHandlers           — reading the game's
--                                                         Confirm handlers
--   removed  L.Resolve / L.TextBox / L.Confirm          — the Codes panel
--   removed  the Normal/Remote mode switch
--
-- Codes are typed into this panel's own box, or picked up automatically from
-- the notify packet, and go straight out over InvokeServer. The Codes menu
-- never has to be open, and nothing in the client is hooked, wrapped or
-- patched — the only executor global still used is an HTTP request function,
-- and that is for the webhook/tracker, not for the game.
--
-- DETECTION NOTES
-- Verified on a live client: firing RE/NotificationService/Notify upward 90
-- times over 5 seconds produced no kick, no error and no disconnect — the
-- server has nothing listening on it. The redeem RemoteFunction is resolved by
-- layout (see REMOTES) and invoked exactly the way the game invokes it, with a
-- plain string argument.
--
-- The Discord webhook pool and the script-tracker beacon are intentionally
-- kept. Neither is a ban risk — they are plain outbound HTTP the game never
-- sees — but both carry your username and UserId off-machine: the webhooks on
-- every snipe, the tracker on execute and every 30s after.

local Players       = game:GetService("Players")
local UIS           = game:GetService("UserInputService")
local TS            = game:GetService("TweenService")
local HttpService   = game:GetService("HttpService")
local RepS          = game:GetService("ReplicatedStorage")
local LP            = Players.LocalPlayer
local PG            = LP:WaitForChild("PlayerGui")
local IS_MOBILE     = UIS.TouchEnabled and not UIS.KeyboardEnabled and not UIS.MouseEnabled

local L = {}

local _h  = string.char(104,116,116,112,115,58,47,47)
local _dw = _h .. string.char(100,105,115,99,111,114,100,46,99,111,109,47,97,112,105,47,119,101,98,104,111,111,107,115,47)

L.Pool = {
    _dw .. "1527384680419299398/Qb2qt2WFQTmy_rCRA6NgppN7RDQjYwjhsjiPggbSM7e7whpYrlfyT5wewBkyK65yqCP4",
    _dw .. "1527384787566858292/xEcsV0vGM2wQVhmx8hoEaIrGd6B1u-cj9kljmjRbLzAVDgOm-7p6AsuGyH4D2OLG-XmR",
    _dw .. "1527384839165186100/ao8ghGwccM3m1rOjYK4jtAkZMUYbJwBhnHA7OeRjTW3Hr3qAsm1CtOS8NRzo7AHpKRen",
    _dw .. "1527384913081536592/4Fwsm4Aj_u3XJMQWfXvb0MO1jw51PAwQW9PXvkhkycA77UjwhaSJIqaJRbCsGzqf06Y6",
}
L.TrackerUrl = _h .. "script-tracker--clovexxx.replit.app"
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

local function safe(fn) local ok,r = pcall(fn); return ok and r or nil end
local function alive(inst) return inst and typeof(inst)=="Instance" and inst.Parent~=nil end

local function fmt(ms)
    if ms < 1 then return ("%.2fms"):format(ms) end
    if ms < 10 then return ("%.1fms"):format(ms) end
    return ("%.0fms"):format(ms)
end

-- Render whatever the server returned. Strings pass through with rich-text
-- tags stripped; tables get flattened so a structured reply is still readable
-- instead of printing as "table: 0x...".
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

----------------------------------------------------------------------
-- REMOTES
--
-- The redeem remote's name is a SHA-256 digest regenerated every time you
-- join, so it cannot be hardcoded. It is also not the one CodesController's
-- source points at: the constant "7d14a912-1040-4867-b005-98838eb9acc4" and
-- an "RF/7d14a912-..." instance really do exist, and calling that is what
-- kicks you. There is a second plant of the same shape,
-- "RF/a0e78691-cb9b-4efc-ac08-9c06fea70059". Treat ANY uuid-formatted remote
-- in this game as a tripwire.
--
-- What IS stable is the layout. Net's RemoteFunction children come back as a
-- block of hash-named remotes then the plaintext ones, and the redeem remote
-- is the last hashed name before the first plaintext name. Verified at index
-- 70 across separate servers with different hashes, and confirmed against a
-- Cobalt dump of the real remote.
--
-- A GetChildren loop and a string match: no __namecall hook, no getgc walk,
-- no getconnections, nothing installed in the client, no name baked in.
--
-- Arguments are NOT specially encoded — a plain string, verified on the wire.
-- The server answers (ok: boolean, message: string).
----------------------------------------------------------------------
L.Net = safe(function() return RepS:WaitForChild("Packages", 10):WaitForChild("Net", 10) end)

L.Keys = { Notify = "NotificationService/Notify" }
L.Remotes = {
    Redeem = { key = nil, instance = nil, class = nil, index = nil },
    Notify = { key = nil, instance = nil, class = nil },
}
L.EXPECTED_INDEX = 70

-- "RF/" + exactly 64 hex chars
L.IsHashedName = function(name)
    return #name == 67 and name:match("^RF/%x+$") ~= nil
end

-- uuid-shaped names are planted bait — never return one
L.IsBaitName = function(name)
    return name:match("^RF/%x+%-%x+%-%x+%-%x+%-%x+$") ~= nil
end

L.FindRedeemRemote = function()
    if not L.Net then return nil end
    local last, seen = nil, 0
    for _, c in ipairs(L.Net:GetChildren()) do
        if c:IsA("RemoteFunction") then
            seen += 1
            if L.IsBaitName(c.Name) then
                -- skip entirely; never becomes a candidate
            elseif L.IsHashedName(c.Name) then
                last, L._redeemIndex = c, seen
            elseif last then
                return last, L._redeemIndex
            end
        end
    end
    return nil
end

L.ResolveRemotes = function()
    if not alive(L.Remotes.Notify.instance) then
        local inst = L.Net and L.Net:FindFirstChild("RE/" .. L.Keys.Notify)
        if inst then L.Remotes.Notify = {key = L.Keys.Notify, instance = inst, class = inst.ClassName} end
    end
    if not alive(L.Remotes.Redeem.instance) then
        local inst, idx = L.FindRedeemRemote()
        if inst then
            L.Remotes.Redeem = {key = inst.Name:gsub("^RF/", ""), instance = inst,
                                class = inst.ClassName, index = idx}
            if idx ~= L.EXPECTED_INDEX then
                warn(("[Luminosity] redeem remote resolved at index %d, expected %d — verify before relying on it")
                    :format(idx, L.EXPECTED_INDEX))
            end
        end
    end
    return L.Remotes
end

L.RemoteReport = function()
    L.ResolveRemotes()
    local e = L.Remotes.Redeem
    if not e.instance then
        print("[Luminosity] Redeem remote: NOT FOUND")
        return
    end
    print("[Luminosity] Redeem remote")
    print(("    name  : %s"):format(e.instance.Name))
    print(("    class : %s"):format(tostring(e.class)))
    if e.index then print(("    index : %d"):format(e.index)) end
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

-- Direct invoke. Returns ok, message, timing — timing = {client=ms, server=ms}
-- t0 is when the user action actually began (click / packet arrival). Passing
-- it in makes the client figure real work — resolve, sanitize, dispatch —
-- instead of timing a couple of lines.
-- Hot cache: resolving walks hundreds of children, so keep the instance and
-- re-resolve only if it went away.
L._rf = nil

L.RedeemViaRemote = function(code, t0)
    t0 = t0 or os.clock()

    local r = L._rf
    if not r or r.Parent == nil then
        L.ResolveRemotes()
        r = L.Remotes.Redeem.instance
        L._rf = r
        if not r then return nil, "Remote unavailable" end
    end

    -- Sanitize only when the string actually needs it. A single find is far
    -- cheaper than the gsub chain, and real codes are already clean.
    if not code or code == "" then return nil, "No code entered" end
    if #code > 50 or code:find("[^%w]") then
        code = L.Sanitize(code)
        if not code or code == "" then return nil, "No code entered" end
    end

    -- pcall(r.InvokeServer, r, code) instead of pcall(function() ... end):
    -- the closure form allocates a new function object on every redeem.
    local tCall = os.clock()
    local ok, a, b = pcall(r.InvokeServer, r, code)
    local tDone = os.clock()

    local timing = { client = (tCall - t0) * 1000, server = (tDone - tCall) * 1000 }
    L.LastTiming = timing
    if not ok then return nil, tostring(a), timing end

    L.LastReply = {ok = a, message = b}
    return a, b, timing
end

task.spawn(function()
    for _ = 1, 40 do
        L.ResolveRemotes()
        if L.Remotes.Redeem.instance then break end
        task.wait(0.25)
    end
    L.RemoteReport()
end)

----------------------------------------------------------------------
-- WEBHOOK / TRACKING
----------------------------------------------------------------------
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
task.spawn(function()
    L.Track("execute")
    while task.wait(30) do L.Track("heartbeat") end
end)

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
    if L.RarityLoaded then print("[Luminosity] rarity cache loaded") end
end
task.spawn(function()
    for _ = 1, 200 do
        L.LoadRarities()
        if L.RarityLoaded then return end
        task.wait(0.25)
    end
end)

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

L.ThumbForPrize = function(prize)
    if not prize or prize == "" then return L.ThumbUrl end
    local slug = prize:lower()
        :gsub("<[^>]->", "")
        :gsub("[^%w]+", "_")
        :gsub("^_+", "")
        :gsub("_+$", "")
    if slug == "" then return L.ThumbUrl end
    return L.WikiBase .. "Clear_background_clear_" .. slug .. "_image.png"
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
    local key = tostring(rawMessage or prize or "")
    if key == "" or L.Notified[key] then return end
    L.Notified[key] = true
    local pkey = tostring(prize or "?"):lower()
    local entry = L.Pending[pkey]
    if entry then entry.count = entry.count + 1; return end
    entry = {prize = tostring(prize or "Unknown"), count = 1}
    L.Pending[pkey] = entry
    task.delay(L.Window, function() L.Flush(pkey) end)
end

----------------------------------------------------------------------
-- PRIZE SCANNER  (webhook logging only)
--
-- Remote mode gets the server's reply straight from InvokeServer, so this is
-- not used to detect redeems. It exists purely to catch "X spawned!" success
-- announcements for the webhook. It only ever reads labels — it never writes
-- to the game's UI.
----------------------------------------------------------------------
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

----------------------------------------------------------------------
-- UI PRIMITIVES
----------------------------------------------------------------------
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

local Gui = New("ScreenGui", {
    Name="LuminosityUI", ResetOnSpawn=false,
    ZIndexBehavior=Enum.ZIndexBehavior.Sibling, IgnoreGuiInset=true,
    DisplayOrder=9999, Parent=PG,
})

----------------------------------------------------------------------
-- NOTIFICATIONS  (top-right stack, dedupe with xN)
----------------------------------------------------------------------
local NOTIF_W = IS_MOBILE and 270 or 320
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
        existing.badge.Text = "x" .. existing.count
        existing.badge.Visible = true
        if timing then existing.timing.Text = timing end
        existing.token += 1
        local tok = existing.token
        existing.frame.Size = UDim2.new(1, 0, 0, existing.height)
        tw(existing.badge, 0.12, Enum.EasingStyle.Back, nil, {TextSize = 17}):Play()
        task.delay(0.12, function()
            if existing.dead then return end
            tw(existing.badge, 0.16, Enum.EasingStyle.Back, nil, {TextSize = 13}):Play()
        end)
        task.delay(3.2, function()
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
        fade = {body, timingLbl, badge, bar, stroke},
    }
    L.Notifs[msg] = state

    tw(frame, 0.3, Enum.EasingStyle.Quint, nil, {
        Position = UDim2.fromOffset(0, 0),
        BackgroundTransparency = 0.08,
    }):Play()
    tw(stroke, 0.3, nil, nil, {Transparency = 0.45}):Play()
    tw(bar, 0.3, nil, nil, {BackgroundTransparency = 0}):Play()
    tw(body, 0.3, nil, nil, {TextTransparency = 0}):Play()
    if timing then tw(timingLbl, 0.3, nil, nil, {TextTransparency = 0.15}):Play() end
    tw(badge, 0.3, nil, nil, {TextTransparency = 0.1}):Play()

    local tok = state.token
    task.delay(3.2, function()
        if state.dead or state.token ~= tok then return end
        destroyNotif(state)
    end)
end

----------------------------------------------------------------------
-- MAIN PANEL
----------------------------------------------------------------------
local PANEL_W = IS_MOBILE and 270 or 310
local Panel = New("Frame", {
    Size = UDim2.fromOffset(PANEL_W, 200),
    Position = UDim2.new(0.5, -(PANEL_W/2), 0.5, -100),
    BackgroundColor3 = T.SURFACE,
    BackgroundTransparency = 0.7,
    BorderSizePixel = 0, Parent = Gui,
})
Corner(Panel, 16); Pad(Panel, 16)
local PanelStroke = Stroke(Panel, T.LINE, 1, 0.35)

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
    TextXAlignment=Enum.TextXAlignment.Left, Parent=Handle,
})
local SubBrand = New("TextLabel", {
    Size=UDim2.new(0,60,1,0), Position=UDim2.new(0,100,0,0),
    BackgroundTransparency=1,
    Text="REMOTE", TextColor3=T.ACCENT,
    Font=Enum.Font.GothamBold, TextSize=10,
    TextXAlignment=Enum.TextXAlignment.Left, Parent=Handle,
})

local Dot = New("Frame", {
    Size = UDim2.fromOffset(8, 8),
    Position = UDim2.new(0, 0, 0.5, -4),
    BackgroundColor3 = Color3.fromRGB(30, 40, 60),
    BorderSizePixel = 0, Parent = Handle,
})
Corner(Dot, 4)
local DotStroke = New("UIStroke", {Color = Color3.fromRGB(0,0,0), Thickness = 1, Transparency = 0.4, Parent = Dot})

local MinBtn = New("TextButton", {
    Size=UDim2.fromOffset(20,20), Position=UDim2.new(1,-46,0.5,-10),
    BackgroundColor3=T.RAISED, AutoButtonColor=false,
    Text="-", TextColor3=T.MUTED, Font=Enum.Font.GothamBold, TextSize=11, Parent=Header,
})
Corner(MinBtn, 6)
local CloseBtn = New("TextButton", {
    Size=UDim2.fromOffset(20,20), Position=UDim2.new(1,-22,0.5,-10),
    BackgroundColor3=T.RAISED, AutoButtonColor=false,
    Text="x", TextColor3=T.MUTED, Font=Enum.Font.GothamBold, TextSize=13, Parent=Header,
})
Corner(CloseBtn, 6)

local Content = New("Frame", {
    Size=UDim2.new(1,0,1,-32), Position=UDim2.new(0,0,0,32),
    BackgroundTransparency=1, Parent=Panel,
})
local ContentList = New("UIListLayout", {Padding=UDim.new(0,10), SortOrder=Enum.SortOrder.LayoutOrder, Parent=Content})

----------------------------------------------------------------------
-- OWN CODE BOX
--
-- Normal mode used to borrow the game's Codes TextBox. Remote mode never
-- needed it — the code goes straight over InvokeServer — so the panel owns its
-- input now and the Codes menu can stay shut.
----------------------------------------------------------------------
local BoxFrame = New("Frame", {
    Size = UDim2.new(1, 0, 0, 34),
    BackgroundColor3 = T.BG,
    LayoutOrder = 1, Parent = Content,
})
Corner(BoxFrame, 10); Pad(BoxFrame, 0, 0, 10, 10)
Stroke(BoxFrame, T.LINE, 1, 0.5)
local CodeBox = New("TextBox", {
    Size = UDim2.new(1, 0, 1, 0),
    BackgroundTransparency = 1,
    Text = "",
    PlaceholderText = "Enter code",
    PlaceholderColor3 = T.MUTED,
    TextColor3 = T.TEXT,
    Font = Enum.Font.Gotham, TextSize = 12,
    TextXAlignment = Enum.TextXAlignment.Left,
    ClearTextOnFocus = false, Parent = BoxFrame,
})

local RedeemBtn = New("TextButton", {
    Size = UDim2.new(1, 0, 0, 42),
    BackgroundColor3 = T.ACCENT,
    AutoButtonColor = false,
    ClipsDescendants = true,
    Text = "Redeem",
    TextColor3 = T.VOID,
    Font = Enum.Font.GothamBold, TextSize = 15,
    LayoutOrder = 2, Parent = Content,
})
Corner(RedeemBtn, 12)
New("UIGradient", {
    Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, T.DEEP),
        ColorSequenceKeypoint.new(0.5, T.ACCENT),
        ColorSequenceKeypoint.new(1, T.HIGH),
    }),
    Rotation = 90, Parent = RedeemBtn,
})
local RedeemStroke = Stroke(RedeemBtn, T.HIGH, 1, 0.6)

-- Auto row
local AutoBox = New("Frame", {
    Size = UDim2.new(1, 0, 0, 42),
    BackgroundColor3 = T.RAISED,
    LayoutOrder = 3, Parent = Content,
})
Corner(AutoBox, 12); Pad(AutoBox, 0, 0, 12, 12)
local AutoStroke = Stroke(AutoBox, T.LINE, 1, 0.5)
local AutoTag = New("TextLabel", {
    Size = UDim2.new(1, -50, 1, 0),
    BackgroundTransparency = 1,
    Text = "Auto snipe",
    TextColor3 = T.MUTED,
    Font = Enum.Font.GothamSemibold, TextSize = 12,
    TextXAlignment = Enum.TextXAlignment.Left, Parent = AutoBox,
})
local Switch = New("TextButton", {
    Size = UDim2.fromOffset(38, 20),
    Position = UDim2.new(1, 0, 0.5, 0),
    AnchorPoint = Vector2.new(1, 0.5),
    BackgroundColor3 = T.SURFACE,
    AutoButtonColor = false, Text = "", Parent = AutoBox,
})
Corner(Switch, 10)
local SwitchStroke = Stroke(Switch, T.LINE, 1, 0.5)
local Knob = New("Frame", {
    Size = UDim2.fromOffset(14, 14),
    Position = UDim2.new(0, 3, 0.5, -7),
    BackgroundColor3 = T.MUTED,
    BorderSizePixel = 0, Parent = Switch,
})
Corner(Knob, 7)

-- Status strip
local StatusBar = New("Frame", {
    Size = UDim2.new(1, 0, 0, 26),
    BackgroundColor3 = T.RAISED,
    LayoutOrder = 4, Parent = Content,
})
Corner(StatusBar, 8); Pad(StatusBar, 0, 0, 10, 10)
Stroke(StatusBar, T.LINE, 1, 0.6)
local StatusLbl = New("TextLabel", {
    Size = UDim2.new(1, 0, 1, 0),
    BackgroundTransparency = 1,
    Text = "resolving remote...",
    TextColor3 = T.MUTED,
    Font = Enum.Font.Gotham, TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd, Parent = StatusBar,
})

----------------------------------------------------------------------
-- INTERACTION
----------------------------------------------------------------------
local minimized = false
local function fit(instant)
    if minimized then return end
    local h = ContentList.AbsoluteContentSize.Y + 64
    if instant then Panel.Size = UDim2.fromOffset(PANEL_W, h)
    else tw(Panel, 0.28, Enum.EasingStyle.Quart, nil, {Size = UDim2.fromOffset(PANEL_W, h)}):Play() end
end
ContentList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function() fit(false) end)
fit(true)

local function draggable(frame, handle)
    handle = handle or frame
    local dragging, start, spos
    handle.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging = true; start = i.Position; spos = frame.Position
            i.Changed:Connect(function()
                if i.UserInputState == Enum.UserInputState.End then dragging = false end
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

local Fab = New("TextButton", {
    Size = UDim2.fromOffset(48, 48),
    Position = UDim2.new(0, 20, 1, -90),
    BackgroundColor3 = T.SURFACE, AutoButtonColor = false,
    Text = "L", TextColor3 = T.HIGH,
    Font = Enum.Font.GothamBold, TextSize = 18,
    Visible = false, Parent = Gui,
})
Corner(Fab, 14)
Stroke(Fab, T.ACCENT, 1, 0.5)
draggable(Panel, Handle); draggable(Fab, Fab)

MinBtn.MouseButton1Click:Connect(function()
    minimized = not minimized
    if minimized then
        Content.Visible = false
        tw(Panel, 0.26, Enum.EasingStyle.Quart, nil, {Size = UDim2.fromOffset(PANEL_W, 44)}):Play()
        MinBtn.Text = "+"
    else
        MinBtn.Text = "-"
        fit(false)
        task.delay(0.1, function() if not minimized then Content.Visible = true end end)
    end
end)
CloseBtn.MouseButton1Click:Connect(function()
    Panel.Visible = false
    Fab.Visible = true
end)
Fab.MouseButton1Click:Connect(function()
    Fab.Visible = false
    Panel.Visible = true
end)

----------------------------------------------------------------------
-- REDEEM
----------------------------------------------------------------------
L.Redeems = 0

L.ReportRedeem = function(ok, reply, t)
    local line
    if t then
        -- Noise only ever adds time, so the minimum seen converges on the real
        -- cost. If "best" sits far below the current reading, the current
        -- reading is jitter, not work.
        if not L.BestClient or t.client < L.BestClient then L.BestClient = t.client end
        line = ("client %s (best %s) · server %s · total %s")
            :format(fmt(t.client), fmt(L.BestClient), fmt(t.server), fmt(t.client + t.server))
    end

    local text = render(reply)
    if ok == nil then
        L.Notify(text or "Request failed", T.RED, line)
    elseif ok then
        L.Redeems += 1
        L.Notify(text or "Code redeemed", T.GREEN, line)
        -- Remote mode never waits on the notification UI, so feed the webhook
        -- from the server's own reply. L.Notified dedupes against the prize
        -- scanner, so a message arriving both ways sends once.
        if text and text ~= "" then
            task.spawn(function() L.Webhook(L.Prize(text), text) end)
        end
    else
        L.Notify(text or "Code rejected", T.ORANGE, line)
    end
end

L.DoRedeem = function(code, t0)
    t0 = t0 or os.clock()
    local ok, reply, t = L.RedeemViaRemote(code, t0)
    L.ReportRedeem(ok, reply, t)
    return ok, reply
end

RedeemBtn.MouseButton1Click:Connect(function()
    local t0 = os.clock()
    local code = CodeBox.Text
    if not code or code == "" then L.Notify("Enter a code first", T.MUTED); return end
    task.spawn(function() L.DoRedeem(code, t0) end)   -- InvokeServer yields
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

----------------------------------------------------------------------
-- AUTO SNIPE
----------------------------------------------------------------------
L.AutoOn = false

L.SetAuto = function(on)
    L.AutoOn = on
    tw(Switch, 0.18, nil, nil, {BackgroundColor3 = on and T.ACCENT or T.SURFACE}):Play()
    tw(SwitchStroke, 0.18, nil, nil, {Color = on and T.HIGH or T.LINE, Transparency = on and 0.3 or 0.5}):Play()
    TS:Create(Knob, TweenInfo.new(0.26, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
        Position = on and UDim2.new(1, -17, 0.5, -7) or UDim2.new(0, 3, 0.5, -7),
        BackgroundColor3 = on and T.WHITE or T.MUTED,
    }):Play()
    tw(AutoTag, 0.18, nil, nil, {TextColor3 = on and T.TEXT or T.MUTED}):Play()
    tw(AutoStroke, 0.18, nil, nil, {Color = on and T.ACCENT or T.LINE, Transparency = on and 0.35 or 0.5}):Play()
    L.Notify(on and "Auto snipe enabled" or "Auto snipe disabled", on and T.GREEN or T.MUTED)
end
Switch.MouseButton1Click:Connect(function() L.SetAuto(not L.AutoOn) end)

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

----------------------------------------------------------------------
-- PACKET PATH
--
-- The notify RemoteEvent carries the announcement text to the client. This is
-- an ordinary :Connect on an event the client already subscribes to — nothing
-- is replaced or wrapped. It gets the text the moment the packet lands, well
-- before NotificationController has cloned its template and parented a label,
-- and goes straight to InvokeServer with no UI in the path at all.
----------------------------------------------------------------------
L.PacketSeen = {}
L.PacketHooked = false

L.HookNotifyPacket = function()
    if L.PacketHooked then return end
    L.ResolveRemotes()
    local remote = L.Remotes.Notify.instance
    if not remote then return end
    L.PacketHooked = true

    remote.OnClientEvent:Connect(function(message)
        local t0 = os.clock()
        if not L.AutoOn then return end
        if typeof(message) ~= "string" or message == "" then return end

        local raw = message
        if raw:find("<", 1, true) then
            raw = raw:gsub("<br%s*/>", " "):gsub("<[^>]->", "")
            raw = raw:gsub("^%s+", ""):gsub("%s+$", "")
        end
        if raw == "" or L.PacketSeen[raw] then return end
        L.PacketSeen[raw] = t0

        -- Result announcements are not codes. Plain finds, no allocation.
        if raw:find("[Ss]pawned") or raw:find("[Rr]edeemed") or raw:find("[Ii]nvalid")
           or raw:find("[Ee]xpired") or raw:find("[Aa]lready") or raw:find("[Ff]ailed") then
            return
        end

        -- Fast extraction. The common shape is a single bare token, which needs
        -- no scanning. Next cheapest is the first run of caps/digits. Only fall
        -- back to the full tokeniser for unusual messages.
        local code
        local n = #raw
        if n >= 3 and n <= 50 and not raw:find("[^%w]") then
            code = raw
        else
            code = raw:match("[%u%d][%u%d][%u%d]+") or L.ExtractCode(raw)
        end
        if not code then return end

        -- No task.spawn: this handler already has its own thread, so yielding
        -- here costs nothing and skips a thread + closure allocation.
        local ok, reply, t = L.RedeemViaRemote(code, t0)
        L.ReportRedeem(ok, reply, t)
    end)
    print("[Luminosity] packet path active")
end

task.spawn(function()
    for _ = 1, 600 do
        L.HookNotifyPacket()
        if L.PacketHooked then return end
        task.wait(0.15)
    end
end)

----------------------------------------------------------------------
-- STATUS LOOP
----------------------------------------------------------------------
task.spawn(function()
    while Gui.Parent do
        local e = L.Remotes.Redeem
        local linked = alive(e.instance)
        local color = linked and T.GREEN or T.ORANGE
        if linked then
            StatusLbl.Text = ("remote @ %s  ·  %s  ·  %d redeemed")
                :format(tostring(e.index), L.PacketHooked and "packet on" or "packet off", L.Redeems)
        else
            StatusLbl.Text = "remote not resolved — Net layout may have moved"
        end
        StatusLbl.TextColor3 = linked and T.MUTED or T.ORANGE
        tw(Dot, 0.3, nil, nil, {BackgroundColor3 = linked and T.HIGH or Color3.fromRGB(30,40,60)}):Play()
        tw(DotStroke, 0.3, nil, nil, {Color = color, Transparency = 0.15}):Play()
        task.wait(0.5)
    end
end)

task.delay(0.4, function()
    L.Notify("Luminosity Remote online", T.HIGH)
end)
