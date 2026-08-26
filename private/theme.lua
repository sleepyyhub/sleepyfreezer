
--[[ ====================================================================
     LUCK PRIVATE  ·  living gradient theme engine

     Appended to the base script rather than forked into it, so the private
     build is always the public one plus this file and the two cannot drift.
     It touches nothing on the detection or send path -- it finds the panels
     after they exist, puts a UIGradient on each, and drives them.

     Ten palettes. Rainbow is a real hue sweep; the rest are hand-picked
     ramps. Pick with the THEME panel, LUCK.SetTheme("Ruby"), or the cycle
     key. The choice is saved.
     ==================================================================== ]]

do

local L = (getgenv and getgenv().LUCK) or LUCK
if not L then return end

local RS   = game:GetService("RunService")
local UIS  = game:GetService("UserInputService")
local HTTP = game:GetService("HttpService")

local rgb   = Color3.fromRGB
local hsv   = Color3.fromHSV
local floor = math.floor

L.Private = true
L.PrivateBuild = "1.0"

-- --------------------------------------------------------------------
-- Palettes
--
-- Colors is the ramp the gradient flows through, and it wraps: the engine
-- appends the first colour to the end so the loop has no seam. Accent is
-- what the swatch and the picker highlight use.
-- --------------------------------------------------------------------
local THEMES = {
    {name = "Rainbow", hue = true, accent = rgb(255, 120, 200)},

    {name = "Clover",  accent = rgb(95, 235, 145), colors = {
        rgb(24, 92, 54), rgb(45, 165, 95), rgb(95, 235, 145), rgb(170, 255, 205)}},

    {name = "Toxic",   accent = rgb(130, 255, 55), colors = {
        rgb(48, 110, 16), rgb(98, 210, 38), rgb(130, 255, 55), rgb(210, 255, 120)}},

    {name = "Mint",    accent = rgb(90, 230, 190), colors = {
        rgb(20, 105, 82), rgb(50, 180, 140), rgb(90, 230, 190), rgb(180, 255, 230)}},

    {name = "Aqua",    accent = rgb(80, 205, 230), colors = {
        rgb(20, 82, 115), rgb(45, 150, 195), rgb(80, 205, 230), rgb(160, 245, 255)}},

    {name = "Ice",     accent = rgb(112, 190, 255), colors = {
        rgb(34, 92, 165), rgb(70, 155, 235), rgb(112, 190, 255), rgb(205, 238, 255)}},

    {name = "Grape",   accent = rgb(150, 112, 255), colors = {
        rgb(62, 34, 130), rgb(112, 68, 205), rgb(150, 112, 255), rgb(210, 186, 255)}},

    {name = "Sakura",  accent = rgb(236, 105, 168), colors = {
        rgb(112, 30, 82), rgb(190, 72, 140), rgb(236, 105, 168), rgb(255, 186, 222)}},

    {name = "Gold",    accent = rgb(220, 172, 64), colors = {
        rgb(102, 68, 16), rgb(180, 126, 38), rgb(220, 172, 64), rgb(255, 230, 145)}},

    {name = "Lava",    accent = rgb(255, 90, 40), colors = {
        rgb(112, 26, 6), rgb(190, 52, 16), rgb(255, 90, 40), rgb(255, 178, 100)}},
}

local byName = {}
for i, t in ipairs(THEMES) do
    t.index = i
    byName[t.name] = t
