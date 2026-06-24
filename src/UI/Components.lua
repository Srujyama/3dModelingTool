--!strict
--[[
	Components.lua — a tiny, dependency-free imperative widget kit.

	Each function returns a configured Instance (and sometimes a small controller
	table). No Roact/Fusion — we keep the plugin portable and install-free. Helpers
	wrap the repetitive boilerplate (corners, strokes, padding, gradients, hover).
]]

local TweenService = game:GetService("TweenService")
local Theme = require(script.Parent.Theme)

local Components = {}

-- ── primitives ──────────────────────────────────────────────────────────────

function Components.corner(radius: number?): UICorner
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or Theme.radius.md)
	return c
end

function Components.stroke(color: Color3?, thickness: number?, transparency: number?): UIStroke
	local s = Instance.new("UIStroke")
	s.Color = color or Theme.color.stroke
	s.Thickness = thickness or 1
	s.Transparency = transparency or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	return s
end

function Components.padding(all: number?, opts: { l: number?, r: number?, t: number?, b: number? }?): UIPadding
	local p = Instance.new("UIPadding")
	local a = all or 0
	local o = opts or {}
	p.PaddingLeft = UDim.new(0, o.l or a)
	p.PaddingRight = UDim.new(0, o.r or a)
	p.PaddingTop = UDim.new(0, o.t or a)
	p.PaddingBottom = UDim.new(0, o.b or a)
	return p
end

function Components.vlist(gap: number?, align: Enum.HorizontalAlignment?): UIListLayout
	local l = Instance.new("UIListLayout")
	l.FillDirection = Enum.FillDirection.Vertical
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.Padding = UDim.new(0, gap or Theme.space.sm)
	l.HorizontalAlignment = align or Enum.HorizontalAlignment.Left
	return l
end

function Components.hlist(gap: number?, align: Enum.VerticalAlignment?): UIListLayout
	local l = Instance.new("UIListLayout")
	l.FillDirection = Enum.FillDirection.Horizontal
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.Padding = UDim.new(0, gap or Theme.space.sm)
	l.VerticalAlignment = align or Enum.VerticalAlignment.Center
	return l
end

function Components.gradient(seq: ColorSequence, rotation: number?): UIGradient
	local g = Instance.new("UIGradient")
	g.Color = seq
	g.Rotation = rotation or 0
	return g
end

-- ── containers ───────────────────────────────────────────────────────────────

export type FrameOpts = {
	name: string?,
	size: UDim2?,
	position: UDim2?,
	color: Color3?,
	transparency: number?,
	radius: number?,
	stroke: Color3?,
	strokeThickness: number?,
	autoY: boolean?, -- AutomaticSize Y
	layoutOrder: number?,
	parent: Instance?,
}

function Components.frame(opts: FrameOpts): Frame
	local f = Instance.new("Frame")
	f.Name = opts.name or "Frame"
	f.Size = opts.size or UDim2.fromScale(1, 0)
	f.Position = opts.position or UDim2.fromScale(0, 0)
	f.BackgroundColor3 = opts.color or Theme.color.surface
	f.BackgroundTransparency = opts.transparency or 0
	f.BorderSizePixel = 0
	f.LayoutOrder = opts.layoutOrder or 0
	if opts.autoY then
		f.AutomaticSize = Enum.AutomaticSize.Y
	end
	if opts.radius then
		Components.corner(opts.radius).Parent = f
	end
	if opts.stroke then
		Components.stroke(opts.stroke, opts.strokeThickness).Parent = f
	end
	if opts.parent then
		f.Parent = opts.parent
	end
	return f
end

function Components.scroll(opts: FrameOpts): ScrollingFrame
	local s = Instance.new("ScrollingFrame")
	s.Name = opts.name or "Scroll"
	s.Size = opts.size or UDim2.fromScale(1, 1)
	s.Position = opts.position or UDim2.fromScale(0, 0)
	s.BackgroundColor3 = opts.color or Theme.color.bg
	s.BackgroundTransparency = opts.transparency or 1
	s.BorderSizePixel = 0
	s.ScrollBarThickness = 4
	s.ScrollBarImageColor3 = Theme.color.strokeStrong
	s.AutomaticCanvasSize = Enum.AutomaticSize.Y
	s.CanvasSize = UDim2.fromScale(0, 0)
	s.ScrollingDirection = Enum.ScrollingDirection.Y
	if opts.parent then
		s.Parent = opts.parent
	end
	return s
