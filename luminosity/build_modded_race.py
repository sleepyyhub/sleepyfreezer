#!/usr/bin/env python3
"""Generate luminosity_modded.lua (Code Race) from luminosity.lua's chrome.

The code race panel does a different job from the sniper — it has admin
fields instead of a redeem button — but it must LOOK identical: same loader,
same letter intro, same shimmer wordmark, same status dot and ring, same
notification cards, same ripple and press and hover, same FAB.

So the chrome is lifted out of luminosity.lua verbatim by anchor and spliced
around this file's own content. Nothing is retyped, so nothing can drift.
Re-run after touching luminosity.lua.
"""

import pathlib
import sys

HERE = pathlib.Path(__file__).parent
MAIN = (HERE / "luminosity.lua").read_text()
OUT = HERE / "luminosity_modded.lua"


def grab(start, end, label):
    i = MAIN.find(start)
    j = MAIN.find(end, i + 1)
    if i < 0 or j < 0:
        sys.exit(f"anchor missing for {label}: {i} {j}")
    return MAIN[i:j].rstrip() + "\n"


BAR = "----------------------------------------------------------------------\n"

helpers    = grab("local function safe(fn)", BAR + "-- REMOTES", "helpers")
primitives = grab(BAR + "-- UI PRIMITIVES", BAR + "-- LOADING SCREEN", "primitives")
loading    = grab(BAR + "-- LOADING SCREEN", BAR + "-- MAIN PANEL", "loading")
panel      = grab(BAR + "-- MAIN PANEL", BAR + "-- NOTIFICATIONS", "panel")
notifs     = grab(BAR + "-- NOTIFICATIONS", "-- kept so existing call sites", "notifs")
fab        = grab("-- FAB (when closed)", BAR + "-- INTERACTION HELPERS", "fab")
interact   = grab(BAR + "-- INTERACTION HELPERS", "press(RedeemBtn,", "interact")
hover      = grab("local function hoverFill(btn, base, hover)", "hoverFill(SendBtn,", "hover")

# The panel block carries the theme table's only consumer of T.BG etc; the
# code race build uses the same palette so nothing needs swapping there.
primitives = primitives.replace('PG:FindFirstChild("LuminosityUI")',
                                'PG:FindFirstChild("LuminosityModdedRace")')
primitives = primitives.replace('Name="LuminosityUI"', 'Name="LuminosityModdedRace"')
panel = panel.replace('Text="LUMINOSITY", TextColor3=T.HIGH', 'Text="CODE RACE · MODDED", TextColor3=T.HIGH')
fab = fab.replace('Text = "L", TextColor3 = T.HIGH', 'Text = "CR", TextColor3 = T.HIGH')
fab = fab.replace("Font = Enum.Font.GothamBold, TextSize = 18,", "Font = Enum.Font.GothamBold, TextSize = 15,")

# The status dot in the main build lights when the game's TextBox and Confirm
# are linked. Here it lights when every admin remote resolved.
panel = panel.replace("local linked = alive(L.TextBox) and alive(L.Confirm)",
                      "local linked = L.AllResolved == true")

