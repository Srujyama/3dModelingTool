--!strict
--[[
	Bridge.lua — the plugin side of the Forge mailbox.

	Responsibilities:
	  * ensureBridge()      — idempotently (re)create ServerStorage/ForgeBridge
	  * enqueue()           — write a prompt with the commit barrier (Ready last)
	  * watch               — react to Claude's writes using the correct signals
	  * heartbeat/liveness  — one low-frequency timer; drives "connected" + stall reclaim
	  * style profile       — persist a style/palette JSON into the bridge
	  * cleanup             — destroy the bridge on plugin unload

	See docs/PROTOCOL.md for the contract and the race analysis. Field names come
	exclusively from Protocol.lua — no magic strings here.
]]

local HttpService = game:GetService("HttpService")

local Protocol = require(script.Parent.Protocol)

export type RequestView = {
	id: number,
	kind: string,
	state: string,
	progress: number,
	prompt: string,
	statusText: string,
	result: string, -- raw JSON manifest, may be ""
	createdAt: number,
	updatedAt: number,
}

export type Callbacks = {
	-- Fired when a request's state changes (also fires once on first observation).
	onRequestUpdate: ((RequestView) -> ())?,
	-- Fired when a request reaches a terminal state, right before the folder is reaped.
	onRequestTerminal: ((RequestView) -> ())?,
	-- Fired when connectivity to Claude changes (engine alive/dead).
	onConnectionChange: ((connected: boolean) -> ())?,
}

local Bridge = {}
Bridge.__index = Bridge

export type Bridge = typeof(setmetatable(
	{} :: {
		plugin: Plugin,
		callbacks: Callbacks,
		running: boolean,
		connected: boolean,
		_bridge: Folder?,
		_conns: { [Instance]: { RBXScriptConnection } },
		_rootConns: { RBXScriptConnection },
		_wiredReqs: Folder?,
		_reaping: { [Instance]: boolean },
		_heartbeatThread: thread?,
		_idFloor: number,
	},
	Bridge
))

-- plugin:SetSetting key for the request-id high-water mark. The bridge is transient
-- (Archivable=false ⇒ recreated every session) but the Store transcript — which keys
-- assistant turns on request ids — persists. So the id counter must also persist, or
-- a rebuilt bridge restarts at 1 and collides with old transcript ids. (Review C2.)
local SETTING_ID_FLOOR = "Forge_LastRequestId_v1"

local function getService(): ServerStorage
	return game:GetService(Protocol.BRIDGE_PARENT_SERVICE) :: ServerStorage
end

--- Build a plain snapshot of a request folder for the UI layer.
local function viewOf(req: Folder): RequestView
	local function str(childName: string): string
		local child = req:FindFirstChild(childName)
		if child and child:IsA("StringValue") then
			return child.Value
		end
		return ""
	end
	return {
		id = (req:GetAttribute(Protocol.Req.Id) :: number?) or 0,
		kind = (req:GetAttribute(Protocol.Req.Kind) :: string?) or Protocol.Kind.Auto,
		state = (req:GetAttribute(Protocol.Req.State) :: string?) or Protocol.State.Queued,
		progress = (req:GetAttribute(Protocol.Req.Progress) :: number?) or 0,
		prompt = str(Protocol.ReqChild.Prompt),
		statusText = str(Protocol.ReqChild.StatusText),
		result = str(Protocol.ReqChild.Result),
		createdAt = (req:GetAttribute(Protocol.Req.CreatedAt) :: number?) or 0,
		updatedAt = (req:GetAttribute(Protocol.Req.UpdatedAt) :: number?) or 0,
	}
end

function Bridge.new(plugin: Plugin, callbacks: Callbacks?): Bridge
	local self = setmetatable({}, Bridge) :: Bridge
	self.plugin = plugin
	self.callbacks = callbacks or {}
	self.running = false
	self.connected = false
	self._bridge = nil
	self._conns = {}
	self._rootConns = {}
	self._wiredReqs = nil
	self._reaping = {}
	self._heartbeatThread = nil
	-- Seed the id floor from persistent storage so ids never repeat across rebuilds.
	local stored = plugin:GetSetting(SETTING_ID_FLOOR)
	self._idFloor = (type(stored) == "number" and stored) or 0
	return self
end

-- ── bridge construction ────────────────────────────────────────────────────

