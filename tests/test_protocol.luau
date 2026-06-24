--[[
	test_protocol.luau — end-to-end execution of the REAL Bridge.lua + Store.lua + Protocol.lua
	under the Roblox mock. Each scenario simulates the Claude Code engine side by writing the
	bridge fields it owns (State / StatusText / Result / heartbeat) exactly as the execute_luau
	steps in engine/forge-engine.md would, then asserts the plugin side reacted correctly.

	Run: luau test_protocol.luau
]]

local Loader = require("./loader")
local Mock = Loader.Mock

-- ── test framework ──────────────────────────────────────────────────────────
local passed, failed = 0, 0
local failures = {}
local currentTest = "?"

local function eq(a, b, msg)
	if a == b then
		passed = passed + 1
	else
		failed = failed + 1
		local line = string.format("  ✗ [%s] %s\n      expected: %s\n      got:      %s", currentTest, msg or "", tostring(b), tostring(a))
		table.insert(failures, line)
		print(line)
	end
end

local function ok(cond, msg)
	eq(cond and true or false, true, msg)
end

-- Tracks bridge objects so we can stop prior ones (kills their heartbeat threads),
-- mirroring real Studio where exactly one plugin instance runs at a time.
local liveBridges = {}

local function test(name, fn)
	-- Stop any bridges from prior scenarios so their parked heartbeat coroutines don't
	-- wake during this test's Mock.tick and fight over the shared bridge folder.
	for _, b in ipairs(liveBridges) do
		pcall(function()
			b:stop()
		end)
	end
	liveBridges = {}

	currentTest = name
	Loader.reset()
	Mock.setTime(1_000_000)
	Mock.setSelection({})
	-- Clear any parked sleepers/deferred work from prior scenarios.
	Mock.resetScheduler()
	local existing = Mock.ServerStorage:FindFirstChild("ForgeBridge")
	if existing then
		existing:Destroy()
	end
	print("\n▶ " .. name)
	fn()
end

