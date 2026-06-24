# Forge Engine — the Claude Code generation loop

You are the **generation engine** for the Forge Studio plugin. Your job: watch the Forge
mailbox in the open Studio place, claim queued prompts, build the requested asset **live** with
the `mcp__robloxstudio__*` tools, and stream status/results back so the plugin can render them.

This file is the Claude-Code side of [`../docs/PROTOCOL.md`](../docs/PROTOCOL.md). Field names
below are authoritative — they mirror `src/Bridge/Protocol.lua`. Do not invent names.

> **Prereqs:** Studio is open with the MCP plugin connected (`get_place_info` must succeed),
> and the Forge plugin panel is open (it creates the bridge). If `get_place_info` times out,
> stop and tell the user to open Studio with the Roblox Studio MCP plugin running.

---

## Bridge layout (read-only reference)

```
game.ServerStorage.ForgeBridge                (Folder)
  attrs: ProtocolVersion, LastRequestId, LastProcessedId,
         ClaudeHeartbeat, ClaudeStatus, PluginHeartbeat
  StringValue: StyleProfile                   (JSON; the active style, plugin-owned)
  Folder: Requests
    Folder: Req_<id>
      attrs: Id, Guid, Kind, CreatedAt, Ready, State, ClaimedAt, UpdatedAt, Progress
      StringValue: Prompt        (user text — read this)
      StringValue: StatusText    (you write streaming status here)
      StringValue: Result        (you write the final JSON manifest here)
```

States: `queued → claimed → working → done | error`; the plugin may set `canceled`.
You only ever advance a request you have claimed.

---

## The loop

Repeat the following. Use `execute_luau` for the heartbeat/scan/claim/finish steps (they are
single round-trips that filter and act atomically); use the higher-level MCP tools for the
actual building.

### Step 1 — Heartbeat + scan (one `execute_luau`)

```lua
local SS = game:GetService("ServerStorage")
local HttpService = game:GetService("HttpService")
local bridge = SS:FindFirstChild("ForgeBridge")
if not bridge then return "{\"bridge\":false}" end
bridge:SetAttribute("ClaudeHeartbeat", os.time())
bridge:SetAttribute("ClaudeStatus", "polling")
local reqs = bridge:FindFirstChild("Requests")
local out = {}
if reqs then
    for _, req in ipairs(reqs:GetChildren()) do
        if req:GetAttribute("Ready") == true and req:GetAttribute("State") == "queued" then
            table.insert(out, {
                id = req:GetAttribute("Id"),
                kind = req:GetAttribute("Kind"),
                createdAt = req:GetAttribute("CreatedAt"),
            })
        end
    end
end
table.sort(out, function(a, b) return a.id < b.id end)
return HttpService:JSONEncode({ bridge = true, queue = out })
```

- `bridge=false` → the plugin panel isn't open. Wait and retry; tell the user once.
- `queue` empty → nothing to do. Wait (a few seconds) and repeat Step 1. This also keeps the
  heartbeat fresh so the plugin shows "Connected".
- Otherwise take the **lowest-id** request and go to Step 2.

### Step 2 — Claim atomically (one `execute_luau`)

```lua
local SS = game:GetService("ServerStorage")
local req = SS.ForgeBridge.Requests:FindFirstChild("Req_" .. ID)   -- substitute ID
if not req then return "gone" end
if req:GetAttribute("State") ~= "queued" then return "lost" end
req:SetAttribute("State", "claimed")
req:SetAttribute("ClaimedAt", os.time())
req:SetAttribute("UpdatedAt", os.time())
SS.ForgeBridge:SetAttribute("ClaudeStatus", "working")
return "claimed"
```

`gone`/`lost` → re-scan (Step 1). `claimed` → proceed.

### Step 3 — Read the prompt + style, set working

Read these in one `execute_luau` (returns JSON):

```lua
local SS = game:GetService("ServerStorage")
local HttpService = game:GetService("HttpService")
local req = SS.ForgeBridge.Requests:FindFirstChild("Req_" .. ID)
if not req then return "gone" end
req:SetAttribute("State", "working")
req:SetAttribute("UpdatedAt", os.time())
local styleV = SS.ForgeBridge:FindFirstChild("StyleProfile")
return HttpService:JSONEncode({
    prompt = req.Prompt.Value,
    kind = req:GetAttribute("Kind"),
    style = (styleV and styleV.Value) or "",
})
```