end

-- ── text ──────────────────────────────────────────────────────────────────────

export type LabelOpts = {
	text: string,
	size: number?,
	color: Color3?,
	font: Enum.Font?,
	align: Enum.TextXAlignment?,
	wrap: boolean?,
	autoY: boolean?,
	layoutOrder: number?,
	width: UDim?,
	parent: Instance?,
	rich: boolean?,
}

function Components.label(opts: LabelOpts): TextLabel
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Text = opts.text
	t.TextSize = opts.size or Theme.text.base
	t.TextColor3 = opts.color or Theme.color.text
	t.Font = opts.font or Theme.font.regular
	t.TextXAlignment = opts.align or Enum.TextXAlignment.Left
	t.TextYAlignment = Enum.TextYAlignment.Top
	t.TextWrapped = opts.wrap or false
	t.RichText = opts.rich or false
	t.LayoutOrder = opts.layoutOrder or 0
	t.Size = UDim2.new(opts.width or UDim.new(1, 0), UDim.new(0, opts.size or Theme.text.base))
	if opts.autoY then
		t.AutomaticSize = Enum.AutomaticSize.Y
	end
	if opts.parent then
		t.Parent = opts.parent
	end
	return t
end

-- ── interactive ────────────────────────────────────────────────────────────────

local function bindHover(button: GuiButton, base: Color3, hover: Color3)
	local function to(c: Color3)
		TweenService:Create(button, TweenInfo.new(0.12), { BackgroundColor3 = c }):Play()
	end
	button.MouseEnter:Connect(function()
		to(hover)
	end)
	button.MouseLeave:Connect(function()
		to(base)
	end)
end

export type ButtonOpts = {
	text: string,
	size: UDim2?,
	color: Color3?,
	hoverColor: Color3?,
	textColor: Color3?,
	font: Enum.Font?,
	textSize: number?,
	radius: number?,
	gradient: ColorSequence?,
	stroke: Color3?,
	layoutOrder: number?,
	parent: Instance?,
	onClick: (() -> ())?,
}

--- A solid/gradient button. Returns the TextButton.
function Components.button(opts: ButtonOpts): TextButton
	local b = Instance.new("TextButton")
	b.AutoButtonColor = false
	b.Text = opts.text
	b.Font = opts.font or Theme.font.medium
	b.TextSize = opts.textSize or Theme.text.base
	b.TextColor3 = opts.textColor or Theme.color.text
	b.Size = opts.size or UDim2.new(1, 0, 0, 36)
	b.BackgroundColor3 = opts.color or Theme.color.surfaceAlt
	b.BorderSizePixel = 0
	b.LayoutOrder = opts.layoutOrder or 0
	Components.corner(opts.radius or Theme.radius.md).Parent = b
	if opts.gradient then
		Components.gradient(opts.gradient, 90).Parent = b
	end
	if opts.stroke then
		Components.stroke(opts.stroke).Parent = b
	end
	if not opts.gradient and not opts.hoverColor then
		bindHover(b, opts.color or Theme.color.surfaceAlt, Theme.color.surfaceHover)
	elseif opts.hoverColor then
		bindHover(b, opts.color or Theme.color.surfaceAlt, opts.hoverColor)
	end
	if opts.onClick then
		b.Activated:Connect(opts.onClick)
	end
	if opts.parent then
		b.Parent = opts.parent
	end
	return b
end

export type ChipController = {
	instance: TextButton,
	setSelected: (selected: boolean) -> (),
}

