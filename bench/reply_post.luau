do
-- What the redeem remote answered, and whether the script can read it.
--
-- Everything downstream was written against one shape -- the invoke returns
-- (boolean, string) -- and a RemoteFunction is under no obligation to do that.
-- When it does not, `reply` came out nil, and a nil reply has nothing to print,
-- so the notification bailed silently. That is the "it says nothing when the
-- code is out of stock" report; the same hole swallowed a win returned as a
-- bare string.
local R = RIG
local H = R.H
local notifyRemote = R.notifyRemote
H.pump(300000)
local L = R.genvTable.LUCK
local fails, checks = {}, 0
local function check(name, cond, detail)
    checks += 1
    if not cond then fails[#fails + 1] = name .. (detail and ("  -- " .. detail) or "") end
end

if not L then print("no getgenv().LUCK") return end
L.AutoOn, L.GuessCode, L.Threshold, L.RedeemPath = true, false, 1, "remote"
L.SyncHot(); H.pump(40000)

-- ------------------------------------------------------------------ the reader
local read = L.ReadReply
check("the reader is exposed", type(read) == "function")
if type(read) == "function" then
    local ok, reply = read(false, "This code is out of stock")
    check("(false, msg) reads as a rejection", ok == false and reply == "This code is out of stock",
        tostring(ok) .. " / " .. tostring(reply))

    ok, reply = read("This code is out of stock", nil)
    check("a bare message keeps its text", reply == "This code is out of stock", tostring(reply))
    check("and reads as a rejection", ok == false, tostring(ok))

    ok, reply = read("Meowl spawned!", nil)
    check("a bare win keeps its text", reply == "Meowl spawned!", tostring(reply))
    check("and reads as a win", ok == true, tostring(ok))

    ok, reply = read({success = false, message = "This code is out of stock"}, nil)
    check("a table with success/message", ok == false and reply == "This code is out of stock",
        tostring(ok) .. " / " .. tostring(reply))

    ok, reply = read({Message = "This code is out of stock"}, nil)
    check("a table with only Message", reply == "This code is out of stock", tostring(reply))

    ok, reply = read({success = true, message = "Dragon Cannelloni spawned!"}, nil)
    check("a table win", ok == true and reply == "Dragon Cannelloni spawned!",
        tostring(ok) .. " / " .. tostring(reply))

    ok, reply = read(nil, "This code is out of stock")
    check("a message in the second slot", reply == "This code is out of stock", tostring(reply))

    ok = read(false, nil)
    check("a bare false is still false", ok == false, tostring(ok))
    ok = read(true, nil)
    check("a bare true is still true", ok == true, tostring(ok))

    -- A stated flag beats the wording. The server is the authority on whether it
    -- worked; the sentence is just how it said so.
    ok = read(true, "This code is out of stock")
    check("a stated flag beats the wording", ok == true, tostring(ok))

    -- "You have already redeemed this code" carries a win word and a fail word.
    ok = read("You have already redeemed this code", nil)
    check("already-redeemed reads as a rejection", ok == false, tostring(ok))

    check("nothing at all stays unknown", read(nil, nil) == nil)
end

-- ------------------------------------------------ wording, including nasty names
-- The win reads "<ANIMAL> spawned!" and an animal is named whatever the game
-- feels like naming it, so a prize whose name carries a rejection word must
-- still read as a win.
local classify = L.ClassifyReply
check("the classifier is exposed", type(classify) == "function")
if type(classify) == "function" then
    local wording = {
        {"Meowl spawned!", true},
        {"Dragon Cannelloni spawned!", true},
        {"Limit Breaker spawned!", true},
        {"No Longer Human spawned!", true},
        {"Error 404 spawned!", true},
        {"Already Dead spawned!", true},
        {"You received a La Vacca!", true},
        {"Congratulations! You got Tralalero", true},
        {"This code is out of stock", false},
        {"This code has expired", false},
        {"You have already redeemed this code", false},
        {"Invalid code", false},
        {"Code not found", false},
        {"Please wait before trying to redeem another Code", false},
        {"This code is no longer available", false},
        {"Sold out", false},
        {"You have reached the limit", false},
        {"", nil},
        {"asdfgh", nil},
    }
    local bad, first = 0, nil
    for _, w in ipairs(wording) do
        if classify(w[1]) ~= w[2] then
            bad += 1
            first = first or (w[1] .. " -> " .. tostring(classify(w[1])))
        end
    end
    check("every wording reads correctly", bad == 0,
        tostring(bad) .. " misread, first: " .. tostring(first))
end

-- A win is never a rate-limit notice, whatever it is called. Reading one as a
-- cooldown does not just mislabel it -- it leaves the countdown anchored to the
-- wrong redeem for the next five seconds.
local isCd = L.IsCooldownReply
if type(isCd) == "function" then
    check("a real rate-limit notice is one",
        isCd("Please wait before trying to redeem another Code") == true)
    check("a prize called Waiter is not", isCd("Waiter spawned!") ~= true,
        "Waiter spawned! read as a cooldown")
    check("a stated win is never one", isCd("Please wait", true) == false)
end

-- The prize's name, out of whatever sentence it arrived in.
local prizes = {
    {"Meowl spawned!", "Meowl"},
    {"La Vacca Saturno Saturnita spawned!", "La Vacca Saturno Saturnita"},
    {"You received a La Vacca!", "La Vacca"},
    {"Congratulations! You got Tralalero Tralala", "Tralalero Tralala"},
    {"You have received the Brainrot God!", "Brainrot God"},
    {"Meowl has been added to your inventory", "Meowl"},
    {'<font color="#fff">Meowl spawned!</font>', "Meowl"},
    {"Tung Tung Tung Sahur", "Tung Tung Tung Sahur"},
}
local badPrize, firstPrize = 0, nil
for _, p in ipairs(prizes) do
    local got = L.Prize(p[1])
    if got ~= p[2] then
        badPrize += 1
        firstPrize = firstPrize or (p[1] .. " -> " .. tostring(got))
    end
end
check("the prize name comes out of the sentence", badPrize == 0,
    tostring(badPrize) .. " off, first: " .. tostring(firstPrize))

-- --------------------------------------------------------- end to end, on screen
local seen = {}
L.Notify = function(text) seen[#seen + 1] = tostring(text) end

local shapes = {
    {"false + message", function() return false, "This code is out of stock" end, "out of stock"},
    {"bare message",    function() return "This code is out of stock" end,        "out of stock"},
    {"table",           function() return {success = false, message = "This code is out of stock"} end, "out of stock"},
    {"table, Message",  function() return {Message = "This code is out of stock"} end, "out of stock"},
    {"bare false",      function() return false end,                              "rejected"},
    {"true + message",  function() return true, "Meowl spawned!" end,             "Meowl spawned"},
    {"bare win",        function() return "Meowl spawned!" end,                   "Meowl spawned"},
}
for i, s in ipairs(shapes) do
    R.setInvokeBehaviour(s[2])
    local n0 = #seen
    notifyRemote.OnClientEvent:FireAll("REPLY" .. i, 5.5, nil, "Top")
    H.pump(80000)
    local got = seen[#seen] or ""
    check("a " .. s[1] .. " answer reaches the screen", #seen > n0, "nothing shown")
    check("  and it says what happened (" .. s[1] .. ")",
        #seen > n0 and got:lower():find(s[3]:lower(), 1, true) ~= nil, got)
end

-- One announcement is still one send. The retry only fires on a stated
-- rejection, never on an answer we could not classify -- re-sending on those
-- burned the cooldown window on a code that may well have landed.
R.setInvokeBehaviour(function() return "Something we have never seen before" end)
local n0 = R.invokeCount()
notifyRemote.OnClientEvent:FireAll("REPLYUNKNOWN", 5.5, nil, "Top")
H.pump(80000)
check("an unclassifiable answer is not re-sent", R.invokeCount() - n0 == 1,
    tostring(R.invokeCount() - n0) .. " sends")

R.setInvokeBehaviour(nil)
print(("checks: %d   failures: %d"):format(checks, #fails))
for _, f in ipairs(fails) do print("  FAIL  " .. f) end
print("runtime errors: " .. #(H.errors or {}))
end
