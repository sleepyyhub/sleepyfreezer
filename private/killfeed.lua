
--[[ ====================================================================
     LUCK PRIVATE  ·  redeem cards

     When someone in the server actually lands a code, a card slides into
     the top right: their headshot, the code, and what they got.

     The card wears the current theme and moves with it -- including a
     custom palette and whichever motion mode is on -- because its
     gradient is registered with the theme engine rather than painted once.
     ==================================================================== ]]

do

local L = (getgenv and getgenv().LUCK) or LUCK
if not L then return end

local Players = game:GetService("Players")
local rgb = Color3.fromRGB

L.CardsOn   = true     -- false stops them appearing
L.CardTime  = 6        -- seconds on screen
L.CardMax   = 5        -- how many at once before the oldest goes

local holder, live = nil, {}

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

local function buildHolder()
    local gui = findGui()
    if not gui then return nil end
    local f = Instance.new("Frame")
    f.Name = "LuckRedeemCards"
    f.AnchorPoint = Vector2.new(1, 0)
    f.Position = UDim2.new(1, -16, 0, 16)
    f.Size = UDim2.new(0, 262, 0, 400)
    f.BackgroundTransparency = 1
    f.BorderSizePixel = 0
    -- Holds cards and paints nothing itself, so it opts out of the sweep.
    pcall(function() f:SetAttribute("LuckNoTheme", true) end)
    f.Parent = gui

    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 6)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
    layout.Parent = f
    return f
end

local order = 0

local function drop(card)
    for i = #live, 1, -1 do
        if live[i] == card then table.remove(live, i) end
    end
    pcall(function() card:Destroy() end)
end

