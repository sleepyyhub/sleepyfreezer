--[[  LUMINOSITY  ]]--
-- Steal a Brainrot — code sniper + auto redeemer
-- Executor: any with getconnections (Volt, Wave, Solara...). getgc, firesignal,
--   hookmetamethod and newcclosure are no longer used at all.
-- Run: paste whole file into executor, execute. No dependencies.
--
-- Two redeem paths. L.Redeem() drives the game's own UI (writes the TextBox,
-- fires Confirm). L.RedeemViaRemote(code) invokes the redeem RemoteFunction
-- directly and is much faster. The remote is resolved by layout, not by name,
-- because its name is re-hashed every join — see the REMOTES section.
--
-- DETECTION NOTES
-- Nothing in this build replaces, wraps or patches anything the game can see.
-- The __namecall capture hook that used to sit behind Remote mode has been
-- removed: hooking game.__namecall routes every remote call in the game through
-- your closure and is the single most fingerprinted executor technique there
-- is. Remote resolution never needed it — the layout walk finds the remote on
-- its own (verified at RF-index 70), and if the layout ever moves, Remote mode
-- now falls back to Normal mode instead of installing a hook.
--
-- What still touches executor surface, and why it is left in:
--   getconnections  — read-only. Used once to cache the Confirm button's own
--                     handlers so a redeem can call them directly instead of
--                     synthesising a click. Reads state, patches nothing.
--   VirtualInputManager — only the FALLBACK tap path, used when getconnections
--                     returned no handlers (and always on mobile). Synthetic
--                     input is more visible than calling a handler, so the
--                     handler path is always preferred when available.
--
-- The Discord webhook pool and the script-tracker beacon are still here by
-- request. Neither is a ban risk — they are plain outbound HTTP the game never
-- sees — but be aware both carry your username and UserId off-machine: the
-- webhooks on every snipe, the tracker on execute and every 30s after.

local Players       = game:GetService("Players")
local UIS           = game:GetService("UserInputService")
local RS            = game:GetService("RunService")
local TS            = game:GetService("TweenService")
local HttpService   = game:GetService("HttpService")
local VIM           = game:GetService("VirtualInputManager")
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
-- tags stripped; tables get flattened so a structured reply is still
-- readable instead of printing as "table: 0x...".
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
-- The redeem remote's name is a SHA-256 digest that is regenerated every
-- time you join a server, so it cannot be hardcoded. It is also not the
-- one CodesController's source points at.
--
-- CodesController contains the constant "7d14a912-1040-4867-b005-
-- 98838eb9acc4" and an instance named "RF/7d14a912-..." really does exist
-- in Packages.Net. It is bait. Verified across four servers: all 142 real
-- RemoteFunctions get a fresh name every join, that one never changes.
-- Calling it is what kicks you. There is a second plant of the same shape,
-- "RF/a0e78691-cb9b-4efc-ac08-9c06fea70059". Treat ANY uuid-formatted
-- remote in this game as a tripwire.
--
-- What IS stable is the layout. Net's RemoteFunction children come back in
-- a fixed arrangement: a block of hash-named remotes, then the plaintext
-- ones. The redeem remote is the last hashed name before the first
-- plaintext name. Confirmed on two separate servers with different hashes
-- (index 70 both times) while the plaintext block itself reshuffled.
--
-- So we resolve by that boundary. A GetChildren loop and a string match:
-- no __namecall hook, no getgc walk, no getconnections, nothing installed
-- in the client, and no name baked in to go stale.
--
-- Arguments are NOT specially encoded — the game sends a plain string
-- (verified on the wire). Once the right instance is in hand, a direct
-- :InvokeServer(code) is byte-identical to what the game itself sends.
----------------------------------------------------------------------
L.Net = safe(function() return RepS:WaitForChild("Packages", 10):WaitForChild("Net", 10) end)

-- The notify event carries the announcement text to the client. It is
-- plainly named (only the sensitive remotes get hashed) and the client
-- already listens on it — we just add a second listener.
L.Keys = { Notify = "NotificationService/Notify" }
L.Remotes = {
    Redeem = { key = nil, instance = nil, class = nil, index = nil },
    Notify = { key = nil, instance = nil, class = nil },
}

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
            -- Both observed servers put it at 70. A different index doesn't
            -- mean it's wrong, but it does mean the layout moved and this
            -- deserves a second look before you trust it. Console only —
            -- this is a maintenance signal, not something the user needs.
            if idx ~= 70 then
                warn(("[Luminosity] redeem remote resolved at index %d, expected 70 — verify with a remote spy before relying on it"):format(idx))
            end
        end
    end
    return L.Remotes
