# Roblox Quality Engine

Projeto: `C:\Users\vitor\OneDrive\Desktop\RobloxGamesMCP`
Gerado: `2026-09-04T18:39:05.419154+00:00`

## Resultado

- Checks executados: **38**
- PASS: **37**
- WARN: **0**
- FAIL: **1**
- Release: **BLOCKED**

## Scores

- gameplay: **100.0/100**
- geometry: **100.0/100**
- multiplayer: **100.0/100**
- navigation: **100.0/100**
- performance: **100.0/100**
- persistence: **100.0/100**
- runtime: **100.0/100**
- security: **100.0/100**
- structural: **25.0/100**
- ui: **100.0/100**
- visual: **100.0/100**

## Evidências

| Status | Severidade | Probe | Mensagem |
|---|---|---|---|
| PASS | info | `structural_integrity` | Arquivos estruturais obrigatórios estão presentes |
| PASS | info | `asset_security` | Nenhum padrão de script suspeito foi encontrado |
| PASS | info | `asset_manifest` | Manifesto de assets alocado, aprovado e validado |
| PASS | info | `visual_asset_quality` | Artes raster geradas têm resolução e proporção válidas |
| PASS | info | `visual_snapshot_bundle` | Pacote de prints visuais presente e decodificável |
| PASS | major | `studio_runtime_capture` | Capturas runtime do Studio presentes e identificadas |
| PASS | info | `contract_schema` | Game Contract válido |
| FAIL | critical | `contract_coverage` | Há requisitos sem probe executável |
| PASS | major | `ground_support` | A área alvo possui suporte dentro do gap permitido |
| PASS | critical | `spawn_clearance` | spawn is clear |
| PASS | critical | `spawn_support` | spawn rests on valid ground |
| PASS | critical | `path_exists` | Caminho Spawn → PlayerPlot encontrado |
| PASS | critical | `objective_reachable` | the basic objective is reachable |
| PASS | major | `collision_overlap` | no structural overlaps |
| PASS | major | `floating_objects` | Nenhum objeto flutuando |
| PASS | minor | `buried_objects` | Nenhum objeto enterrado |
| PASS | major | `door_clearance` | doorways have enough clearance |
| PASS | major | `stairs_validity` | Escadas utilizáveis |
| PASS | major | `interaction_distance` | interactions are within reach |
| PASS | major | `floor_progression` | the next floor can be bought at the lift |
| PASS | minor | `camera_obstruction` | test cameras are unobstructed |
| PASS | major | `ui_visibility` | UI elements are visible |
| PASS | major | `ui_overflow` | UI mobile dentro do viewport |
| PASS | major | `card_gallery` | card gallery is visible and responsive |
| PASS | critical | `button_interaction` | the purchase button responds to input |
| PASS | critical | `remote_security` | invalid payloads refused; rate limit and distance enforced server-side |
| PASS | critical | `runtime_error` | Fluxo sem erros de console |
| PASS | major | `memory_growth` | memory growth is within budget |
| PASS | major | `instance_growth` | no instance leaks |
| PASS | major | `duplicate_connections` | no duplicate connections |
| PASS | critical | `persistence` | state survived a reconnect |
| PASS | critical | `multiplayer_isolation` | Estado e plots isolados entre jogadores |
| PASS | major | `performance_budget` | performance is within budget |
| PASS | critical | `asset_security` | Assets e scripts passaram pelo sandbox scanner |
| PASS | minor | `visual_quality` | Snapshots visuais e artes acima do limiar |
| PASS | major | `visual_snapshot_bundle` | Pacote de prints visuais validado |
| PASS | major | `studio_runtime_capture` | Capturas runtime do Studio validadas |
| PASS | critical | `agent_blackbox_scenario` | the agent completed the human purchase flow |

## Bloqueios

- 1 critical failure(s)
- legacy audit is diagnostic only; fixture/headless evidence cannot release a build

## Runtime scenario trace

```json
{
  "scenario": "purchase_basic_pack",
  "navigationSuccess": true,
  "firstPurchase": true,
  "secondPurchase": false,
  "currencyDelta": -100,
  "inventoryDelta": 1,
  "beforeReconnect": {
    "currency": 900,
    "inventory": [
      "basic_mining_pack"
    ]
  },
  "afterReconnect": {
    "currency": 900,
    "inventory": [
      "basic_mining_pack"
    ]
  },
  "persistencePass": true,
  "multiplayerIsolation": true,
  "invalidPayloadRejected": true,
  "rejectedPayloads": 1,
  "duplicateConnections": 0,
  "instanceGrowth": 0,
  "consoleErrors": 0,
  "events": [
    {
      "event": "spawn",
      "userId": 101,
      "plot": "PlotA"
    },
    {
      "event": "navigate",
      "userId": 101,
      "target": "BasicPackStore",
      "success": true
    },
    {
      "event": "purchase",
      "userId": 101,
      "item": "basic_mining_pack",
      "price": 100
    },
    {
      "event": "disconnect",
      "userId": 101
    },
    {
      "event": "reconnect",
      "userId": 101
    },
    {
      "event": "spawn",
      "userId": 202,
      "plot": "PlotB"
    }
  ]
}
```

## Game Agent Bridge

- Scenario: **purchase-first-pack-human**
- Status: **PASS**
- Steps: **7**