--- A selectable pill chip (generation-type selector). Returns a controller.
function Components.chip(text: string, onClick: (() -> ())?, parent: Instance?): ChipController
	local b = Instance.new("TextButton")
	b.AutoButtonColor = false
	b.Text = text
	b.Font = Theme.font.medium
	b.TextSize = Theme.text.sm
	b.TextColor3 = Theme.color.textDim
	b.AutomaticSize = Enum.AutomaticSize.X
	b.Size = UDim2.new(0, 0, 0, 28)
	b.BackgroundColor3 = Theme.color.surfaceAlt
	b.BorderSizePixel = 0
	Components.corner(Theme.radius.pill).Parent = b
	Components.padding(0, { l = Theme.space.md, r = Theme.space.md }).Parent = b
	local stroke = Components.stroke(Theme.color.stroke)
	stroke.Parent = b

	local selected = false
	local function setSelected(v: boolean)
		selected = v
		if selected then
			b.BackgroundColor3 = Theme.color.accentDeep
			b.TextColor3 = Theme.color.text
			stroke.Color = Theme.color.accentBright
			stroke.Transparency = 0
		else
			b.BackgroundColor3 = Theme.color.surfaceAlt
			b.TextColor3 = Theme.color.textDim
			stroke.Color = Theme.color.stroke
		end
	end

	b.MouseEnter:Connect(function()
		if not selected then
			b.TextColor3 = Theme.color.text
		end
	end)
	b.MouseLeave:Connect(function()
		if not selected then
			b.TextColor3 = Theme.color.textDim
		end
	end)
	if onClick then
		b.Activated:Connect(onClick)
	end
	if parent then
		b.Parent = parent
	end

	return { instance = b, setSelected = setSelected }
end

-- ── feedback widgets ────────────────────────────────────────────────────────────

export type SpinnerController = {
	instance: Frame,
	stop: () -> (),
}

--- A small spinning arc used while a build is in flight.
function Components.spinner(size: number?, color: Color3?, parent: Instance?): SpinnerController
	local s = size or 16
	local holder = Instance.new("ImageLabel")
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromOffset(s, s)
	-- A simple ring image baked into Studio's content; rotate it.
	holder.Image = "rbxasset://textures/loading/robloxTilt.png"
	holder.ImageColor3 = color or Theme.color.accentBright
	if parent then
		holder.Parent = parent
	end

	local running = true
	task.spawn(function()
		local rot = 0
		while running and holder.Parent do
			rot = (rot + 8) % 360
			holder.Rotation = rot
			task.wait(1 / 30)
		end
	end)

	return {
		instance = holder :: any,
		stop = function()
			running = false
			holder:Destroy()
		end,
	}
end

export type ProgressController = {
	instance: Frame,
	set: (fraction: number) -> (),
}

--- A thin progress bar (0..1).
function Components.progress(parent: Instance?): ProgressController
	local track = Components.frame({
		name = "Progress",
		size = UDim2.new(1, 0, 0, 4),
		color = Theme.color.surfaceAlt,
		radius = Theme.radius.pill,
	})
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = Theme.color.accent
	fill.BorderSizePixel = 0
	Components.corner(Theme.radius.pill).Parent = fill
	Components.gradient(Theme.accentGradient, 0).Parent = fill
	fill.Parent = track
	if parent then
		track.Parent = parent
	end
	return {
		instance = track,
		set = function(fraction: number)
			local f = math.clamp(fraction, 0, 1)
			TweenService:Create(fill, TweenInfo.new(0.2), { Size = UDim2.fromScale(f, 1) }):Play()
		end,
	}
end

export type BannerController = {
	instance: Frame,
	show: (text: string, color: Color3?) -> (),
	hide: () -> (),
}

--- A dismissible status banner (e.g. "Claude Code not connected").
function Components.banner(parent: Instance?): BannerController
	local b = Components.frame({
		name = "Banner",
		size = UDim2.new(1, 0, 0, 0),
		color = Theme.color.surfaceAlt,
		radius = Theme.radius.md,
		stroke = Theme.color.warning,
		autoY = true,
	})
	b.Visible = false
	Components.padding(Theme.space.sm, { l = Theme.space.md, r = Theme.space.md }).Parent = b
	local lbl = Components.label({
		text = "",
		size = Theme.text.sm,
		color = Theme.color.warning,
		font = Theme.font.medium,
		wrap = true,
		autoY = true,
		parent = b,
	})
	if parent then
		b.Parent = parent
	end
	return {
		instance = b,
		show = function(text: string, color: Color3?)
			lbl.Text = text
			lbl.TextColor3 = color or Theme.color.warning
			local s = b:FindFirstChildOfClass("UIStroke")
			if s then
				s.Color = color or Theme.color.warning
			end
			b.Visible = true
		end,
		hide = function()
			b.Visible = false
		end,
	}
end

return Components
