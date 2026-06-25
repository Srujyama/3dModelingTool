# Model anything in Roblox Studio from Claude Code

This is the copy-paste setup that turns any Claude Code session into a Studio modeling tool.
It uses the `forge` CLI in this repo to drive your open Studio over the robloxstudio MCP
server — no native MCP tools needed.

## One-time setup

1. Open your place in **Roblox Studio**.
2. Start the **MCP Server** plugin (the panel should say *Connected — pluginConnected: true*).
3. In a Claude Code session, `cd` into this repo.

## The snippet to paste into Claude Code

Paste this once at the start of a session, then just ask for models in plain English:

```
You can model in my open Roblox Studio using the ./forge CLI in this repo. Workflow:

  ./forge check                       # confirm Studio is connected (do this first)
  ./forge ls game.Workspace           # see what's there
  ./forge build <spec.json>           # build a 3D model: create_build + import_build + verify
  ./forge call <tool> '<json>'        # call any robloxstudio MCP tool directly
  ./forge rm game.Workspace.<Name>    # delete something

To build a 3D model, write a spec.json and run ./forge build:
  { "id":"misc/<name>", "style":"misc", "target":"game.Workspace", "position":[0,5,0],
    "palette": { "key": ["<BrickColor>","<Material>"] },
    "parts": [ [px,py,pz, sx,sy,sz, rx,ry,rz, "key", shape?, transparency?] ] }
  shape is Block|Wedge|Cylinder|Ball|CornerWedge (default Block). Up to 10000 parts.

For GUIs, build native instances with ./forge call create_object (NOT create_ui_tree —
this MCP build doesn't implement it). Encode props as {"UDim2":[sx,ox,sy,oy]},
{"Color3":[r,g,b]} (0-1), {"Vector3":[x,y,z]}.

Always run ./forge check first. After building, verify with ./forge tree <path>.
When I ask for a model, write the spec, build it, verify it landed, and tell me the path.
```

## Try it

After pasting the above, just say things like:

- *"make a wooden picnic table"*
- *"build a small fountain near the spawn"*
- *"a glowing sign that says OPEN"*
- *"a row of fence posts along the back wall"*

Claude Code writes a spec, runs `./forge build`, verifies it, and tells you where it is.

## Quick reference (run these yourself too)

```bash
./forge check                                   # connection status
./forge ls game.Workspace                       # list children
./forge tree game.Workspace.MyModel             # list all descendants
./forge build daycare_counter.json              # build a model from a spec file
./forge shot /tmp/s.png                         # capture the viewport to a PNG (then look at it)
./forge scene game.Workspace                    # headless spatial summary of the scene
./forge call create_object '{"className":"Part","parent":"game.Workspace","name":"Box","properties":{"Size":{"Vector3":[4,4,4]},"Position":{"Vector3":[0,10,0]},"Material":"Wood","BrickColor":"Brown"}}'
./forge rm game.Workspace.Box                   # delete
```

### Seeing your build

`./forge shot out.png` saves a real screenshot of the Studio viewport — open it (or have Claude
read it) to actually see what got built. `./forge scene` gives a headless summary (each model's
position, size, how far it floats off the ground, tilted parts) when you just want a sanity
check. `shot` needs *Game Settings → Security → Allow Mesh / Image APIs* enabled and Edit mode.

## Notes

- The CLI auto-discovers the MCP port (defaults to scanning 58741…); override with
  `FORGE_PORT=12345` or `FORGE_URL=http://localhost:12345/mcp` if needed.
- If `./forge check` says the plugin isn't connected, click **Connect** in Studio's MCP
  Server panel and retry. The connection can drop if Studio loses focus for a while.
- `create_ui_tree` is **not implemented** in MCP server v2.6.0 — use `create_object` for GUIs.
- This is the lightweight, session-friendly path. The full Forge plugin (chat panel inside
  Studio) lives in `src/` — see the main [README](README.md).
```