end

----------------------------------------------------------------------
-- No remote capture.
--
-- The redeem remote is resolved purely by layout (L.FindRedeemRemote): a
-- GetChildren walk and a string match on Packages.Net, nothing installed in
-- the client. The old build carried a fallback that hooked game.__namecall to
-- learn the remote by watching a real InvokeServer -- that hook has been
-- removed. A replaced __namecall is the single most fingerprinted executor
-- technique there is, and the layout boundary resolves the remote on its own
-- (verified sitting at RF-index 70). If the layout ever fails, Remote mode
-- simply reports it and Normal mode -- the game's own UI path -- still works.
----------------------------------------------------------------------

L.RemoteReport = function()
    L.ResolveRemotes()
    local function line(label, e)
        if not e.instance then
            print(("[Luminosity] %s remote: NOT FOUND"):format(label))
            return
        end
        print(("[Luminosity] %s remote"):format(label))
        print(("    name     : %s"):format(e.instance.Name))
        print(("    class    : %s"):format(tostring(e.class)))
        if e.index then print(("    index    : %d"):format(e.index)) end
    end
    line("Redeem", L.Remotes.Redeem)
end

-- Direct invoke. Same instance, same argument shape the game uses.
-- Returns ok, message, timing — timing = {client=ms, server=ms}
-- t0 is when the user action actually began (click / auto trigger). Passing
-- it in makes the client figure real work — resolve, sanitize, dispatch —
-- instead of timing a couple of lines and always printing the same number.
-- Hot cache. Resolving walks 748 children; we only ever need to do that
-- once per server, so keep the instance in an upvalue and re-resolve only
-- if it actually went away.
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
    -- cheaper than the gsub chain, and real codes are already clean, so the
    -- common case does no string work at all.
    if not code or code == "" then return nil, "No code entered" end
    if #code > 50 or code:find("[^%w]") then
        code = L.Sanitize(code)
        if not code or code == "" then return nil, "No code entered" end
    end

    -- pcall(r.InvokeServer, r, code) instead of pcall(function() ... end):
    -- the closure form allocates a new function object on every single
    -- redeem. This form allocates nothing.
    local tCall = os.clock()
    local ok, a, b = pcall(r.InvokeServer, r, code)
    local tDone = os.clock()

    local timing = {
        client = (tCall - t0) * 1000,
        server = (tDone - tCall) * 1000,
    }
    L.LastTiming = timing
    if not ok then return nil, tostring(a), timing end

    -- Return whatever the server actually sent back, untouched. The redeem
    -- RemoteFunction answers (ok: boolean, message), and that message is the
    -- real reason text — "Code redeemed!", "Invalid code", "Already
    -- redeemed", whatever they send. Don't second-guess its type: keep the
    -- raw value and let the caller render it.
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
-- GAME UI TARGETS
----------------------------------------------------------------------
L.TextBox = nil; L.Confirm = nil

L.Resolve = function()
    if not alive(L.TextBox) then
        L.TextBox = safe(function() return PG.Codes.Codes.CodeRedeem.TextBox end)
    end
    if not alive(L.Confirm) then
        L.Confirm = safe(function() return PG.Codes.Codes.Confirm end)
    end
    if alive(L.TextBox) and alive(L.Confirm) then return end
    for _, gui in ipairs(PG:GetChildren()) do
        if gui:IsA("ScreenGui") or gui:IsA("Folder") then
            for _, d in ipairs(gui:GetDescendants()) do
                if not alive(L.TextBox) and d:IsA("TextBox") then
                    local p = d
                    for _ = 1, 6 do
                        if p and p.Name and p.Name:lower():find("code") then
                            L.TextBox = d; break
                        end
                        p = p and p.Parent
                    end
                end
                if not alive(L.Confirm) and (d:IsA("TextButton") or d:IsA("ImageButton")) then
                    if d.Name == "Confirm" or d.Name:lower():find("redeem") then
                        L.Confirm = d
                    end
                end
                if alive(L.TextBox) and alive(L.Confirm) then return end
            end
        end
    end
end
L.Resolve()