end
L.Themes = THEMES
L.ThemeNames = (function()
    local out = table.create(#THEMES)
    for i, t in ipairs(THEMES) do out[i] = t.name end
    return out
end)()

-- --------------------------------------------------------------------
-- Knobs
-- --------------------------------------------------------------------
L.ThemeOn    = true      -- false freezes every gradient where it stands
L.ThemeFps   = 30        -- gradient updates per second, NOT per frame
L.ThemeSpeed = 0.14      -- laps per second through the ramp
L.ThemeSpan  = 0.85      -- how much of the ramp is visible at once
L.ThemeKeys  = 20        -- keypoints per gradient
L.ThemeTilt  = 35        -- gradient rotation, degrees

local IS_MOBILE = L.IsMobile == true
if IS_MOBILE then
    -- A phone does not need 30 rebuilds a second of a cosmetic sweep.
    L.ThemeFps, L.ThemeKeys = 15, 10
end

-- --------------------------------------------------------------------
-- Sampling
-- --------------------------------------------------------------------
local function fract(x) return x - floor(x) end

local function scale(c, k)
    return Color3.new(math.clamp(c.R * k, 0, 1),
                      math.clamp(c.G * k, 0, 1),
                      math.clamp(c.B * k, 0, 1))
end
local function toward(c, target, a) return c:Lerp(target, a) end
local WHITE = Color3.new(1, 1, 1)

-- The flat palette the widgets read, derived from the ramp rather than written
-- out ten times by hand -- ten hand-tuned tables is ten chances for one of them
-- to be subtly wrong, and derived ones stay consistent when a ramp is edited.
local function uiFor(theme)
    if theme.ui then return theme.ui end
    if theme.hue then
        -- A hue sweep has no single colour to build a palette from, so Rainbow
        -- gets a neutral one: near-black chrome and near-white text, which is
        -- what lets the sweep itself be the colour.
        theme.ui = {
            VOID    = Color3.fromRGB(6, 6, 9),
            BG      = Color3.fromRGB(11, 11, 16),
            SURFACE = Color3.fromRGB(17, 17, 24),
            RAISED  = Color3.fromRGB(26, 26, 36),
            LINE    = Color3.fromRGB(48, 48, 64),
            ACCENT  = Color3.fromRGB(255, 120, 200),
            HIGH    = Color3.fromRGB(255, 205, 235),
            DEEP    = Color3.fromRGB(150, 60, 190),
            TEXT    = Color3.fromRGB(238, 238, 246),
            MUTED   = Color3.fromRGB(140, 138, 156),
        }
        return theme.ui
    end
    local c = theme.colors
    local dark, mid, bright, light = c[1], c[2], c[3], c[4]
    theme.ui = {
        VOID    = scale(dark, 0.16),
        BG      = scale(dark, 0.28),
        SURFACE = scale(dark, 0.42),
        RAISED  = scale(dark, 0.62),
        LINE    = scale(mid,  0.52),
        ACCENT  = bright,
        HIGH    = light,
        DEEP    = dark,
        TEXT    = toward(light, WHITE, 0.55),
        MUTED   = scale(toward(mid, WHITE, 0.2), 0.62),
    }
    return theme.ui
end

-- Ramps are built once per theme and cached. Rebuilding the keypoint table
-- every tick is unavoidable -- ColorSequence is immutable -- but rebuilding
-- the *ramp* it samples from is not.
local function rampFor(theme)
    if theme.ramp then return theme.ramp end
    local c = theme.colors
    local n = #c
    local ramp = table.create(n + 1)
    for i = 1, n do ramp[i] = {t = (i - 1) / n, v = c[i]} end
    ramp[n + 1] = {t = 1, v = c[1]}   -- wrap, so the loop has no seam
    theme.ramp = ramp
    return ramp
end

local function sampleOf(theme)
    if theme.hue then
        return function(u) return hsv(fract(u), 0.82, 1) end
    end
    local ramp = rampFor(theme)
    local n = #ramp
    return function(u)
        u = fract(u)
        for i = 1, n - 1 do
            local a, b = ramp[i], ramp[i + 1]
            if u >= a.t and u <= b.t then
                local span = b.t - a.t
                return a.v:Lerp(b.v, span > 0 and (u - a.t) / span or 0)
            end
        end
        return ramp[n].v
    end
end

-- --------------------------------------------------------------------
-- Registry
--
-- Flat arrays, walked once. The original this grew out of ran one
-- RenderStepped per gradient and re-walked the whole GUI tree ~28 times a
-- second to find strokes; at 999 fps that is a real main-thread bill for a
-- cosmetic effect. One connection, one throttle, no tree walks at runtime.
-- --------------------------------------------------------------------
local gradients, strokes, swatches, flowText = {}, {}, {}, {}
local tinted = {}          -- every widget captured at boot, with its boot colours
local conn, tAccum, frameAccum = nil, 0, 0
local themedGui

local function currentTheme()
    return byName[L.Theme] or THEMES[1]
end

local function anyVisible()
    for i = 1, #gradients do
        local g = gradients[i]
        local p = g.Parent
        if p and p.Visible then return true end
    end
    return false
end

local function paintStatic()
    local sample = sampleOf(currentTheme())
    local n = L.ThemeKeys
    local kps = table.create(n)
    for i = 1, n do
        local t = (i - 1) / (n - 1)
        kps[i] = ColorSequenceKeypoint.new(t, sample(t * L.ThemeSpan))
    end
    local seq = ColorSequence.new(kps)
    for i = #gradients, 1, -1 do
        local g = gradients[i]
        if g.Parent then g.Color, g.Rotation = seq, L.ThemeTilt
        else table.remove(gradients, i) end
    end
    local a, b = sample(0), sample(0.35)
    for i = #strokes, 1, -1 do
        local s = strokes[i]
        if s.Parent then s.Color = s.Thickness > 1 and a or b
        else table.remove(strokes, i) end
    end
    for i = #flowText, 1, -1 do
        local e = flowText[i]
        if e.Parent then e.TextColor3 = b else table.remove(flowText, i) end
    end
end

local function tick(dt)
    if not L.ThemeOn then return end
    frameAccum += dt
    local rate = 1 / math.max(1, L.ThemeFps)
    if frameAccum < rate then return end
    tAccum += frameAccum
    frameAccum = 0
    if not anyVisible() then return end

    local sample = sampleOf(currentTheme())
    local n = L.ThemeKeys
    local head = fract(tAccum * L.ThemeSpeed)
    local kps = table.create(n)
    for i = 1, n do
        local t = (i - 1) / (n - 1)
        kps[i] = ColorSequenceKeypoint.new(t, sample(head + t * L.ThemeSpan))
    end
    local seq = ColorSequence.new(kps)

    -- Backwards, so dropping a destroyed entry does not shift the ones
    -- still to come.
    for i = #gradients, 1, -1 do
        local g = gradients[i]
        if g.Parent then g.Color = seq else table.remove(gradients, i) end
    end
    local a, b = sample(head), sample(head + 0.35)
    for i = #strokes, 1, -1 do
        local s = strokes[i]
        if s.Parent then s.Color = s.Thickness > 1 and a or b
        else table.remove(strokes, i) end
    end
    -- The headline text -- panel titles, section tags, the FAB -- rides the
    -- sweep too. A fixed set collected once at boot, so this cannot grow.
    for i = #flowText, 1, -1 do
        local e = flowText[i]
        if e.Parent then e.TextColor3 = b else table.remove(flowText, i) end
    end
    for i = #swatches, 1, -1 do
        local sw = swatches[i]
        if sw.frame.Parent then
            sw.grad.Color = sw.theme.hue and seq or sw.grad.Color
        else table.remove(swatches, i) end
    end
end

local function start()
    if conn then return end
    conn = RS.RenderStepped:Connect(tick)
end
local function stop()
    if not conn then return end
    conn:Disconnect()
    conn = nil
end
L.ThemeStop = stop
L.ThemeStart = start

-- --------------------------------------------------------------------
-- Attaching to the panels
-- --------------------------------------------------------------------
local function findGui()
    local parent = L.GuiParent
    if not parent then return nil end
    for _, d in ipairs(parent:GetChildren()) do
        if d:IsA("ScreenGui") and tostring(d.Name):match("^LUCK_%d+$") then
            return d
        end
    end
    return nil
end

-- Top-level chrome only: the panel bodies, the FAB, their outlines. Everything
-- else is a label, a pill or a row -- mostly transparent, so a gradient on it
-- shows nothing, and each one would still cost a write every tick.
--
-- Deliberately NOT filtered on BackgroundTransparency: when this runs every
-- panel is still fully transparent and only tweens up during the intro, so that
-- test would reject all of them.
local function attach(inst)
    local parent = inst.Parent
    if parent ~= themedGui and (parent == nil or parent.Parent ~= themedGui) then
        return
    end
    if inst:IsA("UIStroke") then
        strokes[#strokes + 1] = inst
        return
    end
    if not inst:IsA("Frame") and not inst:IsA("TextButton") then return end
    if parent ~= themedGui then return end
    if inst:FindFirstChild("LuckThemeGradient") then return end
    local g = Instance.new("UIGradient")
    g.Name = "LuckThemeGradient"
    g.Rotation = L.ThemeTilt
    g.Transparency = NumberSequence.new(0.45)
    g.Parent = inst
    gradients[#gradients + 1] = g
end

-- --------------------------------------------------------------------
-- Retinting the whole UI
--
-- The gradient only ever covered the panel bodies, so with a theme picked the
-- rest of the UI stayed the colour it was built in. Fixing that has two halves.
--
-- Half one: rewrite the palette the base script reads its colours from. Widgets
-- read it at creation time, so every toast, feed line and history row built
-- after a theme change comes out in the new colours with nothing to walk.
--
-- Half two: the widgets that already exist were built from the old palette, so
-- they need one pass. Their boot colours are captured once, and every theme
-- change maps boot colour -> new colour from that snapshot. Mapping from the
-- CURRENT colour would work exactly once: after the first change nothing
-- matches the palette it was compared against any more.
--
-- One walk per theme change, which is a click. Nothing per frame, nothing on
-- the path of a redeem.
-- --------------------------------------------------------------------
local PAL_KEYS = {"VOID", "BG", "SURFACE", "RAISED", "LINE",
                  "ACCENT", "HIGH", "DEEP", "TEXT", "MUTED"}
local bootPalette

local function keyOf(c)
    if not c then return nil end
    return floor(c.R * 255 + 0.5) * 65536
         + floor(c.G * 255 + 0.5) * 256
         + floor(c.B * 255 + 0.5)
end

local function capture()
    table.clear(tinted)
    if not themedGui then return end
    for _, d in ipairs(themedGui:GetDescendants()) do
        local rec
        local okBg = pcall(function()
            if d:IsA("GuiObject") then rec = {bg = d.BackgroundColor3} end
        end)
        if not okBg or not rec then rec = {} end
        pcall(function()
            if d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") then
                rec.text = d.TextColor3
            end
        end)
        pcall(function()
            if d:IsA("UIStroke") then rec.stroke = d.Color end
        end)
        if rec.bg or rec.text or rec.stroke then
            rec.inst = d
            tinted[#tinted + 1] = rec
        end
    end
end

local function applyPalette(theme)
    local P = L.Palette
    if not P then return end
    if not bootPalette then
        bootPalette = {}
        for _, k in ipairs(PAL_KEYS) do bootPalette[k] = P[k] end
    end

    local ui = uiFor(theme)
    local remap = {}
    for _, k in ipairs(PAL_KEYS) do
        local from, to = bootPalette[k], ui[k]
        if from and to then remap[keyOf(from)] = to end
        if to then P[k] = to end          -- half one: everything built from here on
    end

    -- half two: the widgets that already exist
    for i = #tinted, 1, -1 do
        local rec = tinted[i]
        local d = rec.inst
        if not d.Parent then
            table.remove(tinted, i)
        else
            if rec.bg then
                local to = remap[keyOf(rec.bg)]
                if to then pcall(function() d.BackgroundColor3 = to end) end
            end
            if rec.text then
                local to = remap[keyOf(rec.text)]
                if to then pcall(function() d.TextColor3 = to end) end
            end
            if rec.stroke then
                local to = remap[keyOf(rec.stroke)]
                if to then pcall(function() d.Color = to end) end
            end
        end
    end

    -- the base repaints these from the palette, so let it
    for _, fn in ipairs({L.PaintModes, L.RefreshHistory, L.RefreshPreview,
                         L.PaintCooldown, L.PaintSwitches, L.PaintSpeed}) do
        if type(fn) == "function" then pcall(fn) end
    end
end

local function attachAll()
    themedGui = findGui()
    if not themedGui then return false end
    table.clear(gradients)
    table.clear(strokes)
    table.clear(flowText)
    for _, d in ipairs(themedGui:GetDescendants()) do attach(d) end
    capture()

    -- The headline text rides the sweep: anything built in the accent or the
    -- highlight colour. Collected once from the boot snapshot, so it is a fixed
    -- set and cannot grow with traffic.
    do
        local P = L.Palette
        local hot = P and {[keyOf(P.ACCENT)] = true, [keyOf(P.HIGH)] = true} or {}
        for _, rec in ipairs(tinted) do
            if rec.text and hot[keyOf(rec.text)] then
                flowText[#flowText + 1] = rec.inst
            end
        end
    end
    -- No DescendantAdded hook, on purpose. The top-level chrome is built once
    -- and never added to again; the things that DO keep arriving are toasts,
    -- feed lines and history rows, and those are not themed. A hook would put a
    -- Lua callback on the creation of every one of them -- and the first version
    -- did exactly that, took every UIStroke it was handed, and grew a list that
    -- held destroyed instances alive between ticks. Measured cost of that on the
    -- SEND path, from GC pressure alone: 171ns -> 315ns. One walk here, nothing
    -- on the hot path, and the picker registers its own pieces as it builds them.
    applyPalette(currentTheme())
    paintStatic()
    start()
    return true
end

-- --------------------------------------------------------------------
-- Choosing
-- --------------------------------------------------------------------
local THEME_FILE = "LUCK/private_theme.txt"
local MIN_FILE   = "LUCK/private_theme_min.txt"
local function saveTheme()
    pcall(function()
        if type(makefolder) == "function"
            and (type(isfolder) ~= "function" or not isfolder("LUCK")) then
            makefolder("LUCK")
        end
        writefile(THEME_FILE, tostring(L.Theme))
    end)
end
local function loadTheme()
    local ok, v = pcall(function()
        if type(isfile) == "function" and not isfile(THEME_FILE) then return nil end
        return readfile(THEME_FILE)
    end)
    if ok and type(v) == "string" and byName[v] then return v end
    return nil
end

L.Theme = loadTheme() or "Rainbow"

local repaintPicker
L.SetTheme = function(name)
    local t = byName[tostring(name)]
    if not t then
        print("[LUCK] themes: " .. table.concat(L.ThemeNames, ", "))
        return false, "unknown theme"
    end
    L.Theme = t.name
    saveTheme()
    applyPalette(t)
    paintStatic()
    if repaintPicker then repaintPicker() end
    if L.Notify then L.Notify("theme · " .. t.name, t.accent) end
    return true
end

L.NextTheme = function()
    local cur = currentTheme().index
    return L.SetTheme(THEMES[(cur % #THEMES) + 1].name)
end

L.ThemePrint = function()
    print("[LUCK] theme " .. tostring(L.Theme)
        .. "   (" .. #THEMES .. " available)")
    print("[LUCK] " .. table.concat(L.ThemeNames, ", "))
    print(("[LUCK] running %s   %d gradients   %d strokes   %d fps"):format(
        conn and "yes" or "no", #gradients, #strokes, L.ThemeFps))
end

-- --------------------------------------------------------------------
-- The picker
-- --------------------------------------------------------------------
local function buildPicker()
    local gui = themedGui
    if not gui then return end

    local W, H = 214, 232
    local root = Instance.new("Frame")
    root.Name = "LuckThemePicker"
    root.Size = UDim2.new(0, W, 0, H)
    root.Position = UDim2.new(0, 16, 0, 210)
    root.BackgroundColor3 = rgb(8, 17, 11)
    root.BackgroundTransparency = 0.12
    root.BorderSizePixel = 0
    root.Visible = false
    root.Parent = gui
    Instance.new("UICorner", root).CornerRadius = UDim.new(0, 14)

    local edge = Instance.new("UIStroke", root)
    edge.Thickness = 1
    edge.Transparency = 0.5

    -- Registered by hand, because the panel walk already ran and there is no
    -- DescendantAdded hook to catch these.
    strokes[#strokes + 1] = edge
    attach(root)

    local header = Instance.new("TextButton")
    header.Size = UDim2.new(1, 0, 0, 28)
    header.BackgroundTransparency = 1
    header.Text = ""
    header.AutoButtonColor = false
    header.Parent = root

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -20, 1, 0)
    title.Position = UDim2.new(0, 12, 0, 0)
    title.BackgroundTransparency = 1
    title.Text = "THEME"
    title.TextColor3 = rgb(165, 255, 198)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 11
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = header

    local nameLabel = Instance.new("TextLabel")
    nameLabel.Size = UDim2.new(1, -20, 0, 12)
    nameLabel.Position = UDim2.new(0, 12, 0, 26)
    nameLabel.BackgroundTransparency = 1
    nameLabel.Text = L.Theme
    nameLabel.TextColor3 = (L.Palette and L.Palette.MUTED) or rgb(108, 148, 120)
    nameLabel.Font = Enum.Font.GothamSemibold
    nameLabel.TextSize = 9
    nameLabel.TextXAlignment = Enum.TextXAlignment.Left
    nameLabel.Parent = root

    -- Body, so minimising is one Visible flip rather than ten. Collapsed, the
    -- panel is just its header -- same behaviour as the script's own panels.
    local body = Instance.new("Frame")
    body.Name = "Body"
    body.Size = UDim2.new(1, 0, 1, -40)
    body.Position = UDim2.new(0, 0, 0, 40)
    body.BackgroundTransparency = 1
    body.Parent = root

    local minBtn = Instance.new("TextButton")
    minBtn.Size = UDim2.new(0, 18, 0, 18)
    minBtn.Position = UDim2.new(1, -46, 0.5, -9)
    minBtn.BackgroundColor3 = (L.Palette and L.Palette.RAISED) or rgb(17, 36, 23)
    minBtn.Text = "-"
    minBtn.TextColor3 = (L.Palette and L.Palette.ACCENT) or rgb(74, 222, 128)
    minBtn.Font = Enum.Font.GothamBold
    minBtn.TextSize = 12
    minBtn.AutoButtonColor = false
    minBtn.BorderSizePixel = 0
    minBtn.Parent = header
    Instance.new("UICorner", minBtn).CornerRadius = UDim.new(0, 6)

    local hideBtn = Instance.new("TextButton")
    hideBtn.Size = UDim2.new(0, 18, 0, 18)
    hideBtn.Position = UDim2.new(1, -24, 0.5, -9)
    hideBtn.BackgroundColor3 = (L.Palette and L.Palette.RAISED) or rgb(17, 36, 23)
    hideBtn.Text = "x"
    hideBtn.TextColor3 = (L.Palette and L.Palette.RED) or rgb(255, 130, 155)
    hideBtn.Font = Enum.Font.GothamBold
    hideBtn.TextSize = 11
    hideBtn.AutoButtonColor = false
    hideBtn.BorderSizePixel = 0
    hideBtn.Parent = header
    Instance.new("UICorner", hideBtn).CornerRadius = UDim.new(0, 6)

    local minimized = false
    local function applyMin()
        minBtn.Text = minimized and "+" or "-"
        body.Visible = not minimized
        nameLabel.Visible = not minimized
        root.Size = minimized and UDim2.new(0, W, 0, 28) or UDim2.new(0, W, 0, H)
    end
    L.MinimizeThemePanel = function(on)
        if on == nil then on = not minimized end
        minimized = on and true or false
        applyMin()
        pcall(function() writefile(MIN_FILE, minimized and "1" or "0") end)
        return minimized
    end
    minBtn.MouseButton1Click:Connect(function() L.MinimizeThemePanel() end)
    hideBtn.MouseButton1Click:Connect(function()
        if L.ToggleThemePanel then L.ToggleThemePanel(false) end
    end)

    -- Drag. The InputChanged handler is connected only while a drag is in
    -- progress and dropped on release, so this is not a permanent global
    -- callback firing on every mouse move -- the base script went to the
    -- trouble of collapsing six of those into one and this must not add a
    -- seventh.
    --
    -- Wrapped, because the picker is cosmetic: an executor or GUI parent that
    -- does not hand out one of these signals should cost the drag, not the
    -- whole panel.
    pcall(function()
        local startPos, startAt, moveConn
        local function stopDrag()
            if moveConn then
                pcall(function() moveConn:Disconnect() end)
                moveConn = nil
            end
        end
        header.InputBegan:Connect(function(i)
            if i.UserInputType ~= Enum.UserInputType.MouseButton1
                and i.UserInputType ~= Enum.UserInputType.Touch then return end
            startAt, startPos = i.Position, root.Position
            stopDrag()
            moveConn = UIS.InputChanged:Connect(function(m)
                if m.UserInputType ~= Enum.UserInputType.MouseMovement
                    and m.UserInputType ~= Enum.UserInputType.Touch then return end
                local d = m.Position - startAt
                root.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
                                          startPos.Y.Scale, startPos.Y.Offset + d.Y)
            end)
            i.Changed:Connect(function()
                if i.UserInputState == Enum.UserInputState.End then stopDrag() end
            end)
        end)
        if header.InputEnded then
            header.InputEnded:Connect(function(i)
                if i.UserInputType == Enum.UserInputType.MouseButton1
                    or i.UserInputType == Enum.UserInputType.Touch then stopDrag() end
            end)
        end
    end)

    local rows = {}
    for i, theme in ipairs(THEMES) do
        local col = (i - 1) % 2
        local row = floor((i - 1) / 2)
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(0, 92, 0, 30)
        b.Position = UDim2.new(0, 12 + col * 98, 0, 6 + row * 36)
        b.BackgroundColor3 = rgb(17, 36, 23)
        b.Text = ""
        b.AutoButtonColor = false
        b.BorderSizePixel = 0
        b.Parent = body
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 8)

        -- Each swatch wears its own palette so the list reads as colours,
        -- not as ten identical buttons with words on them.
        local sw = Instance.new("Frame")
        sw.Size = UDim2.new(0, 22, 0, 18)
        sw.Position = UDim2.new(0, 6, 0.5, -9)
        sw.BackgroundColor3 = theme.accent
        sw.BorderSizePixel = 0
        sw.Parent = b
        Instance.new("UICorner", sw).CornerRadius = UDim.new(0, 5)

        local sg = Instance.new("UIGradient")
        sg.Rotation = 25
        sg.Parent = sw
        if theme.hue then
            local kps = table.create(8)
            for k = 1, 8 do
                local t = (k - 1) / 7
                kps[k] = ColorSequenceKeypoint.new(t, hsv(t * 0.92, 0.82, 1))
            end
            sg.Color = ColorSequence.new(kps)
        else
            local ramp = rampFor(theme)
            local kps = table.create(#ramp)
            for k, e in ipairs(ramp) do
                kps[k] = ColorSequenceKeypoint.new(e.t, e.v)
            end
            sg.Color = ColorSequence.new(kps)
        end
        swatches[#swatches + 1] = {frame = sw, grad = sg, theme = theme}

        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(1, -36, 1, 0)
        lbl.Position = UDim2.new(0, 34, 0, 0)
        lbl.BackgroundTransparency = 1
        lbl.Text = theme.name
        lbl.TextColor3 = rgb(228, 246, 233)
        lbl.Font = Enum.Font.GothamBold
        lbl.TextSize = 10
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.Parent = b

        b.MouseButton1Click:Connect(function() L.SetTheme(theme.name) end)
        rows[i] = {button = b, label = lbl, theme = theme}
    end

    repaintPicker = function()
        nameLabel.Text = L.Theme
        for _, r in ipairs(rows) do
            local on = r.theme.name == L.Theme
            r.button.BackgroundColor3 = on and rgb(31, 60, 41) or rgb(17, 36, 23)
            r.label.TextColor3 = on and r.theme.accent or rgb(160, 190, 170)
        end
    end
    repaintPicker()

    -- restore whatever it was left as
    local savedMin = false
    pcall(function()
        if type(isfile) == "function" and not isfile(MIN_FILE) then return end
        savedMin = readfile(MIN_FILE) == "1"
    end)
    minimized = savedMin
    applyMin()

    L.ThemePanel = root
    L.ToggleThemePanel = function(on)
        if on == nil then on = not root.Visible end
        root.Visible = on and true or false
        return root.Visible
    end
end

-- --------------------------------------------------------------------
-- Boot
--
-- Registered on the readiness gate after the UI's own build, so the panels
-- exist by the time this runs. Nothing here polls for them.
-- --------------------------------------------------------------------
local function boot()
    if not attachAll() then return end
    buildPicker()
    if L.ToggleThemePanel then L.ToggleThemePanel(true) end

    -- Cycle key. Defaults to RightBracket; LUCK.ThemeKey = Enum.KeyCode.X
    -- to move it, or nil to turn it off.
    L.ThemeKey = Enum.KeyCode.RightBracket
    UIS.InputBegan:Connect(function(input, typing)
        if typing or not L.ThemeKey then return end
        if input.KeyCode == L.ThemeKey then L.NextTheme() end
    end)

    print("[LUCK] PRIVATE  ·  " .. #THEMES .. " themes  ·  " .. tostring(L.Theme))
    print("[LUCK] LUCK.SetTheme(\"Clover\")  ·  LUCK.NextTheme()  ·  ] to cycle")
end

-- Errors are reported, not swallowed. A theme engine that half-builds and says
-- nothing is worse than one that does not build at all.
local function safeBoot()
    local ok, err = pcall(boot)
    if not ok then
        L.ThemeError = tostring(err)
        warn("[LUCK] theme engine failed: " .. tostring(err))
    end
end

if L.WhenReady then
    L.WhenReady(safeBoot)
else
    task.defer(safeBoot)
end

end
