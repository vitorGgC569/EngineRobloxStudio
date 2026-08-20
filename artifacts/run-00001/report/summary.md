# run-00001

- Validation level: **RUNTIME_VALIDATED**
- Studio context: **edit**
- Place: **MinersRidgeTycoon-qa-v7.rbxlx**
- Status: **FAIL** (7 PASS / 1 WARN / 1 FAIL)

## Evidence

| Status | Severity | Probe | Message |
|---|---|---|---|
| PASS | info | `studio_bridge_connected` | Live Studio answered through the bridge (edit context) |
| PASS | major | `instance_budget` | Workspace holds 2 instances (budget 25000) |
| PASS | major | `parts_below_floor` | 0 part(s) below y=-50 |
| PASS | minor | `unanchored_parts` | 0 unanchored part(s) (budget 200) |
| FAIL | critical | `spawn_exists` | 0 SpawnLocation(s) found in Workspace |
| PASS | major | `frame_rate` | sampled 59.85 FPS over 0.6s in edit context (budget 30.0) |
| PASS | major | `memory_budget` | 1563.8 MB in use (budget 4000.0 MB) |
| WARN | minor | `spatial_overlap` | only 0 exclusive region(s) discovered; overlap check needs at least two |
| PASS | critical | `runtime_error` | 0 error line(s) in the Studio output |

## Findings

| Severity | Category | Location | Finding | Suggested action |
|---|---|---|---|---|
| critical | world_geometry | `game.Workspace` | the place has no SpawnLocation; players cannot enter | add a SpawnLocation on solid ground in the starting area |

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
