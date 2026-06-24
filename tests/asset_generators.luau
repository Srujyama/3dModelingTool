--[[
	asset_generators.luau — the actual asset payloads the Forge engine produces for real
	prompts, in the EXACT shapes the robloxstudio MCP tools require:

	  * create_build  → { id, style, palette, parts[] }  (parts as tuples)
	  * create_ui_tree → { className, name?, properties?, children[] }
	  * result manifest → { ok, summary, created[], ... }

	These mirror what engine/forge-engine.md instructs Claude Code to build. Keeping them as
	a module lets the validator (test_assets.luau) check them against the tool schemas without
	a live Studio — proving the engine's output is well-formed and importable, not just that
	the prompt text exists.
]]

local Gen = {}

-- ── 3D MODEL: "wooden crate" via create_build (procedural parts) ─────────────────
-- A 1x1x1 crate: 6 thin face panels + 4 corner posts. Honors an optional style palette.
function Gen.woodenCrate(style)
	local woodColor = "Brown"
	local woodMat = "WoodPlanks"
	if style and style.palette and style.palette[1] then
		woodColor = style.palette[1].brickColor
		woodMat = style.palette[1].material
	end
	local s = 4 -- crate side (studs)
	local t = 0.3 -- panel thickness
	local h = s / 2
	-- tuple: [px,py,pz, sx,sy,sz, rx,ry,rz, paletteKey, shape?, transparency?]
	local parts = {
		-- bottom, top
		{ 0, 0, 0, s, t, s, 0, 0, 0, "wood" },
		{ 0, s, 0, s, t, s, 0, 0, 0, "wood" },
		-- four walls
		{ 0, h, -h, s, s, t, 0, 0, 0, "wood" },
		{ 0, h, h, s, s, t, 0, 0, 0, "wood" },
		{ -h, h, 0, t, s, s, 0, 0, 0, "wood" },
		{ h, h, 0, t, s, s, 0, 0, 0, "wood" },
		-- corner posts (frame)
		{ -h, h, -h, t * 1.5, s, t * 1.5, 0, 0, 0, "frame" },
		{ h, h, -h, t * 1.5, s, t * 1.5, 0, 0, 0, "frame" },
		{ -h, h, h, t * 1.5, s, t * 1.5, 0, 0, 0, "frame" },
		{ h, h, h, t * 1.5, s, t * 1.5, 0, 0, 0, "frame" },
	}
	return {
		id = "misc/wooden_crate",
		style = "misc",
		palette = {
			wood = { woodColor, woodMat },
			frame = { "Dark orange", "Wood" },
		},
		parts = parts,
	}
end

-- ── 3D MODEL: "medieval well" via create_build ───────────────────────────────────
function Gen.medievalWell(style)
	local stoneColor, stoneMat = "Medium stone grey", "Cobblestone"
	if style and style.palette and style.palette[1] then
		stoneColor, stoneMat = style.palette[1].brickColor, style.palette[1].material
	end
	local parts = {}
	-- Circular stone wall: 12 blocks around radius 3.
	local segments = 12
	local radius = 3
	for i = 0, segments - 1 do
		local ang = (i / segments) * 2 * math.pi
		local x = math.cos(ang) * radius
		local z = math.sin(ang) * radius
		local ry = math.deg(-ang)
		table.insert(parts, { x, 1.5, z, 1.4, 3, 1, 0, ry, 0, "stone" })
	end
	-- Two posts + roof beam.
	table.insert(parts, { -radius, 5, 0, 0.6, 7, 0.6, 0, 0, 0, "wood" })
	table.insert(parts, { radius, 5, 0, 0.6, 7, 0.6, 0, 0, 0, "wood" })
	table.insert(parts, { 0, 8.5, 0, radius * 2 + 1, 0.5, 3, 0, 0, 0, "roof" })
	-- Water at the bottom.
	table.insert(parts, { 0, 0.5, 0, radius * 2 - 1, 0.4, radius * 2 - 1, 0, 0, 0, "water", "Cylinder", 0.3 })
	return {
		id = "medieval/well_01",
		style = "medieval",
		palette = {
			stone = { stoneColor, stoneMat },
			wood = { "Brown", "Wood" },
			roof = { "Reddish brown", "WoodPlanks" },
			water = { "Bright blue", "Glass" },
		},
		parts = parts,
	}
end

