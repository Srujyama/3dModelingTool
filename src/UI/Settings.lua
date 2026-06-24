--!strict
--[[
	Settings.lua — connection status, how-to, and maintenance actions.

	Read-mostly: shows whether the Claude Code engine is connected, a short setup
	reminder, and a "Clear chat history" button. Live values are pushed in via
	setConnected(); actions are surfaced through callbacks.
]]

local Theme = require(script.Parent.Theme)
local C = require(script.Parent.Components)
local Protocol = require(script.Parent.Parent.Bridge.Protocol)

local Settings = {}
Settings.__index = Settings

export type Settings = typeof(setmetatable(
	{} :: {
		root: ScrollingFrame,
		_statusDot: TextLabel,
		_statusText: TextLabel,
		onClearHistory: (() -> ())?,
	},
	Settings
))

local function infoRow(parent: Instance, order: number, key: string, value: string)
	local row = C.frame({
		name = "Info",
		size = UDim2.new(1, 0, 0, 0),
		transparency = 1,
		autoY = true,
		layoutOrder = order,
		parent = parent,
	})
	C.vlist(2).Parent = row
	C.label({
		text = key,
		size = Theme.text.xs,
		color = Theme.color.textFaint,
		font = Theme.font.bold,
		autoY = true,
		parent = row,
	})
	C.label({
		text = value,
		size = Theme.text.sm,
		color = Theme.color.textDim,
		wrap = true,
		autoY = true,
		parent = row,
	})
end

function Settings.new(parent: Instance): Settings
	local self = setmetatable({}, Settings) :: Settings
	local root = C.scroll({ name = "Settings", size = UDim2.fromScale(1, 1), parent = parent })
	C.padding(Theme.space.md).Parent = root
	C.vlist(Theme.space.md).Parent = root
	self.root = root

	-- Connection card.
	local card = C.frame({
		name = "ConnectionCard",
		size = UDim2.new(1, 0, 0, 0),
		color = Theme.color.surface,
		radius = Theme.radius.md,
		stroke = Theme.color.stroke,
		autoY = true,
		layoutOrder = 1,
		parent = root,
	})
	C.padding(Theme.space.md).Parent = card
	local cardList = C.hlist(Theme.space.sm)
	cardList.Parent = card
	local dot = C.label({
		text = "●",
		size = Theme.text.md,
		color = Theme.color.error,
		width = UDim.new(0, 16),
		parent = card,
	})
	dot.LayoutOrder = 0
	local statusText = C.label({
		text = "Claude Code not connected",
		size = Theme.text.base,
		color = Theme.color.text,
		font = Theme.font.medium,
		width = UDim.new(1, -24),
		parent = card,
	})
	statusText.LayoutOrder = 1
	self._statusDot = dot
	self._statusText = statusText

	infoRow(
		root,
		2,
		"Engine",
		"Forge generates assets by driving Claude Code through the Roblox Studio MCP server. Start it in Claude Code with /forge."
	)
	infoRow(
		root,
		3,
		"Bridge",
		string.format(
			"A hidden, non-published folder at %s.%s carries prompts and results. It is recreated automatically and never ships in your game.",
			Protocol.BRIDGE_PARENT_SERVICE,
			Protocol.BRIDGE_NAME
		)
	)
	infoRow(
		root,
		4,
		"3D mesh retrieval",
		"For organic assets the engine searches the Creator Store — set ROBLOX_OPEN_CLOUD_API_KEY on the MCP server to enable it. Procedural builds and UI work without a key."
	)
	infoRow(
		root,
		5,
		"Visual verify",
		"Enable Game Settings → Security → Allow Mesh/Image APIs so the engine can screenshot and self-correct its builds."
	)

	C.button({
		text = "Clear chat history",
		size = UDim2.new(1, 0, 0, 36),
		color = Theme.color.surfaceAlt,
		stroke = Theme.color.error,
		textColor = Theme.color.error,
		layoutOrder = 6,
		parent = root,
		onClick = function()
			if self.onClearHistory then
				self.onClearHistory()
			end
		end,
	})

	C.label({
		text = "Forge v1 · bridge protocol v" .. tostring(Protocol.VERSION),
		size = Theme.text.xs,
		color = Theme.color.textFaint,
		align = Enum.TextXAlignment.Center,
		autoY = true,
		layoutOrder = 7,
		parent = root,
	})

	return self
end

function Settings.setConnected(self: Settings, connected: boolean)
	if connected then
		self._statusDot.TextColor3 = Theme.color.success
		self._statusText.Text = "Connected — engine ready"
	else
		self._statusDot.TextColor3 = Theme.color.error
		self._statusText.Text = "Claude Code not connected"
	end
end

return Settings
