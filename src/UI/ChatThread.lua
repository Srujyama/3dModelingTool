--!strict
--[[
	ChatThread.lua — the scrolling conversation.

	Renders the transcript as message bubbles: user prompts on the right, assistant
	turns on the left with live status, a progress bar while building, and a result
	card (what was created) when done. Re-renders from the Store on each notify; this
	is cheap because the transcript is small and bounded.
]]

local Theme = require(script.Parent.Theme)
local C = require(script.Parent.Components)
local Protocol = require(script.Parent.Parent.Bridge.Protocol)

local ChatThread = {}
ChatThread.__index = ChatThread

export type ChatThread = typeof(setmetatable(
	{} :: {
		root: ScrollingFrame,
		_list: UIListLayout,
		_spinners: { [number]: any },
		onLocate: ((path: string) -> ())?,
	},
	ChatThread
))

local function bubbleRow(layoutOrder: number, alignRight: boolean): Frame
	local row = C.frame({
		name = "Row",
		size = UDim2.new(1, 0, 0, 0),
		transparency = 1,
		autoY = true,
		layoutOrder = layoutOrder,
	})
	local pad = Instance.new("UIPadding")
	-- Asymmetric padding nudges the bubble left/right like a chat app.
	if alignRight then
		pad.PaddingLeft = UDim.new(0, 48)
	else
		pad.PaddingRight = UDim.new(0, 48)
	end
	pad.Parent = row
	return row
end

local function bubble(color: Color3, alignRight: boolean, parent: Instance): Frame
	local b = C.frame({
		name = "Bubble",
		size = UDim2.new(1, 0, 0, 0),
		color = color,
		radius = Theme.radius.lg,
		stroke = Theme.color.stroke,
		autoY = true,
		parent = parent,
	})
	b.AutomaticSize = Enum.AutomaticSize.Y
	C.padding(Theme.space.md).Parent = b
	local list = C.vlist(Theme.space.sm)
	list.Parent = b
	if alignRight then
		b.AnchorPoint = Vector2.new(1, 0)
		b.Position = UDim2.fromScale(1, 0)
	end
	return b
end

function ChatThread.new(parent: Instance): ChatThread
	local self = setmetatable({}, ChatThread) :: ChatThread
	local root = C.scroll({
		name = "ChatThread",
		size = UDim2.fromScale(1, 1),
		parent = parent,
	})
	C.padding(Theme.space.md).Parent = root
	local list = C.vlist(Theme.space.md)
	list.Parent = root
	self.root = root
	self._list = list
	self._spinners = {}
	return self
end

local function renderResultCard(parent: Instance, resultJson: string)
	local decoded = Protocol.decode(resultJson)
	if type(decoded) ~= "table" then
		return
	end
	local data = decoded :: any
	if not data.created and not data.summary then
		return
	end

	local card = C.frame({
		name = "ResultCard",
		size = UDim2.new(1, 0, 0, 0),
		color = Theme.color.surfaceAlt,
		radius = Theme.radius.md,
		stroke = data.ok == false and Theme.color.error or Theme.color.success,
		autoY = true,
		parent = parent,
	})
	C.padding(Theme.space.md).Parent = card
	local list = C.vlist(Theme.space.xs)
	list.Parent = card

	local headColor = data.ok == false and Theme.color.error or Theme.color.success
	local headText = data.ok == false and "⚠  Failed" or "✓  Created"
	C.label({
		text = headText,
		size = Theme.text.sm,
		color = headColor,
		font = Theme.font.bold,
		autoY = true,
		parent = card,
	})

	local created = data.created or {}
	for _, item in created do
		if type(item) == "table" then
			local path = tostring(item.path or "?")
			local cls = tostring(item.className or "")
			C.label({
				text = string.format('<font color="#A79FC4">%s</font>  %s', cls, path),
				size = Theme.text.xs,
				color = Theme.color.text,
				font = Theme.font.mono,
				rich = true,
				wrap = true,
				autoY = true,
				parent = card,
			})
		end
	end

	if data.tookSeconds then
		C.label({
			text = string.format("took %ss", tostring(data.tookSeconds)),
			size = Theme.text.xs,
			color = Theme.color.textFaint,
			autoY = true,
			parent = card,
		})
	end
end

