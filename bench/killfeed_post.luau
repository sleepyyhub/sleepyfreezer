do
-- Redeem cards: someone lands a code, a card appears top right with their
-- headshot, the code and the prize, wearing the live theme and moving with it.
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
local function key(c)
    if not c then return "nil" end
    return ("%d,%d,%d"):format(math.floor(c.R * 255 + 0.5),
        math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end

print("REDEEM CARDS")
print("================================================================")

local gui
for _, d in ipairs((L.GuiParent or R.RepS):GetChildren()) do
    if d:IsA("ScreenGui") and tostring(d.Name):match("^LUCK_%d+$") then gui = d end
end
local holder = gui and gui:FindFirstChild("LuckRedeemCards")
check("the holder exists", holder ~= nil)
check("it is pinned to the top right",
    holder and holder.AnchorPoint and holder.AnchorPoint.X == 1
        and holder.AnchorPoint.Y == 0)
check("and opts out of the sweep itself",
    holder and holder:GetAttribute("LuckNoTheme") == true)

local function cards()
    local out = {}
    if not holder then return out end
    for _, d in ipairs(holder:GetChildren()) do
        if d.Name == "RedeemCard" then out[#out + 1] = d end
    end
    return out
end

-- a real announcement of somebody else's redeem
local who = R.RepS  -- placeholder, replaced below
local players = game:GetService("Players"):GetPlayers()
who = players[1]
check("there is a player to attribute it to", who ~= nil)

L.ClearRedeemCards()
check("cleared", #cards() == 0, tostring(#cards()))

L.ShowRedeemCard("SUMMER2024", "Meowl", who)
H.pump(40000, H.virtualNow())
local list = cards()
check("a card appears", #list == 1, tostring(#list))

if list[1] then
    local card = list[1]
    local texts, image = {}, nil
    for _, d in ipairs(card:GetDescendants()) do
        if d:IsA("TextLabel") then texts[#texts + 1] = d end
        if d:IsA("ImageLabel") then image = d end
    end
    local function hasText(want)
        for _, t in ipairs(texts) do
            if tostring(t.Text):find(want, 1, true) then return t end
        end
        return nil
    end
    check("it shows the code", hasText("SUMMER2024") ~= nil)
    check("it shows the prize", hasText("Meowl") ~= nil)
    check("it shows who", hasText(tostring(who.DisplayName or who.Name)) ~= nil)
    check("it has a headshot", image ~= nil)
    check("pointed at their user id",
        image and tostring(image.Image):find("AvatarHeadShot", 1, true) ~= nil,
        image and tostring(image.Image) or "no image")

    -- the theme
    local grad, stroke
    for _, d in ipairs(card:GetDescendants()) do
        if d.Name == "LuckThemeGradient" then grad = d end
        if d:IsA("UIStroke") then stroke = d end
    end
    check("the card has its own gradient", grad ~= nil)
    check("and its own outline", stroke ~= nil)

    local function firstColour(g)
        local seq = g and g.Color
        local kp = seq and seq.Keypoints and seq.Keypoints[2]
        return kp and kp.Value or nil
    end
    L.SetTheme("Lava")
    L.SetThemeMotion("Flow")
    RENDER(6, 1 / 30)
    local lava = firstColour(grad)
    L.SetTheme("Ice")
    RENDER(6, 1 / 30)
    local ice = firstColour(grad)
    check("the card follows the theme",
        lava and ice and (math.abs(lava.R - ice.R) + math.abs(lava.B - ice.B)) > 0.1,
        (lava and key(lava) or "?") .. " vs " .. (ice and key(ice) or "?"))

    -- and it MOVES with the motion, not just recolours on switch
    local a = firstColour(grad)
    RENDER(60, 1 / 30)
    local b = firstColour(grad)
    check("and moves with the motion",
        a and b and (math.abs(a.R - b.R) + math.abs(a.G - b.G) + math.abs(a.B - b.B)) > 0.02,
        (a and key(a) or "?") .. " -> " .. (b and key(b) or "?"))

    -- a custom palette reaches it too
    L.SetCustomColor(1, 120, 0, 0)
    L.SetCustomColor(2, 200, 0, 0)
    L.SetCustomColor(3, 255, 0, 0)
    L.SetCustomColor(4, 255, 120, 120)
    L.SetTheme("Custom")
    RENDER(10, 1 / 30)
    local custom = firstColour(grad)
    check("a custom palette reaches the card",
        custom and custom.R > 0.4 and custom.G < 0.35 and custom.B < 0.35,
        custom and key(custom) or "?")

    -- Static must stop it
    L.SetThemeMotion("Static")
    RENDER(6, 1 / 30)
    local s1 = firstColour(grad)
    RENDER(60, 1 / 30)
    local s2 = firstColour(grad)
    check("Static stops the card too",
        s1 and s2 and math.abs(s1.R - s2.R) < 0.001,
        (s1 and key(s1) or "?") .. " -> " .. (s2 and key(s2) or "?"))
    L.SetThemeMotion("Flow")
end

-- the stack is capped, oldest first
L.ClearRedeemCards()
L.CardMax = 3
for i = 1, 7 do L.ShowRedeemCard("CODE" .. i, "Thing" .. i, who) end
H.pump(40000, H.virtualNow())
check("the stack is capped", #cards() == 3, tostring(#cards()))
local newest = false
for _, c in ipairs(cards()) do
    for _, d in ipairs(c:GetDescendants()) do
        if tostring(d.Text) == "CODE7" then newest = true end
    end
end
check("and it drops the oldest, not the newest", newest, "CODE7 was pushed out")
L.CardMax = 5

-- registrations do not pile up as cards come and go. Baseline with nothing live,
-- otherwise the cards left over from the cap test above are counted as permanent.
L.ClearRedeemCards()
RENDER(4, 1 / 30)
local themeCount = 0
for _, d in ipairs(gui:GetDescendants()) do
    if d.Name == "LuckThemeGradient" then themeCount += 1 end
end
for i = 1, 30 do L.ShowRedeemCard("BURST" .. i, "Thing", who) end
H.pump(40000, H.virtualNow())
RENDER(10, 1 / 30)
L.ClearRedeemCards()
RENDER(10, 1 / 30)
local after = 0
for _, d in ipairs(gui:GetDescendants()) do
    if d.Name == "LuckThemeGradient" then after += 1 end
end
check("thirty cards leave nothing behind", after == themeCount,
    ("%d -> %d"):format(themeCount, after))

-- the switch
L.CardsOn = false
L.ClearRedeemCards()
check("CardsOn=false stops them", L.ShowRedeemCard("NOPE", "x", who) == false)
check("and none appear", #cards() == 0, tostring(#cards()))
L.CardsOn = true

-- and the whole thing rides the script's own redeem notice
L.ClearRedeemCards()
if L.NotifyRedeem then
    L.NotifyRedeem("HOOKED1", "Brainrot", who)
    H.pump(40000, H.virtualNow())
    check("NotifyRedeem raises a card", #cards() == 1, tostring(#cards()))
end

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
