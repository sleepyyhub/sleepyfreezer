--!nocheck
-- Liveboard trade sniper - prototype
-- Hooks RE/Liveboard/NewEntry and fires TradeService/Invite at the entry owner.
-- Hot path is pre-resolved: on event we only read OwnerUserId and dispatch.

local Players    = game:GetService("Players")
local RepS       = game:GetService("ReplicatedStorage")
local TS         = game:GetService("TweenService")
local UIS        = game:GetService("UserInputService")
local LP         = Players.LocalPlayer
local PG         = LP:WaitForChild("PlayerGui")

local S = {}
if getgenv then getgenv().LiveSniper = S end

S.Enabled     = false
S.InviteGUID  = "afb005f9-6e81-4e0a-8bb0-3555938a9658"
S.Sent        = {}      -- userId -> os.clock(), dedupe
S.Cooldown    = 30      -- seconds before the same userId is eligible again
S.Stats       = {seen = 0, fired = 0, ok = 0, fail = 0}
S.BestLatency = nil
S.OnlyGlobal  = false   -- true = ignore [SERVER] entries

local T = {
    BG      = Color3.fromRGB(10, 15, 28),
    SURFACE = Color3.fromRGB(16, 24, 44),
    RAISED  = Color3.fromRGB(24, 34, 58),
    LINE    = Color3.fromRGB(38, 54, 88),
    ACCENT  = Color3.fromRGB(120, 180, 255),
    HIGH    = Color3.fromRGB(180, 220, 255),
    TEXT    = Color3.fromRGB(230, 240, 255),
    MUTED   = Color3.fromRGB(120, 145, 185),
    GREEN   = Color3.fromRGB(146, 255, 103),
    RED     = Color3.fromRGB(255, 130, 155),
    ORANGE  = Color3.fromRGB(255, 190, 120),
}

local function New(cls, props, kids)
    local i = Instance.new(cls)
    for k, v in pairs(props or {}) do i[k] = v end
    for _, c in ipairs(kids or {}) do c.Parent = i end
    return i
end
local function Corner(p, r) New("UICorner", {CornerRadius = UDim.new(0, r or 10), Parent = p}) end
local function Stroke(p, c, t) New("UIStroke", {Color = c or T.LINE, Thickness = 1, Transparency = t or 0.45, Parent = p}) end
local function fmt(ms)
    if ms < 1 then return ("%.2fms"):format(ms) end
    if ms < 10 then return ("%.1fms"):format(ms) end
    return ("%.0fms"):format(ms)
end

----------------------------------------------------------------
-- resolve everything ONCE, so the event path stays hot
----------------------------------------------------------------

local Net = RepS:WaitForChild("Packages"):WaitForChild("Net")
local NewEntry = Net:FindFirstChild("RE/Liveboard/NewEntry")
local ClaimEntry = Net:FindFirstChild("RE/Liveboard/ClaimEntry")

local InviteRF
do
    local ok, TC = pcall(require, RepS.Controllers.TradeController)
    if ok and type(TC) == "table" and typeof(TC.SendInvite) == "function" then
        local oku, ups = pcall(debug.getupvalues, TC.SendInvite)
        if oku then
            for _, v in pairs(ups) do
                if typeof(v) == "Instance" and v:IsA("RemoteFunction") then InviteRF = v break end
            end
        end
    end
end

S.Ready = (NewEntry ~= nil) and (InviteRF ~= nil)

----------------------------------------------------------------
-- UI
----------------------------------------------------------------

local oldGui = PG:FindFirstChild("LiveSniperUI")
if oldGui then oldGui:Destroy() end

local Gui = New("ScreenGui", {
    Name = "LiveSniperUI", ResetOnSpawn = false, IgnoreGuiInset = true,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 9999, Parent = PG,
})

local Panel = New("Frame", {
    Size = UDim2.fromOffset(340, 400),
    Position = UDim2.new(0, 24, 0.5, -200),
    BackgroundColor3 = T.SURFACE, BackgroundTransparency = 0.06,
    BorderSizePixel = 0, Parent = Gui,
})
Corner(Panel, 14); Stroke(Panel, T.LINE, 0.35)

local Header = New("Frame", {Size = UDim2.new(1, -24, 0, 34), Position = UDim2.fromOffset(12, 8), BackgroundTransparency = 1, Parent = Panel})
local Title = New("TextLabel", {
    Size = UDim2.new(1, -70, 1, 0), BackgroundTransparency = 1,
    Text = "LIVEBOARD SNIPER", TextColor3 = T.HIGH,
    Font = Enum.Font.GothamBold, TextSize = 13,
    TextXAlignment = Enum.TextXAlignment.Left, Parent = Header,
})

local Dot = New("Frame", {
    Size = UDim2.fromOffset(8, 8), Position = UDim2.new(1, -18, 0.5, -4),
    BackgroundColor3 = S.Ready and T.GREEN or T.RED, BorderSizePixel = 0, Parent = Header,
})
Corner(Dot, 4)