-- --------------------------------------------------------------------
-- The card
-- --------------------------------------------------------------------
local function show(code, prize, who)
    if not L.CardsOn then return false end
    if not holder or not holder.Parent then holder = buildHolder() end
    if not holder then return false end

    local P = L.Palette or {}
    order += 1

    local card = Instance.new("Frame")
    card.Name = "RedeemCard"
    card.Size = UDim2.new(0, 262, 0, 62)
    card.BackgroundColor3 = P.SURFACE or rgb(12, 25, 16)
    card.BackgroundTransparency = 0.08
    card.BorderSizePixel = 0
    card.LayoutOrder = order
    card.Parent = holder
    Instance.new("UICorner", card).CornerRadius = UDim.new(0, 12)

    -- Its own gradient and outline, handed to the theme engine so both ride
    -- whatever palette and motion are live. Destroying the card deregisters
    -- them, because the engine drops anything whose Parent has gone.
    local grad = Instance.new("UIGradient")
    grad.Name = "LuckThemeGradient"
    grad.Rotation = L.ThemeTilt or 35
    grad.Transparency = NumberSequence.new(0.5)
    grad.Parent = card

    local edge = Instance.new("UIStroke")
    edge.Thickness = 1
    edge.Transparency = 0.35
    edge.Color = P.ACCENT or rgb(74, 222, 128)
    edge.Parent = card

    if L.ThemeRegister then
        L.ThemeRegister(grad)
        L.ThemeRegister(edge)
    end

    -- Headshot. rbxthumb is resolved by the client, so there is no HTTP call and
    -- nothing to fail slowly; a face that has not cached yet just appears late.
    local shot = Instance.new("ImageLabel")
    shot.Size = UDim2.new(0, 44, 0, 44)
    shot.Position = UDim2.new(0, 9, 0.5, -22)
    shot.BackgroundColor3 = P.RAISED or rgb(17, 36, 23)
    shot.BackgroundTransparency = 0.2
    shot.BorderSizePixel = 0
    shot.Parent = card
    Instance.new("UICorner", shot).CornerRadius = UDim.new(0, 10)
    local uid = 0
    pcall(function() uid = who and who.UserId or 0 end)
    if uid and uid > 0 then
        shot.Image = ("rbxthumb://type=AvatarHeadShot&id=%d&w=48&h=48"):format(uid)
    end

    local nameLbl = Instance.new("TextLabel")
    nameLbl.Size = UDim2.new(1, -66, 0, 15)
    nameLbl.Position = UDim2.new(0, 61, 0, 7)
    nameLbl.BackgroundTransparency = 1
    nameLbl.Text = tostring((who and (who.DisplayName or who.Name)) or "someone")
    nameLbl.TextColor3 = P.HIGH or rgb(165, 255, 198)
    nameLbl.Font = Enum.Font.GothamBold
    nameLbl.TextSize = 12
    nameLbl.TextXAlignment = Enum.TextXAlignment.Left
    nameLbl.TextTruncate = Enum.TextTruncate.AtEnd
    nameLbl.Parent = card

    local codeLbl = Instance.new("TextLabel")
    codeLbl.Size = UDim2.new(1, -66, 0, 14)
    codeLbl.Position = UDim2.new(0, 61, 0, 23)
    codeLbl.BackgroundTransparency = 1
    codeLbl.Text = tostring(code or "?")
    codeLbl.TextColor3 = P.ACCENT or rgb(74, 222, 128)
    codeLbl.Font = Enum.Font.GothamBold
    codeLbl.TextSize = 13
    codeLbl.TextXAlignment = Enum.TextXAlignment.Left
    codeLbl.TextTruncate = Enum.TextTruncate.AtEnd
    codeLbl.Parent = card
    -- The code rides the sweep, so the card reads as the theme rather than as a
    -- grey box with a coloured edge.
    if L.ThemeRegister then L.ThemeRegister(codeLbl) end

    local prizeLbl = Instance.new("TextLabel")
    prizeLbl.Size = UDim2.new(1, -66, 0, 13)
    prizeLbl.Position = UDim2.new(0, 61, 0, 40)
    prizeLbl.BackgroundTransparency = 1
    prizeLbl.Text = tostring(prize or "?")
    prizeLbl.TextColor3 = P.TEXT or rgb(228, 246, 233)
    prizeLbl.Font = Enum.Font.GothamSemibold
    prizeLbl.TextSize = 11
    prizeLbl.TextXAlignment = Enum.TextXAlignment.Left
    prizeLbl.TextTruncate = Enum.TextTruncate.AtEnd
    prizeLbl.Parent = card

    live[#live + 1] = card
    -- Oldest first, so a burst does not push the newest one off the bottom of
    -- the screen while stale ones sit above it.
    while #live > (L.CardMax or 5) do drop(live[1]) end

    task.delay(tonumber(L.CardTime) or 6, function() drop(card) end)
    return true
end

L.ShowRedeemCard = show
L.ClearRedeemCards = function()
    for i = #live, 1, -1 do drop(live[i]) end
end

-- --------------------------------------------------------------------
-- Hook
--
-- The script already parses "X redeemed CODE for a THING" and works out who,
-- what and which code -- this rides that rather than parsing it again.
-- --------------------------------------------------------------------
-- Wrapped on the readiness gate, NOT at load. L.NotifyRedeem is assigned while
-- the UI builds, and the UI builds on that same gate -- wrapping at load put the
-- wrapper in first and the UI's own assignment then replaced it wholesale, so
-- nothing ever reached the cards. Registering after the UI's own callback means
-- the thing being wrapped is the one that ends up bound.
local function boot()
    holder = buildHolder()
    local prev = L.NotifyRedeem
    L.NotifyRedeem = function(code, prize, who)
        if prev then pcall(prev, code, prize, who) end
        pcall(show, code, prize, who)
    end
end

if L.WhenReady then
    L.WhenReady(function()
        local ok, err = pcall(boot)
        if not ok then
            L.CardError = tostring(err)
            warn("[LUCK] redeem cards failed: " .. tostring(err))
        end
    end)
else
    task.defer(function() pcall(boot) end)
end

end
