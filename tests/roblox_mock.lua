--[[
	roblox_mock.lua — a faithful-enough Roblox engine mock to run the REAL Forge source
	(Bridge.lua, Protocol.lua, Store.lua) unmodified under the standalone `luau` runtime.

	The goal is fidelity on the semantics the protocol actually depends on:

	  * Attributes: SetAttribute / GetAttribute, and crucially GetAttributeChangedSignal —
	    which fires ONLY for attribute changes (NOT Instance.Changed). This distinction is
	    the entire reason the bridge watches State/Progress with AttributeChangedSignal.
	  * Properties: StringValue.Value with a .Changed signal that fires on property change
	    (and NOT on attribute change) — the mirror of the rule above.
	  * Hierarchy: Parent, GetChildren, FindFirstChild, ChildAdded/ChildRemoved, Destroy,
	    IsA (with a tiny class table so Folder/StringValue resolve).
	  * Services: ServerStorage (a real Instance), HttpService (JSONEncode/Decode/GenerateGUID),
	    Selection.
	  * Globals: task.spawn/defer/wait (cooperative, driven by a manual scheduler), os.time
	    (a controllable clock), a `plugin` object with Set/GetSetting persistence.

	A cooperative scheduler models Roblox's single-threaded, run-to-completion event model:
	signal handlers run synchronously to completion (so check-and-set is atomic), while
	task.spawn/defer/wait queue work the test drains explicitly. This lets tests assert on
	ordering and on the deferred-reap behaviour precisely.
]]

local JSON = require("./json")

local Mock = {}

-- ── controllable clock ──────────────────────────────────────────────────────
local clock = { now = 1_000_000 }
function Mock.setTime(t)
	clock.now = t
end
function Mock.advanceTime(dt)
	clock.now = clock.now + dt
end

-- ── cooperative scheduler ────────────────────────────────────────────────────
-- Roblox runs event handlers synchronously; task.spawn/defer/wait reschedule. We model
-- spawn/defer as a FIFO drained by Mock.drain(); wait yields a coroutine that drain resumes.
local deferred = {} -- { fn } queued by task.defer / task.spawn body after a wait
local sleepers = {} -- { co=thread, wake=clock-deadline } parked by task.wait

local scheduler = {}

local function enqueue(fn)
	table.insert(deferred, fn)
end

--- Clear all parked work and sleepers. Used by the test harness between scenarios so a
--- prior bridge's heartbeat coroutine can't wake during the next test.
function Mock.resetScheduler()
	deferred = {}
	sleepers = {}
end

