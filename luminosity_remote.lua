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
-- The interface is otherwise the original one, unchanged: same loader, moon
-- rain, letter intro, shimmer, pulse ring, ripple and press feedback, auto row
-- with word threshold, clipboard paste and animated FAB. Two visual changes
-- only, both forced by the cut: the Normal/Remote switch is replaced by the
-- panel's own code box (Remote mode used to borrow the game's Codes TextBox,
-- so the Codes menu had to be open), and the capture hint card is gone with
-- the hook it belonged to.
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
L.LegacyHook = _dw .. "1523761474810679558/Dedz2zIQfir7lIlLpNeN4Uqm2SdkjZ4oNXqCq4qq_yPkK6VFrWEljo3DYn4cYdCBjjyk"
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

-- preclean: the caller has already proven the string is bare alphanumeric and
-- in range, so the sanitize precheck is skipped. The packet path knows this
-- for free — it had to run that exact test to classify the message — so
-- repeating it here would be pure duplicated work on the hot path.
L.RedeemViaRemote = function(code, t0, preclean)
    t0 = t0 or os.clock()

    local r = L._rf
    if not r or r.Parent == nil then
        L.ResolveRemotes()
        r = L.Remotes.Redeem.instance
        L._rf = r
        if not r then return nil, "Remote unavailable" end
    end

    if not preclean then
        -- Sanitize only when the string actually needs it. A single find is far
        -- cheaper than the gsub chain, and real codes are already clean.
        if not code or code == "" then return nil, "No code entered" end
        if #code > 50 or code:find("[^%w]") then
            code = L.Sanitize(code)
            if not code or code == "" then return nil, "No code entered" end
        end
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
    -- Prime the hot cache so the very first redeem does not pay for the
    -- GetChildren walk.
    L._rf = L.Remotes.Redeem.instance
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
-- LOADING SCREEN
----------------------------------------------------------------------
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
L.RainActive = true
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
        task.wait(0.11)
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
    New("UIStroke", {
        Color = Color3.fromRGB(0,0,0),
        Thickness = 2,
        Transparency = 0.1,
        LineJoinMode = Enum.LineJoinMode.Round,
        Parent = lbl,
    })
    Letters[i] = lbl
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

----------------------------------------------------------------------
-- MAIN PANEL
----------------------------------------------------------------------
local PANEL_W = IS_MOBILE and 260 or 300
local Panel = New("Frame", {
    Size = UDim2.fromOffset(PANEL_W, 190),
    Position = UDim2.new(0.5, -(PANEL_W/2), 0.5, -95 + 40),
    BackgroundColor3 = T.SURFACE,
    BackgroundTransparency = 1,
    BorderSizePixel = 0, Parent = Gui,
})
Corner(Panel, 16); Pad(Panel, 16)
local PanelStroke = Stroke(Panel, T.LINE, 1, 1)

-- Slow aurora sweep across the panel fill. Cheap: one gradient, one loop.
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

-- Header
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
-- Shimmer sweep across the wordmark
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
-- Expanding ring that pulses out of the dot when we're linked up
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
            -- "Linked" now means the redeem remote resolved, since there is no
            -- game TextBox/Confirm to bind to any more.
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

-- Content
local Content = New("Frame", {
    Size=UDim2.new(1,0,1,-32), Position=UDim2.new(0,0,0,32),
    BackgroundTransparency=1, Parent=Panel,
})
local ContentList = New("UIListLayout", {Padding=UDim.new(0,10), SortOrder=Enum.SortOrder.LayoutOrder, Parent=Content})

----------------------------------------------------------------------
-- NOTIFICATIONS  (top-right stack, dedupe with ×N)
--
-- Identical messages don't stack up as duplicates — the live card gets a
-- ×N badge, its timer resets and it pulses. Each card carries an accent
-- bar on the left tinted to its kind, and an optional timing footer.
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

