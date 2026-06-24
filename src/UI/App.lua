--!strict
--[[
	App.lua — top-level Forge view.

	Composes the header (brand + connection pill + tabs) and the four tab panels
	(Chat, Gallery, Style, Settings). It owns the wiring between the Store (session
	state), the Bridge (mailbox to Claude Code), and the panels:

	  PromptBar.onSend  ──► Store.addUserTurn + Bridge.enqueue
	  Bridge.onRequestUpdate / onRequestTerminal ──► Store.upsertAssistantTurn
	  Bridge.onConnectionChange ──► connection pill + Settings + offline banner
	  Store.subscribe ──► re-render the active tab

	Selectable-tab UI is plain show/hide of panel containers — no router needed.
]]

local Selection = game:GetService("Selection")

local Theme = require(script.Parent.Theme)
local C = require(script.Parent.Components)
local Protocol = require(script.Parent.Parent.Bridge.Protocol)

local ChatThread = require(script.Parent.ChatThread)
local PromptBar = require(script.Parent.PromptBar)
local Gallery = require(script.Parent.Gallery)
local StyleRef = require(script.Parent.StyleRef)
local Settings = require(script.Parent.Settings)

local App = {}
App.__index = App

export type App = typeof(setmetatable(
	{} :: {
		root: Frame,
		store: any,
		bridge: any,
		chat: any,
		promptBar: any,
		gallery: any,
		styleRef: any,
		settings: any,
		banner: any,
		_pillDot: TextLabel,
		_pillText: TextLabel,
		_tabs: { [string]: { button: TextButton, panel: GuiObject } },
		_active: string,
		_unsub: (() -> ())?,
	},
	App
))

-- ── selection seeding (style reference) ────────────────────────────────────────

--- Read BrickColor+Material from the currently selected BaseParts, de-duplicated.
local function paletteFromSelection(): { { brickColor: string, material: string } }
	local out = {}
	local seen = {}
	for _, inst in Selection:Get() do
		if inst:IsA("BasePart") then
			local bc = inst.BrickColor.Name
			local mat = inst.Material.Name
			local key = bc .. "|" .. mat
			if not seen[key] then
				seen[key] = true
				table.insert(out, { brickColor = bc, material = mat })
			end
		end
	end
	return out
end

-- ── tab bar ──────────────────────────────────────────────────────────────────

function App._buildHeader(self: App, parent: Instance)
	local header = C.frame({
		name = "Header",
		size = UDim2.new(1, 0, 0, 84),
		color = Theme.color.surface,
		parent = parent,
	})
	header.LayoutOrder = 1
	C.padding(Theme.space.md, { b = 0 }).Parent = header
	local v = C.vlist(Theme.space.sm)
	v.Parent = header

	-- Brand row + connection pill.
	local brandRow = C.frame({
		name = "Brand",
		size = UDim2.new(1, 0, 0, 28),
		transparency = 1,
		layoutOrder = 1,
		parent = header,
	})
	local brand = C.label({
		text = "⬡ Forge",
		size = Theme.text.lg,
		color = Theme.color.text,
		font = Theme.font.bold,
		width = UDim.new(1, -130),
		parent = brandRow,
	})
	brand.Position = UDim2.fromScale(0, 0)

	local pill = C.frame({
		name = "Pill",
		size = UDim2.fromOffset(124, 24),
		position = UDim2.new(1, -124, 0, 2),
		color = Theme.color.surfaceAlt,
		radius = Theme.radius.pill,
		stroke = Theme.color.stroke,
		parent = brandRow,
	})
	C.padding(0, { l = Theme.space.sm, r = Theme.space.sm }).Parent = pill
	C.hlist(Theme.space.xs).Parent = pill
	self._pillDot = C.label({
		text = "●",
		size = Theme.text.sm,
		color = Theme.color.error,
		width = UDim.new(0, 12),
		parent = pill,
	})
	self._pillText = C.label({
		text = "Offline",
		size = Theme.text.xs,
		color = Theme.color.textDim,
		font = Theme.font.medium,
		width = UDim.new(1, -16),
		parent = pill,
	})

	-- Tab buttons.
	local tabRow = C.frame({
		name = "Tabs",
		size = UDim2.new(1, 0, 0, 30),
		transparency = 1,
		layoutOrder = 2,
		parent = header,
	})
	C.hlist(Theme.space.xs).Parent = tabRow
	return tabRow
