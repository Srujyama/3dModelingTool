--[[
	test_assets.luau — validates that the asset payloads the Forge engine produces are
	well-formed against the robloxstudio MCP tool schemas, so they would actually import into
	Studio (not just "the prompt ran"). No live Studio needed — we check structure.

	Run: luau test_assets.luau
]]

local Gen = require("./asset_generators")
local JSON = require("./json")

local passed, failed = 0, 0
local failures = {}
local ctx = "?"

local function ok(cond, msg)
	if cond then
		passed = passed + 1
	else
		failed = failed + 1
		local line = string.format("  ✗ [%s] %s", ctx, msg)
		table.insert(failures, line)
		print(line)
	end
end
local function section(name)
	ctx = name
	print("\n▶ " .. name)
end

-- ── valid sets from the MCP schemas ─────────────────────────────────────────────
local VALID_SHAPES = { Block = true, Wedge = true, Cylinder = true, Ball = true, CornerWedge = true }
local VALID_STYLES = { medieval = true, modern = true, nature = true, scifi = true, misc = true }
-- A representative allowlist of real Roblox GUI classes used by create_ui_tree.
local VALID_GUI_CLASSES = {
	ScreenGui = true,
	Frame = true,
	TextLabel = true,
	TextButton = true,
	ImageLabel = true,
	ImageButton = true,
	UICorner = true,
	UIStroke = true,
	UIGridLayout = true,
	UIListLayout = true,
	UIPadding = true,
	ScrollingFrame = true,
}
-- BrickColor names we use (a small subset; real BrickColor has ~1000). Just sanity that
-- they're non-empty strings — the engine is responsible for real names.
local function isBrickColorName(s)
	return type(s) == "string" and #s > 0
end
local VALID_MATERIALS = {
	WoodPlanks = true,
	Wood = true,
	Cobblestone = true,
	Concrete = true,
	Glass = true,
	Metal = true,
	Slate = true,
	SmoothPlastic = true,
	Brick = true,
	Sand = true,
}

