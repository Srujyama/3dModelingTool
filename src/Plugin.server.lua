--!strict
--[[
	Plugin.server.lua — Forge plugin entry point.

	Creates the toolbar button and a dockable widget, mounts the App, and wires the
	Bridge lifecycle. The Bridge mailbox (ServerStorage/ForgeBridge) is created on
	start and destroyed on plugin unload so a dead session never leaves a stale bridge
	for a fresh Claude Code engine to poll.

	This is the only file with side effects at require-time; everything else is a pure
	module. `plugin` is the global injected by Studio into a plugin's main script.
]]

local Bridge = require(script.Bridge.Bridge)
local Store = require(script.State.Store)
local App = require(script.UI.App)

-- `plugin` is provided by Studio. Guard for the rare non-plugin run (e.g. a test mount).
local pluginRef: Plugin = plugin

-- ── toolbar ────────────────────────────────────────────────────────────────────

local toolbar = pluginRef:CreateToolbar("Forge")
local button = toolbar:CreateButton(
	"Forge",
	"Generate any Roblox asset just by chatting",
	"rbxasset://textures/AnimationEditor/icon_addKeyframe.png"
)
button.ClickableWhenViewportHidden = true

-- ── dock widget ──────────────────────────────────────────────────────────────

local widgetInfo = DockWidgetPluginGuiInfo.new(
	Enum.InitialDockState.Right,
	false, -- initially enabled
	false, -- override previous saved state
	360, -- default width
	560, -- default height
	300, -- min width
	360 -- min height
)

local widget = pluginRef:CreateDockWidgetPluginGui("ForgeWidget", widgetInfo)
widget.Title = "Forge"
widget.Name = "ForgeWidget"
widget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

-- ── wiring ─────────────────────────────────────────────────────────────────────

local store = Store.new(pluginRef)
local bridge = Bridge.new(pluginRef, {})
local app: any = nil

local function mount()
	if app then
		return
	end
	bridge:start()
	app = App.new(widget, store, bridge)
	-- Push the current connection state into the freshly-mounted UI.
	app:_setConnected(bridge.connected)
end

local function unmount()
	if app then
		app:destroy()
		app = nil
	end
	bridge:stop()
end

-- Toggle the widget from the toolbar button.
button.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)

-- Mount when shown, tear down when hidden — keeps the bridge/heartbeat off when the
-- panel is closed, and rebuilds cleanly when reopened.
widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	button:SetActive(widget.Enabled)
	if widget.Enabled then
		mount()
	else
		unmount()
	end
end)

-- If Studio restored the widget as already-open, mount immediately.
if widget.Enabled then
	button:SetActive(true)
	mount()
end

-- Clean up the bridge so it never lingers into a published place or a new session.
pluginRef.Unloading:Connect(function()
	unmount()
end)
