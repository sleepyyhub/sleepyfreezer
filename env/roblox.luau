--[[
    Minimal Roblox client shim, enough to load and run LUCK.txt for real.

    The point is timing fidelity, not graphics. What is modelled honestly:

      * a cooperative scheduler with real coroutines (task.spawn/wait/defer/delay)
      * a frame loop at a configurable FPS with RenderStepped -> defer flush ->
        Heartbeat -> network step, in that order
      * SignalBehavior: Deferred queues callbacks to the next resumption point,
        Immediate runs them inline — switchable, because it is worth ~half a frame
      * replication that is frame-aligned in BOTH directions, with a configurable
        one-way wire delay, because that is where the milliseconds actually go
      * a HYBRID CLOCK: os.clock() returns (real CPU burned) + (simulated delay).
        Real work the script does counts against the frame budget, exactly as it
        would on a device. So the CPU numbers in a run are genuinely measured;
        only the network and frame cadence are simulated.

    What is faked and does not pretend otherwise: rendering, input, physics,
    and the cost of engine-side property writes (here they are Lua table stores,
    on a real client they cross into C++).
]]

local Env = {}

--------------------------------------------------------------------------------
-- clock
--------------------------------------------------------------------------------
local REAL = os.clock
local realAnchor = REAL()
local vt = 0.0 -- accumulated simulated delay, seconds

local function now()
	return (REAL() - realAnchor) + vt
end
Env.now = now
Env.advance = function(dt) vt += dt end
Env.simulated = function() return vt end
Env.realBurned = function() return REAL() - realAnchor end

--------------------------------------------------------------------------------
-- config
--------------------------------------------------------------------------------
local CFG = {
	fps = 60,
	pingMs = 40,          -- round trip
	serverThinkMs = 2,    -- how long the server takes to answer a redeem
	signalBehavior = "Deferred",
	jitterMs = 0,         -- +/- on each wire hop
}
Env.CFG = CFG
-- Per client. Two racers rarely sit on the same route, and a 2 ms difference
-- in round trip is the whole margin at high frame rates -- sharing one global
-- ping would quietly erase exactly the thing being tested.
local rivalRef
local function pingOf(cid)
	if cid == 2 and rivalRef and rivalRef.pingMs then return rivalRef.pingMs end
	return CFG.pingMs
end
local function oneWay(cid) return (pingOf(cid) / 2) / 1000 end
Env.pingOf = pingOf
local function jitter()
	if CFG.jitterMs <= 0 then return 0 end
	return ((math.random() * 2) - 1) * CFG.jitterMs / 1000
end

--------------------------------------------------------------------------------
-- scheduler
--------------------------------------------------------------------------------
local sleepers = {}   -- { co = thread, at = time, args = {...} }
local deferQ = {}
local deferN = 0