-- ── create_build validator ──────────────────────────────────────────────────────
local function validateBuild(build, label)
	ctx = label
	ok(type(build.id) == "string" and build.id:find("/"), "id has style/name form: " .. tostring(build.id))
	ok(VALID_STYLES[build.style] == true, "style is valid enum: " .. tostring(build.style))
	ok(type(build.palette) == "table" and next(build.palette) ~= nil, "palette is a non-empty map")

	-- Palette entries: [BrickColor, Material] (+ optional MaterialVariant).
	for key, tuple in pairs(build.palette) do
		ok(type(key) == "string" and #key > 0, "palette key '" .. tostring(key) .. "' is a non-empty string")
		ok(type(tuple) == "table" and #tuple >= 2, "palette[" .. key .. "] has >=2 elements")
		ok(isBrickColorName(tuple[1]), "palette[" .. key .. "][1] is a BrickColor name: " .. tostring(tuple[1]))
		ok(VALID_MATERIALS[tuple[2]] == true, "palette[" .. key .. "][2] is a known Material: " .. tostring(tuple[2]))
	end

	-- Parts: tuple form [px,py,pz, sx,sy,sz, rx,ry,rz, key, shape?, transparency?].
	ok(type(build.parts) == "table" and #build.parts > 0, "has at least one part")
	ok(#build.parts <= 10000, "part count within 10k cap (" .. #build.parts .. ")")
	local paletteKeys = build.palette
	for i, p in ipairs(build.parts) do
		local pre = label .. " part#" .. i
		ok(type(p) == "table" and #p >= 10, pre .. ": tuple has >=10 elements")
		-- numeric pos/size/rot
		local allNum = true
		for j = 1, 9 do
			if type(p[j]) ~= "number" then
				allNum = false
			end
		end
		ok(allNum, pre .. ": pos/size/rot are all numbers")
		-- positive sizes
		ok(p[4] > 0 and p[5] > 0 and p[6] > 0, pre .. ": sizes are positive")
		-- palette key references a real palette entry
		local key = p[10]
		ok(type(key) == "string" and paletteKeys[key] ~= nil, pre .. ": paletteKey '" .. tostring(key) .. "' exists in palette")
		-- optional shape valid
		if p[11] ~= nil then
			ok(VALID_SHAPES[p[11]] == true, pre .. ": shape is valid: " .. tostring(p[11]))
		end
		-- optional transparency in [0,1]
		if p[12] ~= nil then
			ok(type(p[12]) == "number" and p[12] >= 0 and p[12] <= 1, pre .. ": transparency in [0,1]")
		end
	end

	-- The whole build must JSON round-trip (it's sent over MCP as JSON).
	local encoded = JSON.encode(build)
	local decoded = JSON.decode(encoded)
	ok(decoded.id == build.id and #decoded.parts == #build.parts, label .. ": JSON round-trips intact")
end

-- ── create_ui_tree validator ────────────────────────────────────────────────────
local function validatePropertyValue(name, v, path)
	if type(v) ~= "table" then
		-- primitive (string/number/bool) is fine
		ok(true, path .. "." .. name .. " primitive ok")
		return
	end
	-- structured value: must declare a type and the right shape
	local t = v.type
	if t == "UDim2" then
		ok(
			type(v.scaleX) == "number"
				and type(v.offsetX) == "number"
				and type(v.scaleY) == "number"
				and type(v.offsetY) == "number",
			path .. "." .. name .. " UDim2 has scaleX/offsetX/scaleY/offsetY"
		)
	elseif t == "UDim" then
		ok(type(v.scale) == "number" and type(v.offset) == "number", path .. "." .. name .. " UDim has scale/offset")
	elseif t == "Color3" then
		ok(type(v.hex) == "string" and #v.hex == 6, path .. "." .. name .. " Color3 has 6-char hex")
	else
		ok(false, path .. "." .. name .. " has unknown structured type: " .. tostring(t))
	end
end

local nodeCount = 0
local function validateUINode(node, path, isRoot)
	nodeCount = nodeCount + 1
	ok(type(node.className) == "string", path .. ": has className")
	ok(VALID_GUI_CLASSES[node.className] == true, path .. ": className is a valid GUI class: " .. tostring(node.className))
	if isRoot then
		ok(node.className == "ScreenGui", "root is a ScreenGui")
	end
	if node.properties then
		ok(type(node.properties) == "table", path .. ": properties is a table")
		for k, v in pairs(node.properties) do
			validatePropertyValue(k, v, path)
		end
	end
	if node.children then
		ok(type(node.children) == "table", path .. ": children is an array")
		for i, child in ipairs(node.children) do
			validateUINode(child, path .. "/" .. (child.name or child.className or i), false)
		end
	end
end

-- ── run ──────────────────────────────────────────────────────────────────────────
print("=== ASSET PAYLOAD VALIDATION ===")

section("3D model: wooden crate (no style)")
validateBuild(Gen.woodenCrate(nil), "crate")

section("3D model: wooden crate (with Dark Fantasy style palette)")
local style = { palette = { { brickColor = "Reddish brown", material = "Wood" } } }
local styledCrate = Gen.woodenCrate(style)
validateBuild(styledCrate, "crate-styled")
ok(styledCrate.palette.wood[1] == "Reddish brown", "style palette applied to crate wood color")

section("3D model: medieval well")
local well = Gen.medievalWell(nil)
validateBuild(well, "well")
ok(#well.parts >= 12, "well has the 12 circular wall segments plus extras (" .. #well.parts .. ")")

section("GUI: fantasy shop UI (native instance tree)")
nodeCount = 0
local shop = Gen.shopUI({ ui = { panel = "14121A", accent = "C8A24A", text = "EDE7D6", corner = 10 } })
validateUINode(shop, "ShopUI", true)
ok(nodeCount >= 15, "shop UI built a non-trivial instance tree (" .. nodeCount .. " nodes)")
-- Verify dynamic text is in real TextLabels (not baked into an image) — the key win.
local function findClass(node, cls, acc)
	if node.className == cls then
		acc[#acc + 1] = node
	end
	if node.children then
		for _, c in ipairs(node.children) do
			findClass(c, cls, acc)
		end
	end
	return acc
end
local labels = findClass(shop, "TextLabel", {})
local buttons = findClass(shop, "TextButton", {})
ok(#labels >= 7, "shop has dynamic TextLabels (title + 6 prices = " .. #labels .. ")")
ok(#buttons >= 1, "shop has a real TextButton (Claim)")
-- The shop tree JSON round-trips.
local shopJson = JSON.encode(shop)
ok(JSON.decode(shopJson).className == "ScreenGui", "shop UI JSON round-trips")

section("result manifest")
local m = Gen.manifest("Built a wooden crate Model (10 parts).", { { path = "game.Workspace.WoodenCrate", className = "Model" } })
local mj = JSON.encode(m)
local md = JSON.decode(mj)
ok(md.ok == true, "manifest ok=true survives encode/decode")
ok(md.created[1].path == "game.Workspace.WoodenCrate", "manifest created path intact")
ok(#mj < 150000, "manifest under the StringValue soft cap")

-- ── summary ────────────────────────────────────────────────────────────────────
print("\n" .. string.rep("─", 60))
print(string.format("ASSET TESTS: %d passed, %d failed", passed, failed))
if failed > 0 then
	print("\nFAILURES:")
	for _, f in ipairs(failures) do
		print(f)
	end
	error("test_assets: " .. failed .. " assertion(s) failed", 0)
else
	print("ALL ASSET TESTS PASSED ✓")
end
