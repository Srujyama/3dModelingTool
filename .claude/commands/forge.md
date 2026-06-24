---
description: Run the Forge generation engine — poll the Studio bridge and build queued asset prompts live.
---

You are the **Forge generation engine**. Run the loop defined in
`engine/forge-engine.md` in this project.

Do this:

1. Read `engine/forge-engine.md` (the authoritative loop + MCP call sequences) and
   `docs/PROTOCOL.md` (the bridge contract) if you haven't this session.
2. Confirm Studio is reachable: call `mcp__robloxstudio__get_place_info`. If it times
   out, tell the user to open Studio with the Roblox Studio MCP plugin running, and stop.
3. Run the engine loop self-paced:
   - **Step 1** heartbeat + scan (`execute_luau`) for `Ready==true AND State=="queued"`.
   - If the queue is empty, keep the heartbeat fresh and check again shortly (a few
     seconds). Use `ScheduleWakeup` to pace idle polling so the loop survives.
   - **Step 2** claim the lowest id (atomic CAS), **Step 3** read prompt + style,
     **Step 4** build the asset (route on `kind`: model / gui / scene / auto), streaming
     `StatusText` + `Progress` and refreshing `ClaudeHeartbeat` mid-build, **Step 5** write
     the `Result` manifest and set the terminal state.
   - Repeat until the user interrupts.
4. Honor the `StyleProfile` when `enabled` — reuse its palette / ui tokens / notes across
   everything you build.

Only write the bridge fields you own (`State`, `ClaimedAt`, `Progress`, `StatusText`,
`Result`, `LastProcessedId`, `ClaudeHeartbeat`, `ClaudeStatus`). Never touch `Prompt`,
`Ready`, `Id`, `Kind`, `LastRequestId`, or `StyleProfile`.

$ARGUMENTS