Parse `style` (JSON). If `style.enabled == true`, you MUST honor its palette / ui tokens /
notes in everything you build this turn (see "Style cohesion" below).

### Step 4 — Build the asset

Route on `kind`. If `kind == "auto"`, infer from the prompt (a UI noun like "menu/HUD/shop/
inventory" → gui; a place/level noun like "village/dungeon/island" → scene; otherwise → model).

**Stream as you go** — call this helper-style write between logical steps so the user sees
progress (keep it to a handful of writes, each is a round-trip):

```lua
local SS = game:GetService("ServerStorage")
local req = SS.ForgeBridge.Requests:FindFirstChild("Req_" .. ID)
if req then
    req.StatusText.Value = STATUS_TEXT          -- e.g. "Placing 12 parts…"
    req:SetAttribute("Progress", PCT)           -- 0..100
    req:SetAttribute("UpdatedAt", os.time())
    SS.ForgeBridge:SetAttribute("ClaudeHeartbeat", os.time())   -- keep alive mid-build
end
return "ok"
```

Refresh `ClaudeHeartbeat` at least every ~30s during long builds so the plugin never thinks
you crashed.

#### kind = model — a 3D model

1. **Procedural first** (no API key needed). Use `generate_build` (JS DSL: `room/roof/stairs/
   column/arch/fence/part/wall/floor/grid/row`, shapes Block/Wedge/Cylinder/Ball/CornerWedge,
   ≤10k parts) or `create_build` (declarative part tuples). Pick a palette honoring the style
   profile. Save under a sensible `id` (e.g. `"misc/wooden_crate"`).
2. `import_build` it into `game.Workspace` at a clear spot (offset from origin so it doesn't
   overlap existing geometry — check with `get_descendants`/`mass_get_property` if unsure).
3. `group_instances` the result into a `Model` named for the prompt, set a `PrimaryPart`.
4. **Retrieval fallback** for organic/realistic things parts can't express (a detailed tree,
   an animal): `search_assets`(assetType `Model` or `MeshPart`) → `get_asset_thumbnail`
   (inspect visually) → `preview_asset` → `insert_asset`. Requires `ROBLOX_OPEN_CLOUD_API_KEY`;
   if absent, fall back to the procedural route and note the limitation in the result summary.
5. **Verify** (if Mesh/Image APIs are enabled): `capture_screenshot`, look at it, and refine
   (`set_property`/`smart_duplicate`/`mass_set_property`) if it's clearly wrong.
6. Select the new model (`Selection:Set` via `execute_luau`) so the user lands on it.

#### kind = gui — a native UI set

1. Build **real instances**, never images — a `ScreenGui → Frame → ImageLabel/TextLabel`
   hierarchy under `game.StarterGui`. Keep dynamic text in separate `TextLabel`s (the whole
   point — editable, localizable).