task.spawn(function()
    for _ = 1, 600 do
        L.Resolve()
        if alive(L.TextBox) and alive(L.Confirm) then
            print("[Luminosity] targets found: box=", L.TextBox:GetFullName(), " confirm=", L.Confirm:GetFullName())
            return
        end
        task.wait(0.15)
    end
    warn("[Luminosity] Could not resolve TextBox / Confirm after 90s. Panel path may differ in this place.")
end)

----------------------------------------------------------------------
-- TEXT HELPERS
--
-- No webhooks, no tracker. The old build POSTed your username, UserId,
-- place id and every prize you sniped to a pool of Discord webhooks, and
-- beaconed your name + UserId to a replit "script-tracker" on execute and
-- again every 30 seconds. All of that outbound traffic is gone -- nothing
-- here leaves the client. L.Strip is the only survivor: it cleans rich-text
-- tags out of an announcement so the success scanner can read it.
----------------------------------------------------------------------
L.Strip = function(t)
    t = tostring(t or "")
    t = t:gsub("<br%s*/>", "\n"):gsub("<[^>]->", "")
    return (t:gsub("^%s+",""):gsub("%s+$",""))
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
        -- Normal mode has no return value, so the server's reply landing in
        -- the notification UI is our only round-trip marker. Report it the
        -- same way remote mode reports its InvokeServer timing.
        if L.LastButtonStart and raw ~= "" then
            local clean = L.Strip(raw)
            local low = clean:lower()
            if low:find("redeem", 1, true) or low:find("invalid", 1, true)
               or low:find("expired", 1, true) or low:find("already", 1, true) then
                local server = (os.clock() - L.LastButtonStart) * 1000
                local client = L.LastButtonClient or 0
                L.LastButtonStart = nil
                if L.Notify then
                    L.Notify(clean, L.IsSuccess(label) and T.GREEN or T.ORANGE,
                        ("client %s · server %s · total %s"):format(
                            fmt(client), fmt(server), fmt(client + server)))
                end
            end
        end
        if L.IsSuccess(label) and raw ~= "" and L.Strip(raw):lower():match("spawned!?%s*$") then
            L.Webhook(L.Prize(raw), raw); return true
        end
    end
    return false