-- msg   : body text
-- color : accent colour
-- timing: optional string shown small underneath
L.Notify = function(msg, color, timing)
    msg = tostring(msg or "")
    if msg == "" then return end
    color = color or T.HIGH

    -- dedupe: same body text while still on screen -> bump the counter
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

    -- accent bar down the left edge
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
-- CODE BOX
--
-- Sits where the Normal/Remote switch used to. Remote mode previously read the
-- code out of the game's own Codes TextBox, which meant that menu had to be
-- open; the panel owns its input now so nothing touches the game's UI.
----------------------------------------------------------------------
local BoxFrame = New("Frame", {
    Size = UDim2.new(1, 0, 0, 30),
    BackgroundColor3 = T.BG,
    BackgroundTransparency = 1,
    LayoutOrder = 1, Parent = Content,
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
    Font = Enum.Font.Gotham, TextSize = 12,
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

-- breathing room between the code box and what follows
New("Frame", {
    Size = UDim2.new(1, 0, 0, 6),
    BackgroundTransparency = 1,
    LayoutOrder = 2, Parent = Content,
})

-- Primary redeem button
local RedeemBtn = New("TextButton", {
    Size = UDim2.new(1, 0, 0, 44),
    BackgroundColor3 = T.ACCENT,
    AutoButtonColor = false,
    ClipsDescendants = true,
    Text = "Redeem",
    TextColor3 = T.VOID,
    Font = Enum.Font.GothamBold, TextSize = 15,
    BackgroundTransparency = 1, TextTransparency = 1,
    LayoutOrder = 4, Parent = Content,
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

-- Auto Redeemer row
local AutoBox = New("Frame", {
    Size = UDim2.new(1, 0, 0, 44),
    BackgroundColor3 = T.RAISED,
    BackgroundTransparency = 1,
    LayoutOrder = 5, Parent = Content,
})
Corner(AutoBox, 12); Pad(AutoBox, 0, 0, 12, 12)
local AutoStroke = Stroke(AutoBox, T.LINE, 1, 1)
New("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal,
    VerticalAlignment=Enum.VerticalAlignment.Center,
    HorizontalAlignment=Enum.HorizontalAlignment.Left, Parent=AutoBox})

local AutoTag = New("TextLabel", {
    Size = UDim2.new(1, -154, 1, 0),
    BackgroundTransparency = 1,
    Text = "Auto",
    TextColor3 = T.MUTED,
    Font = Enum.Font.GothamSemibold, TextSize = 12,
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
New("Frame", {Size=UDim2.fromOffset(6,1), BackgroundTransparency=1, LayoutOrder=3, Parent=AutoBox})

local Minus = New("TextButton", {
    Size = UDim2.fromOffset(28, 28),
    BackgroundColor3 = T.SURFACE, AutoButtonColor = false,
    Text = "−", TextColor3 = T.HIGH, Font = Enum.Font.GothamBold, TextSize = 16,
    BackgroundTransparency = 1, TextTransparency = 1,
    LayoutOrder = 4, Parent = AutoBox,
})
Corner(Minus, 8)

local Count = New("TextLabel", {
    Size = UDim2.fromOffset(48, 28),
    BackgroundTransparency = 1,
    Text = "0",
    TextColor3 = T.TEXT,
    Font = Enum.Font.GothamBold, TextSize = 15,
    TextTransparency = 1,
    LayoutOrder = 5, Parent = AutoBox,
})

local Plus = New("TextButton", {
    Size = UDim2.fromOffset(28, 28),
    BackgroundColor3 = T.SURFACE, AutoButtonColor = false,
    Text = "+", TextColor3 = T.HIGH, Font = Enum.Font.GothamBold, TextSize = 16,
    BackgroundTransparency = 1, TextTransparency = 1,
    LayoutOrder = 6, Parent = AutoBox,
})
Corner(Plus, 8)

local SendBtn = New("TextButton", {
    Size = UDim2.new(1, 0, 0, 30),
    BackgroundColor3 = T.RAISED, AutoButtonColor = false,
    ClipsDescendants = true,
    Text = "Paste from clipboard",
    TextColor3 = T.MUTED,
    Font = Enum.Font.GothamSemibold, TextSize = 11,
    BackgroundTransparency = 1, TextTransparency = 1,
    LayoutOrder = 6, Parent = Content,
})
Corner(SendBtn, 10)

-- FAB (when closed)
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
            task.wait(0.4)
        end
    end
end)

----------------------------------------------------------------------
-- INTERACTION HELPERS
----------------------------------------------------------------------
local minimized = false

-- Panel height follows its content instead of being hardcoded, so rows can
-- grow/shrink without anything overlapping.
local function fit(instant)
    if minimized then return end
    local h = ContentList.AbsoluteContentSize.Y + 64
    if instant then
        Panel.Size = UDim2.fromOffset(PANEL_W, h)
    else
        tw(Panel, 0.28, Enum.EasingStyle.Quart, nil, {Size = UDim2.fromOffset(PANEL_W, h)}):Play()
    end
end
ContentList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function() fit(false) end)

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
draggable(Panel, Handle); draggable(Fab, Fab)

-- Circular ripple from the click point. Purely cosmetic, self-cleaning.
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
press(RedeemBtn, UDim2.new(1,0,0,44))
press(SendBtn,   UDim2.new(1,0,0,30))
press(Minus,     UDim2.fromOffset(28,28))
press(Plus,      UDim2.fromOffset(28,28))
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
hoverFill(Minus,   T.SURFACE, T.RAISED)
hoverFill(Plus,    T.SURFACE, T.RAISED)
hoverFill(MinBtn,  T.RAISED,  T.RAISED:Lerp(T.ACCENT, 0.2))
hoverFill(CloseBtn,T.RAISED,  Color3.fromRGB(50, 22, 34))
hoverFill(Fab,     T.SURFACE, T.RAISED)

-- Hero button gets a stroke glow instead of a fill shift
RedeemBtn.MouseEnter:Connect(function()
    tw(RedeemStroke, 0.15, nil, nil, {Transparency = 0.15, Thickness = 2}):Play()
    tw(RedeemGrad, 0.3, nil, nil, {Rotation = 45}):Play()
end)
RedeemBtn.MouseLeave:Connect(function()
    tw(RedeemStroke, 0.25, nil, nil, {Transparency = 0.6, Thickness = 1}):Play()
    tw(RedeemGrad, 0.3, nil, nil, {Rotation = 90}):Play()
end)

----------------------------------------------------------------------
-- REDEEM
----------------------------------------------------------------------
-- Everything here runs AFTER the invoke has returned, so none of it lands in
-- the client figure.
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

    -- Show the server's own words. Only fall back to our text when it returned
    -- nothing at all.
    local text = render(reply)
    if ok == nil then
        L.Notify(text or "Request failed", T.RED, line)
    elseif ok then
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
-- AUTO REDEEMER LOGIC
----------------------------------------------------------------------
L.AutoOn = false
L.Threshold = 1; L.Sent = 0
L.RecentRedeem = 0

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

L.RefreshAuto = function()
    if not L.AutoOn or L.Threshold == 0 then
        Count.Text = tostring(L.Threshold)
        tw(Count, 0.15, nil, nil, {TextColor3 = T.MUTED}):Play()
    else
        Count.Text = L.Sent .. " / " .. L.Threshold
        tw(Count, 0.15, nil, nil, {TextColor3 = T.HIGH}):Play()
    end
end

L.SetAuto = function(on)
    L.AutoOn = on
    L.Sent = 0
    if on and L.Threshold < 1 then L.Threshold = 1 end
    tw(Switch, 0.18, nil, nil, {BackgroundColor3 = on and T.ACCENT or T.SURFACE}):Play()
    tw(SwitchStroke, 0.18, nil, nil, {Color = on and T.HIGH or T.LINE, Transparency = on and 0.3 or 0.5}):Play()
    TS:Create(Knob, TweenInfo.new(0.26, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
        Position = on and UDim2.new(1, -17, 0.5, -7) or UDim2.new(0, 3, 0.5, -7),
        BackgroundColor3 = on and T.WHITE or T.MUTED,
    }):Play()
    tw(AutoTag, 0.18, nil, nil, {TextColor3 = on and T.TEXT or T.MUTED}):Play()
    tw(AutoStroke, 0.18, nil, nil, {Color = on and T.ACCENT or T.LINE, Transparency = on and 0.35 or 0.5}):Play()
    L.RefreshAuto()
    L.Notify(on and "Auto redeem enabled" or "Auto redeem disabled", on and T.GREEN or T.MUTED)
end

Switch.MouseButton1Click:Connect(function() L.SetAuto(not L.AutoOn) end)
Minus.MouseButton1Click:Connect(function()
    L.Threshold = math.max(0, L.Threshold - 1); L.RefreshAuto()
end)
Plus.MouseButton1Click:Connect(function()
    L.Threshold = math.min(50, L.Threshold + 1); L.RefreshAuto()
end)
L.RefreshAuto()

SendBtn.MouseButton1Click:Connect(function()
    local getClip = (getclipboard or (Clipboard and Clipboard.get) or nil)
    if not getClip then L.Notify("Clipboard unavailable", T.RED); return end
    local ok, txt = pcall(getClip)
    if not (ok and typeof(txt) == "string" and #txt > 0) then L.Notify("Clipboard is empty", T.RED); return end
    local cur = CodeBox.Text or ""
    CodeBox.Text = (cur ~= "" and cur .. " " .. txt) or txt
    L.Notify("Pasted from clipboard", T.HIGH)
end)

----------------------------------------------------------------------
-- PANEL MIN / CLOSE
----------------------------------------------------------------------
MinBtn.MouseButton1Click:Connect(function()
    minimized = not minimized
    if minimized then
        Content.Visible = false
        tw(Panel, 0.26, Enum.EasingStyle.Quart, nil, {Size = UDim2.fromOffset(PANEL_W, 44)}):Play()
        MinBtn.Text = "+"
    else
        MinBtn.Text = "—"
        minimized = false
        fit(false)
        task.delay(0.1, function() if not minimized then Content.Visible = true end end)
    end
end)
CloseBtn.MouseButton1Click:Connect(function()
    tw(Panel, 0.2, Enum.EasingStyle.Quart, nil, {
        BackgroundTransparency = 1,
        Size = UDim2.fromOffset(PANEL_W * 0.9, Panel.Size.Y.Offset * 0.9),
    }):Play()
    task.delay(0.2, function()
        Panel.Visible = false
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
    task.delay(0.18, function()
        Fab.Visible = false
        Fab.Rotation = 0
        Fab.Size = UDim2.fromOffset(48, 48)
        Panel.Visible = true
    end)
end)

----------------------------------------------------------------------
-- PACKET PATH
--
-- The notify RemoteEvent carries the announcement text to the client. This is
-- an ordinary :Connect on an event the client already subscribes to — nothing
-- is replaced or wrapped. It gets the text the moment the packet lands, which
-- is the earliest any client code can possibly see an announcement: the UI
-- scanner only runs once NotificationController has cloned its template,
-- applied rich text and parented a label, a frame or more later.
--
-- Everything in this handler is ordered around one rule: nothing that is not
-- required to decide "fire or not" may run before InvokeServer. Measured on a
-- live client, the old ordering carried ~6.3us of avoidable work in front of
-- the wire, and 4.67us of that was a single TweenService:Create + Play from
-- refreshing the counter label. All display work is now deferred behind the
-- invoke, so it lands after the packet is already gone.
--
--   filter    6 pattern finds  1.07us  ->  bare-token test + hash  0.35us
--   sanitize  precheck         0.18us  ->  skipped via preclean    0.00us
--   counter   gmatch           0.32us  ->  skipped when threshold<=1
--   UI        tween            4.67us  ->  deferred behind the wire
--
-- Worth being straight about the scale: the server round trip measured 1210ms,
-- so this is ~6us shaved off ~1.2 million. It costs nothing to do it right,
-- but the packet path itself — arriving a frame earlier than the UI — is where
-- the real win already was.
----------------------------------------------------------------------
L.PacketSeen = {}
L.PacketHooked = false

-- Bare tokens that are results, not codes. A single hash lookup replaces six
-- pattern scans for the common case.
local RESULT_WORDS = {
    spawned = true, redeemed = true, invalid = true,
    expired = true, already = true, failed = true,
}

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

        -- Classify first. A real code is a single bare alphanumeric token, and
        -- that one test also proves the string needs no sanitizing downstream,
        -- so it is worth doing before anything else.
        local code, preclean
        local n = #raw
        if n >= 3 and n <= 50 and not raw:find("[^%w]") then
            if RESULT_WORDS[raw:lower()] then return end
            code, preclean = raw, true
        else
            -- Uncommon shape: sentences, punctuation, rich text remnants.
            if raw:find("[Ss]pawned") or raw:find("[Rr]edeemed") or raw:find("[Ii]nvalid")
               or raw:find("[Ee]xpired") or raw:find("[Aa]lready") or raw:find("[Ff]ailed") then
                return
            end
            code = raw:match("[%u%d][%u%d][%u%d]+") or L.ExtractCode(raw)
            if not code then return end
            preclean = false
        end
        L.PacketSeen[raw] = t0

        -- Threshold gate. At the default of 1 there is nothing to count, so the
        -- word scan is skipped entirely rather than computed and discarded.
        if L.Threshold > 1 then
            local w = 0
            for _ in code:gmatch("%S+") do w += 1 end
            L.Sent += w
            if L.Sent < L.Threshold then
                task.defer(L.RefreshAuto)
                return
            end
            L.Sent = 0
        end

        -- ---- WIRE ----
        -- No task.spawn: this handler already owns a thread, so yielding here
        -- costs nothing and skips a thread + closure allocation.
        local ok, reply, t = L.RedeemViaRemote(code, t0, preclean)

        -- ---- everything below lands after the packet is already gone ----
        L.LastDetect = t0
        L.RecentRedeem = t0
        task.defer(function()
            L.RefreshAuto()
            L.ReportRedeem(ok, reply, t)
        end)
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
-- INTRO SEQUENCE
----------------------------------------------------------------------
task.spawn(function()
    for i, lbl in ipairs(Letters) do
        task.delay((i - 1) * 0.055, function()
            TS:Create(lbl, TweenInfo.new(0.7, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
                Position = UDim2.fromOffset(0, 0),
                Rotation = 0,
                TextTransparency = 0,
            }):Play()
        end)
    end
    task.wait(0.055 * #Letters + 0.35)

    tw(Underline, 0.55, Enum.EasingStyle.Quart, nil, {Size = UDim2.new(0.72, 0, 0, 2)}):Play()
    task.wait(0.15)
    tw(Sub, 0.4, nil, nil, {TextTransparency = 0}):Play()

    local steps = { "loading modules", "resolving remote", "linking packet path", "linking webhook pool", "ready" }
    for _, s in ipairs(steps) do
        Sub.Text = s
        task.wait(0.26)
    end
    task.wait(0.18)

    for _, lbl in ipairs(Letters) do
        TS:Create(lbl, TweenInfo.new(0.35), {TextTransparency = 1}):Play()
    end
    tw(Sub, 0.3, nil, nil, {TextTransparency = 1}):Play()
    tw(Underline, 0.35, nil, nil, {Size = UDim2.new(0, 0, 0, 2), BackgroundTransparency = 1}):Play()
    task.wait(0.4)

    L.RainActive = false
    task.delay(2.5, function() if Loader.Parent then Loader:Destroy() end end)

    -- Panel springs up from slightly below and slightly small
    fit(true)
    local target = Panel.Size
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
        tw(Minus, 0.3, nil, nil, {BackgroundTransparency = 0, TextTransparency = 0}):Play()
        tw(Plus,  0.3, nil, nil, {BackgroundTransparency = 0, TextTransparency = 0}):Play()
        tw(Count, 0.3, nil, nil, {TextTransparency = 0}):Play()
    end)
    task.delay(0.19, function()
        tw(SendBtn, 0.4, nil, nil, {BackgroundTransparency = 0, TextTransparency = 0}):Play()
    end)
    task.delay(0.26, function()
        tw(BoxFrame, 0.4, nil, nil, {BackgroundTransparency = 0}):Play()
        tw(BoxStroke, 0.4, nil, nil, {Transparency = 0.5}):Play()
        tw(CodeBox, 0.4, nil, nil, {TextTransparency = 0}):Play()
    end)
    task.delay(0.6, function() L.DotReady = true end)
    task.delay(0.7, function() L.Notify("Luminosity online", T.HIGH) end)
end)
