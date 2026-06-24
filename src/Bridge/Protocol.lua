--!strict
--[[
	Protocol.lua — the single source of truth for the Forge bridge mailbox.

	Both sides of the bridge (this plugin, and Claude Code via the Roblox Studio MCP
	server) must agree on these names. The Claude-Code side mirrors them in
	engine/forge-engine.md. The human-readable contract is docs/PROTOCOL.md.

	Nothing here touches the DataModel — it is pure constants + helpers so that
	Bridge.lua and the UI never hard-code a magic string.
]]

local HttpService = game:GetService("HttpService")

local Protocol = {}

Protocol.VERSION = 1

-- Where the bridge lives.
Protocol.BRIDGE_PARENT_SERVICE = "ServerStorage"
Protocol.BRIDGE_NAME = "ForgeBridge"
Protocol.REQUESTS_FOLDER = "Requests"
Protocol.REQUEST_PREFIX = "Req_"

-- Bridge-level attribute names (control plane — short, fixed-size).
Protocol.Bridge = {
	ProtocolVersion = "ProtocolVersion",
	LastRequestId = "LastRequestId",
	LastProcessedId = "LastProcessedId",
	ClaudeHeartbeat = "ClaudeHeartbeat",
	ClaudeStatus = "ClaudeStatus",
	PluginHeartbeat = "PluginHeartbeat",
}

-- Bridge-level child StringValue names (data plane).
Protocol.BridgeChild = {
	StyleProfile = "StyleProfile",
}

-- Per-request attribute names (control plane).
Protocol.Req = {
	Id = "Id",
	Guid = "Guid",
	Kind = "Kind",
	CreatedAt = "CreatedAt",
	Ready = "Ready",
	State = "State",
	ClaimedAt = "ClaimedAt",
	UpdatedAt = "UpdatedAt",
	Progress = "Progress",
}

-- Per-request child StringValue names (data plane — variable-length text).
Protocol.ReqChild = {
	Prompt = "Prompt",
	StatusText = "StatusText",
	Result = "Result",
}

-- Request lifecycle states. Terminal states are immutable once set.
Protocol.State = {
	Queued = "queued",
	Claimed = "claimed",
	Working = "working",
	Done = "done",
	Error = "error",
	Canceled = "canceled",
}

Protocol.TERMINAL_STATES = {
	[Protocol.State.Done] = true,
	[Protocol.State.Error] = true,
	[Protocol.State.Canceled] = true,
}

-- Generation kinds chosen by the user via the chips. "auto" lets the engine route.
Protocol.Kind = {
	Auto = "auto",
	Model = "model",
	Gui = "gui",
	Scene = "scene",
}

-- ClaudeStatus values.
Protocol.ClaudeStatus = {
	Idle = "idle",
	Polling = "polling",
	Working = "working",
}

-- Liveness tunables (seconds). Read by Bridge.lua's heartbeat timer.
Protocol.HEARTBEAT_INTERVAL = 3
Protocol.CLAUDE_TIMEOUT = 15 -- 5 missed ticks => "not connected"
Protocol.WORK_STALL_TIMEOUT = 120 -- only reclaim a working build after this AND dead heartbeat

-- Safety margin under the StringValue ~200k cap, used when trimming manifests.
Protocol.STRINGVALUE_SOFT_CAP = 150000

--- Returns true if `state` is one of the immutable terminal states.
function Protocol.isTerminal(state: string?): boolean
	return state ~= nil and Protocol.TERMINAL_STATES[state] == true
end

--- The folder name for a given request id (e.g. "Req_7").
function Protocol.requestName(id: number): string
	return Protocol.REQUEST_PREFIX .. tostring(id)
end

--- Parse a numeric id out of a "Req_<id>" name, or nil if it doesn't match.
function Protocol.parseRequestId(name: string): number?
	local n = string.match(name, "^" .. Protocol.REQUEST_PREFIX .. "(%d+)$")
	return n and tonumber(n) or nil
end

--- Safe JSON encode. Returns the string, or a fallback on failure (never throws).
function Protocol.encode(value: any): string
	local ok, result = pcall(function()
		return HttpService:JSONEncode(value)
	end)
	if ok then
		return result
	end
	return "{}"
end

--- Safe JSON decode. Returns (decoded, nil) on success or (nil, errMessage) on failure.
--- Treats empty/whitespace as an empty object so callers don't special-case it.
function Protocol.decode(text: string?): (any?, string?)
	if text == nil or string.match(text, "^%s*$") then
		return {}, nil
	end
	local ok, result = pcall(function()
		return HttpService:JSONDecode(text)
	end)
	if ok then
		return result, nil
	end
	return nil, tostring(result)
end

return Protocol
