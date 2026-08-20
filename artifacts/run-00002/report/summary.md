# run-00002

- Validation level: **RUNTIME_VALIDATED**
- Studio context: **run**
- Place: **MinersRidgeTycoon-qa-v7.rbxlx**
- Status: **FAIL** (9 PASS / 0 WARN / 1 FAIL)

## Evidence

| Status | Severity | Probe | Message |
|---|---|---|---|
| PASS | info | `studio_bridge_connected` | Live Studio answered through the bridge (run context) |
| PASS | major | `instance_budget` | Workspace holds 372 instances (budget 25000) |
| PASS | major | `parts_below_floor` | 0 part(s) below y=-50 |
| PASS | minor | `unanchored_parts` | 0 unanchored part(s) (budget 200) |
| PASS | critical | `spawn_exists` | 1 SpawnLocation(s) found in Workspace |
| PASS | critical | `ground_support` | Workspace.Map.SpawnPad rests on a surface (9 raycasts, coverage 1) |
| PASS | major | `frame_rate` | sampled 59.89 FPS over 0.6s in run context (budget 30.0) |
| PASS | major | `memory_budget` | 1550.2 MB in use (budget 4000.0 MB) |
| FAIL | critical | `spatial_overlap` | 48 intersecting region pair(s) out of 28 |
| PASS | critical | `runtime_error` | 0 error line(s) in the Studio output |

## Findings

| Severity | Category | Location | Finding | Suggested action |
|---|---|---|---|---|
| high | spatial_overlap | `Workspace.Map.PlotA` | Workspace.Map.PlotA intersects Workspace.Map.PlotA.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotA` | Workspace.Map.PlotA intersects Workspace.Map.PlotA.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotA` | Workspace.Map.PlotA intersects Workspace.Map.PlotA.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotA` | Workspace.Map.PlotA intersects Workspace.Map.PlotA.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotA` | Workspace.Map.PlotA intersects Workspace.Map.PlotA.PlotGate | move one region 0.35 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotA` | Workspace.Map.PlotA intersects Workspace.Map.PlotA.PlotSign | move one region 0.55 studs along Z to separate them |
| high | spatial_overlap | `Workspace.Map.PlotA.PlotBorder` | Workspace.Map.PlotA.PlotBorder intersects Workspace.Map.PlotA.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotA.PlotBorder` | Workspace.Map.PlotA.PlotBorder intersects Workspace.Map.PlotA.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotA.PlotBorder` | Workspace.Map.PlotA.PlotBorder intersects Workspace.Map.PlotA.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotA.PlotBorder` | Workspace.Map.PlotA.PlotBorder intersects Workspace.Map.PlotA.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotA.PlotBorder` | Workspace.Map.PlotA.PlotBorder intersects Workspace.Map.PlotA.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotA.PlotBorder` | Workspace.Map.PlotA.PlotBorder intersects Workspace.Map.PlotA.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotB` | Workspace.Map.PlotB intersects Workspace.Map.PlotB.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotB` | Workspace.Map.PlotB intersects Workspace.Map.PlotB.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotB` | Workspace.Map.PlotB intersects Workspace.Map.PlotB.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotB` | Workspace.Map.PlotB intersects Workspace.Map.PlotB.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotB` | Workspace.Map.PlotB intersects Workspace.Map.PlotB.PlotGate | move one region 0.35 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotB` | Workspace.Map.PlotB intersects Workspace.Map.PlotB.PlotSign | move one region 0.55 studs along Z to separate them |
| high | spatial_overlap | `Workspace.Map.PlotB.PlotBorder` | Workspace.Map.PlotB.PlotBorder intersects Workspace.Map.PlotB.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotB.PlotBorder` | Workspace.Map.PlotB.PlotBorder intersects Workspace.Map.PlotB.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotB.PlotBorder` | Workspace.Map.PlotB.PlotBorder intersects Workspace.Map.PlotB.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotB.PlotBorder` | Workspace.Map.PlotB.PlotBorder intersects Workspace.Map.PlotB.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotB.PlotBorder` | Workspace.Map.PlotB.PlotBorder intersects Workspace.Map.PlotB.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotB.PlotBorder` | Workspace.Map.PlotB.PlotBorder intersects Workspace.Map.PlotB.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotC` | Workspace.Map.PlotC intersects Workspace.Map.PlotC.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotC` | Workspace.Map.PlotC intersects Workspace.Map.PlotC.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotC` | Workspace.Map.PlotC intersects Workspace.Map.PlotC.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotC` | Workspace.Map.PlotC intersects Workspace.Map.PlotC.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotC` | Workspace.Map.PlotC intersects Workspace.Map.PlotC.PlotGate | move one region 0.35 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotC` | Workspace.Map.PlotC intersects Workspace.Map.PlotC.PlotSign | move one region 0.55 studs along Z to separate them |
| high | spatial_overlap | `Workspace.Map.PlotC.PlotBorder` | Workspace.Map.PlotC.PlotBorder intersects Workspace.Map.PlotC.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotC.PlotBorder` | Workspace.Map.PlotC.PlotBorder intersects Workspace.Map.PlotC.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotC.PlotBorder` | Workspace.Map.PlotC.PlotBorder intersects Workspace.Map.PlotC.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotC.PlotBorder` | Workspace.Map.PlotC.PlotBorder intersects Workspace.Map.PlotC.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotC.PlotBorder` | Workspace.Map.PlotC.PlotBorder intersects Workspace.Map.PlotC.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotC.PlotBorder` | Workspace.Map.PlotC.PlotBorder intersects Workspace.Map.PlotC.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotD` | Workspace.Map.PlotD intersects Workspace.Map.PlotD.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotD` | Workspace.Map.PlotD intersects Workspace.Map.PlotD.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotD` | Workspace.Map.PlotD intersects Workspace.Map.PlotD.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotD` | Workspace.Map.PlotD intersects Workspace.Map.PlotD.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotD` | Workspace.Map.PlotD intersects Workspace.Map.PlotD.PlotGate | move one region 0.35 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotD` | Workspace.Map.PlotD intersects Workspace.Map.PlotD.PlotSign | move one region 0.55 studs along Z to separate them |
| high | spatial_overlap | `Workspace.Map.PlotD.PlotBorder` | Workspace.Map.PlotD.PlotBorder intersects Workspace.Map.PlotD.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotD.PlotBorder` | Workspace.Map.PlotD.PlotBorder intersects Workspace.Map.PlotD.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotD.PlotBorder` | Workspace.Map.PlotD.PlotBorder intersects Workspace.Map.PlotD.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotD.PlotBorder` | Workspace.Map.PlotD.PlotBorder intersects Workspace.Map.PlotD.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotD.PlotBorder` | Workspace.Map.PlotD.PlotBorder intersects Workspace.Map.PlotD.PlotBorder | move one region 0.5 studs along Y to separate them |
| high | spatial_overlap | `Workspace.Map.PlotD.PlotBorder` | Workspace.Map.PlotD.PlotBorder intersects Workspace.Map.PlotD.PlotBorder | move one region 0.5 studs along Y to separate them |

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