--- Idempotently create (or find) the bridge tree. Safe to call repeatedly. If it
--- (re)creates the Requests folder while running, it re-establishes the watch wiring
--- so results from Claude are never stranded on a stale, destroyed folder (review C1).
function Bridge.ensureBridge(self: Bridge): Folder
	local ss = getService()
	local bridge = ss:FindFirstChild(Protocol.BRIDGE_NAME)
	local createdRequests = false

	if not bridge then
		bridge = Instance.new("Folder")
		bridge.Name = Protocol.BRIDGE_NAME
		bridge.Archivable = false
		bridge:SetAttribute(Protocol.Bridge.ProtocolVersion, Protocol.VERSION)
		bridge:SetAttribute(Protocol.Bridge.LastProcessedId, 0)
		bridge:SetAttribute(Protocol.Bridge.ClaudeHeartbeat, 0)
		bridge:SetAttribute(Protocol.Bridge.ClaudeStatus, Protocol.ClaudeStatus.Idle)
		bridge:SetAttribute(Protocol.Bridge.PluginHeartbeat, os.time())

		local style = Instance.new("StringValue")
		style.Name = Protocol.BridgeChild.StyleProfile
		style.Archivable = false
		style.Parent = bridge

		local reqs = Instance.new("Folder")
		reqs.Name = Protocol.REQUESTS_FOLDER
		reqs.Archivable = false
		reqs.Parent = bridge
		createdRequests = true

		bridge.Parent = ss
	end
	bridge = bridge :: Folder

	-- Seed LastRequestId to the high-water mark — never below ids we've already issued
	-- (which would collide with persisted transcript turns). (Review C2.)
	local existing = (bridge:GetAttribute(Protocol.Bridge.LastRequestId) :: number?) or 0
	local floor = math.max(self._idFloor, existing)
	if existing ~= floor then
		bridge:SetAttribute(Protocol.Bridge.LastRequestId, floor)
	end
	self._idFloor = floor

	-- Make sure expected children exist even if an older/partial bridge was found.
	if not bridge:FindFirstChild(Protocol.REQUESTS_FOLDER) then
		local reqs = Instance.new("Folder")
		reqs.Name = Protocol.REQUESTS_FOLDER
		reqs.Archivable = false
		reqs.Parent = bridge
		createdRequests = true
	end
	if not bridge:FindFirstChild(Protocol.BridgeChild.StyleProfile) then
		local style = Instance.new("StringValue")
		style.Name = Protocol.BridgeChild.StyleProfile
		style.Archivable = false
		style.Parent = bridge
	end

	self._bridge = bridge

	-- Rebind the request watchers whenever the Requests folder identity changes — whether
	-- WE created it or it appeared some other way (a stale plugin object, a manual rebuild).
	-- Comparing identity (not just a "created" flag) closes the gap where the folder exists
	-- but this object isn't actually watching it, so enqueue would write into dead air (C1).
	local _ = createdRequests
	local reqs = bridge:FindFirstChild(Protocol.REQUESTS_FOLDER) :: Folder
	if self.running and reqs ~= self._wiredReqs then
		self:_wireRequests(reqs)
	end
	return bridge
end

function Bridge.requestsFolder(self: Bridge): Folder
	local bridge = self._bridge or self:ensureBridge()
	local reqs = bridge:FindFirstChild(Protocol.REQUESTS_FOLDER)
	if not reqs then
		-- Recover a missing Requests folder via the canonical path.
		self:ensureBridge()
		reqs = bridge:FindFirstChild(Protocol.REQUESTS_FOLDER)
	end
	return reqs :: Folder
end

-- ── producing prompts ──────────────────────────────────────────────────────

--- Enqueue a prompt. Implements the commit barrier: build the request fully with
--- Ready=false, then flip Ready=true LAST so Claude never sees a half-written request.
--- Returns the new request id.
function Bridge.enqueue(self: Bridge, promptText: string, kind: string?): number
	local bridge = self:ensureBridge()
	local k = kind or Protocol.Kind.Auto

	-- Reserve a monotonic id immediately, on this synchronous thread. Never below the
	-- persisted floor, so ids stay unique even after a bridge rebuild (review C2).
	local current = math.max((bridge:GetAttribute(Protocol.Bridge.LastRequestId) :: number?) or 0, self._idFloor)
	local id = current + 1
	bridge:SetAttribute(Protocol.Bridge.LastRequestId, id)
	self._idFloor = id
	self.plugin:SetSetting(SETTING_ID_FLOOR, id)

	local now = os.time()
	local req = Instance.new("Folder")
	req.Name = Protocol.requestName(id)
	req.Archivable = false
	req:SetAttribute(Protocol.Req.Id, id)
	req:SetAttribute(Protocol.Req.Guid, HttpService:GenerateGUID(false))
	req:SetAttribute(Protocol.Req.Kind, k)
	req:SetAttribute(Protocol.Req.CreatedAt, now)
	req:SetAttribute(Protocol.Req.State, Protocol.State.Queued)
	req:SetAttribute(Protocol.Req.ClaimedAt, 0)
	req:SetAttribute(Protocol.Req.UpdatedAt, now)
	req:SetAttribute(Protocol.Req.Progress, 0)
	req:SetAttribute(Protocol.Req.Ready, false) -- not yet visible to Claude

	local prompt = Instance.new("StringValue")
	prompt.Name = Protocol.ReqChild.Prompt
	prompt.Archivable = false
	prompt.Value = promptText
	prompt.Parent = req

	local statusText = Instance.new("StringValue")
	statusText.Name = Protocol.ReqChild.StatusText
	statusText.Archivable = false
	statusText.Parent = req

	local result = Instance.new("StringValue")
	result.Name = Protocol.ReqChild.Result
	result.Archivable = false
	result.Parent = req

	-- Parent the fully-formed folder, THEN commit by flipping Ready last.
	req.Parent = self:requestsFolder()
	req:SetAttribute(Protocol.Req.Ready, true) -- COMMIT

	return id