HEAD = '''--[[  LUMINOSITY // MODDED  —  Code Race  ]]--
-- Target: the modded place ONLY
-- Executor: any. No hooks, no getgc, no VIM. Straight remote calls.
--
-- Generated from luminosity.lua's chrome by build_modded_race.py, so the
-- panel, loader, notifications and every animation are the main build's
-- code verbatim. Only the content rows differ, because this tool creates
-- codes instead of redeeming them. Edit the main script and regenerate
-- rather than restyling this by hand.
--
-- Remotes used (all verified present in Packages.Net):
--   RF/AnnounceGlobal              (text, gradient?)          -> ok, err
--   RF/AnnounceServer              (text, name, gradient?)    -> ok, err
--   RF/AdminService/CreateCode     (code, brainrot, mutation?, quantity) -> ok, err
--   RF/AdminService/DeleteCode     (code)                     -> ok, err
--
-- Signature sources: AnnouncementSCRIPT lines 78 and 100, and the admin
-- panel's Codes script line 248/272, all decompiled from this client.
-- DeleteCode's arg list is INFERRED (the invoke line did not surface in the
-- decompile) — verify with a spy before trusting it in anger.

local Players     = game:GetService("Players")
local UIS         = game:GetService("UserInputService")
local RS          = game:GetService("RunService")
local TS          = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local RepS        = game:GetService("ReplicatedStorage")
local LP          = Players.LocalPlayer
local PG          = LP:WaitForChild("PlayerGui")
local IS_MOBILE   = UIS.TouchEnabled and not UIS.KeyboardEnabled and not UIS.MouseEnabled

local L = {}

-- Hard place guard. These are admin remotes; they exist only in the modded
-- place and this build must never so much as resolve them anywhere else.
-- It shares no GUI name, no globals and no webhook with the main script.
L.MAIN_PLACE = 109983668079237
L.RightPlace = (game.PlaceId ~= L.MAIN_PLACE)

local T = {
    VOID     = Color3.fromRGB(6, 9, 18),
    BG       = Color3.fromRGB(10, 15, 28),
    SURFACE  = Color3.fromRGB(16, 24, 44),
    RAISED   = Color3.fromRGB(24, 34, 58),
    FIELD    = Color3.fromRGB(13, 19, 36),
    LINE     = Color3.fromRGB(38, 54, 88),
    ACCENT   = Color3.fromRGB(120, 180, 255),
    HIGH     = Color3.fromRGB(180, 220, 255),
    DEEP     = Color3.fromRGB(72, 130, 210),
    TEXT     = Color3.fromRGB(230, 240, 255),
    MUTED    = Color3.fromRGB(120, 145, 185),
    RED      = Color3.fromRGB(255, 130, 155),
    GREEN    = Color3.fromRGB(146, 255, 103),
    ORANGE   = Color3.fromRGB(255, 190, 120),
    PURPLE   = Color3.fromRGB(190, 150, 255),
    WHITE    = Color3.fromRGB(255, 255, 255),
}

'''

REMOTES = BAR + '''-- REMOTES
----------------------------------------------------------------------
L.Net = safe(function() return RepS:WaitForChild("Packages", 10):WaitForChild("Net", 10) end)

L.Names = {
    AnnounceGlobal = "RF/AnnounceGlobal",
    AnnounceServer = "RF/AnnounceServer",
    CreateCode     = "RF/AdminService/CreateCode",
    DeleteCode     = "RF/AdminService/DeleteCode",
}
L.R = {}                -- resolved instances, cached
L.AllResolved = false   -- drives the header dot

L.Resolve = function()
    if not L.Net or not L.RightPlace then return end
    local all = true
    for key, name in pairs(L.Names) do
        local cur = L.R[key]
        if not (cur and cur.Parent) then
            L.R[key] = L.Net:FindFirstChild(name)
        end
        if not L.R[key] then all = false end
    end
    L.AllResolved = all
end
L.Resolve()

-- Invoke and time it. Returns ok, reply, timing.
L.Call = function(key, ...)
    local t0 = os.clock()
    if not L.RightPlace then return nil, "Wrong place — modded build stays disarmed in the main game" end
    local r = L.R[key]
    if not (r and r.Parent) then
        L.Resolve()
        r = L.R[key]
        if not r then return nil, "Remote missing: " .. tostring(L.Names[key]) end
    end
    local tCall = os.clock()
    local ok, a, b = pcall(r.InvokeServer, r, ...)
    local tDone = os.clock()
    local timing = {client = (tCall - t0) * 1000, server = (tDone - tCall) * 1000}
    if not ok then return nil, tostring(a), timing end
    return a, b, timing
end

'''

REPORT = '''
-- Report an ok/reply/timing triple the same way everywhere. Same shape and
-- same wording as the main build's ReportRedeem.
L.Report = function(label, ok, reply, t)
    local line
    if t then
        if not L.BestClient or t.client < L.BestClient then L.BestClient = t.client end
        line = ("client %s (best %s) · server %s · total %s")
            :format(fmt(t.client), fmt(L.BestClient), fmt(t.server), fmt(t.client + t.server))
    end
    local text = render(reply)
    if ok == nil then
        L.Notify(label .. " failed" .. (text and (": " .. text) or ""), T.RED, line)
    elseif ok then
        L.Notify(text or (label .. " ok"), T.GREEN, line)
    else
        L.Notify(text or (label .. " rejected"), T.ORANGE, line)
    end
    return ok
end

'''

