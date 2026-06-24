# Forge Bridge Protocol (v1)

The plugin (Luau, edit-time) and Claude Code (via `mcp__robloxstudio__*`) communicate through
a single instance tree in the DataModel — the **bridge**. No server, no HTTP. The plugin is
the **producer** of prompts and **consumer** of results; Claude Code is the **consumer** of
prompts and **producer** of results.

This file is the contract both sides implement. `src/Bridge/Protocol.lua` is the machine-readable
mirror of the names below; `engine/forge-engine.md` implements the Claude-Code side.

---

## 0. Verified Roblox facts that drive the design

1. **`Instance.Changed` does NOT fire when an attribute changes.** Only `AttributeChanged` /
   `GetAttributeChangedSignal(name)` fire for attributes. `.Changed` on a `StringValue` (its
   `.Value`) fires normally. ⇒ watch attributes with `GetAttributeChangedSignal`, StringValues
   with `.Changed`.
2. **String *attributes* are capped at 50 chars** when NextGenerationReplication / Server
   Authority is enabled (2026). ⇒ **never** put variable text in attributes. Attributes carry
   only short fixed control fields; all variable text goes in `StringValue.Value` (~200k cap).
3. **`StringValue.Value` ≈ 200,000 char limit.** Large result manifests are trimmed before this.
4. **`Archivable = false` excludes an instance (and its descendants) from publish/save and
   `Clone()`.** This keeps the bridge out of the published game. (Never set `Archivable=false`
   on a plugin's own main script — known crash; only on the bridge data instances we create.)
5. `HttpService:JSONEncode/JSONDecode`, `HttpService:GenerateGUID(false)`, `os.time()`,
   `task.*` are available in edit-time plugin context. **The MCP side has no clock and no RNG**,
   so **all ids and timestamps are minted by the plugin.**

---

## 1. Location

`ServerStorage/ForgeBridge` — a `Folder`, `Archivable = false`. Stable path both sides resolve.
Because it is non-archivable it is never saved, so the plugin recreates it idempotently on load
(`ensureBridge`). Every instance the plugin creates under it also gets `Archivable = false`.
On `plugin.Unloading`, the plugin destroys the bridge.

---

## 2. Layout

```
ServerStorage/
└── ForgeBridge                  (Folder, Archivable=false)
    ├── @attr ProtocolVersion : number = 1
    ├── @attr LastRequestId   : number   -- monotonic counter, plugin-owned
    ├── @attr LastProcessedId : number   -- cursor, Claude-owned
    ├── @attr ClaudeHeartbeat : number   -- os.time() Claude writes each poll
    ├── @attr ClaudeStatus    : string   -- "idle" | "polling" | "working"  (≤50)
    ├── @attr PluginHeartbeat : number   -- os.time() plugin writes each tick
    ├── @attr StyleProfile    : (none)   -- see StyleProfile StringValue below
    │
    ├── StyleProfile          (StringValue)  -- JSON style/palette profile (plugin-owned)
    └── Requests              (Folder, Archivable=false)
        └── Req_<id>          (Folder, Archivable=false)
            ├── @attr Id        : number    -- == <id>, plugin-minted, immutable
            ├── @attr Guid      : string    -- GenerateGUID(false), tie-breaker (≤50)
            ├── @attr Kind      : string    -- "auto"|"model"|"gui"|"scene"  (≤50), plugin
            ├── @attr CreatedAt : number    -- os.time() at enqueue (plugin)
            ├── @attr Ready     : boolean   -- false until payload fully written (commit flag)
            ├── @attr State     : string    -- lifecycle enum (§3) (≤50)
            ├── @attr ClaimedAt : number    -- os.time() Claude set State=claimed
            ├── @attr UpdatedAt : number    -- last change (whoever wrote)
            ├── @attr Progress  : number    -- 0..100, Claude-owned
            │
            ├── Prompt        (StringValue) -- user's prompt text (plugin, once)
            ├── StatusText    (StringValue) -- streamed status, Claude-owned
            └── Result        (StringValue) -- JSON result manifest, Claude-owned (§2.2)
```

### 2.1 Field ownership (single-writer-per-field → no lost-update races)

| Field | Writer | Reader |
|---|---|---|
| `LastRequestId` | Plugin | Claude |
| `Req.Id/Guid/Kind/CreatedAt` | Plugin (once) | Claude |
| `Req.Prompt.Value` | Plugin (once) | Claude |
| `Req.Ready` | Plugin (once) | Claude |
| `Req.State` | Claude | Plugin |
| `Req.ClaimedAt/Progress` | Claude | Plugin |
| `Req.StatusText.Value` | Claude | Plugin |
| `Req.Result.Value` | Claude | Plugin |
| `LastProcessedId` | Claude | Plugin |
| `ClaudeHeartbeat/ClaudeStatus` | Claude | Plugin |
| `PluginHeartbeat` | Plugin | Claude |
| `StyleProfile.Value` | Plugin | Claude |

The two sides never write the same field. The only ordering rules are the commit barrier
(§5.2) and the claim handshake (§4.3).

### 2.2 Result manifest JSON (`Result.Value`)

```json
{
  "ok": true,
  "summary": "Built a wooden crate Model (12 parts).",
  "created":  [ { "path": "game.Workspace.WoodenCrate", "className": "Model" } ],
  "modified": [],
  "deleted":  [],
  "errors":   [],
  "tookSeconds": 8
}
```

On failure: `"ok": false`, `summary` is the user-facing error, `errors` is a string array.
If the manifest would exceed ~150k chars, Claude trims the arrays to counts + first N paths and
notes truncation in `summary`.

### 2.3 Style profile JSON (`StyleProfile.Value`)

```json
{
  "enabled": true,
  "name": "Dark Fantasy",
  "palette": [
    { "brickColor": "Really black", "material": "Slate" },
    { "brickColor": "Gold",         "material": "Metal" }
  ],
  "ui": { "bg": "#14121A", "panel": "#1E1B26", "accent": "#C8A24A", "text": "#EDE7D6",
          "corner": 8, "stroke": 2 },
  "notes": "rim-lit, gold accents, dark backgrounds"
}
```

---

## 3. Lifecycle (`State`)

```
   (none) ──plugin enqueues (Ready=true)──► queued
                                              │ Claude claims (atomic CAS, §4.3)
                                              ▼
                                           claimed ──► working ──(stream)──► done
                                              │                               ▲
                                              │ failure ─────────────────► error
   plugin timeout / cancel (only when queued, or working+heartbeat dead) ─► canceled
```

Enum (each ≤50, attribute-safe): `queued`, `claimed`, `working`, `done`, `error`, `canceled`.
Terminal states (`done`, `error`, `canceled`) are immutable. The plugin renders a terminal
request, copies its data into UI/scrollback, then deletes the `Req_<id>` folder.

---

## 4. Claude-Code side (poll loop) — see `engine/forge-engine.md`

Per tick:

1. **Heartbeat + scan** in one `execute_luau`: write `ClaudeHeartbeat=os.time()`,
   `ClaudeStatus="polling"`; return JSON list of `Req` where `Ready==true AND State=="queued"`,
   sorted by `Id` (FIFO).
2. If empty, wait and repeat.
3. **Claim** the lowest id with a check-and-set inside one non-yielding `execute_luau`:
   if `State=="queued"` set `State="claimed"`, `ClaimedAt`, `UpdatedAt`; else return `lost`.
4. Read `Prompt.Value`; set `State="working"`.
5. Build the asset with MCP tools; stream `StatusText.Value` + `Progress`; refresh
   `ClaudeHeartbeat` periodically.
6. Write `Result.Value` manifest; set `State="done"` (or `"error"`), `UpdatedAt`; advance
   `LastProcessedId=max(LastProcessedId,id)`; set `ClaudeStatus="idle"` if queue empty.
7. Loop.

### 4.3 Atomic claim (the anti-double-process)

The claim is a check-then-set within a single synchronous Luau execution (no `task.wait`
inside), so the plugin cannot interleave a write mid-function and two Claude sessions cannot
both win.

---

## 5. Plugin side

### 5.1 `ensureBridge()` — idempotent, on load and before each enqueue.

### 5.2 `enqueue(promptText, kind)` — **commit barrier:** reserve id, build the `Req` folder
with `Ready=false`, set `Prompt.Value`, parent the folder, then flip `Ready=true` **last**.
Claude's scan filters `Ready==true`, so a half-written request is invisible.

### 5.3 Watch — **right signal per type:** `GetAttributeChangedSignal("State"/"Progress")` for
attributes; `.Changed` for `StatusText`/`Result` StringValues. These fire at edit-time in a
plugin, so the UI reacts instantly with zero content polling.

---

## 6. Liveness / timeouts

The plugin runs one low-frequency timer (default 3s, off the render path). It writes
`PluginHeartbeat`, reads `ClaudeHeartbeat`, and sets `connected = (now - hb) <= 15s`.
- `connected==false` + queued requests → banner **"Claude Code not connected"**.
- A `working` request whose `UpdatedAt` is stale > 120s **and** heartbeat dead → reclaim to
  `canceled` (Claude crashed mid-build). A live build keeps the heartbeat fresh, so it is never
  yanked just for being slow.

---

## 7. Races handled (summary)

1. Partial read → commit barrier (`Ready` last). 2. Double-claim → CAS on `State`.
3. Lost update → single-writer-per-field. 4. Id reuse → `LastRequestId` reserved before build,
on the synchronous plugin thread. 5. Read-after-GC → plugin deletes only terminal requests;
Claude null-checks. 6. Crash-mid-build → heartbeat + stall timeout. 7. Cancel-vs-claim →
15s staleness gate + claim CAS rechecks `State`. 8. Manifest over cap → trim + flag.
9. Attribute 50-char truncation → no variable text in attributes. 10. `.Changed` not firing for
attributes → use `GetAttributeChangedSignal`. 11. Bridge missing after restart → `ensureBridge`.

---

## 8. Footguns

- Treat `Result.Value` as untrusted text: `JSONDecode` in `pcall`, render as text — never
  `loadstring` it.
- Missing attribute reads return `nil` — always `(x or default)`.
- Never `Archivable=false` the plugin's own main script.
- Clean up the bridge on `plugin.Unloading`.