end

function App._addTab(self: App, tabRow: Instance, key: string, label: string, panel: GuiObject)
	local btn = Instance.new("TextButton")
	btn.AutoButtonColor = false
	btn.Text = label
	btn.Font = Theme.font.medium
	btn.TextSize = Theme.text.sm
	btn.TextColor3 = Theme.color.textDim
	btn.AutomaticSize = Enum.AutomaticSize.X
	btn.Size = UDim2.new(0, 0, 1, 0)
	btn.BackgroundColor3 = Theme.color.surfaceAlt
	btn.BackgroundTransparency = 1
	btn.BorderSizePixel = 0
	C.padding(0, { l = Theme.space.md, r = Theme.space.md }).Parent = btn
	C.corner(Theme.radius.sm).Parent = btn
	btn.Parent = tabRow
	btn.Activated:Connect(function()
		self:_selectTab(key)
	end)
	self._tabs[key] = { button = btn, panel = panel }
end

function App._selectTab(self: App, key: string)
	self._active = key
	for k, t in self._tabs do
		local on = (k == key)
		t.panel.Visible = on
		t.button.TextColor3 = on and Theme.color.text or Theme.color.textDim
		t.button.BackgroundTransparency = on and 0 or 1
	end
	-- Refresh the panel we're switching to.
	self:_renderActive()
end

-- ── render ─────────────────────────────────────────────────────────────────────

function App._renderActive(self: App)
	if self._active == "chat" then
		self.chat:render(self.store.messages)
	elseif self._active == "gallery" then
		self.gallery:render(self.store.messages)
	elseif self._active == "style" then
		self.styleRef:render(self.store.style)
	end
end

-- ── construction ───────────────────────────────────────────────────────────────

function App.new(parent: Instance, store: any, bridge: any): App
	local self = setmetatable({}, App) :: App
	self.store = store
	self.bridge = bridge
	self._tabs = {}
	self._active = "chat"

	local root = C.frame({
		name = "Forge",
		size = UDim2.fromScale(1, 1),
		color = Theme.color.bg,
		parent = parent,
	})
	C.vlist(0).Parent = root
	self.root = root

	local tabRow = self:_buildHeader(root)

	-- Body holds the offline banner + a stack of panels.
	local body = C.frame({
		name = "Body",
		size = UDim2.new(1, 0, 1, -84),
		transparency = 1,
		parent = root,
	})
	body.LayoutOrder = 2
	C.padding(Theme.space.md, { t = Theme.space.sm }).Parent = body
	local bodyList = C.vlist(Theme.space.sm)
	bodyList.Parent = body

	self.banner = C.banner(body)
	self.banner.instance.LayoutOrder = 0

	-- Panel stack: a frame that fills remaining height; each panel is an overlay.
	local stack = C.frame({
		name = "Stack",
		size = UDim2.new(1, 0, 1, 0),
		transparency = 1,
		parent = body,
	})
	stack.LayoutOrder = 1
	-- Let the banner take its space; stack flexes. We approximate flex by sizing the
	-- stack to fill and letting the banner sit above via the list layout.
	stack.AutomaticSize = Enum.AutomaticSize.None

	-- Chat panel = thread (fills) + prompt bar (bottom). Build a sub-layout.
	local chatPanel = C.frame({
		name = "ChatPanel",
		size = UDim2.fromScale(1, 1),
		transparency = 1,
		parent = stack,
	})
	local chatLayout = C.vlist(Theme.space.sm)
	chatLayout.Parent = chatPanel
	local threadHolder = C.frame({
		name = "ThreadHolder",
		size = UDim2.new(1, 0, 1, -96),
		transparency = 1,
		parent = chatPanel,
	})
	threadHolder.LayoutOrder = 1
	self.chat = ChatThread.new(threadHolder)
	local promptHolder = C.frame({
		name = "PromptHolder",
		size = UDim2.new(1, 0, 0, 0),
		transparency = 1,
		autoY = true,
		parent = chatPanel,
	})
	promptHolder.LayoutOrder = 2
	self.promptBar = PromptBar.new(promptHolder, store.kind)

	-- Other panels overlay-fill the stack.
	local galleryPanel =
		C.frame({ name = "GalleryPanel", size = UDim2.fromScale(1, 1), transparency = 1, parent = stack })
	self.gallery = Gallery.new(galleryPanel)
	local stylePanel = C.frame({ name = "StylePanel", size = UDim2.fromScale(1, 1), transparency = 1, parent = stack })
	self.styleRef = StyleRef.new(stylePanel)
	local settingsPanel =
		C.frame({ name = "SettingsPanel", size = UDim2.fromScale(1, 1), transparency = 1, parent = stack })
	self.settings = Settings.new(settingsPanel)

	-- Overlapping panels: position all at the same spot; visibility switches them.
	for _, p in { chatPanel, galleryPanel, stylePanel, settingsPanel } do
		p.Position = UDim2.fromScale(0, 0)
	end
	-- The non-chat panels shouldn't participate in the chat sub-layout; they live in
	-- the same stack, so disable the list layout's influence by anchoring them.
	galleryPanel.LayoutOrder = 10
	stylePanel.LayoutOrder = 11
	settingsPanel.LayoutOrder = 12

	self:_addTab(tabRow, "chat", "Chat", chatPanel)
	self:_addTab(tabRow, "gallery", "Gallery", galleryPanel)
	self:_addTab(tabRow, "style", "Style", stylePanel)
	self:_addTab(tabRow, "settings", "Settings", settingsPanel)

	self:_wire()
	self:_selectTab("chat")
	self:_renderActive()
	return self
