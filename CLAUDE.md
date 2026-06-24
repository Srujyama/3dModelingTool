# Working in this repo (read this first)

This repo already contains a **finished, working modeling tool**. When the user asks you to
"make" / "build" / "model" something in Roblox, your job is to **drive the existing `./forge`
CLI** — NOT to write your own builder, NOT to reimplement the bridge, NOT to create new scripts
to do what `./forge` already does.

> ⚠️ IMPORTANT: `./forge` (repo root) and the MCP bridge it talks to are **already built and
> tested**. Do not recreate them. If the user says "model a castle", you write a small build
> spec JSON and run `./forge build spec.json`. That's it.

## The tool: `./forge`

A self-contained Python CLI in the repo root that drives the user's **open Roblox Studio** over
the robloxstudio MCP server. It auto-discovers the port and checks the connection.

```
./forge check                       # ALWAYS run this first — is Studio connected?
./forge ls game.Workspace           # list direct children of a path
./forge tree game.Workspace.Model   # list all descendants (use to verify a build)
./forge build <spec.json>           # build a 3D model: create_build + import_build + verify
./forge call <tool> '<json-args>'   # call ANY robloxstudio MCP tool directly
./forge rm game.Workspace.Thing     # delete an instance
```

## How to fulfill "build me X" (a 3D model)

1. Run `./forge check`. If it says the plugin isn't connected, tell the user to click
   **Connect** in Studio's MCP Server panel, then stop and wait — do not try to work around it.
2. Write a build spec to a temp file (e.g. `/tmp/x.json`) in this format:
   ```json
   {
     "id": "misc/<name>",            // "<style>/<name>"; style: medieval|modern|nature|scifi|misc
     "style": "misc",
     "target": "game.Workspace",     // where to place it
     "position": [0, 5, 0],          // world offset
     "palette": { "wood": ["Brown","WoodPlanks"], "metal": ["Dark stone grey","Metal"] },
     "parts": [
       // [posX,posY,posZ, sizeX,sizeY,sizeZ, rotX,rotY,rotZ, "paletteKey", shape?, transparency?]
       [0,0,0, 4,0.3,4, 0,0,0, "wood"]
     ]
   }
   ```
   - `shape` ∈ Block|Wedge|Cylinder|Ball|CornerWedge (default Block). `transparency` ∈ 0..1.
   - Palette tuples are `["<BrickColor name>", "<Material name>"]`. Up to 10000 parts.
   - Think in real studs: a part is centered at its position; size is full extent.
3. Run `./forge build /tmp/x.json`. It prints `✓ create_build`, `✓ import_build`, `✓ verified`.
4. Tell the user where it landed (the `modelPath`, e.g. `game.Workspace.<name>`).

## How to build a GUI

Build **native instances** with `./forge call create_object` (do NOT use `create_ui_tree` — the
installed MCP server does not implement it). Parent by path; encode structured props as:
`{"UDim2":[scaleX,offX,scaleY,offY]}`, `{"UDim":[scale,offset]}`, `{"Color3":[r,g,b]}` (0–1),
`{"Vector3":[x,y,z]}`. Example:
```
./forge call create_object '{"className":"TextLabel","parent":"game.StarterGui.MyUI.Panel","name":"Title","properties":{"Size":{"UDim2":[1,0,0,40]},"Text":"Shop","TextColor3":{"Color3":[1,1,1]},"BackgroundTransparency":1}}'
```

## Rules

- **Use `./forge`. Don't rebuild it.** It is the deliverable; it works (verified live).
- Always `./forge check` before building. Never silently retry a timed-out call more than once —
  if the bridge is down, tell the user to reconnect in Studio.
- After any build, verify with `./forge tree <path>` and report the real result, not an assumption.
- Keep models reasonable (tens to low hundreds of parts) unless asked for more.
- A working example spec is in `examples/daycare_counter.json`. Copy its shape.

## What's also in this repo (context, not your task)

- `src/` — the full Forge Studio plugin (Luau, a chat panel inside Studio). Separate from the
  `./forge` CLI; don't touch it unless asked.
- `engine/`, `docs/` — the plugin's bridge protocol and engine loop.
- `tests/` — executable test suite (`tests/run.sh`); `tests/mcp.sh` is the low-level HTTP caller
  that `./forge` is the friendly wrapper around.
- `MODELING.md` — the human-facing guide for using `./forge` from Claude Code.
