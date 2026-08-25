do
local R = RIG local H = R.H
H.pump(40000)
local L = R.genvTable.LUCK

-- SERVER A: atomic check-and-set. No yield between reading and writing.
local function atomic()
    local last = -math.huge
    return function()
        local now = H.virtualNow()
        if now - last < 5 then return false, "Please wait before trying to redeem another Code" end
        last = now
        return false, "Invalid Code"
    end
end

-- SERVER B: yields between the read and the write, like a DataStore call would.
local function yielding()
    local last = -math.huge
    return function()
        local now = H.virtualNow()
        local seen = last
        if now - seen < 5 then return false, "Please wait before trying to redeem another Code" end
        task.wait(0.05)              -- the gap
        last = now
        return false, "Invalid Code"
    end
end

for name, mk in pairs({["ATOMIC server"] = atomic, ["YIELDING server"] = yielding}) do
    R.setInvokeBehaviour(mk())
    print(("================ %s ================"):format(name))
    task.spawn(PROBE_RUN)
    H.pump(400000)
    print("")
end
R.setInvokeBehaviour(nil)
end