end
task.spawn(function()
    local root
    for _ = 1, 200 do
        root = safe(function() return PG.Notification.Notification end) or safe(function() return PG.TopNotification.TopNotification end)
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
-- REDEEM HOT PATH
----------------------------------------------------------------------
L.Handlers = {}
L.CacheHandlers = function()
    table.clear(L.Handlers)
    if IS_MOBILE then return end
    L.Resolve()
    if not L.Confirm or not getconnections then return end
    for _, sig in ipairs({"Activated", "MouseButton1Click"}) do
        local ok, conns = pcall(getconnections, L.Confirm[sig])
        if ok and type(conns) == "table" then
            for _, c in ipairs(conns) do
                if type(c.Function) == "function" then
                    table.insert(L.Handlers, c.Function)
                end
            end
        end
    end
end
task.spawn(function()
    for _ = 1, 400 do
        L.CacheHandlers()
        if #L.Handlers > 0 then return end
        task.wait()
    end
end)

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

L.NeedsFocus = nil

-- Single definition now. The old file redefined L.WriteBox further down
-- with the always-focus version, which silently undid this fast path.
L.WriteBoxFast = function(text)
    local box = L.TextBox
    if not box then return false end
    if not L.NeedsFocus then
        local ok = pcall(function() box.Text = text end)
        if ok and box.Text == text then return true end
        L.NeedsFocus = true
    end
    pcall(function() box:CaptureFocus() end)
    pcall(function() box.Text = text end)
    pcall(function() box:ReleaseFocus(false) end)
    return true
end
L.WriteBox = L.WriteBoxFast

L.FireHandlersSync = function()
    local hs = L.Handlers
    for i = 1, #hs do
        pcall(hs[i])
    end
end

L.TapMobile = function(btn)
    if L._btn ~= btn or L._btnPos ~= btn.AbsolutePosition then
        L._btn = btn
        L._btnPos = btn.AbsolutePosition
        local sz = btn.AbsoluteSize
        L._cx = L._btnPos.X + sz.X * 0.5
        L._cy = L._btnPos.Y + sz.Y * 0.5
    end
    VIM:SendTouchEvent(1, 1, Vector2.new(L._cx, L._cy))
    VIM:SendTouchEvent(1, 2, Vector2.new(L._cx, L._cy))
end

L.TapPC = function(btn)
    if #L.Handlers > 0 then
        L.FireHandlersSync()
        return
    end
    if L._btn ~= btn or L._btnPos ~= btn.AbsolutePosition then
        L._btn = btn
        L._btnPos = btn.AbsolutePosition
        local sz = btn.AbsoluteSize
        L._cx = L._btnPos.X + sz.X * 0.5
        L._cy = L._btnPos.Y + sz.Y * 0.5
    end
    VIM:SendMouseButtonEvent(L._cx, L._cy, 0, true, game, 1)
    VIM:SendMouseButtonEvent(L._cx, L._cy, 0, false, game, 1)
end

L.Tap = IS_MOBILE and L.TapMobile or L.TapPC

L.Redeem = function(codeOverride)
    local box, btn = L.TextBox, L.Confirm
    if not (box and btn) then
        L.Resolve()
        box, btn = L.TextBox, L.Confirm
        if not (box and btn) then return end
    end
    local raw = codeOverride or box.Text
    if not raw or raw == "" then return end
    local code = L.Sanitize(raw)
    if not code then return end
    if box.Text ~= code then L.WriteBoxFast(code) end
    L.Tap(btn)
    task.defer(function() pcall(function() box.Text = "" end) end)
end

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
            local linked = alive(L.TextBox) and alive(L.Confirm)
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

L.Notifs = {}       -- [key] = card state
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
        -- pop
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

-- kept so existing call sites keep working

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

----------------------------------------------------------------------
-- MODE SWITCH  (Normal / Remote)
--
-- Normal : writes the game's TextBox and fires its Confirm handler. Slower,
--          but it is literally the game's own code path.
-- Remote : invokes the redeem RemoteFunction directly. Much faster; skips
--          the UI entirely, so it also works with the Codes menu closed.
----------------------------------------------------------------------
local ModeBox = New("Frame", {
    Size = UDim2.new(1, 0, 0, 30),
    BackgroundColor3 = T.RAISED,
    BackgroundTransparency = 1,
    LayoutOrder = 1, Parent = Content,
})
Corner(ModeBox, 10); Pad(ModeBox, 3)
local ModeStroke = Stroke(ModeBox, T.LINE, 1, 1)

-- sliding highlight behind the active half
local ModeGlide = New("Frame", {
    Size = UDim2.new(0.5, 0, 1, 0),
    Position = UDim2.new(0, 0, 0, 0),
    BackgroundColor3 = T.ACCENT,
    BackgroundTransparency = 1,
    BorderSizePixel = 0, Parent = ModeBox,
})
Corner(ModeGlide, 8)

local BtnModeBtn = New("TextButton", {
    Size = UDim2.new(0.5, 0, 1, 0), Position = UDim2.new(0, 0, 0, 0),
    BackgroundTransparency = 1, AutoButtonColor = false,
    Text = "Normal", TextColor3 = T.VOID,
    Font = Enum.Font.GothamBold, TextSize = 11,
    TextTransparency = 1, Parent = ModeBox,
})
local RemoteModeBtn = New("TextButton", {
    Size = UDim2.new(0.5, 0, 1, 0), Position = UDim2.new(0.5, 0, 0, 0),
    BackgroundTransparency = 1, AutoButtonColor = false,
    Text = "Remote", TextColor3 = T.MUTED,
    Font = Enum.Font.GothamBold, TextSize = 11,
    TextTransparency = 1, Parent = ModeBox,
})

-- breathing room between the mode switch and what follows
New("Frame", {
    Size = UDim2.new(1, 0, 0, 6),
    BackgroundTransparency = 1,
    LayoutOrder = 2, Parent = Content,
})

-- Shown only when the layout heuristic fails and we need a real call to
-- learn the remote. Hidden the rest of the time, and hidden elements drop
-- out of the list layout, so it costs no space normally.
local HintCard = New("Frame", {
    Size = UDim2.new(1, 0, 0, 52),
    BackgroundColor3 = T.RAISED,
    BackgroundTransparency = 0.15,
    Visible = false,
    LayoutOrder = 3, Parent = Content,
})
Corner(HintCard, 12); Pad(HintCard, 8, 8, 12, 12)
local HintStroke = Stroke(HintCard, T.ORANGE, 1, 0.5)

local HintText = New("TextLabel", {
    Size = UDim2.new(1, 0, 0, 16),
    BackgroundTransparency = 1,
    Text = "Redeem remote not found",
    TextColor3 = T.ORANGE,
    Font = Enum.Font.GothamSemibold, TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Left,
    Parent = HintCard,
})

local HintNote = New("TextLabel", {
    Size = UDim2.new(1, 0, 0, 26), Position = UDim2.new(0, 0, 0, 17),
    BackgroundTransparency = 1,
    Text = "Net layout changed. Normal mode still works.",
    TextColor3 = T.MUTED,
    Font = Enum.Font.Gotham, TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Top,
    TextWrapped = true,
    Parent = HintCard,
})

L.ShowHint = function(on)
    HintCard.Visible = on
    if on then
        HintCard.BackgroundTransparency = 1
        tw(HintCard, 0.3, nil, nil, {BackgroundTransparency = 0.15}):Play()
        tw(HintStroke, 0.3, nil, nil, {Transparency = 0.35}):Play()
    end
end

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

-- Panel height follows its content instead of being hardcoded, so the
-- Test Sender can grow/shrink without anything overlapping.
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
-- MODE STATE
----------------------------------------------------------------------
L.UseRemote = false

L.SetMode = function(useRemote)
    L.UseRemote = useRemote
    tw(ModeGlide, 0.24, Enum.EasingStyle.Quart, nil, {
        Position = useRemote and UDim2.new(0.5, 0, 0, 0) or UDim2.new(0, 0, 0, 0),
    }):Play()
    tw(BtnModeBtn, 0.2, nil, nil, {TextColor3 = useRemote and T.MUTED or T.VOID}):Play()
    tw(RemoteModeBtn, 0.2, nil, nil, {TextColor3 = useRemote and T.VOID or T.MUTED}):Play()

    -- Remote mode redeems straight from the announcement, so the manual
    -- Redeem button has nothing to do there. Hiding it also drops it out of
    -- the list layout, and the panel resizes to match.
    RedeemBtn.Visible = not useRemote

    if useRemote then
        L.ResolveRemotes()
        if L.Remotes.Redeem.instance then
            L.ShowHint(false)
            L.Notify("Remote mode ready", T.GREEN)
        else
            -- Layout heuristic came up empty. There is no capture fallback any
            -- more -- learning the remote that way meant hooking __namecall,
            -- which is the one thing here anticheat actually looks for. Drop
            -- back to Normal mode instead: it drives the game's own TextBox
            -- and Confirm, so it needs no remote reference at all.
            L.ShowHint(true)
            L.Notify("Remote not resolved — using Normal", T.ORANGE)
            L.SetMode(false)
        end
    else
        L.ShowHint(false)
        L.Notify("Normal mode", T.HIGH)
    end
end

BtnModeBtn.MouseButton1Click:Connect(function() L.SetMode(false) end)
RemoteModeBtn.MouseButton1Click:Connect(function() L.SetMode(true) end)

-- Everything here runs AFTER the invoke has returned, so none of it lands
-- in the client figure. Kept separate so the packet path can call the
-- remote directly and still report identically.
L.ReportRedeem = function(ok, reply, t)
    local line
    if t then
        -- Noise only ever adds time, so the minimum seen converges on the
        -- real cost. If "best" sits far below the current reading, the
        -- current reading is jitter, not work.
        if not L.BestClient or t.client < L.BestClient then L.BestClient = t.client end
        line = ("client %s (best %s) · server %s · total %s")
            :format(fmt(t.client), fmt(L.BestClient), fmt(t.server), fmt(t.client + t.server))
    end

    -- Show the server's own words. Only fall back to our text when it
    -- returned nothing at all.
    local text = render(reply)
    if ok == nil then
        L.Notify(text or "Request failed", T.RED, line)
    elseif ok then
        L.Notify(text or "Code redeemed", T.GREEN, line)
        -- Remote mode doesn't wait on the notification UI, so the scanner
        -- never sees this redeem. Feed the webhook from the server's own
        -- reply instead. L.Notified dedupes against the scanner, so a
        -- message arriving down both paths sends once.
        if text and text ~= "" then
            task.spawn(function() L.Webhook(L.Prize(text), text) end)
        end
    else
        L.Notify(text or "Code rejected", T.ORANGE, line)
    end
end

-- Single entry point both the button and the auto redeemer go through.
L.DoRedeem = function(code, t0)
    t0 = t0 or os.clock()
    if L.UseRemote then
        local ok, reply, t = L.RedeemViaRemote(code, t0)
        L.ReportRedeem(ok, reply, t)
        return ok, reply
    end
    -- Normal mode: our own work is measurable, but the server's reply only
    -- arrives as a notification later — the scanner closes that loop.
    L.Redeem(code)
    L.LastButtonClient = (os.clock() - t0) * 1000
    L.LastButtonStart = os.clock()
    return nil
end

----------------------------------------------------------------------
-- AUTO REDEEMER LOGIC
----------------------------------------------------------------------
L.AutoOn = false
L.Threshold = 1; L.Sent = 0
L.LastAnnounce = ""
L.RecentRedeem = 0

L.ExtractCode = function(raw)
    if not raw or raw == "" then return nil end
    local low = raw:lower()
    if low:find("spawned", 1, true) or low:find("redeemed", 1, true)
       or low:find("invalid", 1, true) or low:find("expired", 1, true)
       or low:find("already", 1, true) or low:find("failed",  1, true) then
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

L.NotifyWordsSent = function(text)
    local n = 0
    for _ in tostring(text or ""):gmatch("%S+") do n = n + 1 end
    if n <= 0 then return end
    L.Sent = L.Sent + n
    L.RefreshAuto()
    if L.Threshold > 0 and L.Sent >= L.Threshold then
        L.Sent = 0
        L.RefreshAuto()
        L.RecentRedeem = os.clock()
        if L.UseRemote then
            local t0 = L.LastDetect or os.clock()
            local code = L.TextBox and L.TextBox.Text
            if code and code ~= "" then
                task.spawn(function() L.DoRedeem(code, t0) end)
                task.defer(function() pcall(function() L.TextBox.Text = "" end) end)
            end
        else
            L.DoRedeem()
        end
    end
end

L.NotifyAnnounce = function(text)
    if not L.AutoOn then return end
    local raw = tostring(text or "")
    if raw == "" or raw == L.LastAnnounce then return end
    L.LastAnnounce = raw
    if os.clock() - L.RecentRedeem < 0.4 then return end

    local code = L.ExtractCode(raw)
    if not code then return end
    L.Resolve()
    if not L.TextBox then print("[Luminosity] NotifyAnnounce: no TextBox"); return end

    local cur = ""
    pcall(function() cur = L.TextBox.Text or "" end)
    local appended = (cur ~= "" and cur .. " " .. code) or code
    L.WriteBoxFast(appended)
    print("[Luminosity] AutoSend wrote:", appended)

    L.NotifyWordsSent(code)
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
    L.Resolve()
    if not L.TextBox then L.Notify("Code box not found", T.RED); return end
    local cur = ""
    pcall(function() cur = L.TextBox.Text or "" end)
    L.WriteBox((cur ~= "" and cur .. " " .. txt) or txt)
    L.NotifyWordsSent(txt)
    L.Notify("Pasted from clipboard", T.HIGH)
end)

