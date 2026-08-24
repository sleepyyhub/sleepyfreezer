-- Ranks every variant: correctness first, then speed.
--
--   luau luck/bench/bench.luau

local H = require("./harness")
local V, correct, measure = H.V, H.correct, H.measure
local measureSide = H.measureSide

-- ── run ───────────────────────────────────────────────────────────────────
local order = {"current", "swapgate", "rawdedup", "lastslot", "foldedgate",
               "swapgate_cold", "minimal", "minimal_raw", "solo", "solo_inline", "solo_typelast", "floorcall"}

print(("\n%d iterations x %d rounds, best round per variant\n"):format(
    H.ITERATIONS, H.ROUNDS))

local results, broken = {}, {}
for _, name in ipairs(order) do
    local build = V[name]
    local ok, why = true, nil
    if name ~= "floorcall" then ok, why = correct(name, build) end
    if not ok then
        broken[#broken + 1] = ("%-16s BROKEN  %s"):format(name, why)
    else
        local side = nil
        if name ~= "floorcall" then side = measureSide(build) end
        results[#results + 1] = {name = name, ns = measure(build), side = side}
    end
end

table.sort(results, function(a, b) return a.ns < b.ns end)

local baseline
for _, r in ipairs(results) do
    if r.name == "current" then baseline = r.ns end
end

print("  rank  variant           ns/call   vs current   side-toast")
for i, r in ipairs(results) do
    local delta = baseline and ((r.ns - baseline) / baseline * 100) or 0
    print(("  %-5d %-16s %7.1f   %+6.1f%%   %8.1f"):format(
        i, r.name, r.ns, delta, r.side or -1))
end

if #broken > 0 then
    print("\n  rejected on correctness:")
    for _, line in ipairs(broken) do print("    " .. line) end
end

print(("\n  fastest correct variant: %s\n"):format(results[1] and results[1].name or "none"))
