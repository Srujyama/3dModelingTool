--[[
	loader.luau — loads the REAL Forge source (embedded in forge_sources.luau) and runs it
	under the Roblox mock. The source uses `require(script.Parent.X)` and
	`require(script.Parent.Parent.Bridge.X)`, so we build a fake `script` instance tree that
	mirrors the Rojo layout and a require() that walks it:

	    ForgePlugin (folder)
	      ├── Bridge (folder)
	      │     ├── Protocol   (the real Protocol.lua)
	      │     └── Bridge      (the real Bridge.lua)
	      └── State (folder)
	            └── Store        (the real Store.lua)

	Each module chunk gets its own `script` pointing at its node, plus the injected globals
	(game, task, os, plugin, Instance, HttpService, require). Modules are evaluated lazily and
	cached, exactly like Roblox ModuleScripts.
]]

local Mock = require("./roblox_mock")
local sources = require("./forge_sources")

-- ── fake script tree ──────────────────────────────────────────────────────────
-- A script node: { Name, Parent, _children = {name->node}, _sourceKey = "Bridge"? }
local function node(name, parent)
	local n = { Name = name, Parent = parent, _children = {} }
	if parent then
		parent._children[name] = n
	end
	return n
end

-- Give nodes a metatable so `script.Parent.X` returns the child node by name.
local nodeMeta = {
	__index = function(self, k)
		if k == "Parent" then
			return rawget(self, "Parent")
		end
		local kids = rawget(self, "_children")
		if kids and kids[k] then
			return kids[k]
		end
		return rawget(self, k)
	end,
}
local function mt(n)
	return setmetatable(n, nodeMeta)
end

local root = mt(node("ForgePlugin"))
local bridgeFolder = mt(node("Bridge", root))
local stateFolder = mt(node("State", root))

local protocolNode = mt(node("Protocol", bridgeFolder))
local bridgeNode = mt(node("Bridge", bridgeFolder))
local storeNode = mt(node("Store", stateFolder))

protocolNode._sourceKey = "Protocol"
bridgeNode._sourceKey = "Bridge"
storeNode._sourceKey = "Store"

-- ── module cache + require ──────────────────────────────────────────────────────
local cache = {}

local function makeEnv(scriptNode, requireFn)
	-- Each module sees the mock globals. Fall back to the real _G for built-ins
	-- (string, table, math, pcall, type, ipairs, pairs, tostring, tonumber, etc.).
	local env = setmetatable({
		game = Mock.game,
		task = Mock.task,
		os = Mock.os,
		plugin = Mock.plugin,
		Instance = Mock.Instance,
		BrickColor = Mock.BrickColor,
		script = scriptNode,
		require = requireFn,
	}, { __index = _G })
	return env
end

local requireFn -- forward declare

requireFn = function(target)
	-- target is a fake script node (from script.Parent.X navigation).
	if type(target) == "table" and target._sourceKey then
		local key = target._sourceKey
		if cache[key] ~= nil then
			return cache[key]
		end
		local src = sources[key]
		assert(src, "loader: no embedded source for " .. tostring(key))
		local chunk, err = loadstring(src, "=" .. key)
		if not chunk then
			error("loader: failed to compile " .. key .. ": " .. tostring(err))
		end
		setfenv(chunk, makeEnv(target, requireFn))
		local result = chunk()
		cache[key] = result
		return result
	end
	error("loader: cannot require " .. tostring(target))
end

local Loader = {}
Loader.Mock = Mock

function Loader.reset()
	cache = {}
	Mock.resetPluginSettings()
end

function Loader.require(name)
	if name == "Protocol" then
		return requireFn(protocolNode)
	elseif name == "Bridge" then
		return requireFn(bridgeNode)
	elseif name == "Store" then
		return requireFn(storeNode)
	end
	error("Loader.require: unknown module " .. tostring(name))
end

return Loader
