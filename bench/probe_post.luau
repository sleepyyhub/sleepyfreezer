do
-- A resolved redeem remote is not the same as a working one. The check sends one
-- code and reads the answer; a server that says it cannot find the code is not
-- going to take redeems at all, and that does not fix itself.
local R = RIG
local H = R.H
local L = R.genvTable.LUCK
if not L then print("no getgenv().LUCK") return end

local fails, checks = {}, 0
local function check(n, c, d)
    checks += 1
    if not c then fails[#fails + 1] = n .. (d and ("  -- " .. d) or "") end
end

print("REDEEM REMOTE CHECK")
print("================================================================")

check("the recheck is exposed", type(L.RecheckRedeemRemote) == "function")
check("the state is exposed", type(L.RedeemRemoteBroken) == "boolean")

-- a healthy server: it rejects the code, which is the correct answer
R.setInvokeBehaviour(function() return false, "Invalid Code" end)
L.RecheckRedeemRemote()
H.pump(200000)
check("a rejecting server is not broken", L.RedeemRemoteBroken == false,
    "broken=" .. tostring(L.RedeemRemoteBroken))

-- a server that cannot find the code at all
R.setInvokeBehaviour(function() return false, "Code not found" end)
L.RecheckRedeemRemote()
H.pump(200000)
check("that answer marks it broken", L.RedeemRemoteBroken == true,
    "broken=" .. tostring(L.RedeemRemoteBroken))

-- case and wording do not matter
R.setInvokeBehaviour(function() return false, "ERROR: CODE NOT FOUND in database" end)
L.RecheckRedeemRemote()
H.pump(200000)
check("case and surrounding words do not matter", L.RedeemRemoteBroken == true)

-- the warning is up and stays up
local gui
for _, d in ipairs((L.GuiParent or R.RepS):GetChildren()) do
    if d:IsA("ScreenGui") and tostring(d.Name):match("^LUCK_%d+$") then gui = d end
end
local warnFrame = gui and gui:FindFirstChild("RemoteWarning")
check("the warning exists", warnFrame ~= nil)
check("and is showing", warnFrame and warnFrame.Visible == true,
    tostring(warnFrame and warnFrame.Visible))
if warnFrame then
    local said = {}
    for _, d in ipairs(warnFrame:GetDescendants()) do
        if d:IsA("TextLabel") then said[#said + 1] = tostring(d.Text) end
    end
    local all = table.concat(said, " | "):lower()
    check("it says the remote is not working",
        all:find("not working", 1, true) ~= nil, all)
    check("and says to rejoin", all:find("rejoin", 1, true) ~= nil, all)
    print("     banner: " .. table.concat(said, "  /  "))
end

-- it does not go away on its own
for _ = 1, 4 do H.pump(60000, H.virtualNow() + 20) end
check("it is still up a minute later", L.RedeemRemoteBroken == true
    and warnFrame and warnFrame.Visible == true)

-- and it clears itself the moment the server starts answering properly
R.setInvokeBehaviour(function() return false, "Invalid Code" end)
for _ = 1, 6 do H.pump(60000, H.virtualNow() + 20) end
check("a working server clears it without a reload", L.RedeemRemoteBroken == false,
    "broken=" .. tostring(L.RedeemRemoteBroken))
check("and the warning goes away", warnFrame and warnFrame.Visible == false,
    tostring(warnFrame and warnFrame.Visible))

-- nothing about how remotes are found leaks
print("")
print("NOTHING LEAKED")
print("----------------------------------------------------------------")
local leaked = {}
for k, v in pairs(L) do
    local key = tostring(k):lower()
    if key:find("index", 1, true) and key ~= "speedindex" and key ~= "themeindex"
        and key ~= "connindex" and key ~= "remoteindex" then
        leaked[#leaked + 1] = tostring(k)
    end
end
check("no field on the public table names it", #leaked == 0,
    table.concat(leaked, ", "))
check("the source string does not either",
    tostring(L.RedeemRemoteSource or ""):lower():find("index", 1, true) == nil
        and tostring(L.NotifyRemoteSource or ""):lower():find("index", 1, true) == nil,
    tostring(L.RedeemRemoteSource) .. " / " .. tostring(L.NotifyRemoteSource))
check("and no number is exposed alongside it",
    L.NotifyIndex == nil and L.RedeemIndex == nil,
    tostring(L.NotifyIndex) .. " / " .. tostring(L.RedeemIndex))


-- The probe asks the redeem remote a question and reads the answer, so it has
-- to read it the way the send path does. It used to concatenate tostring(a) and
-- tostring(b), which for a table answer gives "table: 0x…" -- so a remote that
-- was telling us the code was not found read as perfectly healthy, and noticing
-- exactly that is the entire point of this check.
do
    local shapes = {
        {"false and a message", function() return false, "Code not found" end, true},
        {"a bare message",      function() return "Code not found" end,        true},
        {"a table",             function() return {message = "Code not found"} end, true},
        {"a healthy rejection", function() return false, "Invalid code" end,   false},
        {"a healthy table",     function() return {message = "Invalid code"} end, false},
    }
    for _, s2 in ipairs(shapes) do
        R.setInvokeBehaviour(s2[2])
        L.RecheckRedeemRemote()
        H.pump(40000)
        check("a dead remote answering with " .. s2[1] .. " is noticed",
            (L.RedeemRemoteBroken == true) == s2[3],
            "broken=" .. tostring(L.RedeemRemoteBroken) .. " reply=" .. tostring(L.RedeemRemoteReply))
        check("  and the readout is readable (" .. s2[1] .. ")",
            tostring(L.RedeemRemoteReply):find("table: ", 1, true) == nil,
            tostring(L.RedeemRemoteReply))
        -- back to healthy for the next case
        R.setInvokeBehaviour(function() return false, "Invalid code" end)
        L.RecheckRedeemRemote(); H.pump(40000)
    end
    R.setInvokeBehaviour(nil)
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
