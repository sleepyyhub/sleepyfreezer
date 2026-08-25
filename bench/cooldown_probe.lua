-- LUCK cooldown probe.
--
-- Fires N redeems in ONE frame and reports what came back. The point is not speed --
-- it is to find out whether the server's redeem handler yields between reading your
-- cooldown and writing it. If it does, some of a burst slip past the cooldown check
-- and come back with a code error instead of "please wait". If it does not, every
-- reply after the first is the cooldown and this whole idea is dead.
--
-- They go out from N separate threads spawned in the same frame, NOT a loop.
-- InvokeServer yields until the server answers, so a plain loop would be N sequential
-- round trips -- which tests nothing.

local N = 50

local L = (getgenv and getgenv().LUCK) or LUCK
if not L then
    warn("[probe] LUCK is not loaded -- run the main script first")
    return
end

local rem = L.RedeemRemote
if not rem then
    warn("[probe] no redeem remote resolved yet. LUCK.Diag() will say why.")
    return
end
if L.RedeemRemoteIsEvent then
    warn("[probe] the redeem remote is a RemoteEvent -- it returns nothing, so there")
    warn("[probe] are no replies to read and this probe cannot tell you anything.")
    return
end

local inv = rem.InvokeServer

local function text(ok, a, b)
    if not ok then return "ERROR: " .. tostring(a) end
    local parts = {}
    for _, v in ipairs({a, b}) do
        if type(v) == "table" then
            local got = L.PayloadText and L.PayloadText(v, 0)
            parts[#parts + 1] = got or "{table}"
        elseif v ~= nil then
            parts[#parts + 1] = tostring(v)
        end
    end
    return #parts > 0 and table.concat(parts, " / ") or "(no reply)"
end

local results, done = table.create(N), 0
local started = os.clock()

print(("[probe] firing %d invokes in one frame at %s"):format(N, rem.Name))

for i = 1, N do
    task.spawn(function()
        local code = "LUCK" .. tostring(math.random(100000, 999999))
        local at = os.clock()
        local ok, a, b = pcall(inv, rem, code)
        results[i] = {
            i = i,
            code = code,
            ms = (os.clock() - at) * 1000,
            ok = ok and a == true,
            text = text(ok, a, b),
        }
        done += 1
    end)
end

-- wait for them, but do not hang forever if the server never answers some
local deadline = os.clock() + 20
while done < N and os.clock() < deadline do task.wait(0.05) end

local buckets, order = {}, {}
local cooldown, reached, accepted, errored, missing = 0, 0, 0, 0, 0
local firstMs, lastMs

for i = 1, N do
    local r = results[i]
    if not r then
        missing += 1
    else
        local low = r.text:lower()
        if r.ok then
            accepted += 1
        elseif low:find("please wait", 1, true) or low:find("wait", 1, true)
            or low:find("cooldown", 1, true) or low:find("too fast", 1, true) then
            cooldown += 1
        elseif low:find("error:", 1, true) then
            errored += 1
        else
            -- anything that is not the cooldown means the cooldown check let it past
            reached += 1
        end
        if not firstMs or r.ms < firstMs then firstMs = r.ms end
        if not lastMs or r.ms > lastMs then lastMs = r.ms end
        buckets[r.text] = (buckets[r.text] or 0) + 1
        if buckets[r.text] == 1 then order[#order + 1] = r.text end
    end
end

print("[probe] ---- what came back ----")
for _, t in ipairs(order) do
    print(("[probe]   %3d x  %s"):format(buckets[t], t:sub(1, 90)))
end
print(("[probe] cooldown %d   past the cooldown %d   accepted %d   errored %d   no reply %d")
    :format(cooldown, reached, accepted, errored, missing))
if firstMs then
    print(("[probe] reply time: fastest %.0f ms, slowest %.0f ms, whole burst %.0f ms")
        :format(firstMs, lastMs, (os.clock() - started) * 1000))
end

print("[probe] ---- verdict ----")
if accepted > 0 then
    print("[probe] something was ACCEPTED, which should not happen for random codes.")
    print("[probe] check the replies above before trusting this.")
elseif reached > 1 then
    print(("[probe] THE GAP IS REAL: %d of %d got past the cooldown check.")
        :format(reached, N))
    print("[probe] the handler yields between reading and writing the cooldown, so a")
    print("[probe] burst can slip through. Worth building.")
elseif reached == 1 then
    print("[probe] exactly one got through -- that is just the first invoke, which was")
    print("[probe] always going to be allowed. No race. Not worth building.")
else
    print("[probe] every reply was the cooldown. The check-and-set is atomic, speed")
    print("[probe] cannot beat it, and this idea is dead. Do not build it.")
end
