# run-00005

- Validation level: **STATICALLY_VALIDATED**
- Studio context: **edit**
- Place: **MinersRidgeTycoon-qa-v7.rbxlx**
- Status: **FAIL** (10 PASS / 0 WARN / 1 FAIL)

## Evidence

| Status | Severity | Probe | Message |
|---|---|---|---|
| PASS | info | `studio_bridge_connected` | Live Studio answered through the bridge (edit context) |
| FAIL | critical | `clean_baseline` | could not start a clean run: place already holds 372 Workspace descendants (limit 8): it looks like a world was already generated here |
| PASS | major | `instance_budget` | Workspace holds 372 instances (budget 25000) |
| PASS | major | `parts_below_floor` | 0 part(s) below y=-50 |
| PASS | minor | `unanchored_parts` | 0 unanchored part(s) (budget 200) |
| PASS | critical | `spawn_exists` | 1 SpawnLocation(s) found in Workspace |
| PASS | critical | `ground_support` | Workspace.Map.SpawnPad rests on a surface (9 raycasts, coverage 1) |
| PASS | major | `frame_rate` | sampled 59.94 FPS over 0.6s in edit context (budget 30.0) |
| PASS | major | `memory_budget` | 1610.9 MB in use (budget 4000.0 MB) |
| PASS | critical | `spatial_overlap` | 4 exclusive regions, none intersecting |
| PASS | critical | `runtime_error` | 0 error line(s) in the Studio output |

## Findings

| Severity | Category | Location | Finding | Suggested action |
|---|---|---|---|---|
| critical | measurement_integrity | `studio` | the place was not in a clean state, so the run was refused | reopen the place in Studio before measuring; Run mode does not undo what game scripts build |

## Commands that failed

- `run.start`: E_UNSUPPORTED_CONTEXT place already holds 372 Workspace descendants (limit 8): it looks like a world was already generated here

## Reproducibility

```json
{
  "engineVersion": "0.2.0",
  "protocolVersion": "rqe.bridge/1",
  "studioVersion": "0.733.0.7330989",
  "placeId": 0,
  "placeName": "MinersRidgeTycoon-qa-v7.rbxlx",
  "commit": null,
  "host": "OGrandeOxta",
  "python": "3.12.10",
  "observeConfig": {
    "regionTag": "QARegion",
    "regionNamePattern": "^Plot",
    "regionRoot": "game.Workspace",
    "groundSupportSamples": 9,
    "groundSupportMaxGap": 1.5,
    "budgets": {
      "minFps": 30.0,
      "maxWorkspaceInstances": 25000,
      "maxMemoryMb": 4000.0,
      "maxUnanchoredParts": 200
    }
  }
}
```