--- Drain all ready work: deferred callbacks, then any sleepers whose wait elapsed.
--- maxRounds guards against runaway loops (the heartbeat thread loops forever, so tests
--- cap how many ticks they pump).
function Mock.drain(maxRounds)
	maxRounds = maxRounds or 1000
	local rounds = 0
	while (#deferred > 0) and rounds < maxRounds do
		rounds = rounds + 1
		local batch = deferred
		deferred = {}
		for _, fn in ipairs(batch) do
			fn()
		end
	end
end

--- Advance time by dt and wake any task.wait sleepers whose deadline passed (resuming
--- the heartbeat loop body). Returns how many sleepers woke.
function Mock.tick(dt)
	Mock.advanceTime(dt)
	local woke = 0
	local still = {}
	for _, s in ipairs(sleepers) do
		if clock.now >= s.wake then
			woke = woke + 1
			coroutine.resume(s.co)
		else
			table.insert(still, s)
		end
	end
	sleepers = still
	Mock.drain()
	return woke
end

-- ── signal ───────────────────────────────────────────────────────────────────
local Signal = {}
Signal.__index = Signal
function Signal.new()
	return setmetatable({ _handlers = {} }, Signal)
end
function Signal:Connect(fn)
	local h = { fn = fn, connected = true }
	table.insert(self._handlers, h)
	local conn = {}
	function conn:Disconnect()
		h.connected = false
	end
	conn.Connected = true
	return conn
end
function Signal:Fire(...)
	-- Snapshot so a handler disconnecting mid-fire doesn't skip/repeat handlers.
	local snapshot = {}
	for _, h in ipairs(self._handlers) do
		snapshot[#snapshot + 1] = h
	end
	for _, h in ipairs(snapshot) do
		if h.connected then
			h.fn(...)
		end
	end
	-- Compact disconnected handlers.
	local live = {}
	for _, h in ipairs(self._handlers) do
		if h.connected then
			live[#live + 1] = h
		end
	end
	self._handlers = live
end

-- ── instance ───────────────────────────────────────────────────────────────────
local Instance = {}
Instance.__index = Instance

-- Minimal class hierarchy for IsA.
local ISA = {
	Folder = { Folder = true, Instance = true },
	StringValue = { StringValue = true, ValueBase = true, Instance = true },
	ServerStorage = { ServerStorage = true, Instance = true },
}

local function newInstance(className)
	local self = setmetatable({}, Instance)
	self.ClassName = className
	self.Name = className
	self.Archivable = true
	self._attributes = {}
	self._attrSignals = {} -- name -> Signal
	self._children = {}
	self._parent = nil
	self._destroyed = false
	-- Property change signals.
	self.Changed = Signal.new() -- fires (property, value) on a property change
	self.ChildAdded = Signal.new()
	self.ChildRemoved = Signal.new()
	-- StringValue value with change notification.
	if className == "StringValue" then
		self._value = ""
	end
	return self
end

-- A custom metatable intercepts Value/Parent writes so `inst.Value = x` fires .Changed
-- and `inst.Parent = p` maintains the child list + fires ChildAdded/ChildRemoved, exactly
-- like the Roblox engine. All other fields read/write rawly.
local rawget, rawset = rawget, rawset
local function makeMeta()
	return {
		__index = function(self, k)
			if k == "Value" then
				return rawget(self, "_value")
			elseif k == "Parent" then
				return rawget(self, "_parent")
			end
			return Instance[k] or rawget(self, k)
		end,
		__newindex = function(self, k, v)
			if k == "Value" then
				local old = rawget(self, "_value")
				rawset(self, "_value", v)
				if old ~= v then
					rawget(self, "Changed"):Fire(v)
				end
			elseif k == "Parent" then
				local oldParent = rawget(self, "_parent")
				if oldParent == v then
					rawset(self, "_parent", v)
					return
				end
				if oldParent then
					-- remove from old parent's children
					local kids = rawget(oldParent, "_children")
					for i, c in ipairs(kids) do
						if c == self then
							table.remove(kids, i)
							break
						end
					end
					rawget(oldParent, "ChildRemoved"):Fire(self)
				end
				rawset(self, "_parent", v)
				if v then
					table.insert(rawget(v, "_children"), self)
					rawget(v, "ChildAdded"):Fire(self)
				end
			else
				rawset(self, k, v)
			end
		end,
	}
end

function Instance.new(className)
	local self = newInstance(className)
	return setmetatable(self, makeMeta())
end

function Instance:SetAttribute(name, value)
	local old = self._attributes[name]
	self._attributes[name] = value
	if old ~= value then
		local sig = self._attrSignals[name]
		if sig then
			sig:Fire()
		end
	end
end

function Instance:GetAttribute(name)
	return self._attributes[name]
end

function Instance:GetAttributeChangedSignal(name)
	local sig = self._attrSignals[name]
	if not sig then
		sig = Signal.new()
		self._attrSignals[name] = sig
	end
	return sig
end

function Instance:FindFirstChild(name)
	for _, c in ipairs(self._children) do
		if c.Name == name then
			return c
		end
	end
	return nil
end

function Instance:FindFirstChildOfClass(className)
	for _, c in ipairs(self._children) do
		if c.ClassName == className then
			return c
		end
	end
	return nil
end

function Instance:GetChildren()
	local out = {}
	for _, c in ipairs(self._children) do
		out[#out + 1] = c
	end
	return out
end

function Instance:IsA(className)
	local set = ISA[self.ClassName]
	return set ~= nil and set[className] == true
end

function Instance:Destroy()
	self._destroyed = true
	-- Destroy descendants.
	for _, c in ipairs(self:GetChildren()) do
		c:Destroy()
	end
	-- Detach from parent (fires ChildRemoved).
	if self._parent then
		self.Parent = nil
	end
end

-- ── services ────────────────────────────────────────────────────────────────────
local ServerStorage = Instance.new("ServerStorage")
ServerStorage.Name = "ServerStorage"

local HttpService = {}
function HttpService:JSONEncode(v)
	return JSON.encode(v)
end
function HttpService:JSONDecode(s)
	return JSON.decode(s)
end
local guidCounter = 0
function HttpService:GenerateGUID(_withBraces)
	guidCounter = guidCounter + 1
	return string.format("MOCKGUID-%08d", guidCounter)
end

local Selection = {}
local selectionSet = {}
function Selection:Get()
	return selectionSet
end
function Mock.setSelection(list)
	selectionSet = list
end

local services = {
	ServerStorage = ServerStorage,
	HttpService = HttpService,
	Selection = Selection,
}

local game = {}
function game:GetService(name)
	local s = services[name]
	assert(s, "mock: unknown service " .. tostring(name))
	return s
end

-- ── plugin ────────────────────────────────────────────────────────────────────
local pluginSettings = {}
local pluginObj = {}
function pluginObj:SetSetting(k, v)
	pluginSettings[k] = v
end
function pluginObj:GetSetting(k)
	return pluginSettings[k]
end
function Mock.resetPluginSettings()
	pluginSettings = {}
end
function Mock.getPluginSetting(k)
	return pluginSettings[k]
end

-- ── globals injected into the sandbox ────────────────────────────────────────────
local task = {}
function task.spawn(fn)
	-- Run synchronously up to the first yield (matches Roblox), inside a coroutine so
	-- task.wait can yield it.
	local co = coroutine.create(fn)
	coroutine.resume(co)
	return co
end
function task.defer(fn)
	enqueue(fn)
end
function task.wait(seconds)
	seconds = seconds or 0
	local co = coroutine.running()
	table.insert(sleepers, { co = co, wake = clock.now + seconds })
	coroutine.yield()
	return seconds
end

local osMock = {}
function osMock.time()
	return clock.now
end
osMock.clock = function()
	return clock.now
end
osMock.date = os.date

-- BrickColor mock (StyleRef/App use BrickColor.new; tests for those are payload-level).
local BrickColor = {}
function BrickColor.new(name)
	return { Name = name, Color = { r = 0.5, g = 0.5, b = 0.5 } }
end

Mock.Instance = Instance
Mock.game = game
Mock.plugin = pluginObj
Mock.task = task
Mock.os = osMock
Mock.HttpService = HttpService
Mock.ServerStorage = ServerStorage
Mock.Selection = Selection
Mock.BrickColor = BrickColor
Mock.Signal = Signal

return Mock
