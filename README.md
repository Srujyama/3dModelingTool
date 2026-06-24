# Forge — Generate any Roblox asset just by chatting, inside Studio

Forge is a Roblox Studio plugin that gives you a chat panel **inside Studio**. Type a
prompt — `"medieval well"`, `"fantasy shop UI"`, `"small village"` — and the asset is built
**live in your place** as real, editable instances: 3D `Model`s, native
`ScreenGui` / `Frame` / `ImageLabel` / `TextLabel` UI trees, whole builds. No flattened PNGs,
no manual re-layering.

It is a Studio-native answer to [ForgeGUI](https://forgegui.com): that product is a web app
that generates 2D images only and pastes them into Studio as flat pictures. Forge instead
builds **real instances** you can select, edit, script, and ship — and it can do **true 3D
modeling**, which image generators can't.

---

## How it works

```
  ┌───────────────────────┐        DataModel mailbox         ┌────────────────────────┐
  │  Forge plugin (Luau)   │   ServerStorage/ForgeBridge       │   Claude Code           │
  │  the chat UI in Studio │ ───── writes prompt ───────────►  │   (the engine)          │
  │                        │                                   │   drives the Roblox     │
  │  renders status,       │ ◄──── writes status/result ────── │   Studio MCP server to  │
  │  result cards, gallery │                                   │   build the asset live  │
  └───────────────────────┘                                   └────────────────────────┘
```

There is **no external server and no API key**. The plugin and Claude Code talk through a
hidden instance tree in your place (`ServerStorage/ForgeBridge`). The plugin writes your
prompt there; Claude Code — already connected to Studio via the **Roblox Studio MCP server** —
reads it, builds the asset with MCP tools, and streams status/results back. The bridge is
`Archivable = false`, so it is **never saved or published** into your live game.

The full mailbox protocol (race conditions, lifecycle, signals) is in
[`docs/PROTOCOL.md`](docs/PROTOCOL.md). The engine loop Claude Code runs is in
[`engine/forge-engine.md`](engine/forge-engine.md) with operator notes in
[`docs/ENGINE.md`](docs/ENGINE.md).

---

## Two ways to use it

1. **The plugin** (chat panel inside Studio) — the full experience described below.
2. **From Claude Code directly** — paste one snippet and model in your open Studio via the
   `forge` CLI, no plugin install needed. See **[MODELING.md](MODELING.md)** — this is the
   fastest way to start building.

---

## Install (the plugin)

You need two pieces talking to the same Studio session:

### 1. The Forge plugin (this repo)

**Option A — Rojo (recommended):**

```bash
# from the repo root
rojo build plugin.project.json --output Forge.rbxmx
```

Then in Studio, right-click `Plugins` in the Explorer → *Insert from File* → pick
`Forge.rbxmx`. Or drop `Forge.rbxmx` into your local Plugins folder
(*Plugins* tab → *Plugins Folder* in Studio) and restart Studio.

For live development: `rojo serve plugin.project.json` and connect with the Rojo Studio plugin.

**Option B — by hand:** create a `Folder` in `ServerStorage`, recreate the `src/` module tree
inside it, then right-click the folder → *Save as Local Plugin*.

### 2. The Claude Code engine

Forge needs Claude Code running with the **Roblox Studio MCP server** connected to the same
open Studio session (this is the `mcp__robloxstudio__*` toolset). With Studio open and the MCP
plugin active, start the engine loop:

```
/forge
```

(See [`docs/ENGINE.md`](docs/ENGINE.md). The loop can also be run manually by pasting
`engine/forge-engine.md` as instructions.)

---

## Use

1. Open Studio. Click the **Forge** button on the toolbar — a dockable panel appears.
2. Make sure the status pill reads **Connected** (Claude Code engine is running). If it says
   **Claude Code not connected**, start `/forge` in Claude Code.
3. Pick a generation type chip (Model / GUI / Scene / Auto), type a prompt, hit **Send**.
4. Watch it build live in your place. The chat thread streams status; a result card lists what
   was created. Your new instances are selected and ready to edit.

### Style cohesion

Open the **Style** tab to lock a palette so a whole set of assets stays visually consistent
(Forge's analog to ForgeGUI's "upload a screenshot" reference). You can seed the palette from
your current selection — Forge reads its colors/materials and reuses them on everything it
generates next.

---

## Project layout

| Path | What |
|------|------|
| `src/Plugin.server.lua` | Plugin entry: toolbar button, dock widget, wiring |
| `src/Bridge/Protocol.lua` | Single source of mailbox field/enum names + JSON helpers |
| `src/Bridge/Bridge.lua` | `ensureBridge`, `enqueue`, watch, heartbeat/liveness, cleanup |
| `src/UI/*` | Theme, components, chat thread, prompt bar, gallery, style, settings |
| `src/State/Store.lua` | Session state + `plugin:SetSetting` persistence |
| `engine/forge-engine.md` | The Claude Code poll/build loop (the "engine") |
| `docs/PROTOCOL.md` | The bridge mailbox protocol spec (race-audited) |
| `docs/ENGINE.md` | Operator guide for running the engine |
| `tests/` | Executable test suite (runs the real source under a Roblox mock) |

---

## Tests

Forge ships a real, executable test suite that runs the **actual** plugin source (not a
reimplementation) under a faithful Roblox API mock — no Studio required — plus validates the
asset payloads the engine produces against the MCP tool schemas.

```bash
cd tests && ./run.sh
```

It runs **43 protocol assertions** (full request lifecycle, commit barrier, atomic claim,
bridge-rebuild rewire, id persistence across restarts, timeout/reclaim, style round-trip) and
**398 asset-payload assertions** (real `create_build` + `create_ui_tree` output for prompts like
"wooden crate", "medieval well", "fantasy shop UI"), then lints, format-checks, and builds. The
critical scenarios are mutation-checked — breaking the production code makes them fail. See
[`tests/README.md`](tests/README.md).

---

## Contributing

Forge is source-available and welcomes contributions — fork it, file issues, send PRs. See
[CONTRIBUTING.md](CONTRIBUTING.md) for setup, the test workflow, and code style.

---

## License

Forge is licensed under the **Business Source License 1.1** ([LICENSE](LICENSE)). In plain terms:

- ✅ **Use it for anything, including commercially** — generate assets/UIs/models for games you
  sell, use it inside a company or studio, ship and monetize what you make with it.
- ✅ **Fork, modify, and redistribute** the project itself, free of charge, under this license.
- ❌ **Don't resell Forge itself** as a competing commercial product or paid service (a paid
  plugin, a hosted generation SaaS, etc.) without a separate commercial license.

On **2030-06-23** (four years after first release) each version converts to **Apache 2.0**, a
fully open-source license. This is the "use it freely, just don't sell the software out from
under it" model.

---

## Requirements & notes

- **Studio MCP server.** Forge does nothing on its own — Claude Code is the generation engine.
  The plugin only produces prompts and renders results.
- **Marketplace search / mesh retrieval** (for organic 3D assets) needs the MCP server's
  `ROBLOX_OPEN_CLOUD_API_KEY` configured. Procedural builds and UI need no key.
- **`capture_screenshot`** (the engine's visual verify loop) needs *Game Settings → Security →
  Allow Mesh/Image APIs* enabled.
- The bridge is transient (never saved). Chat scrollback persists across restarts via
  `plugin:SetSetting`, not in the place.