end

function App._wire(self: App)
	local store = self.store
	local bridge = self.bridge

	-- Sending a prompt: record locally + enqueue to the bridge.
	self.promptBar.onSend = function(text: string, kind: string)
		store:addUserTurn(text, kind)
		-- Make sure the engine has the latest style profile before this build.
		bridge:setStyleProfile(store.style)
		local id = bridge:enqueue(text, kind)
		store:upsertAssistantTurn(id, { text = "Queued…", state = Protocol.State.Queued })
		self:_selectTab("chat")
	end
	self.promptBar.onKindChange = function(kind: string)
		store:setKind(kind)
	end

	-- Bridge updates → assistant turns.
	bridge.callbacks.onRequestUpdate = function(view)
		store:upsertAssistantTurn(view.id, {
			text = view.statusText ~= "" and view.statusText or nil,
			state = view.state,
			progress = view.progress,
			result = view.result ~= "" and view.result or nil,
		})
	end
	bridge.callbacks.onRequestTerminal = function(view)
		store:upsertAssistantTurn(view.id, {
			state = view.state,
			result = view.result ~= "" and view.result or nil,
			progress = 100,
		})
	end
	bridge.callbacks.onConnectionChange = function(connected)
		self:_setConnected(connected)
	end

	-- Style panel edits → persist + push to bridge.
	self.styleRef.onChange = function(style)
		store:setStyle(style)
		bridge:setStyleProfile(style)
	end
	self.styleRef.onSeedFromSelection = paletteFromSelection

	-- Settings actions.
	self.settings.onClearHistory = function()
		store:clearTranscript()
	end

	-- Re-render the active tab whenever the store changes.
	self._unsub = store:subscribe(function()
		self:_renderActive()
	end)
end

function App._setConnected(self: App, connected: boolean)
	if connected then
		self._pillDot.TextColor3 = Theme.color.success
		self._pillText.Text = "Connected"
		self.banner.hide()
	else
		self._pillDot.TextColor3 = Theme.color.error
		self._pillText.Text = "Offline"
		-- Only nag if there's pending work.
		local hasQueued = false
		for _, m in self.store.messages do
			if m.role == "assistant" and (m.state == Protocol.State.Queued or m.state == Protocol.State.Working) then
				hasQueued = true
				break
			end
		end
		if hasQueued then
			self.banner.show(
				"Claude Code not connected. Start it with /forge (with the Roblox Studio MCP server running), and your prompt will run.",
				Theme.color.warning
			)
		else
			self.banner.hide()
		end
	end
	self.settings:setConnected(connected)
end

function App.destroy(self: App)
	if self._unsub then
		self._unsub()
		self._unsub = nil
	end
	if self.chat then
		self.chat:destroy()
	end
	self.root:Destroy()
end

return App
