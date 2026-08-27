do
-- The theme engine: ten palettes, one throttled connection, no tree walks at
-- runtime, and none of it allowed to touch the send path.
local R = RIG
local H = R.H
H.pump(200000)
local L = R.genvTable.LUCK
if not L then print("no getgenv().LUCK") return end

local fails, checks = {}, 0
local function check(n, c, d)
    checks += 1
    if not c then fails[#fails + 1] = n .. (d and ("  -- " .. d) or "") end
end

print("PRIVATE THEME ENGINE")
print("================================================================")

check("this is the private build", L.Private == true)
check("ten fixed themes plus Custom", L.Themes and #L.Themes == 11,
    "got " .. tostring(L.Themes and #L.Themes))
check("Rainbow is one of them", L.Themes and L.Themes[1].name == "Rainbow")

local wanted = {"Rainbow", "Clover", "Toxic", "Mint", "Aqua",
                "Ice", "Grape", "Sakura", "Gold", "Lava"}
local have = {}
for _, t in ipairs(L.Themes or {}) do have[t.name] = true end
local missing = {}
for _, w in ipairs(wanted) do if not have[w] then missing[#missing + 1] = w end end
check("all ten are named and present", #missing == 0, table.concat(missing, ","))
check("the greens theme is there", have.Clover == true)
print("     themes: " .. table.concat(L.ThemeNames or {}, ", "))

-- gradients actually got attached to the panels
local gui
for _, d in ipairs((L.GuiParent or R.RepS):GetChildren()) do
    if d:IsA("ScreenGui") and tostring(d.Name):match("^LUCK_%d+$") then gui = d end
end
check("the LUCK gui was found", gui ~= nil)
local grads, strokeCount = {}, 0
if gui then
    for _, d in ipairs(gui:GetDescendants()) do
        if d.Name == "LuckThemeGradient" then grads[#grads + 1] = d end
        if d:IsA("UIStroke") then strokeCount += 1 end
    end
end
check("gradients were attached to the panels", #grads > 5, "found " .. tostring(#grads))
check("there are strokes to tint", strokeCount > 5, "found " .. tostring(strokeCount))
print(("     %d gradients, %d strokes"):format(#grads, strokeCount))

-- the picker exists and has a row per theme
local picker = gui and gui:FindFirstChild("LuckThemePicker")
check("the picker panel exists", picker ~= nil)
if picker then
    local buttons = 0
    for _, d in ipairs(picker:GetDescendants()) do
        if d:IsA("TextButton") then buttons += 1 end
    end
    -- ten rows plus the drag header
    check("a button per theme", buttons >= 10, "found " .. tostring(buttons))
end

-- it animates: the same gradient must hold different colours across frames
local function firstColour(g)
    local seq = g.Color
    local kp = seq and seq.Keypoints and seq.Keypoints[2]
    return kp and kp.Value or nil
end
local g1 = grads[1]
check("a gradient has a colour sequence", g1 and firstColour(g1) ~= nil)
if g1 then
    -- Enough frames to clear the throttle: it updates at ThemeFps, not per frame.
    RENDER(4, 1 / 30)
    local a = firstColour(g1)
    RENDER(60, 1 / 30)
    local b = firstColour(g1)
    check("the gradient moves between ticks",
        a and b and (math.abs(a.R - b.R) + math.abs(a.G - b.G) + math.abs(a.B - b.B)) > 0.02,
        a and b and ("%.3f,%.3f,%.3f -> %.3f,%.3f,%.3f"):format(a.R, a.G, a.B, b.R, b.G, b.B)
            or "no colour")
end

-- throttled, not per frame
if g1 then
    L.ThemeFps = 30
    RENDER(4, 1 / 30)
    local before = firstColour(g1)
    -- ten frames at 1000fps is 10ms, a third of one 30Hz tick: nothing should move
    RENDER(10, 1 / 1000)
    local after = firstColour(g1)
    check("it does not rebuild on every frame",
        before and after and math.abs(before.R - after.R) < 0.0001
            and math.abs(before.G - after.G) < 0.0001,
        "moved inside one tick")
end

-- switching themes changes the colours
if g1 then
    L.SetTheme("Lava")
    RENDER(4, 1 / 30)
    local lava = firstColour(g1)
    L.SetTheme("Ice")
    RENDER(4, 1 / 30)
    local ice = firstColour(g1)
    check("SetTheme is applied", L.Theme == "Ice", tostring(L.Theme))
    check("Lava and Ice do not look the same",
        lava and ice and (math.abs(lava.R - ice.R) + math.abs(lava.B - ice.B)) > 0.1,
        lava and ice and ("lava %.2f/%.2f  ice %.2f/%.2f")
            :format(lava.R, lava.B, ice.R, ice.B) or "?")
    check("Ice is bluer than red", ice and ice.B > ice.R,
        ice and ("R %.2f B %.2f"):format(ice.R, ice.B) or "?")
    check("Lava is redder than blue", lava and lava.R > lava.B,
        lava and ("R %.2f B %.2f"):format(lava.R, lava.B) or "?")
end

check("an unknown theme is refused", select(1, L.SetTheme("NotAThing")) == false)
check("and leaves the current one alone", L.Theme == "Ice", tostring(L.Theme))

-- cycling walks the list and wraps, off whatever is genuinely last rather than a
-- name written down here that stops being last the moment one is added
local lastName = L.Themes[#L.Themes].name
L.SetTheme(lastName)
check("the last theme can be selected", L.Theme == lastName, tostring(L.Theme))
L.NextTheme()
check("cycling past the end wraps to the first", L.Theme == L.Themes[1].name,
    tostring(L.Theme))

-- ThemeOn freezes it
if g1 then
    L.SetTheme("Rainbow")
    RENDER(4, 1 / 30)
    local before = firstColour(g1)
    L.ThemeOn = false
    RENDER(120, 1 / 30)
    local after = firstColour(g1)
    check("ThemeOn=false freezes the sweep",
        before and after and math.abs(before.R - after.R) < 0.0001,
        "still moving with the engine off")
    L.ThemeOn = true
end

-- and none of it may touch the redeem path
local before = R.invokeCount()
R.notifyRemote.OnClientEvent:FireAll("THEMECODE1", 5.5, "Sounds.Sfx.Blop", "Top")
H.pump(200000)
check("a code still redeems exactly once with themes running",
    R.invokeCount() - before == 1, "sends=" .. tostring(R.invokeCount() - before))

print("")
print(("checks: %d   failures: %d"):format(checks, #fails))
for _, f in ipairs(fails) do print("  FAIL  " .. f) end
print(("runtime errors: %d"):format(H.errors and #H.errors or 0))
if H.errors then
    local seen = {}
    for _, e in ipairs(H.errors) do
        local k = tostring(e)
        if not seen[k] then seen[k] = true; print("  ERR  " .. k) end
    end
end
end

do
-- The private build is the public one plus cosmetics. Cosmetics that touch the
-- redeem path are not cosmetics, so this pins the two things that made the first
-- version cost 171ns -> 315ns on the send: a callback on every instance the
-- script creates, and a list that grows for the life of the session.
local R = RIG
local H = R.H
local L = R.genvTable.LUCK
local fails, checks = {}, 0
local function check(n, c, d)
    checks += 1
    if not c then fails[#fails + 1] = n .. (d and ("  -- " .. d) or "") end
end

print("")
print("PRIVATE COSTS THE SEND PATH NOTHING")
print("----------------------------------------------------------------")

local gui
for _, d in ipairs((L.GuiParent or R.RepS):GetChildren()) do
    if d:IsA("ScreenGui") and tostring(d.Name):match("^LUCK_%d+$") then gui = d end
end

-- nothing of ours may be listening for new instances
local listeners = 0
if gui then
    local sig = rawget(gui, "DescendantAdded")
    if type(sig) == "table" and sig.conns then listeners = #sig.conns end
end
check("no DescendantAdded hook on the gui", listeners == 0,
    tostring(listeners) .. " connected")

-- and the registries must not grow as the script does its normal work
local function counts()
    local g, s = 0, 0
    if gui then
        for _, d in ipairs(gui:GetDescendants()) do
            if d.Name == "LuckThemeGradient" then g += 1 end
        end
    end
    L.ThemePrint = L.ThemePrint
    return g
end
local gradsBefore = counts()

-- 200 redeems' worth of toasts, feed lines and history rows
L.ToastOn = true
for i = 1, 200 do
    R.notifyRemote.OnClientEvent:FireAll("THEMEGROW" .. i, 5.5, "Sounds.Sfx.Blop", "Top")
end
H.pump(400000)
RENDER(10, 1 / 30)

local gradsAfter = counts()
check("the gradient set did not grow with traffic", gradsAfter == gradsBefore,
    ("%d -> %d"):format(gradsBefore, gradsAfter))

-- the theme sweep must be throttled, not per frame
local ticks = 0
local probe = L.ThemeFps
check("the sweep is throttled well under frame rate", probe and probe <= 30,
    "ThemeFps=" .. tostring(probe))

check("it can be turned off entirely", type(L.ThemeStop) == "function")

print(("checks: %d   failures: %d"):format(checks, #fails))
for _, f in ipairs(fails) do print("  FAIL  " .. f) end
end

do
-- The theme has to reach ALL of the UI, not just the panel bodies, and the
-- picker has to collapse.
local R = RIG
local H = R.H
local L = R.genvTable.LUCK
local fails, checks = {}, 0
local function check(n, c, d)
    checks += 1
    if not c then fails[#fails + 1] = n .. (d and ("  -- " .. d) or "") end
end
local function key(c)
    if not c then return "nil" end
    return ("%d,%d,%d"):format(math.floor(c.R * 255 + 0.5),
        math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end

print("")
print("THEME REACHES THE WHOLE UI")
print("----------------------------------------------------------------")

local gui
for _, d in ipairs((L.GuiParent or R.RepS):GetChildren()) do
    if d:IsA("ScreenGui") and tostring(d.Name):match("^LUCK_%d+$") then gui = d end
end

check("the palette is exposed", type(L.Palette) == "table")

-- snapshot every colour in the UI under one theme, then another
local function snapshot()
    local out = {}
    for _, d in ipairs(gui:GetDescendants()) do
        local bg, tx
        pcall(function() if d:IsA("GuiObject") then bg = d.BackgroundColor3 end end)
        pcall(function()
            if d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") then
                tx = d.TextColor3
            end
        end)
        if bg or tx then out[#out + 1] = key(bg) .. "/" .. key(tx) end
    end
    return out
end

L.SetTheme("Clover")
RENDER(4, 1 / 30)
local green = snapshot()
local greenPal = key(L.Palette.ACCENT) .. "|" .. key(L.Palette.BG)

L.SetTheme("Sakura")
RENDER(4, 1 / 30)
local pink = snapshot()
local pinkPal = key(L.Palette.ACCENT) .. "|" .. key(L.Palette.BG)

check("the palette itself changed", greenPal ~= pinkPal,
    greenPal .. "  vs  " .. pinkPal)
check("Sakura's accent is pinker than Clover's",
    L.Palette.ACCENT.R > L.Palette.ACCENT.G, key(L.Palette.ACCENT))

local moved, same = 0, 0
for i = 1, math.min(#green, #pink) do
    if green[i] ~= pink[i] then moved += 1 else same += 1 end
end
check("most of the UI recoloured, not just the panels", moved > 20,
    ("%d of %d widgets changed"):format(moved, moved + same))
print(("     %d of %d widgets recoloured between themes"):format(moved, moved + same))

-- widgets built AFTER a theme change come out already themed
L.SetTheme("Lava")
RENDER(4, 1 / 30)
local lavaAccent = key(L.Palette.ACCENT)
L.ToastOn = true
R.notifyRemote.OnClientEvent:FireAll("THEMEAFTER1", 5.5, "Sounds.Sfx.Blop", "Top")
H.pump(200000)
check("the palette a new widget would read is the Lava one",
    key(L.Palette.ACCENT) == lavaAccent)

-- minimize
local picker = gui and gui:FindFirstChild("LuckThemePicker")
check("the picker has a body to collapse", picker and picker:FindFirstChild("Body") ~= nil)
check("minimize is exposed", type(L.MinimizeThemePanel) == "function")
if picker and L.MinimizeThemePanel then
    local body = picker:FindFirstChild("Body")
    L.MinimizeThemePanel(false)
    local openH = picker.Size.Y.Offset
    check("open, the body shows", body.Visible == true)
    L.MinimizeThemePanel(true)
    check("minimized, the body is hidden", body.Visible == false)
    check("and the panel shrinks to its header",
        picker.Size.Y.Offset < openH and picker.Size.Y.Offset <= 30,
        ("%d -> %d"):format(openH, picker.Size.Y.Offset))
    check("toggling with no argument flips it back",
        L.MinimizeThemePanel() == false and body.Visible == true)
end

-- and a redeem is still exactly once through all of that
local before = R.invokeCount()
R.notifyRemote.OnClientEvent:FireAll("THEMEWIDE1", 5.5, "Sounds.Sfx.Blop", "Top")
H.pump(200000)
check("a code still redeems exactly once", R.invokeCount() - before == 1,
    "sends=" .. tostring(R.invokeCount() - before))

print(("checks: %d   failures: %d"):format(checks, #fails))
for _, f in ipairs(fails) do print("  FAIL  " .. f) end
print(("runtime errors: %d"):format(H.errors and #H.errors or 0))
end

do
-- The Custom theme: four slots driven by sliders, saved, and actually painting
-- the UI when it is the one selected.
local R = RIG
local H = R.H
local L = R.genvTable.LUCK
local fails, checks = {}, 0
local function check(n, c, d)
    checks += 1
    if not c then fails[#fails + 1] = n .. (d and ("  -- " .. d) or "") end
end
local function key(c)
    if not c then return "nil" end
    return ("%d,%d,%d"):format(math.floor(c.R * 255 + 0.5),
        math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end

print("")
print("CUSTOM THEME")
print("----------------------------------------------------------------")

check("Custom is an eleventh theme", #L.Themes == 11, tostring(#L.Themes))
check("it is named Custom", L.Themes[11] and L.Themes[11].name == "Custom")
check("four slots", L.CustomSlots == 4, tostring(L.CustomSlots))
check("the setter is exposed", type(L.SetCustomColor) == "function")
check("the getter is exposed", type(L.GetCustomColor) == "function")

-- setting a slot takes
check("a slot can be set", L.SetCustomColor(3, 255, 40, 90) == true)
local r, g, b = L.GetCustomColor(3)
check("and reads back", r == 255 and g == 40 and b == 90,
    ("%d,%d,%d"):format(r, g, b))

-- out of range is clamped, not accepted blindly
L.SetCustomColor(1, 999, -20, 30)
local r1, g1, b1 = L.GetCustomColor(1)
check("values are clamped to 0-255", r1 == 255 and g1 == 0 and b1 == 30,
    ("%d,%d,%d"):format(r1, g1, b1))
check("a bad slot number is refused", L.SetCustomColor(9, 1, 2, 3) == false)
check("slot 0 is refused", L.SetCustomColor(0, 1, 2, 3) == false)

-- selecting Custom paints the UI with those colours
L.SetTheme("Custom")
RENDER(4, 1 / 30)
check("Custom can be selected", L.Theme == "Custom", tostring(L.Theme))
check("the accent follows slot 3", key(L.Palette.ACCENT) == "255,40,90",
    key(L.Palette.ACCENT))

-- and moving a slider repaints, rather than showing the colour you left
L.SetCustomColor(3, 40, 120, 255)
RENDER(4, 1 / 30)
check("changing a slot repaints the live theme",
    key(L.Palette.ACCENT) == "40,120,255", key(L.Palette.ACCENT))

-- the gradient itself follows it
local gui
for _, d in ipairs((L.GuiParent or R.RepS):GetChildren()) do
    if d:IsA("ScreenGui") and tostring(d.Name):match("^LUCK_%d+$") then gui = d end
end
local grad
for _, d in ipairs(gui:GetDescendants()) do
    if d.Name == "LuckThemeGradient" then grad = d break end
end
local function firstColour(gr)
    local seq = gr and gr.Color
    local kp = seq and seq.Keypoints and seq.Keypoints[2]
    return kp and kp.Value or nil
end
L.SetCustomColor(1, 255, 0, 0)
L.SetCustomColor(2, 255, 0, 0)
L.SetCustomColor(3, 255, 0, 0)
L.SetCustomColor(4, 255, 0, 0)
RENDER(10, 1 / 30)
local allRed = firstColour(grad)
check("an all-red custom palette makes a red gradient",
    allRed and allRed.R > 0.8 and allRed.G < 0.2 and allRed.B < 0.2,
    allRed and key(allRed) or "no colour")

-- random gives something different, and something coherent
L.SetCustomColor(1, 10, 10, 10)
local beforeRand = key(L.Themes[11].colors[3])
L.RandomCustom()
check("random changes the palette", key(L.Themes[11].colors[3]) ~= beforeRand,
    beforeRand .. " -> " .. key(L.Themes[11].colors[3]))
check("random keeps four slots", #L.Themes[11].colors == 4)

-- the editor only shows on Custom
local picker = gui and gui:FindFirstChild("LuckThemePicker")
local body = picker and picker:FindFirstChild("Body")
local editor = body and body:FindFirstChild("CustomEditor")
check("the slider editor exists", editor ~= nil)
if editor then
    L.SetTheme("Custom")
    check("it shows on Custom", editor.Visible == true)
    L.SetTheme("Ice")
    check("and hides on a fixed palette", editor.Visible == false)
    local sliders = 0
    for _, d in ipairs(editor:GetDescendants()) do
        if d:IsA("TextLabel") and (d.Text == "R" or d.Text == "G" or d.Text == "B") then
            sliders += 1
        end
    end
    check("three sliders", sliders == 3, tostring(sliders))
end

print(("checks: %d   failures: %d"):format(checks, #fails))
for _, f in ipairs(fails) do print("  FAIL  " .. f) end
end
