do
-- Does the result reach the screen without a timer in between? Measured in virtual
-- time: pump only the deferred queue, never letting the clock advance, and see whether
-- the status line, the history row and the feed are already written.
local R = RIG
local H = R.H
H.pump(200000)
local L = R.genvTable.LUCK
if not L then print("no getgenv().LUCK") return end

local fails, checks = {}, 0
local function check(n, c, d)
    checks += 1
    if not c then fails[#fails + 1] = n .. (d and ("  -- " .. d) or "") end
end

print("INSTANT RESULT")
print("================================================================")

-- find the pieces of the UI a result is supposed to land in
local function findByText(root, pred, out)
    out = out or {}
    for _, d in ipairs(root:GetDescendants()) do
        if d:IsA("TextLabel") and pred(d) then out[#out + 1] = d end
    end
    return out
end
local gui
for _, d in ipairs((L.GuiParent or R.RepS):GetChildren()) do
    if d:IsA("ScreenGui") and tostring(d.Name):match("^LUCK_%d+$") then gui = d end
end
check("the UI exists to receive a result", gui ~= nil)
if not gui then
    print(("checks: %d   failures: %d"):format(checks, #fails))
    for _, f in ipairs(fails) do print("  FAIL  " .. f) end
    return
end

local function labelCount()
    local n = 0
    for _, d in ipairs(gui:GetDescendants()) do
        if d:IsA("TextLabel") then n += 1 end
    end
    return n
end

-- Pump the deferred queue only. untilTime = now means the scheduler may drain
-- everything already queued but may not advance the clock by even a microsecond, so
-- anything sitting on a task.delay cannot run.
local function drainNoTime() H.pump(40000, H.virtualNow()) end

L.ToastOn = false
local t0 = H.virtualNow()
local histBefore = #L.CodeHistory
local labelsBefore = labelCount()

R.notifyRemote.OnClientEvent:FireAll("INSTANT1", 5.5, "Sounds.Sfx.Blop", "Top")
drainNoTime()

check("the clock did not move", H.virtualNow() == t0,
    ("advanced %.4fs"):format(H.virtualNow() - t0))
check("the history row is already written", #L.CodeHistory > histBefore,
    ("history %d -> %d"):format(histBefore, #L.CodeHistory))
check("the history row is this code",
    L.CodeHistory[1] and tostring(L.CodeHistory[1].code) == "INSTANT1",
    tostring(L.CodeHistory[1] and L.CodeHistory[1].code))
check("the preview verdict is already written", L.LastPreviewCode == "INSTANT1",
    tostring(L.LastPreviewCode))
check("a feed line was already created", labelCount() > labelsBefore,
    ("labels %d -> %d"):format(labelsBefore, labelCount()))

-- the toast, when it is on, has to be legible the moment it exists rather than
-- tweening up from invisible
L.ToastOn = true
local before = labelCount()
L.Notify("straight to screen", nil)
drainNoTime()
local fresh
for _, d in ipairs(gui:GetDescendants()) do
    if d:IsA("TextLabel") and tostring(d.Text):find("straight to screen", 1, true) then
        fresh = d
    end
end
check("the notify line exists immediately", fresh ~= nil,
    ("labels %d -> %d"):format(before, labelCount()))
if fresh then
    check("it is visible, not waiting on a fade", fresh.TextTransparency == 0,
        "TextTransparency=" .. tostring(fresh.TextTransparency))
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
