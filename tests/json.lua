--[[
	json.lua — a small, correct JSON encoder/decoder for the test harness, standing in for
	HttpService:JSONEncode/JSONDecode. Handles objects, arrays, strings, numbers, booleans,
	and null. Array vs object detection mirrors Roblox: a table with consecutive integer
	keys from 1 encodes as an array; otherwise as an object. Empty tables encode as `[]`
	(matching how Roblox encodes an empty Lua table, which the protocol treats as an array).
]]

local json = {}

-- ── encode ──────────────────────────────────────────────────────────────────
local escapes = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}

local function encodeString(s)
	return '"' .. s:gsub('[%z\1-\31\\"]', function(c)
		return escapes[c] or string.format("\\u%04x", string.byte(c))
	end) .. '"'
end

local function isArray(t)
	local n = 0
	for k in pairs(t) do
		if type(k) ~= "number" then
			return false
		end
		n = n + 1
	end
	-- consecutive 1..n ?
	for i = 1, n do
		if t[i] == nil then
			return false
		end
	end
	return true, n
end

local encodeValue

local function encodeTable(t)
	if next(t) == nil then
		return "[]" -- empty table => array, matching protocol expectations
	end
	local arr, n = isArray(t)
	if arr then
		local parts = {}
		for i = 1, n do
			parts[i] = encodeValue(t[i])
		end
		return "[" .. table.concat(parts, ",") .. "]"
	else
		local parts = {}
		-- Stable key order for deterministic output (helps test assertions).
		local keys = {}
		for k in pairs(t) do
			keys[#keys + 1] = tostring(k)
		end
		table.sort(keys)
		for _, k in ipairs(keys) do
			parts[#parts + 1] = encodeString(k) .. ":" .. encodeValue(t[k])
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
end

function encodeValue(v)
	local tv = type(v)
	if tv == "string" then
		return encodeString(v)
	elseif tv == "number" then
		if v ~= v then
			return "null"
		end -- NaN
		return tostring(v)
	elseif tv == "boolean" then
		return v and "true" or "false"
	elseif tv == "nil" then
		return "null"
	elseif tv == "table" then
		return encodeTable(v)
	end
	error("json: cannot encode " .. tv)
end

function json.encode(v)
	return encodeValue(v)
end

-- ── decode ──────────────────────────────────────────────────────────────────
local function decodeError(s, i, msg)
	error(string.format("json decode error at %d: %s", i, msg))
end

local decodeValue

local function skipWhitespace(s, i)
	local _, j = s:find("^[ \t\r\n]*", i)
	return (j or i - 1) + 1
end

local function decodeString(s, i)
	-- s[i] == '"'
	local buf = {}
	i = i + 1
	while i <= #s do
		local c = s:sub(i, i)
		if c == '"' then
			return table.concat(buf), i + 1
		elseif c == "\\" then
			local n = s:sub(i + 1, i + 1)
			local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
			if map[n] then
				buf[#buf + 1] = map[n]
				i = i + 2
			elseif n == "u" then
				local hex = s:sub(i + 2, i + 5)
				buf[#buf + 1] = utf8.char(tonumber(hex, 16) or 63)
				i = i + 6
			else
				decodeError(s, i, "bad escape")
			end
		else
			buf[#buf + 1] = c
			i = i + 1
		end
	end
	decodeError(s, i, "unterminated string")
end

local function decodeNumber(s, i)
	local num = s:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", i)
	return tonumber(num), i + #num
end

local function decodeArray(s, i)
	local arr = {}
	i = skipWhitespace(s, i + 1)
	if s:sub(i, i) == "]" then
		return arr, i + 1
	end
	while true do
		local v
		v, i = decodeValue(s, i)
		arr[#arr + 1] = v
		i = skipWhitespace(s, i)
		local c = s:sub(i, i)
		if c == "]" then
			return arr, i + 1
		elseif c == "," then
			i = skipWhitespace(s, i + 1)
		else
			decodeError(s, i, "expected , or ]")
		end
	end
end

local function decodeObject(s, i)
	local obj = {}
	i = skipWhitespace(s, i + 1)
	if s:sub(i, i) == "}" then
		return obj, i + 1
	end
	while true do
		i = skipWhitespace(s, i)
		if s:sub(i, i) ~= '"' then
			decodeError(s, i, "expected key string")
		end
		local key
		key, i = decodeString(s, i)
		i = skipWhitespace(s, i)
		if s:sub(i, i) ~= ":" then
			decodeError(s, i, "expected :")
		end
		i = skipWhitespace(s, i + 1)
		local v
		v, i = decodeValue(s, i)
		obj[key] = v
		i = skipWhitespace(s, i)
		local c = s:sub(i, i)
		if c == "}" then
			return obj, i + 1
		elseif c == "," then
			i = i + 1
		else
			decodeError(s, i, "expected , or }")
		end
	end
end

function decodeValue(s, i)
	i = skipWhitespace(s, i)
	local c = s:sub(i, i)
	if c == '"' then
		return decodeString(s, i)
	elseif c == "{" then
		return decodeObject(s, i)
	elseif c == "[" then
		return decodeArray(s, i)
	elseif c == "t" then
		if s:sub(i, i + 3) == "true" then
			return true, i + 4
		end
	elseif c == "f" then
		if s:sub(i, i + 4) == "false" then
			return false, i + 5
		end
	elseif c == "n" then
		if s:sub(i, i + 3) == "null" then
			return nil, i + 4
		end
	elseif c == "-" or c:match("%d") then
		return decodeNumber(s, i)
	end
	decodeError(s, i, "unexpected char '" .. c .. "'")
end

function json.decode(s)
	local v = decodeValue(s, 1)
	return v
end

return json