CONTENT = BAR + '''-- CONTENT ROWS
--
-- The only part that differs from the main panel. Same primitives, same
-- ripple / press / hover treatment, same 10px list rhythm.
----------------------------------------------------------------------
local order = 0
local function nextOrder() order += 1; return order end

local function Field(label, placeholder, default)
    local wrap = New("Frame", {
        Size = UDim2.new(1,0,0,42), BackgroundTransparency = 1,
        LayoutOrder = nextOrder(), Parent = Content,
    })
    New("TextLabel", {
        Size = UDim2.new(1,0,0,12), BackgroundTransparency = 1,
        Text = label, TextColor3 = T.MUTED,
        Font = Enum.Font.GothamSemibold, TextSize = 9,
        TextXAlignment = Enum.TextXAlignment.Left, Parent = wrap,
    })
    local box = New("TextBox", {
        Size = UDim2.new(1,0,0,26), Position = UDim2.new(0,0,0,14),
        BackgroundColor3 = T.FIELD, BorderSizePixel = 0,
        PlaceholderText = placeholder or "", PlaceholderColor3 = T.MUTED,
        Text = default or "", TextColor3 = T.TEXT, ClearTextOnFocus = false,
        Font = Enum.Font.GothamSemibold, TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left, Parent = wrap,
    })
    Corner(box, 8); Pad(box, 0, 0, 8, 8)
    local st = Stroke(box, T.LINE, 1, 0.55)
    box.Focused:Connect(function() tw(st, 0.15, nil, nil, {Color = T.ACCENT, Transparency = 0.2}):Play() end)
    box.FocusLost:Connect(function() tw(st, 0.2, nil, nil, {Color = T.LINE, Transparency = 0.55}):Play() end)
    return box
end

local function Row(height)
    return New("Frame", {
        Size = UDim2.new(1,0,0,height or 30), BackgroundTransparency = 1,
        LayoutOrder = nextOrder(), Parent = Content,
    })
end

local function Btn(parent, text, xScale, xOffset, widthScale, widthOffset, fill, textColor)
    local b = New("TextButton", {
        Size = UDim2.new(widthScale, widthOffset, 1, 0),
        Position = UDim2.new(xScale, xOffset, 0, 0),
        BackgroundColor3 = fill or T.RAISED, AutoButtonColor = false,
        ClipsDescendants = true, Text = text, TextColor3 = textColor or T.TEXT,
        Font = Enum.Font.GothamBold, TextSize = 11, Parent = parent,
    })
    Corner(b, 8)
    ripple(b, T.WHITE)
    hoverFill(b, fill or T.RAISED, (fill or T.RAISED):Lerp(T.WHITE, 0.12))
    return b
end

local CodeBox     = Field("CODE",      "SUMMER2026")
local BrainrotBox = Field("BRAINROT",  "exact name from Datas.Animals")
local MutationBox = Field("MUTATION",  "blank or None for no mutation")
local QuantityBox = Field("QUANTITY",  "number, or Infinite", "1")

local CodeRow = Row(32)
local CreateBtn  = Btn(CodeRow, "CREATE",  0,    0,   0.32, -4, T.ACCENT, T.VOID)
local DeleteBtn  = Btn(CodeRow, "DELETE",  0.34, 0,   0.32, -4, T.RAISED, T.RED)
local RecycleBtn = Btn(CodeRow, "RECYCLE", 0.68, 0,   0.32,  0, T.RAISED, T.PURPLE)

local AnnBox  = Field("ANNOUNCE TEXT", "message shown to players")
local NameBox = Field("ANNOUNCE NAME", "sender name (server only)")
local GradBox = Field("GRADIENT",      "gradient preset, blank for none")

local AnnRow = Row(32)
local GlobalBtn = Btn(AnnRow, "ANNOUNCE GLOBAL", 0,    0, 0.49, -4, T.RAISED, T.HIGH)
local ServerBtn = Btn(AnnRow, "ANNOUNCE SERVER", 0.51, 0, 0.49,  0, T.RAISED, T.HIGH)

-- The hero button, styled exactly like the main build's Redeem: gradient
-- fill, stroke that glows on hover, press sink, ripple from the click point.
local RaceRow = Row(44)
local RaceBtn = New("TextButton", {
    Size = UDim2.new(1, 0, 1, 0),
    BackgroundColor3 = T.ACCENT, AutoButtonColor = false, ClipsDescendants = true,
    Text = "RACE  (create + announce)", TextColor3 = T.VOID,
    Font = Enum.Font.GothamBold, TextSize = 15, Parent = RaceRow,
})
Corner(RaceBtn, 12)
local RaceGrad = New("UIGradient", {
    Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, T.DEEP),
        ColorSequenceKeypoint.new(0.5, T.ACCENT),
        ColorSequenceKeypoint.new(1, T.HIGH),
    }), Rotation = 90, Parent = RaceBtn,
})
local RaceStroke = Stroke(RaceBtn, T.HIGH, 1, 0.6)
press(RaceBtn, UDim2.new(1,0,1,0))
ripple(RaceBtn, T.VOID)
RaceBtn.MouseEnter:Connect(function()
    tw(RaceStroke, 0.15, nil, nil, {Transparency = 0.15, Thickness = 2}):Play()
    tw(RaceGrad, 0.3, nil, nil, {Rotation = 45}):Play()
end)
RaceBtn.MouseLeave:Connect(function()
    tw(RaceStroke, 0.25, nil, nil, {Transparency = 0.6, Thickness = 1}):Play()
    tw(RaceGrad, 0.3, nil, nil, {Rotation = 90}):Play()
end)

hoverFill(MinBtn,   T.RAISED, T.RAISED:Lerp(T.ACCENT, 0.2))
hoverFill(CloseBtn, T.RAISED, Color3.fromRGB(50, 22, 34))
hoverFill(Fab,      T.SURFACE, T.RAISED)

'''

