# Forge tests

These tests run the **real** Forge source — not a reimplementation — under a faithful Roblox
API mock, so the protocol logic is exercised exactly as it runs in Studio. They need only the
`luau` CLI (no Studio, no network).

## Run everything

```bash
./run.sh
```

Regenerates the embedded source bundle, runs both suites, lints, checks formatting, and builds.
Prints `ALL CHECKS PASSED ✓` and exits 0 on success; non-zero on any failure.

Run a suite directly:

```bash
./gen_sources.sh           # refresh forge_sources.luau from ../src first
luau test_protocol.luau
luau test_assets.luau
```

## How it works

The standalone `luau` runtime has no Roblox API and no `io.open`, so:

| File | Role |
|------|------|
| `roblox_mock.lua` | A Roblox engine mock: `Instance` (attributes, `GetAttributeChangedSignal`, `.Changed`, children, `Destroy`, `IsA`), services (`ServerStorage`, `HttpService`, `Selection`), `task.*`, `os.time`, a `plugin` with `Set/GetSetting`, and a cooperative scheduler. It is faithful on the semantics the protocol depends on — most importantly that **`GetAttributeChangedSignal` fires for attributes while `.Changed` does not**, and the reverse for `StringValue.Value`. |
| `json.lua` | A small JSON encoder/decoder standing in for `HttpService:JSONEncode/Decode`. |
| `gen_sources.sh` | Embeds the real `../src/Bridge/Protocol.lua`, `Bridge.lua`, and `../src/State/Store.lua` verbatim into `forge_sources.luau` as strings (since the runtime can't read files). |
| `loader.luau` | Builds a fake `script` instance tree mirroring the Rojo layout so `require(script.Parent.X)` resolves, then `loadstring`s each embedded source with the mock globals injected. This is how the production code actually executes. |
| `asset_generators.luau` | The asset payloads the engine produces for real prompts (`create_build` for a crate/well, `create_ui_tree` for a shop UI), in the exact MCP tool shapes. |
| `test_protocol.luau` | Drives the real `Bridge`/`Store` through full lifecycle scenarios; simulates the Claude Code engine side with the same writes `execute_luau` would do. |
| `test_assets.luau` | Validates the generated payloads against the robloxstudio MCP schemas. |

The cooperative scheduler models Roblox's single-threaded, run-to-completion event loop: signal
handlers run synchronously (so check-and-set is atomic), while `task.spawn/defer/wait` queue
work the tests drain explicitly with `Mock.drain()` / `Mock.tick(dt)`. `Mock.tick(dt)` advances
the controllable clock and wakes the heartbeat loop, letting tests assert timeouts and the
bridge-rebuild path deterministically.

## Adding a scenario

In `test_protocol.luau`, call `test("name", function() ... end)` and use:

- `newBridge(events)` — construct the real `Bridge` with callbacks (auto-stopped between tests).
- `engineScan() / engineClaim(id) / engineWorking(id) / engineStream(id, text, pct) /
  engineFinish(id, manifest, state)` — simulate the engine side.
- `Mock.drain()` — run deferred work (e.g. the deferred reap).
- `Mock.tick(dt)` / `Mock.advanceTime(dt)` — advance time and wake the liveness loop.
- `eq(actual, expected, msg)` / `ok(cond, msg)` — assertions.

**Write tests that can fail.** The critical scenarios are mutation-checked — breaking the
production code makes them red. If a new test passes even when you sabotage the code it covers,
it isn't testing anything.