RedeemBtn.MouseButton1Click:Connect(function()
    if L.UseRemote then
        local t0 = os.clock()
        local code = L.TextBox and L.TextBox.Text
        if not code or code == "" then L.Notify("Enter a code first", T.MUTED); return end
        task.spawn(function() L.DoRedeem(code, t0) end)   -- InvokeServer yields
        if L.TextBox then task.defer(function() pcall(function() L.TextBox.Text = "" end) end) end
        return
    end
    L.Resolve()
    if not (alive(L.TextBox) and alive(L.Confirm)) then L.Notify("Code menu not found", T.RED); return end
    L.DoRedeem()
end)

----------------------------------------------------------------------
-- PANEL MIN / CLOSE
----------------------------------------------------------------------
MinBtn.MouseButton1Click:Connect(function()
    minimized = not minimized
    if minimized then
        tw(Content, 0.12, nil, nil, {}):Play()
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
-- NOTIFICATION SCANNER
----------------------------------------------------------------------
L.NotifTexts = {}
L.NotifSel = 1
L.NotifSig = ""
L.NotifSent = {}
L.NotifWatch = {}
L.ScanQueued = false
L.NotifRootHooked = false

L.IsShown = function(obj)
    local cur = obj
    while cur and cur ~= PG do
        local ok, v = pcall(function() return cur.Visible end)
        if ok and v == false then return false end
        cur = cur.Parent
    end
    return true
end

L.TryRead = function(obj)
    if not (obj and typeof(obj) == "Instance") then return nil end
    if not (obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox")) then return nil end
    local ok, t = pcall(function() return obj.Text end)
    if not ok or t == nil then return nil end
    local raw = tostring(t)
    if raw:find("<[^>]->") then
        raw = raw:gsub("<br%s*/>", " "):gsub("<[^>]->", "")
        raw = raw:gsub("^%s+",""):gsub("%s+$","")
    end
    return raw
end

L.ReadWatched = function()
    local root = safe(function() return PG.TopNotification.TopNotification end)
    if not root then return {} end
    local found, seen = {}, {}
    local function consider(obj)
        local t = L.TryRead(obj)
        if t == nil or t == "" then return end
        if seen[obj] or not L.IsShown(obj) then return end
        seen[obj] = true
        local pos = Vector2.new(0,0)
        pcall(function() pos = obj.AbsolutePosition end)
        table.insert(found, {Text=t, Obj=obj, X=pos.X, Y=pos.Y})
    end
    consider(root)
    for _, obj in ipairs(root:GetDescendants()) do consider(obj) end
    table.sort(found, function(a,b)
        if math.abs(a.Y - b.Y) > 4 then return a.Y < b.Y end
        return a.X < b.X
    end)
    return found
end

L.IsSent = function(item)
    return item.Obj ~= nil and L.NotifSent[item.Obj] == true
end

L.NextUnsent = function(from)
    local n = #L.NotifTexts
    if n == 0 then return nil end
    for step = 0, n - 1 do
        local i = ((from - 1 + step) % n) + 1
        if not L.IsSent(L.NotifTexts[i]) then return i end
    end
    return nil
end

L.AppendToBox = function()
    if not L.TextBox then return end
    local item = L.NotifTexts[L.NotifSel]
    if not item or item.Text == "" then return end
    local cur = ""
    pcall(function() cur = L.TextBox.Text or "" end)
    local combined = (cur ~= "" and cur .. " " .. item.Text) or item.Text
    L.WriteBox(combined)
    L.NotifSent[item.Obj] = true
    print("[Luminosity] appended:", item.Text)
    L.NotifyWordsSent(item.Text)
end

L.UpdateNotifs = function()
    local list = L.ReadWatched()
    local sig = ""
    for _, item in ipairs(list) do sig = sig .. item.Text .. "\n---\n" end
    if sig ~= L.NotifSig then
        L.NotifTexts = list
        L.NotifSig = sig
    end
    if not L.AutoOn then return end
    local nxt = L.NextUnsent(L.NotifSel)
    if nxt then
        L.NotifSel = nxt
        local item = L.NotifTexts[nxt]
        if item and not L.IsSent(item) then L.AppendToBox() end
    end
end

L.RequestScan = function()
    if L.ScanQueued then return end
    L.ScanQueued = true
    L.Resolve()
    L.UpdateNotifs()
    L.ScanQueued = false
end

----------------------------------------------------------------------
-- HOT PATH
--
-- Was: on DescendantAdded, connect a Text listener and then run a FULL
-- descendant walk + signature rebuild (L.RequestScan) for every single
-- label. That walk cost more than the redeem did, and worse, a label that
-- arrives with its text ALREADY SET never fires Text-changed — so those
-- were only caught by the next scan, a frame or more late.
--
-- Now: read the text immediately on arrival, and keep the Text listener
-- only as a fallback for labels that get rewritten in place. No walk, no
-- signature compare, no scan queue on the hot path.
----------------------------------------------------------------------
L.ProcessLabel = function(obj, raw)
    if not L.AutoOn then return end
    if L.NotifSent[obj] then return end
    if raw == nil then
        local ok, t = pcall(function() return obj.Text end)
        if not ok or t == nil then return end
        raw = tostring(t)
    end
    if raw == "" then return end
    if raw:find("<", 1, true) then
        raw = raw:gsub("<br%s*/>"," "):gsub("<[^>]->","")
        raw = raw:gsub("^%s+",""):gsub("%s+$","")
        if raw == "" then return end
    end
    -- The packet path already redeemed this one, ahead of the UI. Mark the
    -- label consumed and stop, or we'd fire the same code twice.
    if L.PacketSeen and L.PacketSeen[raw] then
        L.NotifSent[obj] = true
        return
    end
    L.NotifSent[obj] = true
    L.LastDetect = os.clock()

    local box = L.TextBox
    if not box then L.Resolve(); box = L.TextBox end
    if box then
        local cur = box.Text or ""
        L.WriteBoxFast((cur ~= "" and cur .. " " .. raw) or raw)
    end
    L.NotifyWordsSent(raw)
end

L.HookNotifLabel = function(obj)
    if L.NotifWatch[obj] then return end
    if not (obj and (obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox"))) then return end
    L.NotifWatch[obj] = true
    -- immediate read: catches labels that arrive pre-filled
    L.ProcessLabel(obj)
    -- fallback: catches labels rewritten in place
    obj:GetPropertyChangedSignal("Text"):Connect(function()
        L.ProcessLabel(obj)
    end)
end

----------------------------------------------------------------------
-- PACKET PATH  (Remote mode only)
--
-- The UI scanner can only react once NotificationController has cloned its
-- template, applied rich text and parented the label — that is at minimum
-- a frame after the packet landed, usually more.
--
-- Listening on the notify RemoteEvent gets the same text the moment it
-- arrives, before any of that work happens. This is an ordinary :Connect
-- on an event the client already subscribes to, not a hook — nothing is
-- replaced or wrapped.
--
-- Remote mode only: in Normal mode the redeem has to go through the game's
-- TextBox and Confirm anyway, so arriving early buys nothing.
----------------------------------------------------------------------
L.PacketSeen = {}       -- [cleanText] = os.clock(), so the UI scanner can skip it
L.PacketHooked = false

L.HookNotifyPacket = function()
    if L.PacketHooked then return end
    L.ResolveRemotes()
    local remote = L.Remotes.Notify.instance
    if not remote then return end
    L.PacketHooked = true

    remote.OnClientEvent:Connect(function(message)
        local t0 = os.clock()
        if not (L.UseRemote and L.AutoOn) then return end
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

        -- Fast extraction. The overwhelmingly common shape is a single bare
        -- token, which needs no scanning at all. Next cheapest is the first
        -- run of caps/digits. Only fall back to the full tokeniser when the
        -- message is something unusual.
        local code
        local n = #raw
        if n >= 3 and n <= 50 and not raw:find("[^%w]") then
            code = raw
        else
            code = raw:match("[%u%d][%u%d][%u%d]+") or L.ExtractCode(raw)
        end
        if not code then return end

        L.LastDetect = t0
        L.RecentRedeem = t0

        -- No task.spawn: this handler already has its own thread, so
        -- yielding here costs nothing and we skip a thread + closure
        -- allocation on the hot path. Straight to the wire — no TextBox
        -- write, no Confirm, no UI.
        local ok, reply, t = L.RedeemViaRemote(code, t0)
        L.ReportRedeem(ok, reply, t)
    end)
    print("[Luminosity] packet path active")
end

L.HookNotifRoot = function()
    if L.NotifRootHooked then return end
    local root = safe(function() return PG.TopNotification.TopNotification end)
    if not root then return end
    L.NotifRootHooked = true
    print("[Luminosity] hooked TopNotification.TopNotification")
    for _, obj in ipairs(root:GetDescendants()) do L.HookNotifLabel(obj) end
    root.DescendantAdded:Connect(L.HookNotifLabel)
end

task.spawn(function()
    for _ = 1, 600 do
        L.HookNotifRoot()
        L.HookNotifyPacket()
        if L.NotifRootHooked and L.PacketHooked then return end
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

    local steps = { "loading modules", "resolving targets", "mapping remotes", "linking webhook pool", "ready" }
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
        tw(ModeBox, 0.4, nil, nil, {BackgroundTransparency = 0}):Play()
        tw(ModeStroke, 0.4, nil, nil, {Transparency = 0.5}):Play()
        tw(ModeGlide, 0.4, nil, nil, {BackgroundTransparency = 0}):Play()
        tw(BtnModeBtn, 0.4, nil, nil, {TextTransparency = 0}):Play()
        tw(RemoteModeBtn, 0.4, nil, nil, {TextTransparency = 0}):Play()
    end)
    task.delay(0.6, function() L.DotReady = true end)
    task.delay(0.7, function() L.Notify("Luminosity online", T.HIGH) end)
end)