--- Re-render the whole thread from a list of messages.
function ChatThread.render(self: ChatThread, messages: { any })
	-- Clear (stop spinners first).
	for _, sp in self._spinners do
		sp.stop()
	end
	self._spinners = {}
	for _, child in self.root:GetChildren() do
		if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
			child:Destroy()
		end
	end

	if #messages == 0 then
		-- Empty state.
		local empty = C.frame({
			name = "Empty",
			size = UDim2.new(1, 0, 0, 0),
			transparency = 1,
			autoY = true,
			layoutOrder = 1,
			parent = self.root,
		})
		C.padding(Theme.space.xl).Parent = empty
		local v = C.vlist(Theme.space.sm, Enum.HorizontalAlignment.Center)
		v.Parent = empty
		C.label({
			text = "Forge",
			size = Theme.text.xl,
			color = Theme.color.text,
			font = Theme.font.bold,
			align = Enum.TextXAlignment.Center,
			autoY = true,
			parent = empty,
		})
		C.label({
			text = "Generate any Roblox asset just by chatting.\nTry “medieval well”, “fantasy shop UI”, or “small village”.",
			size = Theme.text.sm,
			color = Theme.color.textDim,
			align = Enum.TextXAlignment.Center,
			wrap = true,
			autoY = true,
			parent = empty,
		})
		return
	end

	for i, m in messages do
		if m.role == "user" then
			local row = bubbleRow(i, true)
			row.Parent = self.root
			local b = bubble(Theme.color.userBubble, true, row)
			local inner = b:FindFirstChildOfClass("Frame") or b
			if m.kind and m.kind ~= Protocol.Kind.Auto then
				C.label({
					text = string.upper(m.kind),
					size = Theme.text.xs,
					color = Theme.color.accentBright,
					font = Theme.font.bold,
					autoY = true,
					parent = inner,
				})
			end
			C.label({
				text = m.text,
				size = Theme.text.base,
				color = Theme.color.text,
				wrap = true,
				autoY = true,
				parent = inner,
			})
		elseif m.role == "assistant" then
			local row = bubbleRow(i, false)
			row.Parent = self.root
			local b = bubble(Theme.color.assistantBubble, false, row)

			-- Status header row: dot + label (+ spinner while building).
			local header = C.frame({
				name = "Header",
				size = UDim2.new(1, 0, 0, 18),
				transparency = 1,
				parent = b,
			})
			C.hlist(Theme.space.sm).Parent = header
			local color, lbl = Theme.statusOf(m.state or Protocol.State.Queued)
			C.label({
				text = "●  " .. lbl,
				size = Theme.text.sm,
				color = color,
				font = Theme.font.medium,
				width = UDim.new(0, 120),
				parent = header,
			})
			if m.state == Protocol.State.Working or m.state == Protocol.State.Claimed then
				local sp = C.spinner(14, Theme.color.accentBright, header)
				self._spinners[m.id] = sp
			end

			-- Streaming status text.
			if m.text and m.text ~= "" then
				C.label({
					text = m.text,
					size = Theme.text.sm,
					color = Theme.color.textDim,
					wrap = true,
					autoY = true,
					parent = b,
				})
			end

			-- Progress bar while in flight.
			if m.state == Protocol.State.Working then
				local pc = C.progress(b)
				pc.set((m.progress or 0) / 100)
			end

			-- Result card on terminal.
			if m.result and m.result ~= "" then
				renderResultCard(b, m.result)
			end
		else -- system
			local note = C.frame({
				name = "SystemNote",
				size = UDim2.new(1, 0, 0, 0),
				transparency = 1,
				autoY = true,
				layoutOrder = i,
				parent = self.root,
			})
			C.padding(0, { l = Theme.space.sm, r = Theme.space.sm }).Parent = note
			C.label({
				text = m.text,
				size = Theme.text.xs,
				color = Theme.color.textFaint,
				align = Enum.TextXAlignment.Center,
				wrap = true,
				autoY = true,
				parent = note,
			})
		end
	end

	-- Auto-scroll to the bottom on the next frame (after layout settles).
	task.defer(function()
		if self.root.Parent then
			self.root.CanvasPosition = Vector2.new(0, self.root.AbsoluteCanvasSize.Y)
		end
	end)
end

--- Stop any in-flight spinner coroutines. Call before tearing down the App so spinner
--- threads don't touch a destroyed tree on the next frame (review m1).
function ChatThread.destroy(self: ChatThread)
	for _, sp in self._spinners do
		sp.stop()
	end
	self._spinners = {}
end

return ChatThread
