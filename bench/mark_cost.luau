-- How much does it cost to record "this code is in flight" just before the send?
-- Every candidate stores a GC-managed string somewhere, and that store carries a write
-- barrier -- which is the part that actually costs, not the arithmetic around it.
local N = 500000
local CLOCK_NS
do
    local t = os.clock()
    for _ = 1, N do local _ = os.clock() end
    CLOCK_NS = (os.clock() - t) / N * 1e9
end

local keys = table.create(N)
for i = 1, N do keys[i] = "LUCKCODE" .. i end

local function timeIt(label, body)
    local best
    for _ = 1, 7 do
        local t0 = os.clock()
        body()
        local ns = (os.clock() - t0) / N * 1e9 - CLOCK_NS
        if not best or ns < best then best = ns end
    end
    print(("  %-42s %7.1f ns"):format(label, best))
end

local sink
timeIt("nothing (loop floor)", function()
    for i = 1, N do sink = i end
end)

do
    local fly, flyAt = table.create(4), 0
    timeIt("4-slot array ring", function()
        for n = 1, N do
            local msg = keys[n]
            local i = flyAt + 1; if i > 4 then i = 1 end; flyAt = i; fly[i] = msg
        end
    end)
end

do
    local fly1
    timeIt("one upvalue", function()
        for n = 1, N do
            fly1 = keys[n]
        end
    end)
end

do
    local fly1, fly2
    timeIt("two upvalues, shift", function()
        for n = 1, N do
            fly2 = fly1; fly1 = keys[n]
        end
    end)
end

do
    local sent = {}
    timeIt("hash insert, cleared every 16", function()
        for n = 1, N do
            sent[keys[n]] = true
            if n % 16 == 0 then table.clear(sent) end
        end
    end)
end
