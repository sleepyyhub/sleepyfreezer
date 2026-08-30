do
-- Nothing this script installs may sit on the frame clock.
--
-- A standing RenderStepped or Heartbeat connection is a Lua call on every
-- frame, on the same thread the redeem goes out on, at a cap of around a
-- thousand a second. The base build holds none; the private build held one for
-- the gradient sweep, which is what this exists to keep out.
local R = RIG
local H = R.H
H.pump(300000)
local L = R.genvTable.LUCK
local fails, checks = {}, 0
local function check(name, cond, detail)
    checks += 1
    if not cond then fails[#fails + 1] = name .. (detail and ("  -- " .. detail) or "") end
end

local RunS = game:GetService("RunService")
local function count(sig)
    if not sig then return 0 end
    local n = 0
    for _, c in ipairs(sig.conns or {}) do if c._enabled ~= false then n += 1 end end
    return n
end

local render, heart = count(RunS.RenderStepped), count(RunS.Heartbeat)
check("nothing on RenderStepped", render == 0, tostring(render) .. " connected")
check("nothing on Heartbeat", heart == 0, tostring(heart) .. " connected")

-- Firing frames must not run script work. If something is still on the frame
-- clock this walks straight into it.
local before = os.clock()
RENDER(2000, 1 / 999)
local perFrame = (os.clock() - before) / 2000 * 1e9
check("a frame costs the script nothing", perFrame < 2000,
    string.format("%.0f ns/frame", perFrame))

-- Idle wakeups. The base build sits at effectively zero; the themed build wakes
-- at its sweep rate and no faster.
local t0, steps = H.virtualNow(), 0
for _ = 1, 100000 do
    H.pump(1)
    steps += 1
    if H.virtualNow() - t0 >= 30 then break end
end
local dt = math.max(H.virtualNow() - t0, 1)
local rate = steps / dt
local cap = (L.ThemeOn ~= nil) and ((L.ThemeFps or 30) + 5) or 2
check("idle wakeups stay at the sweep rate", rate <= cap,
    string.format("%.1f/s against a ceiling of %d", rate, cap))

-- The cap is the biggest client-side latency lever there is: the packet waits
-- for the network send step, which is ~1ms at the cap and ~16ms at 60. It was
-- set once at load and never checked again.
check("the cap is set at boot", RIG.fpsCap() == 999, tostring(RIG.fpsCap()))
check("and the script knows what it asked for", L.FpsCap == 999, tostring(L.FpsCap))

setfpscap(60)
check("something else can clobber it", RIG.fpsCap() == 60, tostring(RIG.fpsCap()))
H.pump(300000, H.virtualNow() + 65)
check("the janitor puts it back", RIG.fpsCap() == 999, tostring(RIG.fpsCap()))

-- But a deliberate lowering is a choice, not drift. Turbo off sets 240.
L.SetFpsCap(240)
H.pump(300000, H.virtualNow() + 65)
check("a deliberate cap survives the sweep", RIG.fpsCap() == 240, tostring(RIG.fpsCap()))
L.SetFpsCap(999)

print(("checks: %d   failures: %d"):format(checks, #fails))
for _, f in ipairs(fails) do print("  FAIL  " .. f) end
print("runtime errors: " .. #(H.errors or {}))
end
