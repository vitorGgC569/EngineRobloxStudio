# Continuous improvement loop

The project has a persistent quality loop for the Roblox game. It does not mutate gameplay code automatically: every cycle audits the project, writes deterministic evidence, refreshes the fix plan, evaluates visual quality and UI snapshots, and records the next improvement backlog in `reports/continuous-status.json`.

The quality focus covers structure, visual composition, UI, geometry, navigation, gameplay, persistence, multiplayer, performance, security and runtime stability. Visual quality uses both the audit evidence and the raw visual score/snapshot set, so a structurally correct but visually weak game remains in the improvement backlog.

Run one cycle for CI or a smoke check:

```powershell
python rqe.py improve . --once
```

Run the never-ending watcher:

```powershell
python rqe.py improve .
```

The default interval is five minutes. Set `--interval-seconds` to change it. The loop is silent, does not open windows, survives an individual failed cycle, and stops cleanly only when interrupted with Ctrl+C or SIGTERM. Its default behavior is intentionally never-ending.
