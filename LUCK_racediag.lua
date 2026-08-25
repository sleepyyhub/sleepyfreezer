--[[
    RACEDIAG — find out why you are losing the race
    Roblox / Luau. Run in your executor. LUCK does not need to be loaded, but
    if it is, this also reports when LUCK fired relative to everything else.

    The question this answers: when the code goes live, WHAT does your client
    learn about it first, and how much earlier is that than the announcement
    your script is reading?

    It listens on every RemoteEvent the client can see, watches replicated
    values and attributes, and timestamps everything into a ring buffer. It
    changes nothing and fires nothing.

    Use it like this:

      1. run it
      2. lose a race
      3. RACEDIAG.report("THECODE")     -- the code you lost

    LUCK already reads straight off the notify RemoteEvent's OnClientEvent --
    that is the earliest anything can observe THAT remote, and it is not the
    question. The question is whether some OTHER channel carries the code
    before that remote fires.

    You get a timeline: every place that code appeared on your client, in
    order, with the gap from the first sighting. If something sits above the
    notify remote, that channel is the earlier one and no handler tuning
    closes the gap.

      RACEDIAG.channels()   -- what is talking, ranked by traffic
      RACEDIAG.last(40)     -- the last 40 events, whatever they were
      RACEDIAG.stop()       -- unhook everything
]]

local Players = game:GetService("Players")
local RepS    = game:GetService("ReplicatedStorage")
local LP      = Players.LocalPlayer

local BUFFER   = 4000    -- events kept
local MAXDEPTH = 5       -- how deep to stringify payloads
local MAXLEN   = 300     -- per-event payload text cap

local D = {}
getgenv().RACEDIAG = D

local clock = os.clock
local T0 = clock()

local log, logN = table.create(BUFFER), 0
local conns = {}
local seenChannels = {}

