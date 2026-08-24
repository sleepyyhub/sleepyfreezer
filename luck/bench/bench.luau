-- Ranks every variant: correctness first, then speed.
--
--   luau luck/bench/bench.luau

local H = require("./harness")
local V, correct, measure = H.V, H.correct, H.measure
local measureSide = H.measureSide

-- ── run ───────────────────────────────────────────────────────────────────
local order = {"current", "swapgate", "rawdedup", "lastslot", "foldedgate",
               "swapgate_cold", "minimal", "minimal_raw", "solo", "solo_inline", "solo_typelast", "solo_bare", "floorcall", "floorcall_c", "noop"}

print(("\n%d iterations x %d rounds, best round per variant\n"):format(
    H.ITERATIONS, H.ROUNDS))

local results, broken = {}, {}
for _, name in ipairs(order) do
    local build = V[name]
    local ok, why = true, nil
    local ref = name == "floorcall" or name == "floorcall_c" or name == "noop"
    if not ref then ok, why = correct(name, build) end
    if not ok then
        broken[#broken + 1] = ("%-16s BROKEN  %s"):format(name, why)
    else
        local side = nil
        if not ref then side = measureSide(build) end
        results[#results + 1] = {name = name, ns = measure(build), side = side}
    end
end

-- The call overhead is not ours: the signal dispatch that enters the handler
-- and the send itself both belong to Roblox. floorcall measures exactly that
-- pair, so subtracting it leaves the work the script actually controls --
-- the same quantity L.FloorUs reports on the live client.
local floor
for _, r in ipairs(results) do
    if r.name == "floorcall" then floor = r.ns end
end
for _, r in ipairs(results) do
    r.logic = floor and math.max(r.ns - floor, 0) or nil
end

table.sort(results, function(a, b) return a.ns < b.ns end)

local baseline
for _, r in ipairs(results) do
    if r.name == "current" then baseline = r.ns end
end

print("  rank  variant           ns/call   vs current   side-toast   logic")
for i, r in ipairs(results) do
    local delta = baseline and ((r.ns - baseline) / baseline * 100) or 0
    print(("  %-5d %-16s %7.1f   %+6.1f%%   %8.1f  %6s"):format(
        i, r.name, r.ns, delta, r.side or -1,
        r.logic and ("%.1f"):format(r.logic) or "ref"))
end

if #broken > 0 then
    print("\n  rejected on correctness:")
    for _, line in ipairs(broken) do print("    " .. line) end
end

print(("\n  fastest correct variant: %s\n"):format(results[1] and results[1].name or "none"))