end

--- Cancel a still-queued request (user-initiated). In-flight builds are not canceled
--- here — those are reclaimed by the liveness timer only when Claude's heartbeat dies.
function Bridge.cancel(self: Bridge, id: number)
	local req = self:requestsFolder():FindFirstChild(Protocol.requestName(id))
	if not req then
		return
	end
	local state = req:GetAttribute(Protocol.Req.State) :: string?
	if state == Protocol.State.Queued then
		req:SetAttribute(Protocol.Req.State, Protocol.State.Canceled)
		req:SetAttribute(Protocol.Req.UpdatedAt, os.time())
	end
end

-- ── style profile ───────────────────────────────────────────────────────────

function Bridge.setStyleProfile(self: Bridge, profile: any)
	local bridge = self:ensureBridge()
	local style = bridge:FindFirstChild(Protocol.BridgeChild.StyleProfile) :: StringValue
	style.Value = Protocol.encode(profile)
end

function Bridge.getStyleProfile(self: Bridge): any?
	local bridge = self:ensureBridge()
	local style = bridge:FindFirstChild(Protocol.BridgeChild.StyleProfile)
	if style and style:IsA("StringValue") then
		local decoded = Protocol.decode(style.Value)
		return decoded
	end
	return nil
end

-- ── consuming results (watch) ───────────────────────────────────────────────

local function disconnectAll(list: { RBXScriptConnection })
	for _, c in list do
		c:Disconnect()
	end
end

--- Reap a terminal request: notify, then delete the folder so the queue stays small.
--- Deferred so a same-frame Result `.Changed` (Claude may write Result and flip State
--- in the same execute_luau call) is observed before the folder is destroyed (review M2).
function Bridge._reap(self: Bridge, req: Folder)
	if self._reaping[req] then
		return -- already scheduled
	end
	self._reaping[req] = true
	task.defer(function()
		if not req.Parent then
			self._reaping[req] = nil
			return
		end
		-- Read fresh at reap time so a late Result write is included.
		local view = viewOf(req)
		if self.callbacks.onRequestTerminal then
			self.callbacks.onRequestTerminal(view)
		end
		local conns = self._conns[req]
		if conns then
			disconnectAll(conns)
			self._conns[req] = nil
		end
		self._reaping[req] = nil
		req:Destroy()
	end)
end

--- Wire up signals for a single request folder. Attributes use AttributeChangedSignal
--- (the only signal that fires for them); StringValues use .Changed.
function Bridge._watchRequest(self: Bridge, req: Folder)
	if self._conns[req] then
		return -- already watching
	end
	local conns: { RBXScriptConnection } = {}

	local function pushUpdate()
		if self.callbacks.onRequestUpdate then
			self.callbacks.onRequestUpdate(viewOf(req))
		end
	end

	-- State (attribute): the primary lifecycle signal.
	table.insert(
		conns,
		req:GetAttributeChangedSignal(Protocol.Req.State):Connect(function()
			pushUpdate()
			local state = req:GetAttribute(Protocol.Req.State) :: string?
			if Protocol.isTerminal(state) then
				self:_reap(req)
			end
		end)
	)

	-- Progress (attribute).
	table.insert(conns, req:GetAttributeChangedSignal(Protocol.Req.Progress):Connect(pushUpdate))

	-- StatusText / Result (StringValues): .Changed fires for property changes.
	local statusText = req:FindFirstChild(Protocol.ReqChild.StatusText)
	if statusText and statusText:IsA("StringValue") then
		table.insert(conns, statusText.Changed:Connect(pushUpdate))
	end
	local result = req:FindFirstChild(Protocol.ReqChild.Result)
	if result and result:IsA("StringValue") then
		table.insert(conns, result.Changed:Connect(pushUpdate))
	end

	self._conns[req] = conns

	-- Emit an initial snapshot, and reap immediately if it's already terminal.
	pushUpdate()
	if Protocol.isTerminal(req:GetAttribute(Protocol.Req.State) :: string?) then
		self:_reap(req)
	end
