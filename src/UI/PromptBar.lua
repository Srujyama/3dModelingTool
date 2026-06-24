--!strict
--[[
	PromptBar.lua — generation-type chips + multiline prompt input + send.

	Sits at the bottom of the chat tab. Emits onSend(text, kind) when the user
	submits (Send button or Enter without Shift). The selected kind is reflected via
	the chip row and persisted through the Store by the App layer.
]]

local UserInputService = game:GetService("UserInputService")

local Theme = require(script.Parent.Theme)
local C = require(script.Parent.Components)
local Protocol = require(script.Parent.Parent.Bridge.Protocol)

local PromptBar = {}
PromptBar.__index = PromptBar

export type PromptBar = typeof(setmetatable(
	{} :: {
		root: Frame,
		_box: TextBox,
		_chips: { [string]: any },
		_selectedKind: string,
		onSend: ((text: string, kind: string) -> ())?,
		onKindChange: ((kind: string) -> ())?,
	},
	PromptBar
))

local KINDS = {
	{ key = Protocol.Kind.Auto, label = "Auto" },
	{ key = Protocol.Kind.Model, label = "3D Model" },
	{ key = Protocol.Kind.Gui, label = "GUI" },
	{ key = Protocol.Kind.Scene, label = "Scene" },
}

function PromptBar.new(parent: Instance, initialKind: string?): PromptBar
	local self = setmetatable({}, PromptBar) :: PromptBar
	self._selectedKind = initialKind or Protocol.Kind.Auto
	self._chips = {}

	local root = C.frame({
		name = "PromptBar",
		size = UDim2.new(1, 0, 0, 0),
		color = Theme.color.surface,
		radius = Theme.radius.lg,
		stroke = Theme.color.stroke,
		autoY = true,
		parent = parent,
	})
	C.padding(Theme.space.md).Parent = root
	local v = C.vlist(Theme.space.sm)
	v.Parent = root
	self.root = root

	-- Chip row.
	local chipRow = C.frame({
		name = "Chips",
		size = UDim2.new(1, 0, 0, 28),
		transparency = 1,
		layoutOrder = 1,
		parent = root,
	})
	C.hlist(Theme.space.sm).Parent = chipRow
	for _, k in KINDS do
		local chip = C.chip(k.label, function()
			self:_select(k.key)
		end, chipRow)
		chip.setSelected(k.key == self._selectedKind)
		self._chips[k.key] = chip
	end

	-- Input row: text box + send button.
	local inputRow = C.frame({
		name = "Input",
		size = UDim2.new(1, 0, 0, 0),
		transparency = 1,
		autoY = true,
		layoutOrder = 2,
		parent = root,
	})
	local inputList = C.hlist(Theme.space.sm, Enum.VerticalAlignment.Bottom)
	inputList.Parent = inputRow

	local boxFrame = C.frame({
		name = "BoxFrame",
		size = UDim2.new(1, -52, 0, 0),
		color = Theme.color.surfaceAlt,
		radius = Theme.radius.md,
		stroke = Theme.color.stroke,
		autoY = true,
		parent = inputRow,
	})
	boxFrame.AutomaticSize = Enum.AutomaticSize.Y
	C.padding(Theme.space.sm, { l = Theme.space.md, r = Theme.space.md }).Parent = boxFrame

	local box = Instance.new("TextBox")
	box.Name = "Prompt"
	box.BackgroundTransparency = 1
	box.Size = UDim2.new(1, 0, 0, 22)
	box.AutomaticSize = Enum.AutomaticSize.Y
	box.ClearTextOnFocus = false
	box.MultiLine = true
	box.TextWrapped = true
	box.TextEditable = true
	box.Font = Theme.font.regular
	box.TextSize = Theme.text.base
	box.TextColor3 = Theme.color.text
	box.PlaceholderText = "Describe the asset to forge…"
	box.PlaceholderColor3 = Theme.color.textFaint
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.TextYAlignment = Enum.TextYAlignment.Top
	box.Text = ""
	box.Parent = boxFrame
	self._box = box

	local sendBtn = C.button({
		text = "➤",
		size = UDim2.fromOffset(44, 44),
		gradient = Theme.accentGradient,
		textSize = Theme.text.lg,
		radius = Theme.radius.md,
		parent = inputRow,
		onClick = function()
			self:_submit()
		end,
	})
	sendBtn.LayoutOrder = 2

	-- Focus styling.
	local focused = false
	box.Focused:Connect(function()
		focused = true
		local stroke = boxFrame:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = Theme.color.accent
		end
	end)
	box.FocusLost:Connect(function()
		focused = false
		local stroke = boxFrame:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = Theme.color.stroke
		end
	end)

	-- Enter submits, Shift+Enter inserts a newline. A MultiLine TextBox does NOT lose
	-- focus on Enter, so FocusLost can't be used — watch InputBegan while focused and
	-- submit on a plain Return. The newline Roblox still inserts is trimmed by _submit.
	UserInputService.InputBegan:Connect(function(input)
		if not focused then
			return
		end
		if input.KeyCode == Enum.KeyCode.Return or input.KeyCode == Enum.KeyCode.KeypadEnter then
			local shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
				or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
			if not shift then
				self:_submit()
			end
		end
	end)

	return self
end

function PromptBar._select(self: PromptBar, kind: string)
	self._selectedKind = kind
	for key, chip in self._chips do
		chip.setSelected(key == kind)
	end
	if self.onKindChange then
		self.onKindChange(kind)
	end
end

function PromptBar.setKind(self: PromptBar, kind: string)
	self:_select(kind)
end

function PromptBar._submit(self: PromptBar)
	local text = self._box.Text
	-- Trim whitespace.
	text = string.gsub(text, "^%s+", "")
	text = string.gsub(text, "%s+$", "")
	if text == "" then
		return
	end
	if self.onSend then
		self.onSend(text, self._selectedKind)
	end
	self._box.Text = ""
end

return PromptBar
