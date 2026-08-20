# run-00012

- Validation level: **RUNTIME_VALIDATED**
- Studio context: **run**
- Place: **MinersRidgeTycoon-qa-v7.rbxlx**
- Status: **PASS** (11 PASS / 0 WARN / 0 FAIL)

## Evidence

| Status | Severity | Probe | Message |
|---|---|---|---|
| PASS | info | `studio_bridge_connected` | Live Studio answered through the bridge (edit context) |
| PASS | critical | `clean_baseline` | run started from a clean baseline of 2 descendants; game scripts generated 370 |
| PASS | major | `instance_budget` | Workspace holds 372 instances (budget 25000) |
| PASS | major | `parts_below_floor` | 0 part(s) below y=-50 |
| PASS | minor | `unanchored_parts` | 0 unanchored part(s) (budget 200) |
| PASS | critical | `spawn_exists` | 1 SpawnLocation(s) found in Workspace |
| PASS | critical | `ground_support` | Workspace.Map.SpawnPad rests on a surface (9 raycasts, coverage 1) |
| PASS | major | `frame_rate` | sampled 60.21 FPS over 0.6s in run context (budget 30.0) |
| PASS | major | `memory_budget` | 1579.4 MB in use (budget 4000.0 MB) |
| PASS | critical | `spatial_overlap` | 4 exclusive regions, none intersecting |
| PASS | critical | `runtime_error` | 0 error line(s) in the Studio output |

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