ACTIONS = BAR + '''-- FIELD READING + ACTIONS
----------------------------------------------------------------------
local function clean(s)
    s = tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
    return s ~= "" and s or nil
end

-- quantity: number, or math.huge for Infinite (matches the admin panel)
local function readQuantity()
    local q = clean(QuantityBox.Text)
    if not q then return math.huge end
    if q:lower() == "infinite" or q == "\\226\\136\\158" then return math.huge end
    local n = tonumber(q)
    if n and n >= 1 then return n end
    return nil
end

-- mutation: nil when blank or "None", exactly like the game's own panel
local function readMutation()
    local m = clean(MutationBox.Text)
    if not m or m == "None" or m:lower() == "none" then return nil end
    return m
end

L.CreateCode = function(silent)
    local code = clean(CodeBox.Text)
    if not code then L.Notify("Code name required", T.RED); return nil end
    local brainrot = clean(BrainrotBox.Text)
    if not brainrot then L.Notify("Brainrot required", T.RED); return nil end
    local qty = readQuantity()
    if not qty then L.Notify("Quantity must be a number or Infinite", T.RED); return nil end

    local ok, reply, t = L.Call("CreateCode", code, brainrot, readMutation(), qty)
    if not silent then L.Report("Create", ok, reply, t) end
    return ok, reply, t
end

L.DeleteCode = function(silent)
    local code = clean(CodeBox.Text)
    if not code then L.Notify("Code name required", T.RED); return nil end
    local ok, reply, t = L.Call("DeleteCode", code)
    if not silent then L.Report("Delete", ok, reply, t) end
    return ok, reply, t
end

-- Recycle: delete then immediately recreate, so the code is fresh and its
-- stock resets. Delete is allowed to fail (the code may not exist yet) —
-- create is the part that has to land.
L.Recycle = function()
    local t0 = os.clock()
    local dOk = L.DeleteCode(true)
    local cOk, reply = L.CreateCode(true)
    local total = (os.clock() - t0) * 1000
    local sub = ("delete %s · create %s · cycle %s")
        :format(dOk and "ok" or "skipped", cOk and "ok" or "failed", fmt(total))
    if cOk then
        L.Notify("Recycled " .. (clean(CodeBox.Text) or ""), T.PURPLE, sub)
    else
        L.Notify(render(reply) or "Recycle failed", T.RED, sub)
    end
    return cOk
end

L.AnnounceGlobal = function(silent)
    local text = clean(AnnBox.Text)
    if not text then L.Notify("Announce text required", T.RED); return nil end
    local ok, reply, t = L.Call("AnnounceGlobal", text, clean(GradBox.Text))
    if not silent then L.Report("Announce", ok, reply, t) end
    return ok, reply, t
end

L.AnnounceServer = function(silent)
    local text = clean(AnnBox.Text)
    if not text then L.Notify("Announce text required", T.RED); return nil end
    local ok, reply, t = L.Call("AnnounceServer", text, clean(NameBox.Text) or "", clean(GradBox.Text))
    if not silent then L.Report("Announce", ok, reply, t) end
    return ok, reply, t
end

-- Race: make the code, then shout it. If the announce box is empty we
-- announce the code itself, which is the usual point of a race.
L.Race = function()
    local t0 = os.clock()
    local cOk, reply = L.CreateCode(true)
    if not cOk then
        L.Notify(render(reply) or "Create failed", T.RED)
        return false
    end
    local code = clean(CodeBox.Text)
    if not clean(AnnBox.Text) then AnnBox.Text = code end
    local aOk = L.AnnounceGlobal(true)
    local total = (os.clock() - t0) * 1000
    L.Notify("Raced " .. code, aOk and T.GREEN or T.ORANGE,
        ("create ok · announce %s · total %s"):format(aOk and "ok" or "failed", fmt(total)))
    return true
end

CreateBtn.MouseButton1Click:Connect(function()  task.spawn(L.CreateCode) end)
DeleteBtn.MouseButton1Click:Connect(function()  task.spawn(L.DeleteCode) end)
RecycleBtn.MouseButton1Click:Connect(function() task.spawn(L.Recycle) end)
GlobalBtn.MouseButton1Click:Connect(function()  task.spawn(L.AnnounceGlobal) end)
ServerBtn.MouseButton1Click:Connect(function()  task.spawn(L.AnnounceServer) end)
RaceBtn.MouseButton1Click:Connect(function()    task.spawn(L.Race) end)

'''

