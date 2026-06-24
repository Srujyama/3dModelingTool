# Forge Engine — Operator Guide

Forge's plugin is just the chat UI. **Claude Code is the generation engine.** This guide
explains how to run it.

## What "the engine" is

A loop where Claude Code, connected to Studio via the **Roblox Studio MCP server**
(`mcp__robloxstudio__*`), repeatedly:

1. polls the bridge mailbox (`ServerStorage/ForgeBridge`) for new prompts,
2. claims one, builds the requested asset live in the place,
3. streams status and writes a result manifest back.

The full, copy-pasteable instruction set the engine follows is
[`../engine/forge-engine.md`](../engine/forge-engine.md). It implements the Claude-Code side of
[`PROTOCOL.md`](PROTOCOL.md).

## Prerequisites

- **Studio is open** with the place you want to build in.
- **The Roblox Studio MCP plugin is running** and connected to Claude Code (verify:
  `get_place_info` returns the place, not a timeout).
- The **Forge plugin** is installed and its panel is open (it creates the bridge).
- For 3D mesh retrieval: MCP server has `ROBLOX_OPEN_CLOUD_API_KEY` set.
- For the screenshot verify loop: *Game Settings → Security → Allow Mesh/Image APIs* is on.

## Running it

### Option A — `/forge` (recommended)

```
/forge
```

This starts a self-paced loop (via the `loop` skill) that runs the engine instructions until
you stop it. It polls every few seconds while idle and tightly while a build is in flight.

### Option B — manual

Paste the contents of `engine/forge-engine.md` into Claude Code as your instructions and tell
it to "run the Forge engine loop." It will poll and build until you interrupt.

### Option C — single shot

If you just want to process whatever is currently queued once: tell Claude Code "run one Forge
engine tick." It does steps 1–6 once and stops.

## What you'll see

- In **Studio**: the asset appears in `Workspace` (models/scenes) or `StarterGui` (UI),
  grouped and selected.
- In the **Forge panel**: the request goes `queued → working` with streaming status text and a
  progress bar, then a **result card** listing what was created.
- In **Claude Code**: a short log per tick (claimed #N, building…, done).

## Stopping

Interrupt the loop in Claude Code (Esc / stop). The plugin will show "Claude Code not
connected" within ~15s once the heartbeat goes stale — that's expected.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Panel says "Claude Code not connected" | engine loop not running, or MCP disconnected | start `/forge`; confirm `get_place_info` works |
| Prompt stuck on `queued` | engine running but not picking up | check Claude Code logs; confirm bridge path `ServerStorage/ForgeBridge` exists |
| Build stalls on `working` then cancels | engine crashed mid-build | restart `/forge`; the plugin auto-reclaims after the stall timeout |
| 3D mesh prompts return only blocky parts | no Open Cloud key → retrieval route unavailable | set `ROBLOX_OPEN_CLOUD_API_KEY`, or accept procedural part builds |
| Screenshot verify skipped | Mesh/Image APIs disabled | enable in Game Settings → Security |
