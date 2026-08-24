-- Correctness gate, then a speed run. A wrong variant never gets a time.
--
--   luau luck/bench/bench.luau

local V = require("./variants")

local H = {}

local ITERATIONS = 60000
local ROUNDS = 7
-- A real session sees a handful of codes, so the dedup table stays tiny.
-- Letting it grow to ITERATIONS entries measured hash rehashing, not the
-- handler: with 60k distinct keys the table cost swamped every difference
-- between variants. The set is cleared every WORKING_SET calls so the table
-- stays session-sized while every call still walks the fresh-code path.
local WORKING_SET = 32

local function payloadText(v, depth)
    if type(v) == "string" then return v end
    if type(v) ~= "table" or depth > 4 then return nil end
    return payloadText(v.Message or v.Text or v.content, depth + 1)
end

-- Two shapes of fake send. The logging one is for correctness, where the
-- exact codes matter. The timed one only counts: appending to a table grows
-- it and allocates, and that cost is identical for every variant, so leaving
-- it in the timed loop would dilute the differences being measured.
local function newCtx()
    local ctx = {sent = {}, remote = {}, log = {}}
    ctx.payloadText = payloadText
    ctx.invoke = function(_, code)
        ctx.log[#ctx.log + 1] = code
    end
    return ctx
end

local function newFastCtx()
    local ctx = {sent = {}, remote = {}, n = 0}
    ctx.payloadText = payloadText
    ctx.invoke = function()
        ctx.n += 1
    end
    return ctx
end

-- ── correctness ───────────────────────────────────────────────────────────
local CASES = {
    {name = "fresh code sends once",
     acts = {{"ABC123", "Top"}}, want = {"ABC123"}},
    {name = "repeat sends nothing", needsDedup = true,
     acts = {{"DUP1", "Top"}, {"DUP1", "Top"}}, want = {"DUP1"}},
    {name = "non-Top sends nothing",
     acts = {{"SIDE1", nil}}, want = {}},
    {name = "two different codes both send",
     acts = {{"AAA1", "Top"}, {"BBB2", "Top"}}, want = {"AAA1", "BBB2"}},
    {name = "table payload unwrapped",
     acts = {{{Message = "TBL9"}, "Top"}}, want = {"TBL9"}},
    {name = "unusable payload sends nothing",
     acts = {{{Nope = 1}, "Top"}}, want = {}},
}

local function sameList(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

-- A variant that declares solo has no dedup by design: it is only ever bound
-- when a single surface is armed, where the same announcement cannot arrive
-- twice. It still has to pass every other case, so the exemption is narrow
-- and declared rather than assumed.
local function correct(name, build)
    for _, case in ipairs(CASES) do
        local ctx = newCtx()
        local v = build(ctx)
        if case.needsDedup and v.solo then continue end
        for _, act in ipairs(case.acts) do
            v.get()(act[1], 5, nil, act[2])
        end
        if not sameList(ctx.log, case.want) then
            return false, ("%s: got {%s}, want {%s}"):format(
                case.name, table.concat(ctx.log, ","), table.concat(case.want, ","))
        end
    end
    -- auto off must send nothing
    local ctx = newCtx()
    local v = build(ctx)
    v.gate(false)
    v.get()("GATED1", 5, nil, "Top")
    if #ctx.log ~= 0 then return false, "auto off still sent" end
    v.gate(true)
    v.get()("GATED2", 5, nil, "Top")
    if #ctx.log ~= 1 then return false, "gate did not reopen" end
    return true
end

-- ── speed ─────────────────────────────────────────────────────────────────
-- Codes are pre-generated so no allocation happens inside the timed loop,
-- and every iteration uses a fresh one so the dedup never short-circuits
-- the path we are trying to measure.
local codes = table.create(ITERATIONS)
for i = 1, ITERATIONS do
    codes[i] = "CODE" .. i
end

local function measure(build)
    local best = math.huge
    for _ = 1, ROUNDS do
        local ctx = newFastCtx()
        local v = build(ctx)
        local handler = v.get()
        local sent = ctx.sent
        local start = os.clock()
        for i = 1, ITERATIONS do
            handler(codes[i], 5, nil, "Top")
            if i % WORKING_SET == 0 then table.clear(sent) end
        end
        local elapsed = os.clock() - start
        if ctx.n ~= ITERATIONS then
            error("variant dropped sends during the timed run")
        end
        if elapsed < best then best = elapsed end
    end
    return best / ITERATIONS * 1e9
end


-- ── duel ──────────────────────────────────────────────────────────────────
-- Two variants, alternating rounds. Interleaving matters: CPU frequency and
-- cache state drift over a run, and measuring A fully then B fully hands the
-- drift straight to whichever went second. Reported as median, because one
-- lucky round is not evidence.
local function median(t)
    local c = table.clone(t)
    table.sort(c)
    local n = #c
    if n % 2 == 1 then return c[(n + 1) // 2] end
    return (c[n // 2] + c[n // 2 + 1]) / 2
end

local function duel(nameA, nameB, rounds)
    local buildA, buildB = V[nameA], V[nameB]
    assert(buildA, nameA .. " not found")
    assert(buildB, nameB .. " not found")
    for _, pair in ipairs({{nameA, buildA}, {nameB, buildB}}) do
        local ok, why = correct(pair[1], pair[2])
        assert(ok, pair[1] .. " is not correct: " .. tostring(why))
    end

    local a, b = {}, {}
    for i = 1, rounds do
        local first = (i % 2 == 1)
        local function one(build, into)
            local ctx = newFastCtx()
            local v = build(ctx)
            local handler = v.get()
            local sent = ctx.sent
            local start = os.clock()
            for k = 1, ITERATIONS do
                handler(codes[k], 5, nil, "Top")
                if k % WORKING_SET == 0 then table.clear(sent) end
            end
            into[#into + 1] = (os.clock() - start) / ITERATIONS * 1e9
            assert(ctx.n == ITERATIONS)
        end
        if first then one(buildA, a) one(buildB, b)
        else one(buildB, b) one(buildA, a) end
    end

    local ma, mb = median(a), median(b)
    local wins = 0
    for i = 1, rounds do if a[i] < b[i] then wins += 1 end end

    print(("\n  duel: %s vs %s, %d rounds of %d calls\n"):format(
        nameA, nameB, rounds, ITERATIONS))
    print(("    %-16s median %7.1f ns   min %7.1f   max %7.1f"):format(
        nameA, ma, math.min(table.unpack(a)), math.max(table.unpack(a))))
    print(("    %-16s median %7.1f ns   min %7.1f   max %7.1f"):format(
        nameB, mb, math.min(table.unpack(b)), math.max(table.unpack(b))))
    print(("\n    %s won %d of %d rounds, median gap %+.1f%%"):format(
        nameA, wins, rounds, (ma - mb) / mb * 100))
    return ma < mb and nameA or nameB
end




-- Side toasts -- joins, purchases, quest popups -- are the majority of what
-- this remote carries, and every one of them is work the handler does for
-- nothing. The Top-only loop never measured that, so a variant could pay a
-- call per side toast and still look free.
local function measureSide(build)
    local best = math.huge
    for _ = 1, ROUNDS do
        local ctx = newFastCtx()
        local v = build(ctx)
        local handler = v.get()
        local start = os.clock()
        for i = 1, ITERATIONS do
            handler(codes[i], 5, nil, nil)
        end
        local elapsed = os.clock() - start
        if ctx.n ~= 0 then error("a side toast reached the send") end
        if elapsed < best then best = elapsed end
    end
    return best / ITERATIONS * 1e9
end

H.V = V
H.ITERATIONS = ITERATIONS
H.ROUNDS = ROUNDS
H.correct = correct
H.measure = measure
H.measureSide = measureSide
H.duel = duel
H.median = median
H.codes = codes
H.WORKING_SET = WORKING_SET

return H