local StatusLbl = New("TextLabel", {
    Size = UDim2.new(1, -24, 0, 14), Position = UDim2.fromOffset(12, 40),
    BackgroundTransparency = 1,
    Text = S.Ready and "armed - NewEntry + Invite resolved" or "NOT READY - remote missing",
    TextColor3 = S.Ready and T.MUTED or T.RED,
    Font = Enum.Font.Gotham, TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left, Parent = Panel,
})

-- auto toggle
local Toggle = New("TextButton", {
    Size = UDim2.new(1, -24, 0, 34), Position = UDim2.fromOffset(12, 60),
    BackgroundColor3 = T.RAISED, AutoButtonColor = false,
    Text = "AUTO SNIPE : OFF", TextColor3 = T.MUTED,
    Font = Enum.Font.GothamBold, TextSize = 12, Parent = Panel,
})
Corner(Toggle, 10); Stroke(Toggle, T.LINE, 0.5)

-- test button (fake log)
local TestBtn = New("TextButton", {
    Size = UDim2.new(0.5, -14, 0, 28), Position = UDim2.fromOffset(12, 100),
    BackgroundColor3 = T.RAISED, AutoButtonColor = false,
    Text = "Inject fake log", TextColor3 = T.HIGH,
    Font = Enum.Font.GothamSemibold, TextSize = 11, Parent = Panel,
})
Corner(TestBtn, 8); Stroke(TestBtn, T.LINE, 0.5)

local ClearBtn = New("TextButton", {
    Size = UDim2.new(0.5, -14, 0, 28), Position = UDim2.new(0.5, 2, 0, 100),
    BackgroundColor3 = T.RAISED, AutoButtonColor = false,
    Text = "Clear", TextColor3 = T.MUTED,
    Font = Enum.Font.GothamSemibold, TextSize = 11, Parent = Panel,
})
Corner(ClearBtn, 8); Stroke(ClearBtn, T.LINE, 0.5)

local StatsLbl = New("TextLabel", {
    Size = UDim2.new(1, -24, 0, 14), Position = UDim2.fromOffset(12, 134),
    BackgroundTransparency = 1, Text = "seen 0 | fired 0 | ok 0 | fail 0",
    TextColor3 = T.MUTED, Font = Enum.Font.Gotham, TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left, Parent = Panel,
})

local Feed = New("ScrollingFrame", {
    Size = UDim2.new(1, -24, 1, -166), Position = UDim2.fromOffset(12, 154),
    BackgroundColor3 = T.BG, BackgroundTransparency = 0.35,
    BorderSizePixel = 0, ScrollBarThickness = 3,
    ScrollBarImageColor3 = T.LINE, CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = Panel,
})
Corner(Feed, 10)
New("UIListLayout", {Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = Feed})
New("UIPadding", {PaddingTop = UDim.new(0, 6), PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6), Parent = Feed})

local rowOrder = 0
local function addRow(text, color, sub)
    rowOrder += 1
    local row = New("Frame", {
        Size = UDim2.new(1, 0, 0, sub and 34 or 22),
        BackgroundColor3 = T.SURFACE, BackgroundTransparency = 0.3,
        BorderSizePixel = 0, LayoutOrder = -rowOrder, Parent = Feed,
    })
    Corner(row, 6)
    New("TextLabel", {
        Size = UDim2.new(1, -10, 0, sub and 16 or 22), Position = UDim2.fromOffset(6, 0),
        BackgroundTransparency = 1, Text = text, TextColor3 = color or T.TEXT,
        Font = Enum.Font.GothamSemibold, TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd, Parent = row,
    })
    if sub then
        New("TextLabel", {
            Size = UDim2.new(1, -10, 0, 14), Position = UDim2.fromOffset(6, 16),
            BackgroundTransparency = 1, Text = sub, TextColor3 = T.MUTED,
            Font = Enum.Font.Gotham, TextSize = 10,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd, Parent = row,
        })
    end
    while #Feed:GetChildren() > 60 do
        for _, c in ipairs(Feed:GetChildren()) do
            if c:IsA("Frame") then c:Destroy() break end
        end
    end
end

local function refreshStats()
    StatsLbl.Text = ("seen %d | fired %d | ok %d | fail %d%s"):format(
        S.Stats.seen, S.Stats.fired, S.Stats.ok, S.Stats.fail,
        S.BestLatency and ("  |  best " .. fmt(S.BestLatency)) or "")
end

----------------------------------------------------------------
-- hot path
----------------------------------------------------------------