-- ── engine-side helpers (simulate Claude Code's execute_luau writes) ─────────────
local function bridgeFolder()
	return Mock.ServerStorage:FindFirstChild("ForgeBridge")
end
local function reqFolder(id)
	return bridgeFolder():FindFirstChild("Requests"):FindFirstChild("Req_" .. id)
end

-- Step 1: Claude heartbeats + scans (returns queued ids, lowest first).
local function engineScan()
	local b = bridgeFolder()
	b:SetAttribute("ClaudeHeartbeat", Mock.os.time())
	b:SetAttribute("ClaudeStatus", "polling")
	local out = {}
	for _, req in ipairs(b:FindFirstChild("Requests"):GetChildren()) do
		if req:GetAttribute("Ready") == true and req:GetAttribute("State") == "queued" then
			table.insert(out, req:GetAttribute("Id"))
		end
	end
	table.sort(out)
	return out
end

-- Step 2: atomic claim (check-and-set on State).
local function engineClaim(id)
	local req = reqFolder(id)
	if not req then
		return "gone"
	end
	if req:GetAttribute("State") ~= "queued" then
		return "lost"
	end
	req:SetAttribute("State", "claimed")
	req:SetAttribute("ClaimedAt", Mock.os.time())
	req:SetAttribute("UpdatedAt", Mock.os.time())
	return "claimed"
end

local function engineWorking(id)
	local req = reqFolder(id)
	req:SetAttribute("State", "working")
	req:SetAttribute("UpdatedAt", Mock.os.time())
end

local function engineStream(id, text, pct)
	local req = reqFolder(id)
	req:FindFirstChild("StatusText").Value = text
	req:SetAttribute("Progress", pct)
	req:SetAttribute("UpdatedAt", Mock.os.time())
	bridgeFolder():SetAttribute("ClaudeHeartbeat", Mock.os.time())
end

-- Step 5: finish — write Result then flip terminal State (same execute_luau order).
local function engineFinish(id, manifest, state)
	local req = reqFolder(id)
	req:FindFirstChild("Result").Value = Mock.HttpService:JSONEncode(manifest)
	req:SetAttribute("Progress", 100)
	req:SetAttribute("State", state or "done")
	req:SetAttribute("UpdatedAt", Mock.os.time())
end

-- ── scenarios ────────────────────────────────────────────────────────────────
local Bridge = Loader.require("Bridge")

local function newBridge(events)
	local b = Bridge.new(Mock.plugin, events)
	table.insert(liveBridges, b)
	return b
end

-- Scenario 1: happy-path round trip (the real-world flow).
test("happy path: enqueue → scan → claim → working → stream → done", function()
	local updates, terminals = {}, {}
	local bridge = newBridge({
		onRequestUpdate = function(v)
			table.insert(updates, { id = v.id, state = v.state, status = v.statusText, progress = v.progress })
		end,
		onRequestTerminal = function(v)
			table.insert(terminals, { id = v.id, state = v.state, result = v.result })
		end,
	})
	bridge:start()

	local id = bridge:enqueue("a wooden crate", "model")
	eq(id, 1, "first id is 1")

	-- Claude scans and sees the queued request (commit barrier respected).
	local queue = engineScan()
	eq(#queue, 1, "scan finds 1 queued request")
	eq(queue[1], 1, "queued id is 1")

	-- Claim → claimed (plugin should fire an update).
	eq(engineClaim(1), "claimed", "claim succeeds")
	Mock.drain()
	ok(#updates >= 1, "plugin observed a state update after claim")
	eq(updates[#updates].state, "claimed", "last update state is claimed")

	-- Working + stream.
	engineWorking(1)
	engineStream(1, "Placing 12 parts…", 50)
	Mock.drain()
	local last = updates[#updates]
	eq(last.status, "Placing 12 parts…", "status text streamed through")
	eq(last.progress, 50, "progress streamed through")

	-- Finish.
	engineFinish(1, {
		ok = true,
		summary = "Built a wooden crate Model (12 parts).",
		created = { { path = "game.Workspace.WoodenCrate", className = "Model" } },
		tookSeconds = 8,
	}, "done")
	Mock.drain()

	eq(#terminals, 1, "exactly one terminal callback")
	eq(terminals[1].state, "done", "terminal state is done")
	ok(terminals[1].result:find("WoodenCrate"), "terminal result contains the created path")

	-- The request folder is reaped (deleted) after terminal.
	ok(reqFolder(1) == nil, "request folder reaped after done")
end)

-- Scenario 2 (M2): Result written in the SAME step as terminal State must not be lost.
test("M2: result+state written together survives the deferred reap", function()
	local terminals = {}
	local bridge = newBridge({
		onRequestTerminal = function(v)
			table.insert(terminals, { result = v.result, state = v.state })
		end,
	})
	bridge:start()
	local id = bridge:enqueue("fantasy shop UI", "gui")
	engineClaim(id)
	engineWorking(id)
	Mock.drain()

	-- Simulate Claude's single finish call: Result set, then State flipped, same tick.
	local req = reqFolder(id)
	req:FindFirstChild("Result").Value = '{"ok":true,"summary":"shop ui","created":[{"path":"game.StarterGui.ShopUI","className":"ScreenGui"}]}'
	req:SetAttribute("State", "done") -- triggers deferred reap
	Mock.drain() -- run the deferred reap

	eq(#terminals, 1, "one terminal callback")
	ok(terminals[1].result ~= "" and terminals[1].result ~= nil, "result NOT lost (deferred reap read it fresh)")
	ok(terminals[1].result:find("ShopUI"), "result contains ShopUI path")
end)

-- Scenario 3 (C1): bridge rebuild must rewire watchers; results still reach the UI.
test("C1: after the bridge is deleted+rebuilt, new requests are still watched", function()
	local terminals = {}
	local bridge = newBridge({
		onRequestTerminal = function(v)
			table.insert(terminals, v.id)
		end,
	})
	bridge:start()

	-- Process one request normally.
	local id1 = bridge:enqueue("medieval well", "model")
	engineClaim(id1)
	engineFinish(id1, { ok = true, summary = "well", created = {} }, "done")
	Mock.drain()
	eq(#terminals, 1, "first request reached terminal")

	-- USER DELETES the bridge folder (the C1 trigger).
	bridgeFolder():Destroy()
	ok(Mock.ServerStorage:FindFirstChild("ForgeBridge") == nil, "bridge deleted")

	-- The liveness timer ticks, detects the missing bridge, and rebuilds + rewires.
	-- start() spawned a heartbeat loop parked on task.wait(3); advance time to wake it.
	Mock.tick(3)
	ok(Mock.ServerStorage:FindFirstChild("ForgeBridge") ~= nil, "bridge rebuilt by liveness tick")

	-- New request into the REBUILT bridge.
	local id2 = bridge:enqueue("stone tower", "model")
	ok(id2 > id1, "id is monotonic across rebuild (no reuse)")
	engineClaim(id2)
	engineFinish(id2, { ok = true, summary = "tower", created = {} }, "done")
	Mock.drain()

	-- THE BUG WOULD BE: this terminal never fires because the watcher was stranded.
	eq(#terminals, 2, "second request (post-rebuild) ALSO reached terminal — watchers rewired")
	eq(terminals[2], id2, "the second terminal is the post-rebuild request")
end)

-- Scenario 4 (C2): request ids never repeat across a full plugin restart.
test("C2: ids persist across plugin restart (no collision with old transcript)", function()
	-- First session: issue a few ids.
	local b1 = newBridge({})
	b1:start()
	b1:enqueue("p1", "auto")
	b1:enqueue("p2", "auto")
	local lastId = b1:enqueue("p3", "auto")
	eq(lastId, 3, "third id is 3")
	b1:stop() -- destroys the bridge folder (transient)
	ok(bridgeFolder() == nil, "bridge destroyed on stop")

	-- Persisted floor should be 3.
	eq(Mock.getPluginSetting("Forge_LastRequestId_v1"), 3, "id floor persisted to plugin settings")

	-- Second session: brand-new bridge object reading the same persistent settings.
	local b2 = newBridge({})
	b2:start()
	local nextId = b2:enqueue("p4", "auto")
	ok(nextId > lastId, "next id after restart is strictly greater than last (no reuse)")
	eq(nextId, 4, "next id is 4, not 1")
end)

-- Scenario 5: commit barrier — a half-written request is invisible to the scan.
test("commit barrier: Ready=false request is not seen by the engine scan", function()
	local bridge = newBridge({})
	bridge:start()
	-- Manually create a half-written request (Ready=false), bypassing enqueue's commit.
	local b = bridgeFolder()
	local reqs = b:FindFirstChild("Requests")
	local req = Mock.Instance.new("Folder")
	req.Name = "Req_99"
	req:SetAttribute("Id", 99)
	req:SetAttribute("State", "queued")
	req:SetAttribute("Ready", false) -- NOT committed
	local p = Mock.Instance.new("StringValue")
	p.Name = "Prompt"
	p.Parent = req
	req.Parent = reqs

	local queue = engineScan()
	eq(#queue, 0, "scan ignores the uncommitted (Ready=false) request")

	-- Now commit it.
	req:SetAttribute("Ready", true)
	queue = engineScan()
	eq(#queue, 1, "scan sees it once committed")
end)

-- Scenario 5b: enqueue() itself must respect the barrier — at the instant the request
-- folder is parented (ChildAdded), Prompt must already be set AND Ready must STILL be
-- false (it's flipped to true only on the next line). This catches a broken ordering in
-- the real enqueue, which scenario 5 (manual construction) cannot.
test("commit barrier: enqueue parents folder with Prompt set but Ready still false", function()
	local bridge = newBridge({})
	bridge:start()
	local reqs = bridgeFolder():FindFirstChild("Requests")
	local observed = nil
	-- Hook ChildAdded to snapshot the request's state at parent-time.
	local conn = reqs.ChildAdded:Connect(function(child)
		if child.Name:sub(1, 4) == "Req_" then
			local promptChild = child:FindFirstChild("Prompt")
			observed = {
				ready = child:GetAttribute("Ready"),
				prompt = promptChild and promptChild.Value or "<missing>",
			}
		end
	end)
	bridge:enqueue("build a castle", "scene")
	conn:Disconnect()

	ok(observed ~= nil, "ChildAdded fired during enqueue")
	eq(observed.ready, false, "Ready is STILL false at parent-time (commit comes after)")
	eq(observed.prompt, "build a castle", "Prompt is ALREADY set at parent-time")

	-- And after enqueue returns, it's committed and visible.
	local queue = engineScan()
	eq(#queue, 1, "request visible to scan after enqueue completes")
end)

-- Scenario 6: double-claim is impossible (CAS on State).
test("double-claim: second claimer loses (atomic check-and-set)", function()
	local bridge = newBridge({})
	bridge:start()
	local id = bridge:enqueue("p", "auto")
	eq(engineClaim(id), "claimed", "first claim wins")
	eq(engineClaim(id), "lost", "second claim loses (State already != queued)")
end)

-- Scenario 7: stalled working build is reclaimed only when heartbeat is dead.
test("timeout: stalled working build reclaimed after heartbeat dies + stall timeout", function()
	local updates = {}
	local bridge = newBridge({
		onRequestTerminal = function(v)
			table.insert(updates, v.state)
		end,
	})
	bridge:start()
	local id = bridge:enqueue("p", "auto")
	engineClaim(id)
	engineWorking(id)
	Mock.drain()

	-- Heartbeat goes stale: do NOT call engineStream. Advance past CLAUDE_TIMEOUT (15s)
	-- AND WORK_STALL_TIMEOUT (120s) without refreshing ClaudeHeartbeat.
	-- The working build's UpdatedAt is now; advance 130s and tick the liveness loop.
	Mock.tick(3) -- wake the heartbeat thread once (still within timeouts)
	-- now jump well past the stall timeout
	Mock.advanceTime(130)
	Mock.tick(3) -- liveness tick: connected=false AND now-updated>120 → reclaim

	eq(updates[#updates], "canceled", "stalled working build reclaimed to canceled")
end)

-- Scenario 8: a build that keeps streaming is NEVER reclaimed (heartbeat stays fresh).
test("no false reclaim: a slow-but-alive build is not canceled", function()
	local terminals = {}
	local bridge = newBridge({
		onRequestTerminal = function(v)
			table.insert(terminals, v.state)
		end,
	})
	bridge:start()
	local id = bridge:enqueue("big scene", "scene")
	engineClaim(id)
	engineWorking(id)

	-- Simulate a long build: stream + heartbeat every 10s for 200s total.
	for _ = 1, 20 do
		Mock.advanceTime(10)
		engineStream(id, "still building…", 50)
		Mock.tick(0) -- run any due liveness logic without extra time
	end
	-- Pump a couple liveness ticks; heartbeat is fresh so no reclaim.
	Mock.tick(3)
	eq(#terminals, 0, "alive build was NOT reclaimed despite 200s elapsed")

	engineFinish(id, { ok = true, summary = "scene", created = {} }, "done")
	Mock.drain()
	eq(terminals[#terminals], "done", "build finishes normally as done")
end)

-- Scenario 9: error path produces a terminal error with the message.
test("error path: failed build surfaces as terminal error", function()
	local terminals = {}
	local bridge = newBridge({
		onRequestTerminal = function(v)
			table.insert(terminals, { state = v.state, result = v.result })
		end,
	})
	bridge:start()
	local id = bridge:enqueue("impossible thing", "model")
	engineClaim(id)
	engineWorking(id)
	engineFinish(id, { ok = false, summary = "No Open Cloud key for mesh retrieval.", errors = { "missing key" } }, "error")
	Mock.drain()
	eq(terminals[#terminals].state, "error", "terminal state is error")
	ok(terminals[#terminals].result:find("Open Cloud"), "error message carried in result")
end)

-- Scenario 10: style profile round-trips through the bridge.
test("style profile: set on plugin side, readable by engine", function()
	local bridge = newBridge({})
	bridge:start()
	bridge:setStyleProfile({
		enabled = true,
		name = "Dark Fantasy",
		palette = { { brickColor = "Gold", material = "Metal" } },
		notes = "gold accents",
	})
	local styleV = bridgeFolder():FindFirstChild("StyleProfile")
	ok(styleV ~= nil, "StyleProfile child exists")
	local decoded = Mock.HttpService:JSONDecode(styleV.Value)
	eq(decoded.enabled, true, "engine reads enabled=true")
	eq(decoded.name, "Dark Fantasy", "engine reads the style name")
	eq(decoded.palette[1].brickColor, "Gold", "engine reads the palette")
end)

-- ── summary ────────────────────────────────────────────────────────────────
print("\n" .. string.rep("─", 60))
print(string.format("PROTOCOL TESTS: %d passed, %d failed", passed, failed))
if failed > 0 then
	print("\nFAILURES:")
	for _, f in ipairs(failures) do
		print(f)
	end
	error("test_protocol: " .. failed .. " assertion(s) failed", 0)
else
	print("ALL PROTOCOL TESTS PASSED ✓")
end
