do
-- The Sender panel drives the real pipeline: threshold, buffer, guess mode and
-- the send itself -- with Auto Redeem on OR off.
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
local function fire(txt)
    L.SenderBox.Text = txt
    L.SenderSubmit()
    H.pump(200000)
end
local function setup(auto, threshold, guess)
    L.Threshold = threshold or 1
    L.GuessCode = guess and true or false
    L.SetAuto(auto and true or false)
    L.SyncHot()
    H.pump(200000)
end
local function lastSent()
    local lg = R.sentLog()
    return lg[#lg]
end

print("TEST SENDER")
print("================================================================")

check("the sender is reachable", L.SenderSubmit ~= nil and L.SenderBox ~= nil)
check("the forced-redeem knob is exposed", L.SenderRedeems == true)

-- Auto Redeem ON, threshold 1: straight through
setup(true, 1)
local n = R.invokeCount()
fire("SENDONE1")
check("auto on, threshold 1: one fake is one redeem", R.invokeCount() - n == 1,
    "sends=" .. tostring(R.invokeCount() - n))
check("and it is the code that was typed", lastSent() == "SENDONE1", tostring(lastSent()))

-- Auto Redeem ON, threshold 3: the parts have to buffer, not fire early
setup(true, 3)
n = R.invokeCount()
fire("AA")
check("auto on, threshold 3: part 1 does not fire", R.invokeCount() - n == 0,
    "sends=" .. tostring(R.invokeCount() - n))
check("and it counted toward the threshold", L.BufN == 1, "BufN=" .. tostring(L.BufN))
fire("BB")
check("part 2 does not fire either", R.invokeCount() - n == 0)
check("and the buffer is at two", L.BufN == 2, "BufN=" .. tostring(L.BufN))
fire("CC")
check("part 3 fires", R.invokeCount() - n == 1,
    "sends=" .. tostring(R.invokeCount() - n))
check("with the parts joined", lastSent() == "AABBCC", tostring(lastSent()))
check("and the buffer reset", L.BufN == 0, "BufN=" .. tostring(L.BufN))

-- Auto Redeem OFF, threshold 1: pressing Send is deliberate, so it still goes
setup(false, 1)
n = R.invokeCount()
fire("SENDOFF1")
check("auto OFF, threshold 1: it still redeems", R.invokeCount() - n == 1,
    "sends=" .. tostring(R.invokeCount() - n))
check("with the typed code", lastSent() == "SENDOFF1", tostring(lastSent()))
check("and Auto Redeem was NOT switched on behind your back",
    L.AutoOn == false, "AutoOn=" .. tostring(L.AutoOn))

-- Auto Redeem OFF, threshold 3: the buffer still has to work
setup(false, 3)
n = R.invokeCount()
fire("DD")
check("auto OFF, threshold 3: part 1 counts", L.BufN == 1, "BufN=" .. tostring(L.BufN))
check("and does not fire", R.invokeCount() - n == 0)
fire("EE")
fire("FF")
check("part 3 fires", R.invokeCount() - n == 1,
    "sends=" .. tostring(R.invokeCount() - n))
check("joined", lastSent() == "DDEEFF", tostring(lastSent()))

-- and the knob turns it off again
setup(false, 1)
L.SenderRedeems = false
n = R.invokeCount()
fire("NOSEND1")
check("SenderRedeems=false announces without redeeming",
    R.invokeCount() - n == 0, "sends=" .. tostring(R.invokeCount() - n))
L.SenderRedeems = true

-- forcing skips the Auto gate and nothing else: the repeat guard still applies
setup(false, 1)
n = R.invokeCount()
fire("REPEAT1")
fire("REPEAT1")
check("the same code twice does not double-send", R.invokeCount() - n == 1,
    "sends=" .. tostring(R.invokeCount() - n))

-- and it still works with Auto back on afterwards
setup(true, 1)
n = R.invokeCount()
fire("BACKON1")
check("auto on again still works", R.invokeCount() - n == 1,
    "sends=" .. tostring(R.invokeCount() - n))

-- a real announcement with Auto off must still NOT send: forcing is for the
-- Sender only, it is not a way to switch Auto Redeem off and keep redeeming
setup(false, 1)
n = R.invokeCount()
R.notifyRemote.OnClientEvent:FireAll("REALDROP1", 5.5, "Sounds.Sfx.Blop", "Top")
H.pump(200000)
check("a real announcement with auto off still does nothing",
    R.invokeCount() - n == 0, "sends=" .. tostring(R.invokeCount() - n))

setup(true, 1)
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
