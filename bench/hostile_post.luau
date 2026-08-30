do
-- Whatever comes back over the redeem remote is not ours.
--
-- It can be a table with a metatable that throws on index, a cycle, a function,
-- a number, or twenty kilobytes of text. None of it may take out the result
-- path, and none of it may leave the script silent -- silence after a redeem is
-- indistinguishable from the script having missed the code, which is the exact
-- complaint this path exists to answer.
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

local seen = {}
L.Notify = function(t) seen[#seen + 1] = tostring(t) end

local angry = setmetatable({}, {__index = function() error("no") end})
local cyclic = {}
cyclic.self = cyclic
cyclic.message = "Meowl spawned!"

local cases = {
    {"a cycle carrying a win",  function() return cyclic end},
    {"a metatable that throws", function() return angry end},
    {"a number",               function() return 42 end},
    {"nil and a number",       function() return nil, 7 end},
    {"a function",             function() return print end},
    {"an empty table",         function() return {} end},
    {"twenty kilobytes",       function() return string.rep("x", 20000) end},
    {"a table of tables",      function() return {{{}}, {}} end},
    {"a boolean pair",         function() return true, false end},
}

for i, c in ipairs(cases) do
    R.setInvokeBehaviour(c[2])
    local n0, e0 = #seen, #(H.errors or {})
    local sends0 = R.invokeCount()
    local fired = pcall(function()
        notifyRemote.OnClientEvent:FireAll("HOSTILE" .. i, 5.5, nil, "Top")
    end)
    H.pump(150000)
    check("it survives " .. c[1], fired, "the handler threw")
    check("  no runtime error (" .. c[1] .. ")", #(H.errors or {}) == e0,
        tostring(#(H.errors or {}) - e0) .. " errors")
    check("  the code still went out (" .. c[1] .. ")",
        R.invokeCount() - sends0 >= 1, tostring(R.invokeCount() - sends0))
    check("  and it says something (" .. c[1] .. ")", #seen > n0, "silent")
    if #seen > n0 then
        check("  within a label's worth (" .. c[1] .. ")",
            #seen[#seen] <= (tonumber(L.ResultTextMax) or 160) + 80,
            tostring(#seen[#seen]) .. " chars")
    end
    -- Checked here rather than at the end: the history keeps only five rows.
    if c[1] == "a cycle carrying a win" then
        local row = L.CodeHistory and L.CodeHistory[1]
        check("a win inside a cycle is still a win",
            row and row.code == "HOSTILE" .. i and row.status == "success",
            tostring(row and row.code) .. " / " .. tostring(row and row.status))
    end
end

R.setInvokeBehaviour(nil)
print(("checks: %d   failures: %d"):format(checks, #fails))
for _, f in ipairs(fails) do print("  FAIL  " .. f) end
print("runtime errors: " .. #(H.errors or {}))
end
