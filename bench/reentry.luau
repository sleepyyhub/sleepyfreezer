do
local R = RIG local H = R.H local notifyRemote = R.notifyRemote
H.pump(40000)
local L = R.genvTable.LUCK
L.AutoOn = true; L.SyncHot(); H.pump(20000)
pcall(L.TakePole); H.pump(20000)

-- The game's handler emits another notification when it draws one, which is what
-- NotificationController line 198 is doing. This is the cascade.
local depth, maxDepth, emitted = 0, 0, 0
local cascade = loadstring([[
    return function(fire)
        return function(msg, dur, sound, position)
            fire()
        end
    end
]], "@ReplicatedStorage.Controllers.NotificationController")()

local held = L.PoleTaken
if held then
    for i = 1, #held do
        held[i] = cascade(function()
            depth += 1
            if depth > maxDepth then maxDepth = depth end
            if depth < 200 and emitted < 400 then
                emitted += 1
                notifyRemote.OnClientEvent:FireAll("CASCADE", 5.5, nil, "Top")
            end
            depth -= 1
        end)
    end
end

local before = R.invokeCount()
notifyRemote.OnClientEvent:FireAll("KICKOFF", 5.5, nil, "Top")
H.pump(300000)

print(("one announcement into a cascading game handler"))
print(("  nesting depth reached   %d   (Roblox aborts at 80)"):format(maxDepth))
print(("  redeems sent            %d"):format(R.invokeCount() - before))
print(("  scheduler errors        %d"):format(H.errors and #H.errors or 0))
if H.errors then
    for i = 1, math.min(2, #H.errors) do print("   " .. tostring(H.errors[i])) end
end
end