WINDOW = BAR + '''-- PANEL MIN / CLOSE   (main build, verbatim behaviour)
----------------------------------------------------------------------
MinBtn.MouseButton1Click:Connect(function()
    minimized = not minimized
    if minimized then
        Content.Visible = false
        tw(Panel, 0.26, Enum.EasingStyle.Quart, nil, {Size = UDim2.fromOffset(PANEL_W, 44)}):Play()
        MinBtn.Text = "+"
    else
        MinBtn.Text = "—"
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

'''

INTRO = BAR + '''-- INTRO SEQUENCE   (same timings as the main build)
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

    local steps = { "loading modules", "resolving admin remotes", "checking place", "ready" }
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
    task.delay(0.6, function() L.DotReady = true end)

    if not L.RightPlace then
        L.Notify("Wrong place", T.RED, "this is the main game — nothing here will fire")
        return
    end

    L.Resolve()
    local missing = {}
    for key, name in pairs(L.Names) do
        if not L.R[key] then missing[#missing+1] = name end
    end
    if #missing == 0 then
        task.delay(0.7, function() L.Notify("All remotes resolved", T.GREEN) end)
    else
        task.delay(0.7, function() L.Notify("Missing remotes", T.RED, table.concat(missing, ", ")) end)
        warn("[CodeRace] missing:", table.concat(missing, ", "))
    end
end)

print("[CodeRace] loaded for placeId " .. tostring(game.PlaceId))
'''

out = "".join([
    HEAD, helpers, "\n", REMOTES,
    primitives, "\n", loading, "\n", panel, "\n", notifs, REPORT,
    fab, "\n", interact, "\n", hover, "\n",
    CONTENT, ACTIONS, WINDOW, INTRO,
])

OUT.write_text(out)
print(f"wrote {OUT} ({len(out.splitlines())} lines)")