local function schedule(co, at, args)
	sleepers[#sleepers + 1] = { co = co, at = at, args = args }
end

local resumeThread
resumeThread = function(co, args)
	local ok, err
	if args then
		ok, err = coroutine.resume(co, table.unpack(args, 1, args.n or #args))
	else
		ok, err = coroutine.resume(co)
	end
	if not ok then
		Env.onError(err)
	end
end

Env.onError = function(err)
	print("[thread error] " .. tostring(err))
end

local function pushDefer(fn, args)
	deferN += 1
	deferQ[deferN] = { fn = fn, args = args }
end

local function flushDefer()
	local guard = 0
	while deferN > 0 do
		guard += 1
		if guard > 100000 then break end
		local batch, n = deferQ, deferN
		deferQ, deferN = {}, 0
		for i = 1, n do
			local item = batch[i]
			local co = coroutine.create(item.fn)
			resumeThread(co, item.args)
		end
	end
end
Env.flushDefer = flushDefer

-- wake every sleeper whose deadline has passed
local function runReady()
	local moved = true
	while moved do
		moved = false
		local t = now()
		local keep = {}
		local fire = {}
		for _, s in ipairs(sleepers) do
			if s.at <= t then fire[#fire + 1] = s else keep[#keep + 1] = s end
		end
		if #fire > 0 then
			sleepers = keep
			moved = true
			for _, s in ipairs(fire) do
				resumeThread(s.co, s.args)
			end
		end
	end
end

-- push the simulated clock forward to the next scheduled thing
local function nextDeadline()
	local lo = nil
	for _, s in ipairs(sleepers) do
		if not lo or s.at < lo then lo = s.at end
	end
	return lo
end

local task = {}

function task.wait(d)
	d = d or 0
	local co = coroutine.running()
	schedule(co, now() + d)
	coroutine.yield()
	return d
end

function task.spawn(fn, ...)
	local co = type(fn) == "thread" and fn or coroutine.create(fn)
	resumeThread(co, table.pack(...))
	return co
end

function task.defer(fn, ...)
	if type(fn) == "thread" then
		local co = fn
		local args = table.pack(...)
		pushDefer(function() resumeThread(co, args) end)
		return co
	end
	pushDefer(fn, table.pack(...))
	return nil
end

function task.delay(d, fn, ...)
	local args = table.pack(...)
	local co = coroutine.create(function() fn(table.unpack(args, 1, args.n)) end)
	schedule(co, now() + (d or 0))
	return co
end

function task.cancel(co)
	for i, s in ipairs(sleepers) do
		if s.co == co then table.remove(sleepers, i) return end
	end
end

function task.synchronize() end
function task.desynchronize() end
Env.task = task

--------------------------------------------------------------------------------
-- signals
--------------------------------------------------------------------------------
local Signal = {}
Signal.__index = Signal

local function newSignal(name)
	return setmetatable({ _name = name, _conns = {}, _waiters = {} }, Signal)
end
Env.newSignal = newSignal

function Signal:Connect(fn)
	local c = { Function = fn, Connected = true, _sig = self }
	function c:Disconnect()
		self.Connected = false
		for i, v in ipairs(self._sig._conns) do
			if v == self then table.remove(self._sig._conns, i) break end
		end
	end
	c.disconnect = c.Disconnect
	self._conns[#self._conns + 1] = c
	return c
end
Signal.connect = Signal.Connect
Signal.Once = function(self, fn)
	local c
	c = self:Connect(function(...) c:Disconnect() fn(...) end)
	return c
end

function Signal:Wait()
	local co = coroutine.running()
	self._waiters[#self._waiters + 1] = co
	return coroutine.yield()
end

-- deliver: honours SignalBehavior
function Signal:Fire(...)
	local args = table.pack(...)
	local conns = table.clone(self._conns)
	local waiters = self._waiters
	self._waiters = {}

	if CFG.signalBehavior == "Immediate" then
		for _, c in ipairs(conns) do
			if c.Connected then
				local co = coroutine.create(c.Function)
				resumeThread(co, args)
			end
		end
	else
		for _, c in ipairs(conns) do
			if c.Connected then
				pushDefer(c.Function, args)
			end
		end
	end
	for _, co in ipairs(waiters) do
		schedule(co, now(), args)
	end
end
Signal.fire = Signal.Fire

-- bypasses SignalBehavior entirely; this is what the executor's firesignal does
function Signal:FireSync(...)
	local args = table.pack(...)
	for _, c in ipairs(table.clone(self._conns)) do
		if c.Connected then
			local co = coroutine.create(c.Function)
			resumeThread(co, args)
		end
	end
end

--------------------------------------------------------------------------------
-- datatypes
--------------------------------------------------------------------------------
local function struct(name, fields)
	local M = {}
	M.__index = M
	M.__tostring = function() return name end
	return M
end

local UDim = struct("UDim")
UDim.new = function(s, o) return setmetatable({ Scale = s or 0, Offset = o or 0 }, UDim) end

local UDim2 = struct("UDim2")
UDim2.new = function(xs, xo, ys, yo)
	return setmetatable({ X = UDim.new(xs, xo), Y = UDim.new(ys, yo) }, UDim2)
end
UDim2.fromOffset = function(x, y) return UDim2.new(0, x, 0, y) end
UDim2.fromScale = function(x, y) return UDim2.new(x, 0, y, 0) end

local Color3 = struct("Color3")
Color3.__index = Color3
function Color3:Lerp(other, a)
	return Color3.new(self.R + (other.R - self.R) * a,
		self.G + (other.G - self.G) * a,
		self.B + (other.B - self.B) * a)
end
Color3.new = function(r, g, b) return setmetatable({ R = r or 0, G = g or 0, B = b or 0 }, Color3) end
Color3.fromRGB = function(r, g, b) return Color3.new((r or 0) / 255, (g or 0) / 255, (b or 0) / 255) end
Color3.fromHSV = function(h, s, v) return Color3.new(h, s, v) end

local Vector2 = struct("Vector2")
Vector2.new = function(x, y) return setmetatable({ X = x or 0, Y = y or 0, Magnitude = 0 }, Vector2) end

local Vector3 = struct("Vector3")
Vector3.new = function(x, y, z) return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, Vector3) end

local Rect = struct("Rect")
Rect.new = function(a, b, c, d) return setmetatable({}, Rect) end

local CSK = struct("ColorSequenceKeypoint")
CSK.new = function(t, c) return setmetatable({ Time = t, Value = c }, CSK) end
local ColorSequence = struct("ColorSequence")
ColorSequence.new = function(a, b) return setmetatable({ Keypoints = type(a) == "table" and a or { a, b } }, ColorSequence) end

local NSK = struct("NumberSequenceKeypoint")
NSK.new = function(t, v) return setmetatable({ Time = t, Value = v }, NSK) end
local NumberSequence = struct("NumberSequence")
NumberSequence.new = function(a, b) return setmetatable({ Keypoints = type(a) == "table" and a or { a, b } }, NumberSequence) end

local TweenInfo = struct("TweenInfo")
TweenInfo.new = function(t, style, dir, reps, rev, delay)
	return setmetatable({ Time = t or 1, EasingStyle = style, EasingDirection = dir }, TweenInfo)
end

--------------------------------------------------------------------------------
-- Enum
--------------------------------------------------------------------------------
local EnumItem = {}
EnumItem.__index = EnumItem
EnumItem.__tostring = function(s) return "Enum." .. s.EnumType .. "." .. s.Name end

local Enum = setmetatable({}, {
	__index = function(self, enumType)
		local e = setmetatable({}, {
			__index = function(_, name)
				local item = setmetatable(
					{ Name = name, Value = 0, EnumType = enumType }, EnumItem)
				return item
			end,
		})
		rawset(self, enumType, e)
		return e
	end,
})

--------------------------------------------------------------------------------
-- Instance
--------------------------------------------------------------------------------
local CLASS_PARENTS = {
	Frame = "GuiObject", TextLabel = "GuiObject", TextButton = "GuiObject",
	TextBox = "GuiObject", ImageLabel = "GuiObject", ImageButton = "GuiObject",
	ScrollingFrame = "Frame", CanvasGroup = "GuiObject", ViewportFrame = "GuiObject",
	GuiObject = "GuiBase2d", GuiBase2d = "Instance", ScreenGui = "LayerCollector",
	LayerCollector = "GuiBase2d",
	UICorner = "UIComponent", UIStroke = "UIComponent", UIGradient = "UIComponent",
	UIListLayout = "UILayout", UIPadding = "UIComponent", UIAspectRatioConstraint = "UIComponent",
	UISizeConstraint = "UIComponent", UITextSizeConstraint = "UIComponent",
	UILayout = "UIComponent", UIComponent = "Instance",
	RemoteEvent = "Instance", RemoteFunction = "Instance", BindableEvent = "Instance",
	ModuleScript = "LuaSourceContainer", LocalScript = "LuaSourceContainer",
	LuaSourceContainer = "Instance", Folder = "Instance",
	Player = "Instance", PlayerGui = "BasePlayerGui", BasePlayerGui = "Instance",
	Players = "Instance", ReplicatedStorage = "Instance", Camera = "Instance",
}

local GUI_SIGNALS = {
	"MouseButton1Click", "MouseButton1Down", "MouseButton1Up", "MouseButton2Click",
	"Activated", "MouseEnter", "MouseLeave", "MouseMoved",
	"InputBegan", "InputChanged", "InputEnded",
	"FocusLost", "Focused", "SelectionGained",
}
local CORE_SIGNALS = {
	"Changed", "AncestryChanged", "ChildAdded", "ChildRemoved",
	"DescendantAdded", "Destroying", "AttributeChanged",
}

local InstanceMT = {}
local function isInstance(v)
	return type(v) == "table" and getmetatable(v) == InstanceMT
end

local instanceMethods = {}

local function newInstance(cls)
	local self = {}
	local o = setmetatable(self, InstanceMT)
	rawset(self, "__class", cls)
	rawset(self, "__props", {
		Name = cls, Parent = nil, ClassName = cls,
		Text = "", Visible = true, Value = 0, LayoutOrder = 0, ZIndex = 1,
		BackgroundTransparency = 0, TextTransparency = 0, Transparency = 0,
		AbsoluteSize = Vector2.new(400, 300), AbsolutePosition = Vector2.new(0, 0),
		Archivable = true, Active = false, Enabled = true,
	})
	rawset(self, "__children", {})
	rawset(self, "__signals", {})
	rawset(self, "__attrs", {})
	rawset(self, "__propSignals", {})
	return o
end

local function signalOf(inst, name)
	local sigs = rawget(inst, "__signals")
	local s = sigs[name]
	if not s then
		s = newSignal(name)
		sigs[name] = s
	end
	return s
end

local function isA(inst, cls)
	local c = rawget(inst, "__class")
	while c do
		if c == cls then return true end
		c = CLASS_PARENTS[c]
	end
	return cls == "Instance"
end

function instanceMethods:IsA(cls) return isA(self, cls) end
function instanceMethods:GetChildren() return table.clone(rawget(self, "__children")) end
function instanceMethods:GetDescendants()
	local out = {}
	local function walk(node)
		for _, c in ipairs(rawget(node, "__children")) do
			out[#out + 1] = c
			walk(c)
		end
	end
	walk(self)
	return out
end
function instanceMethods:FindFirstChild(name, recursive)
	for _, c in ipairs(rawget(self, "__children")) do
		if rawget(c, "__props").Name == name then return c end
	end
	if recursive then
		for _, c in ipairs(rawget(self, "__children")) do
			local hit = instanceMethods.FindFirstChild(c, name, true)
			if hit then return hit end
		end
	end
	return nil
end
function instanceMethods:FindFirstChildOfClass(cls)
	for _, c in ipairs(rawget(self, "__children")) do
		if rawget(c, "__class") == cls then return c end
	end
	return nil
end
function instanceMethods:FindFirstChildWhichIsA(cls, recursive)
	for _, c in ipairs(rawget(self, "__children")) do
		if isA(c, cls) then return c end
	end
	if recursive then
		for _, c in ipairs(rawget(self, "__children")) do
			local hit = instanceMethods.FindFirstChildWhichIsA(c, cls, true)
			if hit then return hit end
		end
	end
	return nil
end
function instanceMethods:IsDescendantOf(other)
	local p = rawget(self, "__props").Parent
	while p do
		if p == other then return true end
		p = rawget(p, "__props").Parent
	end
	return false
end
function instanceMethods:IsAncestorOf(other)
	if not isInstance(other) then return false end
	return instanceMethods.IsDescendantOf(other, self)
end
function instanceMethods:FindFirstAncestorOfClass(cls)
	local p = rawget(self, "__props").Parent
	while p do
		if rawget(p, "__class") == cls then return p end
		p = rawget(p, "__props").Parent
	end
	return nil
end
function instanceMethods:FindFirstAncestorWhichIsA(cls)
	local p = rawget(self, "__props").Parent
	while p do
		if isA(p, cls) then return p end
		p = rawget(p, "__props").Parent
	end
	return nil
end

function instanceMethods:FindFirstAncestor(name)
	local p = rawget(self, "__props").Parent
	while p do
		if rawget(p, "__props").Name == name then return p end
		p = rawget(p, "__props").Parent
	end
	return nil
end
function instanceMethods:WaitForChild(name, timeout)
	local hit = instanceMethods.FindFirstChild(self, name)
	if hit then return hit end
	local deadline = now() + (timeout or 10)
	while now() < deadline do
		task.wait(0.03)
		hit = instanceMethods.FindFirstChild(self, name)
		if hit then return hit end
	end
	return nil
end
function instanceMethods:Destroy()
	local props = rawget(self, "__props")
	local parent = props.Parent
	if parent then
		local sibs = rawget(parent, "__children")
		for i, c in ipairs(sibs) do if c == self then table.remove(sibs, i) break end end
	end
	props.Parent = nil
	signalOf(self, "Destroying"):Fire()
	signalOf(self, "AncestryChanged"):Fire(self, nil)
	for _, c in ipairs(table.clone(rawget(self, "__children"))) do
		instanceMethods.Destroy(c)
	end
end
function instanceMethods:ClearAllChildren()
	for _, c in ipairs(table.clone(rawget(self, "__children"))) do
		instanceMethods.Destroy(c)
	end
end
function instanceMethods:Clone()
	local copy = newInstance(rawget(self, "__class"))
	for k, v in pairs(rawget(self, "__props")) do
		if k ~= "Parent" then rawget(copy, "__props")[k] = v end
	end
	for _, c in ipairs(rawget(self, "__children")) do
		local cc = instanceMethods.Clone(c)
		rawget(cc, "__props").Parent = copy
		table.insert(rawget(copy, "__children"), cc)
	end
	return copy
end
function instanceMethods:GetPropertyChangedSignal(prop)
	local ps = rawget(self, "__propSignals")
	if not ps[prop] then ps[prop] = newSignal(prop) end
	return ps[prop]
end
function instanceMethods:GetAttribute(k) return rawget(self, "__attrs")[k] end
function instanceMethods:SetAttribute(k, v) rawget(self, "__attrs")[k] = v end
function instanceMethods:GetAttributes() return table.clone(rawget(self, "__attrs")) end
function instanceMethods:GetFullName()
	local parts, node = {}, self
	while node do
		table.insert(parts, 1, rawget(node, "__props").Name)
		node = rawget(node, "__props").Parent
	end
	return table.concat(parts, ".")
end
-- Present so a pcall'd path fails for a real reason rather than on a missing
-- method. A silently swallowed "attempt to call missing method" is how this
-- harness once made a build look like it took 10 s to arm.
function instanceMethods:CaptureFocus() end
function instanceMethods:ReleaseFocus() end
function instanceMethods:Disable() end
function instanceMethods:Enable() end
function instanceMethods:AddTag() end
function instanceMethods:GetTags() return {} end
function instanceMethods:TweenSize() end
function instanceMethods:TweenPosition() end

InstanceMT.__index = function(self, key)
	local m = instanceMethods[key]
	if m then return m end
	local props = rawget(self, "__props")
	if props[key] ~= nil then return props[key] end
	local sigs = rawget(self, "__signals")
	if sigs[key] then return sigs[key] end
	for _, s in ipairs(CORE_SIGNALS) do
		if s == key then return signalOf(self, key) end
	end
	for _, s in ipairs(GUI_SIGNALS) do
		if s == key then return signalOf(self, key) end
	end
	local child = instanceMethods.FindFirstChild(self, key)
	if child then return child end
	-- unknown property: report nil rather than exploding, the script pcalls a lot
	return nil
end

InstanceMT.__newindex = function(self, key, value)
	local props = rawget(self, "__props")
	if key == "Parent" then
		local old = props.Parent
		if old then
			local sibs = rawget(old, "__children")
			for i, c in ipairs(sibs) do if c == self then table.remove(sibs, i) break end end
		end
		props.Parent = value
		if value then
			table.insert(rawget(value, "__children"), self)
			signalOf(value, "ChildAdded"):Fire(self)
		end
		signalOf(self, "AncestryChanged"):Fire(self, value)
		return
	end
	local prev = props[key]
	props[key] = value
	if prev ~= value then
		local ps = rawget(self, "__propSignals")[key]
		if ps then ps:Fire() end
		local ch = rawget(self, "__signals")["Changed"]
		if ch then ch:Fire(key) end
	end
end

InstanceMT.__tostring = function(self) return rawget(self, "__props").Name end

local Instance = {}
function Instance.new(cls, parent)
	local i = newInstance(cls)
	if parent then i.Parent = parent end
	return i
end
Env.Instance = Instance
Env.newInstance = newInstance
Env.isInstance = isInstance
Env.signalOf = signalOf

local function typeofFn(v)
	if isInstance(v) then return "Instance" end
	local mt = getmetatable(v)
	if mt == Color3 then return "Color3" end
	if mt == UDim2 then return "UDim2" end
	if mt == EnumItem then return "EnumItem" end
	return type(v)
end
Env.typeofFn = typeofFn

--------------------------------------------------------------------------------
-- replication: frame-aligned in both directions, configurable wire delay
--------------------------------------------------------------------------------
-- One queue pair PER CLIENT. A code race is two clients on their own frame
-- grids, so they cannot share an inbox or the phase difference vanishes.
local nets = {}
local function netOf(cid)
	cid = cid or 1
	local n = nets[cid]
	if not n then n = { out = {}, inn = {} }; nets[cid] = n end
	return n
end
Env.netOf = netOf

Env.stats = {
	packetsOut = 0, packetsIn = 0,
}

-- server-side handlers, keyed by remote instance
local serverHandlers = setmetatable({}, { __mode = "k" })
Env.serverHandlers = serverHandlers

Env.queueToServer = function(remote, kind, payload, replyTo, cid)
	local out = netOf(cid).out
	out[#out + 1] = {
		remote = remote, kind = kind, payload = payload,
		replyTo = replyTo, queuedAt = now(), cid = cid or 1,
	}
end

Env.queueToClient = function(signal, args, sentAt, cid, extraDelay)
	local inn = netOf(cid).inn
	inn[#inn + 1] = {
		signal = signal, args = args,
		arriveAt = (sentAt or now()) + oneWay(cid) + jitter() + (extraDelay or 0),
	}
end

local function networkStep(cid)
	local net = netOf(cid)
	-- outgoing: everything queued this frame goes on the wire now
	if #net.out > 0 then
		local batch = net.out
		net.out = {}
		local flushAt = now()
		for _, pkt in ipairs(batch) do
			Env.stats.packetsOut += 1
			local arriveAt = flushAt + oneWay(pkt.cid) + jitter()
			local handler = serverHandlers[pkt.remote]
			-- the server thread: wakes when the packet lands
			task.delay(arriveAt - now(), function()
				local reply
				if handler then
					reply = table.pack(handler(pkt.kind, pkt.payload, arriveAt, {
						queuedAt = pkt.queuedAt, flushAt = flushAt, cid = pkt.cid,
					}))
				end
				if pkt.replyTo then
					local think = CFG.serverThinkMs / 1000
					task.delay(think, function()
						Env.queueToClient(pkt.replyTo, reply or table.pack(), now())
					end)
				end
			end)
		end
	end
end

local function receiveStep(cid)
	local net = netOf(cid)
	if #net.inn == 0 then return end
	local t = now()
	local keep = {}
	for _, pkt in ipairs(net.inn) do
		if pkt.arriveAt <= t then
			Env.stats.packetsIn += 1
			if type(pkt.signal) == "function" then
				pkt.signal(table.unpack(pkt.args, 1, pkt.args.n or #pkt.args))
			else
				pkt.signal:Fire(table.unpack(pkt.args, 1, pkt.args.n or #pkt.args))
			end
		else
			keep[#keep + 1] = pkt
		end
	end
	net.inn = keep
end

--------------------------------------------------------------------------------
-- frame loop
--------------------------------------------------------------------------------
local RunService
local frameCount = 0
local nextFrame = nil
Env.frameCount = function() return frameCount end
-- exposed so a caller can place an event at an exact offset inside the frame
Env.nextFrameAt = function() return nextFrame end

local function runFrame()
	frameCount += 1
	receiveStep(1)         -- replication in
	flushDefer()           -- deferred signal queue drains
	RunService.RenderStepped:FireSync(1 / CFG.fps)
	flushDefer()
	RunService.Stepped:FireSync(now(), 1 / CFG.fps)
	flushDefer()
	RunService.Heartbeat:FireSync(1 / CFG.fps)
	flushDefer()
	networkStep(1)         -- replication out
	runReady()
	flushDefer()
end

--------------------------------------------------------------------------------
-- A second client, on its OWN frame grid.
--
-- Two Roblox clients on one machine do not share a frame clock. Their frame
-- boundaries sit at some fixed offset from each other, and that offset does not
-- drift while both stay up. It is the single biggest thing separating two
-- otherwise identical racers, so it gets modelled explicitly rather than
-- assumed away.
--------------------------------------------------------------------------------
local rival = nil
Env.setRival = function(cfg)
	if not cfg then rival = nil; rivalRef = nil; return end
	rival = {
		fps = cfg.fps or CFG.fps,
		pingMs = cfg.pingMs,            -- nil = same route as us
		phase = cfg.phase or 0,        -- seconds its grid leads ours by
		handler = cfg.handler,          -- function(deliveredAt) -- runs on its frame
		onFrame = cfg.onFrame,          -- function(t) -- runs every rival frame
		nextAt = nil,
		frames = 0,
	}
	nets[2] = { out = {}, inn = {} }
	rivalRef = rival
	return rival
end
Env.rival = function() return rival end

local function runRivalFrame()
	if not rival then return end
	rival.frames += 1
	receiveStep(2)
	if rival.onFrame then rival.onFrame(now()) end
	networkStep(2)
end

-- nextFrame (declared above) is the persistent frame grid. Re-anchoring it per
-- call would let the caller's own polling cadence masquerade as the client's
-- frame rate, which silently flattens any fps comparison.
-- run the world until `duration` of simulated+real time has passed
Env.run = function(duration)
	local stop = now() + duration
	if not nextFrame then nextFrame = now() end
	if rival and not rival.nextAt then
		rival.nextAt = nextFrame + rival.phase
	end
	local guard = 0
	while now() < stop do
		guard += 1
		if guard > 2000000 then break end

		local frameDt = 1 / CFG.fps
		local rivalDt = rival and (1 / rival.fps) or nil

		local deadline = nextDeadline()
		local target = nextFrame
		if rival and rival.nextAt < target then target = rival.nextAt end
		if deadline and deadline < target then target = deadline end
		if target > stop then target = stop end

		local need = target - now()
		if need > 0 then vt += need end

		runReady()

		-- whichever grid is due fires; ties go to us, which is the pessimistic
		-- reading and keeps the result from flattering the script under test
		if rival and now() >= rival.nextAt - 1e-9 then
			runRivalFrame()
			rival.nextAt += rivalDt
			if rival.nextAt < now() then rival.nextAt = now() + rivalDt end
		end
		if now() >= nextFrame - 1e-9 then
			runFrame()
			nextFrame += frameDt
			if nextFrame < now() then nextFrame = now() + frameDt end
		end
	end
end

--------------------------------------------------------------------------------
-- services
--------------------------------------------------------------------------------
RunService = newInstance("RunService")
RunService.Name = "RunService"
rawget(RunService, "__signals").Heartbeat = newSignal("Heartbeat")
rawget(RunService, "__signals").RenderStepped = newSignal("RenderStepped")
rawget(RunService, "__signals").Stepped = newSignal("Stepped")
rawget(RunService, "__signals").PreRender = rawget(RunService, "__signals").RenderStepped
instanceMethods.IsClient = function() return true end
instanceMethods.IsServer = function() return false end
instanceMethods.IsStudio = function() return false end
instanceMethods.BindToRenderStep = function() end
instanceMethods.Set3dRenderingEnabled = function() return true end
instanceMethods.UnbindFromRenderStep = function() end
Env.RunService = RunService

local TweenService = newInstance("TweenService")
instanceMethods.Create = function(self, inst, info, goal)
	local tween = newInstance("Tween")
	rawget(tween, "__props").TweenInfo = info
	rawget(tween, "__signals").Completed = newSignal("Completed")
	rawget(tween, "__props").Play = function()
		-- apply the goal immediately; nothing here renders, and holding the
		-- intermediate values would only add noise to the timing
		for k, v in pairs(goal or {}) do
			pcall(function() inst[k] = v end)
		end
		local sig = rawget(tween, "__signals").Completed
		task.delay(info and info.Time or 0, function() sig:Fire() end)
	end
	rawget(tween, "__props").Cancel = function() end
	rawget(tween, "__props").Pause = function() end
	return tween
end
Env.TweenService = TweenService

local HttpService = newInstance("HttpService")

local Stats = newInstance("Stats")
do
	local net = newInstance("Network")
	net.Name = "Network"
	net.Parent = Stats
	local ssi = newInstance("ServerStatsItem")
	ssi.Name = "ServerStatsItem"
	ssi.Parent = net
	local ping = newInstance("Stat")
	ping.Name = "Data Ping"
	rawget(ping, "__props").GetValue = function() return CFG.pingMs end
	ping.Parent = ssi
	-- Stats.Network.ServerStatsItem["Data Ping"] must index by string
	rawget(net, "__props").ServerStatsItem = setmetatable({}, {
		__index = function(_, k)
			if k == "Data Ping" then return { GetValue = function() return CFG.pingMs end } end
			return { GetValue = function() return 0 end }
		end,
	})
end
Env.Stats = Stats

local Lighting = newInstance("Lighting")
local CoreGui = newInstance("CoreGui")

local UserInputService = newInstance("UserInputService")
rawget(UserInputService, "__props").TouchEnabled = false
rawget(UserInputService, "__props").MouseEnabled = true
rawget(UserInputService, "__props").KeyboardEnabled = true
rawget(UserInputService, "__props").GetPlatform = function() return Enum.Platform.Windows end
rawget(UserInputService, "__signals").InputBegan = newSignal("InputBegan")
rawget(UserInputService, "__signals").InputEnded = newSignal("InputEnded")
rawget(UserInputService, "__signals").InputChanged = newSignal("InputChanged")
Env.UserInputService = UserInputService

Env.Enum = Enum
Env.datatypes = {
	UDim = UDim, UDim2 = UDim2, Color3 = Color3, Vector2 = Vector2, Vector3 = Vector3,
	Rect = Rect, ColorSequence = ColorSequence, ColorSequenceKeypoint = CSK,
	NumberSequence = NumberSequence, NumberSequenceKeypoint = NSK, TweenInfo = TweenInfo,
	Font = setmetatable({}, { __index = function(_, k) return { Name = k } end }),
}
Env.services = {
	RunService = RunService, TweenService = TweenService, HttpService = HttpService,
	Stats = Stats, Lighting = Lighting, CoreGui = CoreGui,
	UserInputService = UserInputService,
}
Env.instanceMethods = instanceMethods
Env.Signal = Signal
Env.schedule = schedule
Env.resumeThread = function(co, args) return resumeThread(co, args) end
Env.pushDefer = pushDefer
Env.oneWay = oneWay

return Env