-- ── GUI: "fantasy shop UI" via create_ui_tree (native instances) ─────────────────
-- Real ScreenGui → Frame → (title TextLabel, item slots, claim button) tree, with dynamic
-- TextLabels kept separate (the whole point vs a flattened PNG). Honors style ui tokens.
function Gen.shopUI(style)
	local ui = (style and style.ui) or {}
	local bg = ui.panel or "1E1B26"
	local accent = ui.accent or "C8A24A"
	local textColor = ui.text or "EDE7D6"
	local corner = ui.corner or 10

	local function slot(i)
		return {
			className = "Frame",
			name = "Slot" .. i,
			properties = {
				Size = { type = "UDim2", scaleX = 0, offsetX = 90, scaleY = 0, offsetY = 90 },
				BackgroundColor3 = { type = "Color3", hex = "2A2440" },
				BorderSizePixel = 0,
				LayoutOrder = i,
			},
			children = {
				{ className = "UICorner", properties = { CornerRadius = { type = "UDim", scale = 0, offset = 8 } } },
				{
					className = "TextLabel",
					name = "Price",
					properties = {
						Size = { type = "UDim2", scaleX = 1, offsetX = 0, scaleY = 0, offsetY = 20 },
						Position = { type = "UDim2", scaleX = 0, offsetX = 0, scaleY = 1, offsetY = -20 },
						BackgroundTransparency = 1,
						Text = (i * 100) .. "g",
						TextColor3 = { type = "Color3", hex = accent },
						Font = "GothamBold",
						TextSize = 14,
					},
				},
			},
		}
	end

	local slots = {}
	for i = 1, 6 do
		slots[i] = slot(i)
	end

	return {
		className = "ScreenGui",
		name = "ShopUI",
		properties = { ResetOnSpawn = false, ZIndexBehavior = "Sibling" },
		children = {
			{
				className = "Frame",
				name = "Panel",
				properties = {
					Size = { type = "UDim2", scaleX = 0, offsetX = 420, scaleY = 0, offsetY = 320 },
					Position = { type = "UDim2", scaleX = 0.5, offsetX = -210, scaleY = 0.5, offsetY = -160 },
					BackgroundColor3 = { type = "Color3", hex = bg },
					BorderSizePixel = 0,
				},
				children = {
					{ className = "UICorner", properties = { CornerRadius = { type = "UDim", scale = 0, offset = corner } } },
					{ className = "UIStroke", properties = { Color = { type = "Color3", hex = accent }, Thickness = 2 } },
					{
						className = "TextLabel",
						name = "Title",
						properties = {
							Size = { type = "UDim2", scaleX = 1, offsetX = 0, scaleY = 0, offsetY = 44 },
							BackgroundTransparency = 1,
							Text = "Fantasy Shop",
							TextColor3 = { type = "Color3", hex = textColor },
							Font = "GothamBold",
							TextSize = 24,
						},
					},
					{
						className = "Frame",
						name = "Slots",
						properties = {
							Size = { type = "UDim2", scaleX = 1, offsetX = -32, scaleY = 0, offsetY = 200 },
							Position = { type = "UDim2", scaleX = 0, offsetX = 16, scaleY = 0, offsetY = 52 },
							BackgroundTransparency = 1,
						},
						children = (function()
							local c = {
								{
									className = "UIGridLayout",
									properties = {
										CellSize = { type = "UDim2", scaleX = 0, offsetX = 90, scaleY = 0, offsetY = 90 },
										CellPadding = { type = "UDim2", scaleX = 0, offsetX = 10, scaleY = 0, offsetY = 10 },
									},
								},
							}
							for _, sl in ipairs(slots) do
								table.insert(c, sl)
							end
							return c
						end)(),
					},
					{
						className = "TextButton",
						name = "ClaimButton",
						properties = {
							Size = { type = "UDim2", scaleX = 0, offsetX = 160, scaleY = 0, offsetY = 40 },
							Position = { type = "UDim2", scaleX = 0.5, offsetX = -80, scaleY = 1, offsetY = -52 },
							BackgroundColor3 = { type = "Color3", hex = accent },
							Text = "Claim",
							TextColor3 = { type = "Color3", hex = "1A1410" },
							Font = "GothamBold",
							TextSize = 18,
							BorderSizePixel = 0,
						},
						children = {
							{ className = "UICorner", properties = { CornerRadius = { type = "UDim", scale = 0, offset = 8 } } },
						},
					},
				},
			},
		},
	}
end

-- ── RESULT MANIFEST ──────────────────────────────────────────────────────────────
function Gen.manifest(summary, created)
	return {
		ok = true,
		summary = summary,
		created = created,
		modified = {},
		deleted = {},
		errors = {},
		tookSeconds = 8,
	}
end

return Gen
