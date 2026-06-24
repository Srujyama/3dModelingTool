--!strict
--[[
	Store.lua — Forge session state + persistence.

	Holds the chat transcript, the currently-selected generation kind, and the style
	profile. Chat scrollback and settings persist across Studio restarts via
	plugin:SetSetting / GetSetting (plugin-local storage, NOT the DataModel — the
	bridge is transient by design).
]]

local Protocol = require(script.Parent.Parent.Bridge.Protocol)

local Store = {}
Store.__index = Store

-- A transcript entry. role "user" | "assistant" | "system".
-- `id` is a local monotonic key for stable identity (every message has a unique one).
-- `requestId` is the bridge request id, present only on assistant turns; lookups key on
-- it so the request-id space never collides with the local-id space (review M3).
export type Message = {
	id: number, -- local monotonic key, unique across all roles
	requestId: number?, -- bridge request id (assistant turns only)
	role: string,
	kind: string?, -- generation kind for user turns
	text: string, -- prompt text or summary
	state: string?, -- request state for assistant turns
	result: string?, -- raw result manifest JSON
	createdAt: number,
}

export type StyleProfile = {
	enabled: boolean,
	name: string,
	palette: { { brickColor: string, material: string } },
	ui: { [string]: any },
	notes: string,
}

-- v2: messages gained a separate `requestId`; old v1 data has a different id scheme.
local SETTING_TRANSCRIPT = "Forge_Transcript_v2"
local SETTING_KIND = "Forge_Kind_v1"
local SETTING_STYLE = "Forge_Style_v1"
local MAX_TRANSCRIPT = 60

export type Store = typeof(setmetatable(
	{} :: {
		plugin: Plugin,
		messages: { Message },
		kind: string,
		style: StyleProfile,
		_counter: number,
		_listeners: { (Store) -> () },
	},
	Store
))

local function defaultStyle(): StyleProfile
	return {
		enabled = false,
		name = "Untitled style",
		palette = {},
		ui = { bg = "#14121A", panel = "#1E1B26", accent = "#8B5CF6", text = "#F4F1FB", corner = 8, stroke = 1 },
		notes = "",
	}
end

function Store.new(plugin: Plugin): Store
	local self = setmetatable({}, Store) :: Store
	self.plugin = plugin
	self.messages = {}
	self.kind = Protocol.Kind.Auto
	self.style = defaultStyle()
	self._counter = 0
	self._listeners = {}
	self:_load()
	return self
end

-- ── persistence ──────────────────────────────────────────────────────────────

function Store._load(self: Store)
	local t = self.plugin:GetSetting(SETTING_TRANSCRIPT)
	if type(t) == "string" then
		local decoded = Protocol.decode(t)
		-- Only accept a well-formed array of message-shaped tables (review m5).
		if type(decoded) == "table" then
			local clean = {}
			for _, m in decoded :: any do
				if type(m) == "table" and type(m.id) == "number" and type(m.role) == "string" then
					table.insert(clean, m)
				end
			end
			self.messages = clean
		end
	end
	local k = self.plugin:GetSetting(SETTING_KIND)
	if type(k) == "string" then
		self.kind = k
	end
	local s = self.plugin:GetSetting(SETTING_STYLE)
	if type(s) == "string" then
		local decoded = Protocol.decode(s)
		if type(decoded) == "table" then
			-- Merge over defaults so missing keys are filled in.
			local base = defaultStyle()
			for key, value in decoded :: any do
				base[key] = value
			end
			self.style = base
		end
	end
	-- Recover the counter so new local ids don't collide.
	for _, m in self.messages do
		if m.id > self._counter then
			self._counter = m.id
		end
	end
end

function Store._saveTranscript(self: Store)
	-- Trim to the most recent MAX_TRANSCRIPT before persisting.
	local n = #self.messages
	if n > MAX_TRANSCRIPT then
		local trimmed = {}
		for i = n - MAX_TRANSCRIPT + 1, n do
			table.insert(trimmed, self.messages[i])
		end
		self.messages = trimmed
	end
	self.plugin:SetSetting(SETTING_TRANSCRIPT, Protocol.encode(self.messages))
end

function Store.saveStyle(self: Store)
	self.plugin:SetSetting(SETTING_STYLE, Protocol.encode(self.style))
end

function Store.saveKind(self: Store)
	self.plugin:SetSetting(SETTING_KIND, self.kind)
end

-- ── change notification ────────────────────────────────────────────────────────

function Store.subscribe(self: Store, fn: (Store) -> ()): () -> ()
	table.insert(self._listeners, fn)
	return function()
		local idx = table.find(self._listeners, fn)
		if idx then
			table.remove(self._listeners, idx)
		end
	end
end

function Store._notify(self: Store)
	for _, fn in self._listeners do
		fn(self)
	end
end

-- ── mutations ──────────────────────────────────────────────────────────────────

function Store.nextLocalId(self: Store): number
	self._counter += 1
	return self._counter
end

--- Append a user prompt turn. Returns the created message.
function Store.addUserTurn(self: Store, text: string, kind: string): Message
	local msg: Message = {
		id = self:nextLocalId(),
		role = "user",
		kind = kind,
		text = text,
		createdAt = os.time(),
	}
	table.insert(self.messages, msg)
	self:_saveTranscript()
	self:_notify()
	return msg
end

--- Append (or update) an assistant turn keyed by its bridge `requestId` (never the
--- local id), so a rebuilt bridge that restarts ids can't match an old turn (review M3).
function Store.upsertAssistantTurn(self: Store, requestId: number, fields: { [string]: any }): Message
	for _, m in self.messages do
		if m.role == "assistant" and m.requestId == requestId then
			for k, v in fields do
				m[k] = v
			end
			self:_saveTranscript()
			self:_notify()
			return m
		end
	end
	local msg: Message = {
		id = self:nextLocalId(),
		requestId = requestId,
		role = "assistant",
		text = fields.text or "",
		state = fields.state,
		result = fields.result,
		createdAt = os.time(),
	}
	for k, v in fields do
		msg[k] = v
	end
	table.insert(self.messages, msg)
	self:_saveTranscript()
	self:_notify()
	return msg
end

function Store.addSystemNote(self: Store, text: string)
	table.insert(self.messages, {
		id = self:nextLocalId(),
		role = "system",
		text = text,
		createdAt = os.time(),
	})
	self:_saveTranscript()
	self:_notify()
end

function Store.clearTranscript(self: Store)
	self.messages = {}
	self:_saveTranscript()
	self:_notify()
end

function Store.setKind(self: Store, kind: string)
	self.kind = kind
	self:saveKind()
	self:_notify()
end

function Store.setStyle(self: Store, style: StyleProfile)
	self.style = style
	self:saveStyle()
	self:_notify()
end

return Store