function S.Fire(userId, label, t0)
    if not InviteRF then return end
    S.Stats.fired += 1
    -- dispatch latency: event receipt -> InvokeServer call
    local dispatch = (os.clock() - t0) * 1000
    if not S.BestLatency or dispatch < S.BestLatency then S.BestLatency = dispatch end

    task.spawn(function()
        local tCall = os.clock()
        local ok, a, b = pcall(InviteRF.InvokeServer, InviteRF, S.InviteGUID, userId)
        local rtt = (os.clock() - tCall) * 1000
        if ok and a then
            S.Stats.ok += 1
            addRow(("SENT -> %s"):format(label), T.GREEN,
                ("dispatch %s | server %s | %s"):format(fmt(dispatch), fmt(rtt), tostring(b)))
        else
            S.Stats.fail += 1
            addRow(("FAIL -> %s"):format(label), T.RED,
                ("dispatch %s | %s"):format(fmt(dispatch), tostring(ok and b or a)))
        end
        refreshStats()
    end)
    refreshStats()
end

function S.OnEntry(entry, faked)
    local t0 = os.clock()
    if type(entry) ~= "table" then return end
    if type(entry.BrainrotName) ~= "string" then return end

    S.Stats.seen += 1
    local uid   = entry.OwnerUserId
    local name  = entry.OwnerDisplayName
    local scope = entry.IsLocalServer and "[SERVER]" or "[GLOBAL]"
    local mut   = entry.Mutation and (" <" .. tostring(entry.Mutation) .. ">") or ""

    addRow(("%s%s %s"):format(scope, mut, entry.BrainrotName),
        faked and T.ORANGE or T.TEXT,
        uid and ("owner %s (%s)"):format(tostring(name or "?"), tostring(uid)) or "UNCLAIMED")

    if not S.Enabled then refreshStats() return end
    if not uid or type(uid) ~= "number" then refreshStats() return end
    if uid == LP.UserId then refreshStats() return end
    if S.OnlyGlobal and entry.IsLocalServer then refreshStats() return end

    local last = S.Sent[uid]
    if last and (os.clock() - last) < S.Cooldown then refreshStats() return end
    S.Sent[uid] = os.clock()

    S.Fire(uid, ("%s (%s)"):format(tostring(name or uid), tostring(uid)), t0)
end

if NewEntry then
    NewEntry.OnClientEvent:Connect(function(entry) S.OnEntry(entry, false) end)
end
if ClaimEntry then
    -- a claim also reveals an owner: uid, ownerUserId, ownerDisplayName
    ClaimEntry.OnClientEvent:Connect(function(_, ownerUserId, ownerDisplayName)
        if type(ownerUserId) == "number" then
            S.OnEntry({
                UID = "claim", BrainrotName = "(claimed entry)",
                OwnerUserId = ownerUserId, OwnerDisplayName = ownerDisplayName,
                IsLocalServer = false, Timestamp = 0, DisplayDuration = 0,
            }, false)
        end
    end)
end

----------------------------------------------------------------
-- controls
----------------------------------------------------------------

Toggle.MouseButton1Click:Connect(function()
    S.Enabled = not S.Enabled
    Toggle.Text = "AUTO SNIPE : " .. (S.Enabled and "ON" or "OFF")
    Toggle.TextColor3 = S.Enabled and T.GREEN or T.MUTED
    TS:Create(Toggle, TweenInfo.new(0.18), {
        BackgroundColor3 = S.Enabled and T.RAISED:Lerp(T.GREEN, 0.18) or T.RAISED,
    }):Play()
    addRow(S.Enabled and "auto snipe enabled" or "auto snipe disabled", S.Enabled and T.GREEN or T.MUTED)
end)

-- fake log: kasthmz
TestBtn.MouseButton1Click:Connect(function()
    S.OnEntry({
        UID              = "FAKE-" .. tostring(math.random(1e6)),
        BrainrotName     = "Test Brainrot",
        Mutation         = "Gold",
        OwnerUserId      = 902460523,
        OwnerDisplayName = "kasthmz",
        Timestamp        = workspace:GetServerTimeNow(),
        DisplayDuration  = 30,
        IsLocalServer    = false,
    }, true)
end)

ClearBtn.MouseButton1Click:Connect(function()
    for _, c in ipairs(Feed:GetChildren()) do if c:IsA("Frame") then c:Destroy() end end
    S.Sent = {}
    S.Stats = {seen = 0, fired = 0, ok = 0, fail = 0}
    S.BestLatency = nil
    refreshStats()
end)

-- drag
do
    local dragging, start, spos
    Header.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging = true; start = i.Position; spos = Panel.Position
            i.Changed:Connect(function()
                if i.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    UIS.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
            local d = i.Position - start
            Panel.Position = UDim2.new(spos.X.Scale, spos.X.Offset + d.X, spos.Y.Scale, spos.Y.Offset + d.Y)
        end
    end)
end

refreshStats()
addRow("sniper online", T.HIGH,
    ("NewEntry %s | Invite %s"):format(NewEntry and "ok" or "MISSING", InviteRF and "ok" or "MISSING"))

return S
