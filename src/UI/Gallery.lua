--!strict
--[[
	Gallery.lua — a grid of assets generated this session.

	Each successfully-completed request becomes a card showing its prompt and what was
	created. It's a session record (echoing ForgeGUI's community gallery, but personal).
	Cards are derived from terminal assistant messages in the transcript.
]]

local Theme = require(script.Parent.Theme)
local C = require(script.Parent.Components)
local Protocol = require(script.Parent.Parent.Bridge.Protocol)

local Gallery = {}
Gallery.__index = Gallery

export type Gallery = typeof(setmetatable(
	{} :: {
		root: ScrollingFrame,
		_grid: UIGridLayout,
	},
	Gallery
))

function Gallery.new(parent: Instance): Gallery
	local self = setmetatable({}, Gallery) :: Gallery
	local root = C.scroll({ name = "Gallery", size = UDim2.fromScale(1, 1), parent = parent })
	C.padding(Theme.space.md).Parent = root
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.new(0.5, -Theme.space.sm, 0, 96)
	grid.CellPadding = UDim2.fromOffset(Theme.space.sm, Theme.space.sm)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = root
	self.root = root
	self._grid = grid
	return self
end

local function card(parent: Instance, prompt: string, count: number, ok: boolean, order: number)
	local c = C.frame({
		name = "Card",
		color = Theme.color.surface,
		radius = Theme.radius.md,
		stroke = ok and Theme.color.stroke or Theme.color.error,
		layoutOrder = order,
		parent = parent,
	})
	C.padding(Theme.space.md).Parent = c
	local v = C.vlist(Theme.space.xs)
	v.Parent = c

	-- A small gradient swatch as a stand-in thumbnail.
	local swatch = C.frame({
		name = "Swatch",
		size = UDim2.new(1, 0, 0, 28),
		color = Theme.color.accentDeep,
		radius = Theme.radius.sm,
		parent = c,
	})
	C.gradient(Theme.accentGradient, 30).Parent = swatch

	C.label({
		text = prompt,
		size = Theme.text.sm,
		color = Theme.color.text,
		font = Theme.font.medium,
		wrap = true,
		autoY = true,
		parent = c,
	})
	C.label({
		text = ok and string.format("%d instance%s", count, count == 1 and "" or "s") or "failed",
		size = Theme.text.xs,
		color = ok and Theme.color.textDim or Theme.color.error,
		autoY = true,
		parent = c,
	})
end

function Gallery.render(self: Gallery, messages: { any })
	for _, child in self.root:GetChildren() do
		if child:IsA("Frame") or child.Name == "EmptyState" then
			child:Destroy()
		end
	end

	local order = 0
	local any = false
	-- Walk newest-first so the freshest assets show top-left.
	for i = #messages, 1, -1 do
		local m = messages[i]
		if m.role == "assistant" and m.result and m.result ~= "" then
			local decoded = Protocol.decode(m.result)
			if type(decoded) == "table" then
				local data = decoded :: any
				local created = data.created or {}
				-- Find the matching user prompt (previous user turn).
				local promptText = data.summary or "asset"
				for j = i - 1, 1, -1 do
					if messages[j].role == "user" then
						promptText = messages[j].text
						break
					end
				end
				order += 1
				any = true
				card(self.root, promptText, #created, data.ok ~= false, order)
			end
		end
	end

	if not any then
		local empty = C.label({
			text = "Your generated assets will appear here.",
			size = Theme.text.sm,
			color = Theme.color.textDim,
			align = Enum.TextXAlignment.Center,
			wrap = true,
			autoY = true,
			parent = self.root,
		})
		empty.Size = UDim2.new(1, 0, 0, 40)
		empty.Name = "EmptyState"
	end
end

return Gallery
