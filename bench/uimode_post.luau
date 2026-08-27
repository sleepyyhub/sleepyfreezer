do
-- UI detect mode used to double every send, and the label surface re-fired on
-- every repaint on top of that. Detection is a choice of ONE surface.
local R = RIG
local H = R.H
H.pump(300000)
local L = R.genvTable.LUCK
if not L then print("no getgenv().LUCK") return end

local fails, checks = {}, 0
local function check(n, c, d)
    checks += 1
    if not c then fails[#fails + 1] = n .. (d and ("  -- " .. d) or "") end
end
R.setInvokeBehaviour(function() return false, "Invalid Code" end)

local seq = 0
local function announce()
    seq += 1
    local n = R.invokeCount()
    R.notifyRemote.OnClientEvent:FireAll("UIMODE" .. seq, 5.5, "Sounds.Sfx.Blop", "Top")
    H.pump(300000)
    return R.invokeCount() - n
end

print("UI DETECT MODE")
print("================================================================")

check("the one-surface rule is exposed", type(L.ApplyDetectMode) == "function")
check("so is standing the remote down", type(L.DisconnectNotifyRemote) == "function")

-- remote mode: the baseline
L.SetDetectMode("remote")
H.pump(300000)
check("remote mode uses the remote", L.RemoteDetectOn == true)
check("and drops the notify hook", L.NotifyHooked == false,
    "NotifyHooked=" .. tostring(L.NotifyHooked))
check("remote mode: one announcement, one send", announce() == 1)

-- ui mode: the bug
L.SetDetectMode("ui")
H.pump(300000)
check("ui mode installs a UI surface", L.NotifyHooked == true or L.GuiHooked == true,
    ("notify=%s gui=%s"):format(tostring(L.NotifyHooked), tostring(L.GuiHooked)))
check("and stands the remote down", L.RemoteDetectOn == false,
    "RemoteDetectOn=" .. tostring(L.RemoteDetectOn))
check("and lets go of pole, so the game's own popups still run",
    L.PoleOn ~= true, "PoleOn=" .. tostring(L.PoleOn))
local uiSends = announce()
check("ui mode: one announcement, one send", uiSends == 1,
    "sends=" .. tostring(uiSends))
check("ui mode again: still one", announce() == 1)

-- switching back and forth must not accumulate surfaces
for _ = 1, 3 do
    L.SetDetectMode("remote"); H.pump(300000)
    L.SetDetectMode("ui");     H.pump(300000)
end
check("after three round trips, ui is still one send", announce() == 1)
L.SetDetectMode("remote"); H.pump(300000)
check("and remote is still one send", announce() == 1)

-- the label surface: a repaint is not a new announcement
L.SetDetectMode("ui")
H.pump(300000)
local PG = PlayerGuiRef
local top = PG:FindFirstChild("TopNotification")
if not top then
    top = Instance.new("Folder"); top.Name = "TopNotification"; top.Parent = PG
    local inner = Instance.new("Frame"); inner.Name = "TopNotification"; inner.Parent = top
end
local inner = top:FindFirstChild("TopNotification") or top
local rows = {}
for i = 1, 3 do
    local l = Instance.new("TextLabel")
    l.Name = "DiagRow" .. i
    l.Text = ""
    l.Parent = inner
    rows[i] = l
end
if L.HookGui then L.HookGui() end
-- dispatchText stands down while the notify hook is installed, so with it in
-- place the labels are inert and prove nothing. This is the fallback path.
L.NotifyHooked = false
H.pump(300000)

local n = R.invokeCount()
rows[1].Text = "PAINTED1"
H.pump(300000)
check("a label appearing sends once", R.invokeCount() - n == 1,
    "sends=" .. tostring(R.invokeCount() - n))

for _ = 1, 6 do
    H.pump(4000, H.virtualNow() + 1.0)
    rows[1].Text = ""
    rows[1].Text = "PAINTED1"
end
H.pump(300000)
check("six repaints a second apart do not resend", R.invokeCount() - n == 1,
    "sends=" .. tostring(R.invokeCount() - n))

local n2 = R.invokeCount()
H.pump(4000, H.virtualNow() + 1.0)
rows[2].Text = "PAINTED1"          -- the game recycling the old row down
rows[1].Text = "PAINTED2"          -- and the new one on top
H.pump(300000)
check("recycling old text into another row does not resend",
    R.invokeCount() - n2 == 1, "sends=" .. tostring(R.invokeCount() - n2))

-- a genuinely different code still gets through
local n3 = R.invokeCount()
H.pump(4000, H.virtualNow() + 1.0)
rows[1].Text = "PAINTED3"
H.pump(300000)
check("a different code still sends", R.invokeCount() - n3 == 1,
    "sends=" .. tostring(R.invokeCount() - n3))

-- Expiry is checked against the guard directly with explicit timestamps, not by
-- advancing the scheduler: dispatchText stamps with os.clock(), and the virtual
-- clock does not move that. Driving it through the labels would have needed a
-- real 30 second sleep to prove anything.
check("the window is long and tunable", (L.UiRepeatWindow or 0) >= 10,
    tostring(L.UiRepeatWindow))
do
    local W = 30
    L.FanSeen["EXPIRY"] = nil
    check("first sighting goes through",
        L.SeenRecently("EXPIRY", 100, W, true) == false)
    check("a repeat inside the window is held",
        L.SeenRecently("EXPIRY", 110, W, true) == true)
    check("and the window slides, so a slow drip never ages out",
        L.SeenRecently("EXPIRY", 135, W, true) == true)
    check("past the window it is allowed again",
        L.SeenRecently("EXPIRY", 200, W, true) == false)
    L.FanSeen["EXPIRY2"] = nil
    check("without slide it expires from the FIRST sighting",
        L.SeenRecently("EXPIRY2", 100, W, false) == false
            and L.SeenRecently("EXPIRY2", 110, W, false) == true
            and L.SeenRecently("EXPIRY2", 135, W, false) == false)
end

L.SetDetectMode("remote")
H.pump(300000)

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
