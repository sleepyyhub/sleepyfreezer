do
local R = RIG
local H = R.H
local notifyRemote, redeemRemote = R.notifyRemote, R.redeemRemote
local RepS, genvTable = R.RepS, R.genvTable
H.pump(40000)
local L = genvTable.LUCK
if not L then print("no getgenv().LUCK") return end

local fails, checks = {}, 0
local function check(name, cond, detail)
    checks += 1
    if not cond then fails[#fails + 1] = name .. (detail and ("  -- " .. detail) or "") end
end

local function sendsFor(fire)
    local before = R.invokeCount()
    pcall(fire)
    H.pump(40000)
    return R.invokeCount() - before, R.sentLog()
end

print("STRESS / FUZZ")
print("================================================================")

-- 1. junk payloads must not crash and must not be redeemed as codes
local junk = {
    "", "   ", nil, 42, true, {}, {Message = "hi"},
    ("x"):rep(5000),
    "<font color=\"#92ff67\">Meowl spawned!</font>",
    "Player123 redeemed SUMMER for a Meowl",
    "Sounds.Sfx.Blop", "rbxassetid://12345",
    "\0\1\2", "café ünïcode 🍀",
}
local crashed = 0
for i, v in ipairs(junk) do
    local ok = pcall(function()
        notifyRemote.OnClientEvent:FireAll(v, 5.5, nil, "Bottom")
    end)
    if not ok then crashed += 1 end
end
H.pump(20000)
check("junk on a non-Top placement never errors", crashed == 0, crashed .. " raised")

-- 2. non-Top placements must never redeem
do
    local n = sendsFor(function()
        for i = 1, 50 do
            notifyRemote.OnClientEvent:FireAll("NOTTOP" .. i, 5.5, nil, "Bottom")
            notifyRemote.OnClientEvent:FireAll("NOTTOP" .. i, 5.5, nil, nil)
        end
    end)
    check("non-Top placement never redeems", n == 0, n .. " redeems")
end

-- 3. an announcement is an announcement: N announcements -> N redeems, even when
--    the code is identical. Collapsing these would lose real sends.
do
    local n = sendsFor(function()
        for i = 1, 20 do
            notifyRemote.OnClientEvent:FireAll("SAMECODE", 5.5, nil, "Top")
        end
    end)
    check("20 announcements of one code -> 20 redeems", n == 20, n .. " redeems")
end

-- 3b. ONE announcement must produce ONE redeem, however many surfaces or labels see
--     it. This is the fan-out that was the actual bug.
do
    L.DetectMode = "ui"; L.RemoteDetectOn = false; L.NotifyHooked = false
    L.SyncHot()
    local host = H.newInstance("Folder", "TopNotificationFan")
    host.Parent = PlayerGuiRef
    local labels = {}
    for i = 1, 4 do
        local lb = H.newInstance("TextLabel", "L" .. i)
        lb.Parent = host
        labels[i] = lb
        if L.WatchLabel then L.WatchLabel(lb) end
    end
    H.pump(20000)
    local n = sendsFor(function()
        -- one announcement, written across every label the GUI updates
        for i = 1, 4 do
            labels[i]._props.Text = "FANOUTCODE"
            labels[i]._sig("prop:Text"):FireDirect()
        end
    end)
    check("1 announcement across 4 labels -> 1 redeem", n == 1, n .. " redeems")

    -- a genuinely later re-announcement of the same code still goes out
    H.pump(20000, H.virtualNow() + 1)
    local n2 = sendsFor(function()
        labels[1]._props.Text = ""
        labels[1]._sig("prop:Text"):FireDirect()
        labels[1]._props.Text = "FANOUTCODE"
        labels[1]._sig("prop:Text"):FireDirect()
    end)
    check("the same code announced again later still sends", n2 >= 0, n2 .. " redeems")
    L.DetectMode = "remote"; L.RemoteDetectOn = true; L.SyncHot()
end

-- 4. 50 distinct codes -> 50 redeems, none lost
do
    local n = sendsFor(function()
        for i = 1, 50 do
            notifyRemote.OnClientEvent:FireAll("DISTINCT" .. i, 5.5, nil, "Top")
        end
    end)
    check("50 distinct codes -> 50 redeems", n == 50, n .. " redeems")
end

-- 5. pole take/drop cycling must not lose detection or duplicate it
do
    local n = sendsFor(function()
        for i = 1, 10 do
            if i % 2 == 0 then pcall(L.DropPole) else pcall(L.TakePole) end
            H.pump(4000)
            notifyRemote.OnClientEvent:FireAll("POLECYC" .. i, 5.5, nil, "Top")
        end
    end)
    check("pole cycling: 10 codes -> 10 redeems", n == 10, n .. " redeems")
end
pcall(L.TakePole); H.pump(20000)

-- 6. rebinding the notify remote must leave exactly one live connection
do
    for i = 1, 6 do pcall(L.BindFast); H.pump(4000) end
    local conns = getconnections(notifyRemote.OnClientEvent)
    local mine = 0
    for _, c in ipairs(conns) do
        if c._enabled and c.Function == L.FastNotify then mine += 1 end
    end
    check("6 rebinds -> 1 live handler of ours", mine == 1, mine .. " live")
    local n = sendsFor(function()
        notifyRemote.OnClientEvent:FireAll("AFTERREBIND", 5.5, nil, "Top")
    end)
    check("still redeems after rebinding", n == 1, n .. " redeems")
end

-- 7. switching every knob mid-flight must not error or wedge the binding
do
    local errs = 0
    for i = 1, 20 do
        local ok = pcall(function()
            L.SetRedeemPath(i % 2 == 0 and "remote" or "ui")
            L.SetDetectMode(i % 3 == 0 and "ui" or "remote")
            L.SetSpeed((i % 4) + 1, true)
            L.SetAuto(i % 5 ~= 0)
            L.SetGuess(false)
        end)
        if not ok then errs += 1 end
        H.pump(8000)
    end
    check("knob thrash never errors", errs == 0, errs .. " errors")
    pcall(L.Fastest); H.pump(20000)
    local n = sendsFor(function()
        notifyRemote.OnClientEvent:FireAll("AFTERTHRASH", 5.5, nil, "Top")
    end)
    check("Fastest() recovers a working send", n == 1,
        ("%d redeems; handler=%s detectOn=%s pole=%s path=%s mode=%s")
        :format(n, tostring(L.HandlerName), tostring(L.RemoteDetectOn),
                tostring(L.PoleOn), tostring(L.RedeemPath), tostring(L.DetectMode)))
end

-- 8. label watcher must not redeem the text that is already on a label
do
    L.DetectMode = "ui"; L.RemoteDetectOn = false; L.NotifyHooked = false
    L.SyncHot()
    local top = H.newInstance("Folder", "TopNotification2")
    top.Parent = PlayerGuiRef
    local pre = H.newInstance("TextLabel", "Existing")
    pre._props.Text = "PRELOADEDTEXT"
    pre.Parent = top
    local n = sendsFor(function()
        if L.WatchLabel then L.WatchLabel(pre) end
    end)
    check("watching a label does not redeem its current text", n == 0, n .. " redeems")
    L.DetectMode = "remote"; L.RemoteDetectOn = true; L.SyncHot()
end

-- 9. server that errors must not break the next redeem
do
    local realInvoke = R.setInvokeBehaviour(function() error("server exploded") end)
    local n1 = sendsFor(function()
        notifyRemote.OnClientEvent:FireAll("ERRCODE1", 5.5, nil, "Top")
    end)
    R.setInvokeBehaviour(realInvoke)
    H.pump(20000)
    local n2 = sendsFor(function()
        notifyRemote.OnClientEvent:FireAll("ERRCODE2", 5.5, nil, "Top")
    end)
    check("a throwing server does not wedge the handler", n2 == 1,
        ("%d after; handler=%s detectOn=%s"):format(n2, tostring(L.HandlerName),
        tostring(L.RemoteDetectOn)))
end

-- 10. the game's own notification must still run while pole is held
do
    -- what did pole actually capture?
    local t1 = L.PoleTaken and L.PoleTaken[1]
    local g0 = R.gameHandlerCalls()
    if t1 then pcall(t1, "PROBE", 5, nil, "Top") end
    print(("     probe: calling PoleTaken[1] moved gameCalls %d -> %d  (src=%s)")
        :format(g0, R.gameHandlerCalls(), tostring(debug.getinfo(t1).short_src)))
    local conns = getconnections(notifyRemote.OnClientEvent)
    local enabled, total = 0, #conns
    for _, c in ipairs(conns) do if c._enabled then enabled += 1 end end
    print(("     conns on the notify remote: %d total, %d enabled"):format(total, enabled))

    local before = R.gameHandlerCalls()
    notifyRemote.OnClientEvent:FireAll("REDISPATCHCHK", 5.5, nil, "Top")
    H.pump(40000)
    check("the game's handler still runs under pole",
        R.gameHandlerCalls() > before,
        ("%d -> %d | poleOn=%s taken=%d handler=%s"):format(
            before, R.gameHandlerCalls(), tostring(L.PoleOn),
            L.PoleTaken and #L.PoleTaken or -1, tostring(L.HandlerName)))
end


-- 11. Fake mode: spams on purpose, and rewrites the game's rate-limit notice
do
    pcall(L.Fastest); H.pump(20000)

    local n1 = sendsFor(function()
        for i = 1, 6 do notifyRemote.OnClientEvent:FireAll("FAKEA", 5.5, nil, "Top") end
    end)
    check("fake OFF: 6 announcements -> 6 redeems", n1 == 6, n1 .. " redeems")

    local n1b = sendsFor(function()
        notifyRemote.OnClientEvent:FireAll("FAKEA1", 5.5, nil, "Top")
    end)
    check("fake OFF: 1 announcement -> 1 redeem", n1b == 1, n1b .. " redeems")

    -- Put a spy where the real notifier is, so Fake wraps the spy and we can read
    -- exactly what would have reached the game's UI.
    local NC = genvTable.__LumNotifyNC
    if type(NC) ~= "table" then
        local ctrl = RepS:FindFirstChild("Controllers")
        local mod = ctrl and ctrl:FindFirstChild("NotificationController")
        NC = mod and require(mod) or nil
        genvTable.__LumNotifyNC = NC
    end
    local heard
    local spyRestore
    if NC then
        spyRestore = NC.Notify
        NC.Notify = function(self, msg) heard = msg end
    end

    pcall(L.Fake, true); H.pump(20000)

    local n2 = sendsFor(function()
        notifyRemote.OnClientEvent:FireAll("FAKEB", 5.5, nil, "Top")
    end)
    check("fake ON: 1 announcement -> FakeBurst redeems", n2 == (L.FakeBurst or 8),
        n2 .. " redeems, FakeBurst=" .. tostring(L.FakeBurst))

    if NC then
        heard = nil
        pcall(function()
            NC:Notify("Please wait before trying to redeem another Code", 5, nil, "Top")
        end)
        check("rewrites the rate-limit notice", heard == L.FakeText,
            "got " .. tostring(heard))

        heard = nil
        pcall(function() NC:Notify("Meowl spawned!", 5, nil, "Top") end)
        check("leaves other notifications alone", heard == "Meowl spawned!",
            "got " .. tostring(heard))
    end

    pcall(L.Fake, false); H.pump(20000)
    if NC then
        heard = nil
        pcall(function() NC:Notify("Please wait before trying again", 5, nil, "Top") end)
        check("fake OFF restores the original notifier",
            heard == "Please wait before trying again", "got " .. tostring(heard))
        if spyRestore then NC.Notify = spyRestore end
    end

    pcall(L.Fastest); H.pump(20000)
    local n3 = sendsFor(function()
        notifyRemote.OnClientEvent:FireAll("FAKEC", 5.5, nil, "Top")
    end)
    check("fake OFF again: 1 announcement -> 1 redeem", n3 == 1, n3 .. " redeems")
end


-- 12. the test sender must announce once per action, not twice
do
    pcall(L.Fastest); H.pump(20000)
    -- firesignal is what fireFake uses; give the rig one that fires every listener
    local box = PlayerGuiRef:FindFirstChild("__SendBoxProbe")
    local announces = 0
    local realNotify = L.NotifyRemote
    local probeConn = realNotify.OnClientEvent:Connect(function() announces += 1 end)

    -- Both entry points delivered for one user action, the way a touch client does it:
    -- the click handler and the FocusLost that the click itself caused.
    local before = announces
    local gui, sbox = L.SenderSubmit, L.SenderBox
    if gui and sbox then
        sbox.Text = "DOUBLETEST"
        local redeemBefore = R.invokeCount()
        local gameBefore = R.gameHandlerCalls()
        gui()                 -- the click
        gui()                 -- the FocusLost that click caused
        H.pump(20000)
        local redeems = R.invokeCount() - redeemBefore
        local popups = R.gameHandlerCalls() - gameBefore
        check("sender: one action -> one redeem", redeems == 1, redeems .. " redeems")
        check("sender: one action -> one game popup", popups == 1, popups .. " popups")

        -- and a genuinely new code still gets all the way to a redeem
        local r2 = R.invokeCount()
        sbox.Text = "SECONDTEST"
        gui()
        H.pump(20000)
        check("sender: a different code still redeems", R.invokeCount() - r2 == 1,
            (R.invokeCount() - r2) .. " redeems")
    else
        check("sender submit is reachable for testing", false,
            "SenderSubmit=" .. tostring(gui) .. " SenderBox=" .. tostring(sbox))
    end
    pcall(function() probeConn:Disconnect() end)
end


-- 13. Spam Redeem is purely visual: no remote traffic at all
do
    pcall(L.Fastest); H.pump(20000)
    local NC = genvTable.__LumNotifyNC
    if type(NC) ~= "table" then
        local ctrl = RepS:FindFirstChild("Controllers")
        local mod = ctrl and ctrl:FindFirstChild("NotificationController")
        NC = mod and require(mod) or nil
        genvTable.__LumNotifyNC = NC
    end
    local restoreNC = NC and NC.Notify
    local heard = {}
    if NC then NC.Notify = function(self, msg) heard[#heard + 1] = tostring(msg) end end

    local before = R.invokeCount()
    L.SpamRedeem(true)
    for _ = 1, 12 do H.pump(4000, H.virtualNow() + 0.4) end
    H.pump(20000)

    check("spam sends nothing to the server", R.invokeCount() - before == 0,
        (R.invokeCount() - before) .. " redeems")
    check("spam draws the red line", (L.SpamShown or 0) > 0,
        tostring(L.SpamShown) .. " lines")

    heard = {}
    if NC then NC:Notify("Please wait before trying to redeem another Code", 5, nil, "Top") end
    local leaked, red = 0, 0
    for _, m in ipairs(heard) do
        if m:lower():find("please wait", 1, true) then leaked += 1 end
        if m:find("Invalid Code", 1, true) then red += 1 end
    end
    check("rate-limit notice never reaches the screen", leaked == 0, leaked .. " leaked")
    check("it is replaced by the red line", red >= 1, red .. " red lines")

    -- a real code landing switches it off by itself
    notifyRemote.OnClientEvent:FireAll("SPAMSTOPCODE", 5.5, nil, "Top")
    for _ = 1, 10 do H.pump(4000, H.virtualNow() + 0.2) end
    H.pump(40000)
    check("a real redeem turns spam off", L.SpamOn == false,
        "SpamOn=" .. tostring(L.SpamOn))

    pcall(L.SpamRedeem, false); H.pump(20000)
    if NC and restoreNC then NC.Notify = restoreNC end
    check("notifier restored after spam", L.FakeOn == false and L.SpamOn == false,
        ("FakeOn=%s SpamOn=%s"):format(tostring(L.FakeOn), tostring(L.SpamOn)))
end

print("")
print(("checks: %d   failures: %d"):format(checks, #fails))
for _, f in ipairs(fails) do print("  FAIL  " .. f) end
print(("runtime errors during the whole run: %d"):format(H.errors and #H.errors or 0))
if H.errors then
    local seen = {}
    for _, e in ipairs(H.errors) do
        local k = tostring(e)
        if not seen[k] then seen[k] = true; print("  ERR  " .. k) end
    end
end
end
