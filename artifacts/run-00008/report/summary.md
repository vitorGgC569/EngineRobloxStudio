# run-00008

- Validation level: **RUNTIME_VALIDATED**
- Studio context: **run**
- Place: **MinersRidgeTycoon-qa-v7.rbxlx**
- Status: **PASS** (6 PASS / 0 WARN / 0 FAIL)

## Evidence

| Status | Severity | Probe | Message |
|---|---|---|---|
| PASS | info | `studio_bridge_connected` | Live Studio answered through the bridge (edit context) |
| PASS | critical | `clean_baseline` | run started from a clean baseline of 2 descendants; game scripts generated 370 |
| PASS | major | `frame_rate` | sampled 60.09 FPS over 0.6s in run context (budget 30.0) |
| PASS | major | `memory_budget` | 1562.8 MB in use (budget 4000.0 MB) |
| PASS | critical | `spatial_overlap` | 4 exclusive regions, none intersecting |
| PASS | critical | `runtime_error` | 0 error line(s) in the Studio output |

## Commands that failed

- `world.summary`: E_TIMEOUT plugin did not answer world.summary within 30.0s

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
