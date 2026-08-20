# Runtime bridge contract

`AgentBridge.server.lua` is the safe server-side half of the Game Agent Bridge.

It creates a `BindableFunction` at:

```text
ReplicatedStorage.QualityAgent.QualityAgentRequest
```

The Studio-side relay can invoke these read-only commands:

- `observe` with `blackbox`, `graybox` or `whitebox`;
- `get_player`;
- `get_ui`;
- `get_nearby`;
- `raycast`.

It intentionally does not expose a client-callable mutation RemoteEvent. Human-mode actions continue through Studio/MCP keyboard, mouse, camera and character-navigation operations. This preserves the proof boundary: the agent must physically play the game, while instrumented mode can diagnose a failure.

The Python `StudioGameAdapter` maps these relay operations to the `quality_probe_*` transport calls and maps actions to `playtest_start`, `screen_capture`, `console_read`, `character_navigation`, `user_keyboard_input` and `user_mouse_input`.

