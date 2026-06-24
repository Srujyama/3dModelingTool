--!strict
--[[
	Theme.lua — ForgeGUI-style design tokens.

	A dark, modern panel palette echoing the forgegui.com landing page: deep
	near-black backgrounds, a warm violet→magenta accent, gold highlight for assets,
	generous radii and soft strokes. Centralizing these means every component reads
	the same tokens and a re-theme is a one-file change.
]]

local Theme = {}

Theme.color = {
	-- Surfaces (darkest → lightest).
	bg = Color3.fromHex("#0C0A12"), -- app background
	surface = Color3.fromHex("#141020"), -- panels / cards
	surfaceAlt = Color3.fromHex("#1B1530"), -- inputs / raised rows
	surfaceHover = Color3.fromHex("#241B40"),
	stroke = Color3.fromHex("#2A2342"), -- hairline borders
	strokeStrong = Color3.fromHex("#3A2F5C"),

	-- Brand accent gradient (forgegui violet → magenta).
	accent = Color3.fromHex("#8B5CF6"),
	accentBright = Color3.fromHex("#A78BFA"),
	accentDeep = Color3.fromHex("#6D28D9"),
	magenta = Color3.fromHex("#D946EF"),

	-- Asset highlight (the "gold" of generated icons/thumbnails).
	gold = Color3.fromHex("#E8B84B"),

	-- Text.
	text = Color3.fromHex("#F4F1FB"),
	textDim = Color3.fromHex("#A79FC4"),
	textFaint = Color3.fromHex("#6E6690"),

	-- Status semantics.
	success = Color3.fromHex("#34D399"),
	warning = Color3.fromHex("#FBBF24"),
	error = Color3.fromHex("#F87171"),
	info = Color3.fromHex("#60A5FA"),

	-- Bubbles.
	userBubble = Color3.fromHex("#241B40"),
	assistantBubble = Color3.fromHex("#141020"),
}

-- A reusable accent gradient (violet → magenta), e.g. for the send button & header.
Theme.accentGradient = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Theme.color.accent),
	ColorSequenceKeypoint.new(1, Theme.color.magenta),
})

Theme.font = {
	regular = Enum.Font.Gotham,
	medium = Enum.Font.GothamMedium,
	bold = Enum.Font.GothamBold,
	mono = Enum.Font.Code,
}

Theme.text = {
	xs = 11,
	sm = 13,
	base = 14,
	md = 16,
	lg = 20,
	xl = 26,
}

Theme.space = {
	xs = 4,
	sm = 8,
	md = 12,
	lg = 16,
	xl = 24,
}

Theme.radius = {
	sm = 6,
	md = 10,
	lg = 14,
	pill = 999,
}

-- Map a request state to a status color + human label.
function Theme.statusOf(state: string): (Color3, string)
	if state == "queued" then
		return Theme.color.textDim, "Queued"
	elseif state == "claimed" then
		return Theme.color.info, "Starting"
	elseif state == "working" then
		return Theme.color.accentBright, "Building"
	elseif state == "done" then
		return Theme.color.success, "Done"
	elseif state == "error" then
		return Theme.color.error, "Failed"
	elseif state == "canceled" then
		return Theme.color.warning, "Canceled"
	end
	return Theme.color.textDim, state
end

return Theme