end

--- (Re)bind the ChildAdded/ChildRemoved watchers onto a Requests folder, dropping any
--- prior binding. Called from start() and whenever ensureBridge() makes a new folder,
--- so a bridge rebuild never strands the watchers on a destroyed folder (review C1).
function Bridge._wireRequests(self: Bridge, reqs: Folder)
	self._wiredReqs = reqs
	-- Drop the old root connections (they may point at a destroyed folder).
	disconnectAll(self._rootConns)
	self._rootConns = {}
	-- Drop per-request connections; the folders they watched are gone or replaced.
	for inst, conns in self._conns do
		disconnectAll(conns)
		self._conns[inst] = nil
	end

	table.insert(
		self._rootConns,
		reqs.ChildAdded:Connect(function(child)
			if child:IsA("Folder") then
				self:_watchRequest(child)
			end
		end)
	)
	table.insert(
		self._rootConns,
		reqs.ChildRemoved:Connect(function(child)
			local conns = self._conns[child]
			if conns then
				disconnectAll(conns)
				self._conns[child] = nil
			end
		end)
	)
	for _, child in reqs:GetChildren() do
		if child:IsA("Folder") then
			self:_watchRequest(child)
		end
	end
end

-- ── liveness timer ───────────────────────────────────────────────────────────

function Bridge._setConnected(self: Bridge, connected: boolean)
	if connected ~= self.connected then
		self.connected = connected
		if self.callbacks.onConnectionChange then
			self.callbacks.onConnectionChange(connected)
		end
	end
end

function Bridge._tickLiveness(self: Bridge)
	local bridge = self._bridge
	if not bridge or not bridge.Parent then
		-- Bridge vanished (e.g. user deleted it) — rebuild and report disconnected.
		self:ensureBridge()
		self:_setConnected(false)
		return
	end

	local now = os.time()
	bridge:SetAttribute(Protocol.Bridge.PluginHeartbeat, now)
	local hb = (bridge:GetAttribute(Protocol.Bridge.ClaudeHeartbeat) :: number?) or 0
	local connected = (now - hb) <= Protocol.CLAUDE_TIMEOUT
	self:_setConnected(connected)

	-- Reclaim builds that stalled while Claude is gone.
	if not connected then
		for _, req in self:requestsFolder():GetChildren() do
			if req:IsA("Folder") then
				local state = req:GetAttribute(Protocol.Req.State) :: string?
				if state == Protocol.State.Claimed or state == Protocol.State.Working then
					local updated = (req:GetAttribute(Protocol.Req.UpdatedAt) :: number?) or 0
					if now - updated > Protocol.WORK_STALL_TIMEOUT then
						req:SetAttribute(Protocol.Req.State, Protocol.State.Canceled)
						req:SetAttribute(Protocol.Req.UpdatedAt, now)
					end
				end
			end
		end
	end
end

-- ── lifecycle ────────────────────────────────────────────────────────────────

--- Start watching the bridge and running the liveness timer. Call once on plugin load.
function Bridge.start(self: Bridge)
	if self.running then
		return
	end
	self.running = true
	self:ensureBridge()

	-- Watch existing + future request folders (re-bindable across bridge rebuilds).
	self:_wireRequests(self:requestsFolder())

	-- Low-frequency liveness loop, off the render path.
	self._heartbeatThread = task.spawn(function()
		while self.running do
			-- Guard each tick so a transient error never kills the loop.
			local ok, err = pcall(function()
				self:_tickLiveness()
			end)
			if not ok then
				warn("[Forge] liveness tick error: " .. tostring(err))
			end
			task.wait(Protocol.HEARTBEAT_INTERVAL)
		end
	end)
end

--- Stop watching and destroy the bridge. Call on plugin.Unloading.
function Bridge.stop(self: Bridge)
	self.running = false
	disconnectAll(self._rootConns)
	self._rootConns = {}
	for inst, conns in self._conns do
		disconnectAll(conns)
		self._conns[inst] = nil
	end
	self._wiredReqs = nil
	if self._bridge and self._bridge.Parent then
		self._bridge:Destroy()
	end
	self._bridge = nil
end

return Bridge