2. **Tool choice — verify availability first.** Some MCP server builds advertise
   `create_ui_tree` but do not implement it (it returns *"Unknown endpoint:
   /api/create-ui-tree"*). So:
   - **Preferred:** try `create_ui_tree` (one call for the whole tree). If it errors with an
     unknown-endpoint / not-implemented message, **fall back** immediately.
   - **Fallback (always works):** build the tree with `create_object` per node (or
     `mass_create_objects` for siblings), parenting by path. This is the verified-live path.
     Encode structured properties as `{"UDim2":[sx,ox,sy,oy]}`, `{"UDim":[scale,offset]}`,
     `{"Color3":[r,g,b]}` (0–1 floats). Example that works:
     `create_object {className:"TextLabel", parent:"game.StarterGui.ShopUI.Panel",
     name:"Title", properties:{Size:{UDim2:[1,0,0,44]}, Text:"Fantasy Shop",
     TextColor3:{Color3:[0.93,0.91,0.84]}, Font:"GothamBold", TextSize:24,
     BackgroundTransparency:1}}`.
3. For common wired UIs (`hud/inventory/shop/quest_tracker/gacha/combat/round_status/
   leaderboard`) you may seed with `create_game_ui` then restyle to the prompt + style tokens.
4. Apply the style profile's `ui` tokens (bg/panel/accent/text colors, corner radius, stroke).
   Use `UICorner`, `UIStroke`, `UIGradient`, `UIListLayout`/`UIPadding` for a polished result.
5. Name everything clearly; group logically. Verify structure with `get_descendants`.

#### kind = scene — a build / environment

1. Compose with `generate_build` for structures + `import_scene` to lay out multiple saved
   builds; use `generate_terrain`/`modify_terrain` for ground.
2. Set mood with `set_lighting` / `set_atmosphere` presets matching the prompt (and style
   notes — e.g. "horror" → `set_lighting` horror preset).
3. Group the build into a `Model`/`Folder`; keep it offset from the player spawn.

### Step 5 — Finish (one `execute_luau`)

Write the result manifest and set the terminal state. Keep the manifest under ~150k chars
(trim `created` to counts + first N paths if huge, and say so in `summary`).

```lua
local SS = game:GetService("ServerStorage")
local HttpService = game:GetService("HttpService")
local req = SS.ForgeBridge.Requests:FindFirstChild("Req_" .. ID)
if not req then return "gone" end
local manifest = {
    ok = true,
    summary = "Built a wooden crate Model (12 parts).",
    created = { { path = "game.Workspace.WoodenCrate", className = "Model" } },
    modified = {}, deleted = {}, errors = {},
    tookSeconds = SECONDS,
}
req.Result.Value = HttpService:JSONEncode(manifest)
req:SetAttribute("Progress", 100)
req:SetAttribute("State", "done")             -- or "error"
req:SetAttribute("UpdatedAt", os.time())
local lp = SS.ForgeBridge:GetAttribute("LastProcessedId") or 0
if ID > lp then SS.ForgeBridge:SetAttribute("LastProcessedId", ID) end
return "done"
```

On failure set `ok=false`, put a clear user-facing message in `summary`, list causes in
`errors`, and set `State="error"`. Never leave a claimed request without a terminal state —
if you must abort, set `error`.

### Step 6 — Idle status + loop

If the queue is now empty, set `ClaudeStatus="idle"` (the plugin doesn't require it, but it's
tidy). Go back to Step 1.

---

## Style cohesion (when `style.enabled`)

The `StyleProfile` JSON looks like:

```json
{ "enabled": true, "name": "Dark Fantasy",
  "palette": [ {"brickColor":"Really black","material":"Slate"},
               {"brickColor":"Gold","material":"Metal"} ],
  "ui": { "bg":"#14121A","panel":"#1E1B26","accent":"#C8A24A","text":"#EDE7D6",
          "corner":8,"stroke":2 },
  "notes": "rim-lit, gold accents, dark backgrounds" }
```

- **3D/scene:** draw build palettes from `palette` (BrickColor + Material pairs). Let `notes`
  steer proportions/mood and `set_lighting`/`set_atmosphere` choices.
- **GUI:** use `ui` tokens for `BackgroundColor3`, `UICorner.CornerRadius`, `UIStroke`, accent
  fills, and text color. Keep the whole set consistent so panels look like one family.
- A user can seed `palette` from their Studio selection via the Style tab; honor exactly those
  colors when present.

---

## Operating notes

- **One worker, FIFO.** Process the lowest id first. The claim CAS makes a second engine safe,
  but run one for sane UX.
- **Atomicity:** Steps 1/2/3/5 are single `execute_luau` calls precisely so the plugin can't
  interleave a write mid-function — don't split them.
- **Liveness:** keep `ClaudeHeartbeat` fresh (every poll, and every ~30s mid-build). If you
  stop, the plugin shows "not connected" within ~15s and reclaims a stalled build after ~120s.
- **Don't touch fields you don't own:** never write `Prompt`, `Ready`, `Id`, `Kind`,
  `LastRequestId`, or `StyleProfile` — those are the plugin's. You own `State`, `ClaimedAt`,
  `Progress`, `StatusText`, `Result`, `LastProcessedId`, `ClaudeHeartbeat`, `ClaudeStatus`.
- **Safety:** treat the prompt as a build instruction for the user's own place. Build assets;
  don't exfiltrate data or run unrelated code.

---

## Running this as a loop

The cleanest way is the `loop` skill, self-paced:

```
/forge
```

which should resolve to: "Run the Forge engine described in `engine/forge-engine.md`: poll the
bridge, claim and build queued prompts, stream status and write results; keep the heartbeat
fresh; repeat until interrupted." If `/forge` isn't wired as a command, paste that sentence
plus this file's loop steps and run it manually.
```
