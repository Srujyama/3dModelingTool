--!strict
--[[
	StyleRef.lua — style-reference / palette cohesion controls.

	Forge's native analog to ForgeGUI's "upload a screenshot" feature. The user defines
	a style profile (name, on/off, free-text notes, and a palette of
	BrickColor+Material pairs). When enabled, the engine reuses it across every
	generation so a set stays visually consistent.

	"Seed from selection" reads the colors/materials of the currently-selected parts in
	Studio and turns them into palette entries — a one-click way to match an existing
	look. (The actual read is delegated via the onSeedFromSelection callback so this
	module stays UI-only.)
]]

local Theme = require(script.Parent.Theme)
local C = require(script.Parent.Components)

local StyleRef = {}
StyleRef.__index = StyleRef

export type StyleRef = typeof(setmetatable(
	{} :: {
		root: ScrollingFrame,
		_paletteList: Frame,
		onChange: ((style: any) -> ())?,
		onSeedFromSelection: (() -> { { brickColor: string, material: string } })?,
		_style: any,
	},
	StyleRef
))

local function sectionLabel(text: string, parent: Instance, order: number)
	C.label({
		text = string.upper(text),
		size = Theme.text.xs,
		color = Theme.color.textFaint,
		font = Theme.font.bold,
		layoutOrder = order,
		autoY = true,
		parent = parent,
	})
end

local function toggleRow(parent: Instance, order: number, initial: boolean, onToggle: (boolean) -> ()): TextButton
	local row = C.frame({
		name = "ToggleRow",
		size = UDim2.new(1, 0, 0, 36),
		transparency = 1,
		layoutOrder = order,
		parent = parent,
	})
	C.hlist(Theme.space.sm).Parent = row
	C.label({
		text = "Apply this style to every generation",
		size = Theme.text.sm,
		color = Theme.color.text,
		width = UDim.new(1, -52),
		parent = row,
	})
	local on = initial
	local btn = C.button({
		text = on and "ON" or "OFF",
		size = UDim2.fromOffset(48, 26),
		color = on and Theme.color.accentDeep or Theme.color.surfaceAlt,
		textSize = Theme.text.xs,
		radius = Theme.radius.pill,
		parent = row,
	})
	btn.Activated:Connect(function()
		on = not on
		btn.Text = on and "ON" or "OFF"
		btn.BackgroundColor3 = on and Theme.color.accentDeep or Theme.color.surfaceAlt
		onToggle(on)
	end)
	return btn
end

local function textField(
	parent: Instance,
	order: number,
	placeholder: string,
	value: string,
	onCommit: (string) -> ()
): TextBox
	local frame = C.frame({
		name = "Field",
		size = UDim2.new(1, 0, 0, 34),
		color = Theme.color.surfaceAlt,
		radius = Theme.radius.md,
		stroke = Theme.color.stroke,
		layoutOrder = order,
		parent = parent,
	})
	C.padding(0, { l = Theme.space.md, r = Theme.space.md }).Parent = frame
	local box = Instance.new("TextBox")
	box.BackgroundTransparency = 1
	box.Size = UDim2.fromScale(1, 1)
	box.Font = Theme.font.regular
	box.TextSize = Theme.text.sm
	box.TextColor3 = Theme.color.text
	box.PlaceholderText = placeholder
	box.PlaceholderColor3 = Theme.color.textFaint
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.ClearTextOnFocus = false
	box.Text = value
	box.Parent = frame
	box.FocusLost:Connect(function()
		onCommit(box.Text)
	end)
	return box
end

function StyleRef.new(parent: Instance): StyleRef
	local self = setmetatable({}, StyleRef) :: StyleRef
	local root = C.scroll({ name = "StyleRef", size = UDim2.fromScale(1, 1), parent = parent })
	C.padding(Theme.space.md).Parent = root
	C.vlist(Theme.space.md).Parent = root
	self.root = root
	return self
end

function StyleRef._commit(self: StyleRef)
	if self.onChange then
		self.onChange(self._style)
	end
end

