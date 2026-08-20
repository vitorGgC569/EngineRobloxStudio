# Game Agent Bridge

The bridge is the boundary between an LLM planner and a real Roblox playtest.

## Operation surface

```text
game.start(mode)
game.observe(mode)
game.act(action)
game.navigate_human(target)
game.navigate_pathfinding(target)
game.interact(target)
game.inspect_nearby()
game.get_ui()
game.get_player()
game.raycast(origin, direction)
game.run_scenario(scenario)
game.assert(assertion)
game.replay(records)
game.spawn_agents(count)
```

`navigate_human` is the proof path. It is translated to WASD/mouse/controller input in the Studio adapter, and to the local controller in CI. `navigate_pathfinding` is a gray-box diagnostic path. `navigate_direct` is deliberately forbidden in black-box mode and is never used by the release scenario.

## Observation modes

| Mode | Agent receives | Intended use |
|---|---|---|
| blackbox | screenshot, visible UI text, visible prompts, player-visible events | prove that a human can complete the objective |
| graybox | blackbox + position, health, velocity, UI tree and nearby state | diagnose navigation and interaction failures |
| whitebox | graybox + internal paths, remotes, datastore and probe diagnostics | localize root cause and propose a fix |

The `GameAgentBridge` records every action as:

```text
BEFORE observation
ACTION keyboard/mouse/semantic command
AFTER observation
RESULT PASS/FAIL + reason + details
```

These records are included in `reports/agent-session.json` and in the `agentSession` section of `reports/latest.json`.

## Studio/MCP integration

The Python `StudioGameAdapter` is transport-agnostic and maps to the official Studio primitives named in the product design:

| Bridge responsibility | Studio/MCP operation |
|---|---|
| start/stop | `playtest_start`, `playtest_stop` |
| visual observation | `screen_capture` |
| console evidence | `console_read` |
| human movement | `character_navigation` |
| keyboard | `user_keyboard_input` |
| mouse/camera | `user_mouse_input` |
| instrumented state | `quality_probe_*` via `AgentBridge.server.lua` |

The adapter does not silently fall back to teleportation. If the human navigation call fails, the resulting action record is a FAIL and the instrumented mode can then raycast the obstruction.

