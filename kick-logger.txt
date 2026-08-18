--!nocheck
-- KICK LOGGER
-- The reason a kick happened dies with the session, so this writes it to disk.
-- Run it BEFORE the sniper. After the next kick, rejoin and run:
--     print(readfile("nyx_kick_log.txt"))
-- or just re-run this file, which prints the previous log on startup.

local Players    = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local LogService = game:GetService("LogService")
local CoreGui    = game:GetService("CoreGui")
local LP         = Players.LocalPlayer

local FILE = "nyx_kick_log.txt"

local K = {}
if getgenv then getgenv().NyxKickLog = K end

K.Actions = {}      -- rolling record of what we did, so the kick has context
K.MaxActions = 60

local function stamp()
    return os.date("%H:%M:%S")
end

local function append(line)
    local prev = ""
    if isfile and isfile(FILE) then
        local ok, r = pcall(readfile, FILE)
        if ok then prev = r end
    end
    pcall(writefile, FILE, prev .. line .. "\n")
end

-- public: call this from other scripts to record what you were doing
function K.Mark(what)
    local e = ("[%s] %s"):format(stamp(), tostring(what))
    table.insert(K.Actions, e)
    if #K.Actions > K.MaxActions then table.remove(K.Actions, 1) end
end

-- dump everything we know at the moment of death
local dumped = false
local function dump(reason, source)
    if dumped then return end
    dumped = true

    local out = {}
    table.insert(out, "================================================")
    table.insert(out, ("KICK  %s"):format(os.date("%Y-%m-%d %H:%M:%S")))
    table.insert(out, ("source : %s"):format(tostring(source)))
    table.insert(out, ("reason : %s"):format(tostring(reason)))
    table.insert(out, ("place  : %s   job: %s"):format(tostring(game.PlaceId), tostring(game.JobId)))
    table.insert(out, ("player : %s (%s)"):format(LP.Name, tostring(LP.UserId)))
    table.insert(out, ("uptime : %.0fs"):format(time()))

    -- whatever the sniper recorded about its own traffic
    local sniper = getgenv and getgenv().LiveSniper
    if type(sniper) == "table" then
        local st = sniper.Stats or {}
        table.insert(out, ("sniper : seen=%s fired=%s ok=%s fail=%s skipped=%s")
            :format(tostring(st.seen), tostring(st.fired), tostring(st.ok),
                    tostring(st.fail), tostring(st.skipped)))
        if type(sniper.FireLog) == "table" then
            table.insert(out, ("invites in last 60s at kick : %d"):format(#sniper.FireLog))
        end
        table.insert(out, ("settings: searchFirst=%s maxPerMin=%s minGap=%s cooldown=%s")
            :format(tostring(sniper.SearchFirst), tostring(sniper.MaxPerMin),
                    tostring(sniper.MinGap), tostring(sniper.Cooldown)))
    else
        table.insert(out, "sniper : not loaded")
    end

    -- other executor scripts sharing the client raise the noise floor
    local g = getgenv and getgenv()
    if g then
        local others = {}
        for _, name in ipairs({"Luminosity", "Cobalt", "LiveSniper"}) do
            if rawget(g, name) ~= nil then others[#others + 1] = name end
        end
        table.insert(out, ("loaded : %s"):format(#others > 0 and table.concat(others, ", ") or "none detected"))
    end

    table.insert(out, "-- recent actions --")
    for _, a in ipairs(K.Actions) do table.insert(out, "   " .. a) end

    -- last client log lines, which sometimes carry the server's complaint
    if LogService then
        local ok, hist = pcall(function() return LogService:GetLogHistory() end)
        if ok and type(hist) == "table" then
            table.insert(out, "-- last log lines --")
            local start = math.max(1, #hist - 25)
            for i = start, #hist do
                local e = hist[i]
                if type(e) == "table" and e.message then
                    table.insert(out, ("   [%s] %s"):format(tostring(e.messageType), tostring(e.message)))
                end
            end
        end
    end
    table.insert(out, "================================================")

    append(table.concat(out, "\n"))
    warn("[NyxKickLog] captured: " .. tostring(reason))
end

-- 1. GuiService carries the disconnect message
pcall(function()
    GuiService:GetPropertyChangedSignal("SelectedObject"):Connect(function() end)
end)
task.spawn(function()
    local last = ""
    while true do
        local ok, msg = pcall(function() return GuiService:GetErrorMessage() end)
        if ok and type(msg) == "string" and msg ~= "" and msg ~= last then
            last = msg
            dump(msg, "GuiService:GetErrorMessage")
        end
        task.wait(0.25)
    end
end)

-- 2. the disconnect prompt renders the reason as text in CoreGui
task.spawn(function()
    while true do
        local ok = pcall(function()
            for _, d in ipairs(CoreGui:GetDescendants()) do
                if d:IsA("TextLabel") and type(d.Text) == "string" and d.Text ~= "" then
                    local t = d.Text:lower()
                    if t:find("kick") or t:find("disconnect") or t:find("cheat")
                       or t:find("removed from") or t:find("banned") then
                        dump(d.Text, "CoreGui: " .. d:GetFullName())
                        return
                    end
                end
            end
        end)
        if not ok then end
        task.wait(0.4)
    end
end)

-- 3. losing the character/player is a late but reliable signal
Players.PlayerRemoving:Connect(function(p)
    if p == LP then dump("(PlayerRemoving fired - no message captured)", "PlayerRemoving") end
end)

-- print the previous run's log so you see it immediately on rejoin
task.spawn(function()
    if isfile and isfile(FILE) then
        local ok, prev = pcall(readfile, FILE)
        if ok and prev ~= "" then
            warn("[NyxKickLog] previous log:\n" .. prev:sub(-4000))
            if setclipboard then pcall(setclipboard, prev:sub(-8000)) end
        end
    else
        warn("[NyxKickLog] armed, no previous log")
    end
end)

K.Mark("logger armed")
return K