function StyleRef._renderPalette(self: StyleRef)
	if not self._paletteList then
		return
	end
	for _, child in self._paletteList:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	local palette = self._style.palette or {}
	if #palette == 0 then
		local none = C.label({
			text = "No palette colors yet. Add one or seed from your selection.",
			size = Theme.text.xs,
			color = Theme.color.textFaint,
			wrap = true,
			autoY = true,
			parent = self._paletteList,
		})
		none.Name = "Frame" -- so the sweep clears it next render
		return
	end
	for idx, entry in palette do
		local row = C.frame({
			name = "Frame",
			size = UDim2.new(1, 0, 0, 30),
			color = Theme.color.surfaceAlt,
			radius = Theme.radius.sm,
			layoutOrder = idx,
			parent = self._paletteList,
		})
		C.padding(0, { l = Theme.space.sm, r = Theme.space.sm }).Parent = row
		C.hlist(Theme.space.sm).Parent = row
		local ok, bc = pcall(function()
			return BrickColor.new(entry.brickColor).Color
		end)
		local swatch = C.frame({
			name = "Sw",
			size = UDim2.fromOffset(18, 18),
			color = ok and bc or Theme.color.surfaceHover,
			radius = Theme.radius.sm,
			parent = row,
		})
		swatch.LayoutOrder = 0
		C.label({
			text = string.format("%s · %s", entry.brickColor, entry.material),
			size = Theme.text.xs,
			color = Theme.color.text,
			width = UDim.new(1, -70),
			parent = row,
		})
		C.button({
			text = "✕",
			size = UDim2.fromOffset(22, 22),
			color = Theme.color.surface,
			textSize = Theme.text.xs,
			radius = Theme.radius.sm,
			parent = row,
			onClick = function()
				table.remove(self._style.palette, idx)
				self:_renderPalette()
				self:_commit()
			end,
		})
	end
end

--- Render the panel for a given style profile.
function StyleRef.render(self: StyleRef, style: any)
	self._style = style
	for _, child in self.root:GetChildren() do
		if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
			child:Destroy()
		end
	end

	sectionLabel("Style reference", self.root, 1)
	C.label({
		text = "Lock a look so every generated asset stays cohesive — Forge's take on ForgeGUI's screenshot reference.",
		size = Theme.text.xs,
		color = Theme.color.textDim,
		wrap = true,
		autoY = true,
		layoutOrder = 2,
		parent = self.root,
	})

	textField(self.root, 3, "Style name (e.g. Dark Fantasy)", style.name or "", function(v)
		self._style.name = v
		self:_commit()
	end)

	toggleRow(self.root, 4, style.enabled == true, function(on)
		self._style.enabled = on
		self:_commit()
	end)

	sectionLabel("Notes (free-form aesthetic)", self.root, 5)
	textField(self.root, 6, "rim-lit, gold accents, dark backgrounds…", style.notes or "", function(v)
		self._style.notes = v
		self:_commit()
	end)

	sectionLabel("Palette", self.root, 7)
	local paletteList = C.frame({
		name = "PaletteList",
		size = UDim2.new(1, 0, 0, 0),
		transparency = 1,
		autoY = true,
		layoutOrder = 8,
		parent = self.root,
	})
	C.vlist(Theme.space.xs).Parent = paletteList
	self._paletteList = paletteList
	self:_renderPalette()

	-- Add-color row: BrickColor name + Material name.
	local addRow = C.frame({
		name = "AddRow",
		size = UDim2.new(1, 0, 0, 34),
		transparency = 1,
		layoutOrder = 9,
		parent = self.root,
	})
	C.hlist(Theme.space.sm).Parent = addRow
	local bcField = textField(addRow, 0, "BrickColor", "", function() end)
	bcField.Parent.Size = UDim2.new(0.5, -4, 0, 34)
	local matField = textField(addRow, 1, "Material", "", function() end)
	matField.Parent.Size = UDim2.new(0.5, -4, 0, 34)

	local actionsRow = C.frame({
		name = "Actions",
		size = UDim2.new(1, 0, 0, 34),
		transparency = 1,
		layoutOrder = 10,
		parent = self.root,
	})
	C.hlist(Theme.space.sm).Parent = actionsRow
	C.button({
		text = "+ Add color",
		size = UDim2.new(0.5, -4, 0, 32),
		color = Theme.color.surfaceAlt,
		textSize = Theme.text.sm,
		parent = actionsRow,
		onClick = function()
			local bc = bcField.Text ~= "" and bcField.Text or "Medium stone grey"
			local mat = matField.Text ~= "" and matField.Text or "SmoothPlastic"
			self._style.palette = self._style.palette or {}
			table.insert(self._style.palette, { brickColor = bc, material = mat })
			bcField.Text = ""
			matField.Text = ""
			self:_renderPalette()
			self:_commit()
		end,
	})
	C.button({
		text = "⛏ Seed from selection",
		size = UDim2.new(0.5, -4, 0, 32),
		color = Theme.color.accentDeep,
		textSize = Theme.text.sm,
		parent = actionsRow,
		onClick = function()
			if self.onSeedFromSelection then
				local entries = self.onSeedFromSelection()
				self._style.palette = self._style.palette or {}
				-- De-dupe against entries already in the palette (review M4) so repeated
				-- seeding of the same selection doesn't stack duplicates.
				local seen = {}
				for _, e in self._style.palette do
					seen[e.brickColor .. "|" .. e.material] = true
				end
				for _, e in entries do
					local key = e.brickColor .. "|" .. e.material
					if not seen[key] then
						seen[key] = true
						table.insert(self._style.palette, e)
					end
				end
				self:_renderPalette()
				self:_commit()
			end
		end,
	})
end

return StyleRef