--------------------------------------------------------------------------------
-- payload -> searchable text
--------------------------------------------------------------------------------
local function flatten(v, depth, out)
    depth = depth or 0
    if depth > MAXDEPTH then return end
    local t = typeof(v)
    if t == "string" then
        out[#out + 1] = v
    elseif t == "number" or t == "boolean" then
        out[#out + 1] = tostring(v)
    elseif t == "Instance" then
        out[#out + 1] = v.Name
    elseif t == "table" then
        for k, item in pairs(v) do
            if type(k) == "string" then out[#out + 1] = k end
            flatten(item, depth + 1, out)
        end
    end
end

local function textOf(...)
    local parts = {}
    local n = select("#", ...)
    for i = 1, n do
        flatten((select(i, ...)), 0, parts)
    end
    local s = table.concat(parts, " | ")
    if #s > MAXLEN then s = s:sub(1, MAXLEN) .. "…" end
    return s
end

-- Never let naming an object take the tool down: anything reachable here can
-- be a proxy, a stripped instance, or something the executor wraps.
local function fullName(inst)
    local ok, n = pcall(function() return inst:GetFullName() end)
    if ok and type(n) == "string" then return n end
    local ok2, n2 = pcall(function() return tostring(inst.Name) end)
    if ok2 and type(n2) == "string" then return n2 end
    return tostring(inst)
end

local function record(source, kind, text)
    logN += 1
    local slot = ((logN - 1) % BUFFER) + 1
    log[slot] = { at = clock(), source = source, kind = kind, text = text or "" }
    seenChannels[source] = (seenChannels[source] or 0) + 1
end
D.record = record

local function ordered()
    local out = {}
    if logN <= BUFFER then
        for i = 1, logN do out[#out + 1] = log[i] end
    else
        local start = ((logN) % BUFFER) + 1
        for i = start, BUFFER do out[#out + 1] = log[i] end
        for i = 1, start - 1 do out[#out + 1] = log[i] end
    end
    return out
end

--------------------------------------------------------------------------------
-- 1. every RemoteEvent the client can see
--------------------------------------------------------------------------------
local hooked = setmetatable({}, { __mode = "k" })

local function hookRemote(re)
    if hooked[re] then return end
    hooked[re] = true
    local name = fullName(re)
    local ok, c = pcall(function()
        return re.OnClientEvent:Connect(function(...)
            record(name, "remote", textOf(...))
        end)
    end)
    if ok and c then conns[#conns + 1] = c end
end

local function sweepRemotes(root)
    local ok, list = pcall(function() return root:GetDescendants() end)
    if not ok then return 0 end
    local n = 0
    for _, d in ipairs(list) do
        if d:IsA("RemoteEvent") then hookRemote(d); n += 1 end
    end
    return n
end

--------------------------------------------------------------------------------
-- 2. replicated values and attributes
--------------------------------------------------------------------------------
local VALUE_CLASSES = {
    StringValue = true, IntValue = true, NumberValue = true,
    BoolValue = true, ObjectValue = true,
}

local watchedValues = setmetatable({}, { __mode = "k" })

local function watchValue(inst)
    if watchedValues[inst] then return end
    watchedValues[inst] = true
    local name = fullName(inst)
    local ok, c = pcall(function()
        return inst:GetPropertyChangedSignal("Value"):Connect(function()
            record(name, "value", tostring(inst.Value))
        end)
    end)
    if ok and c then conns[#conns + 1] = c end
end

local function watchAttributes(inst)
    local name = fullName(inst)
    local ok, c = pcall(function()
        return inst.AttributeChanged:Connect(function(attr)
            record(name .. "@" .. attr, "attribute", tostring(inst:GetAttribute(attr)))
        end)
    end)
    if ok and c then conns[#conns + 1] = c end
end

--------------------------------------------------------------------------------
-- 3. anything newly replicated into the tree
--------------------------------------------------------------------------------
local function watchTree(root, label)
    local ok, c = pcall(function()
        return root.DescendantAdded:Connect(function(d)
            record(label .. "/+" .. d.ClassName, "added", d.Name)
            if d:IsA("RemoteEvent") then hookRemote(d) end
            if VALUE_CLASSES[d.ClassName] then watchValue(d) end
        end)
    end)
    if ok and c then conns[#conns + 1] = c end
end

--------------------------------------------------------------------------------
-- 4. if LUCK is loaded, note when IT fired
--------------------------------------------------------------------------------
-- L.Note runs from the tail, which is deferred until AFTER the redeem's server
-- round trip has come back. So this timestamp is when the redeem RESOLVED, not
-- when it was sent. The send itself is microseconds after the notification row
-- above it -- that row is the one to read for detection timing.
local L = getgenv().LUCK
if type(L) == "table" then
    local realNote = L.Note
    L.Note = function(src, code, at)
        record("LUCK redeem resolved (incl. round trip)", "luck", tostring(code))
        if type(realNote) == "function" then return realNote(src, code, at) end
    end
end

--------------------------------------------------------------------------------
-- arm
--------------------------------------------------------------------------------
local remoteCount = 0
remoteCount += sweepRemotes(RepS)
remoteCount += sweepRemotes(workspace)
pcall(function() remoteCount += sweepRemotes(LP:WaitForChild("PlayerGui", 5)) end)

local valueCount = 0
for _, d in ipairs(RepS:GetDescendants()) do
    if VALUE_CLASSES[d.ClassName] then watchValue(d); valueCount += 1 end
end

watchTree(RepS, "ReplicatedStorage")
watchTree(workspace, "Workspace")
watchAttributes(RepS)
watchAttributes(workspace)

-- keep up with remotes that appear later
task.spawn(function()
    while D.running ~= false do
        task.wait(2)
        sweepRemotes(RepS)
    end
end)
D.running = true

print("")
print("[RACEDIAG] armed")
print(string.format("[RACEDIAG]   %d RemoteEvents listening", remoteCount))
print(string.format("[RACEDIAG]   %d replicated values watched", valueCount))
print(string.format("[RACEDIAG]   LUCK %s", type(L) == "table" and "detected, its fire is tagged" or "not loaded"))
print("[RACEDIAG] lose a race, then run:  RACEDIAG.report(\"THECODE\")")
print("")

--------------------------------------------------------------------------------
-- report
--------------------------------------------------------------------------------
function D.report(code)
    if type(code) ~= "string" or code == "" then
        warn("[RACEDIAG] pass the code you lost, e.g. RACEDIAG.report(\"SUMMER2026\")")
        return nil
    end
    local needle = code:upper()
    local hits = {}
    for _, e in ipairs(ordered()) do
        if e.text:upper():find(needle, 1, true) then
            hits[#hits + 1] = e
        end
    end

    print("")
    print("[RACEDIAG] ---- " .. code .. " ----")
    if #hits == 0 then
        print("[RACEDIAG] that code never appeared in anything this client received.")
        print("[RACEDIAG] either the buffer rolled over, or your client learned it")
        print("[RACEDIAG] through a path this tool does not watch.")
        return
    end

    local first = hits[1].at
    print(string.format("[RACEDIAG] %d sightings. first one is t=0.", #hits))
    print("")
    for i, e in ipairs(hits) do
        print(string.format("[RACEDIAG]  %2d.  +%8.3f ms  [%-9s]  %s",
            i, (e.at - first) * 1000, e.kind, e.source))
        if i == 1 or e.kind == "luck" then
            print(string.format("[RACEDIAG]                        %s", e.text:sub(1, 140)))
        end
    end
    print("")

    -- the verdict that matters
    local firstNotify, firstAny, luckAt
    for _, e in ipairs(hits) do
        if not firstAny then firstAny = e end
        if e.kind == "luck" and not luckAt then luckAt = e.at end
        if not firstNotify and (e.source:lower():find("notif", 1, true)
            or e.source:lower():find("notify", 1, true)) then
            firstNotify = e
        end
    end

    if firstNotify and firstAny and firstNotify ~= firstAny then
        local lead = (firstNotify.at - firstAny.at) * 1000
        print(string.format("[RACEDIAG] the announcement was NOT first. %s beat it by %.3f ms.",
            firstAny.source, lead))
        print("[RACEDIAG] a script reading that source starts that much ahead of you,")
        print("[RACEDIAG] and no handler tuning closes it.")
    elseif firstAny then
        print(string.format("[RACEDIAG] first sighting was %s — no other channel",
            firstAny.source))
        print("[RACEDIAG] on this client carried the code earlier, so you are already")
        print("[RACEDIAG] reading the earliest thing that exists. If you still lose,")
        print("[RACEDIAG] the cause is frame phase, ping, or the rival pre-firing —")
        print("[RACEDIAG] not detection.")
    end

    if luckAt and firstAny then
        print(string.format("[RACEDIAG] LUCK's redeem resolved %.3f ms after the first sighting;",
            (luckAt - firstAny.at) * 1000))
        print("[RACEDIAG] that figure INCLUDES the server round trip, so do not read it")
        print("[RACEDIAG] as reaction time. LUCK sends within microseconds of the")
        print("[RACEDIAG] notification row above.")
    end
    print("")
    return hits
end

function D.channels()
    local rows = {}
    for name, n in pairs(seenChannels) do rows[#rows + 1] = { name, n } end
    table.sort(rows, function(a, b) return a[2] > b[2] end)
    print("")
    print("[RACEDIAG] traffic by channel")
    for i = 1, math.min(#rows, 30) do
        print(string.format("[RACEDIAG]  %5d  %s", rows[i][2], rows[i][1]))
    end
    print("")
    return rows
end

function D.last(n)
    n = n or 30
    local all = ordered()
    print("")
    for i = math.max(1, #all - n + 1), #all do
        local e = all[i]
        print(string.format("[RACEDIAG] %9.3f s  [%-9s] %s",
            e.at - T0, e.kind, e.source))
        print(string.format("[RACEDIAG]              %s", e.text:sub(1, 120)))
    end
    print("")
end

function D.stop()
    D.running = false
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    conns = {}
    print("[RACEDIAG] stopped, " .. tostring(logN) .. " events recorded")
end

return D
