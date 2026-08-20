# Roblox Quality Engine

Projeto: `C:\Users\vitor\OneDrive\Desktop\RobloxGamesMCP`
Gerado: `2026-08-12T03:28:29.945223+00:00`

## Resultado

- Checks executados: **38**
- PASS: **35**
- WARN: **2**
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
- visual: **86.7/100**

## Evidências

| Status | Severidade | Probe | Mensagem |
|---|---|---|---|
| PASS | info | `structural_integrity` | Arquivos estruturais obrigatórios estão presentes |
| PASS | info | `asset_security` | Nenhum padrão de script suspeito foi encontrado |
| PASS | info | `asset_manifest` | Manifesto de assets alocado, aprovado e validado |
| PASS | info | `visual_asset_quality` | Artes raster geradas têm resolução e proporção válidas |
| PASS | info | `visual_snapshot_bundle` | Pacote de prints visuais presente e decodificável |
| WARN | major | `studio_runtime_capture` | Capturas runtime do Studio ainda não estão disponíveis |
| PASS | info | `contract_schema` | Game Contract válido |
| FAIL | critical | `contract_coverage` | Há requisitos sem probe executável |
| PASS | major | `ground_support` | A área alvo possui suporte dentro do gap permitido |
| PASS | critical | `spawn_clearance` | Spawn sem obstrução |
| PASS | critical | `spawn_support` | Spawn apoiado em superfície válida |
| PASS | critical | `path_exists` | Caminho Spawn → PlayerPlot encontrado |
| PASS | critical | `objective_reachable` | Objetivo básico alcançável |
| PASS | major | `collision_overlap` | Nenhuma colisão estrutural detectada |
| PASS | major | `floating_objects` | Nenhum objeto flutuando |
| PASS | minor | `buried_objects` | Nenhum objeto enterrado |
| PASS | major | `door_clearance` | Portas têm passagem suficiente |
| PASS | major | `stairs_validity` | Escadas utilizáveis |
| PASS | major | `interaction_distance` | Interações dentro do alcance |
| PASS | major | `floor_progression` | Compra do próximo andar disponível no elevador |
| PASS | minor | `camera_obstruction` | Câmeras de teste sem obstrução |
| PASS | major | `ui_visibility` | Elementos de UI visíveis |
| PASS | major | `ui_overflow` | UI mobile dentro do viewport |
| PASS | major | `card_gallery` | Galeria de cartas visível e responsiva |
| PASS | critical | `button_interaction` | Botão de compra responde ao input |
| PASS | critical | `remote_security` | Payload inválido rejeitado, rate limit e distância server-side ativos |
| PASS | critical | `runtime_error` | Fluxo sem erros de console |
| PASS | major | `memory_growth` | Crescimento de memória dentro do orçamento |
| PASS | major | `instance_growth` | Nenhum vazamento de instâncias |
| PASS | major | `duplicate_connections` | Nenhuma conexão duplicada |
| PASS | critical | `persistence` | Estado preservado após reconnect |
| PASS | critical | `multiplayer_isolation` | Estado e plots isolados entre jogadores |
| PASS | major | `performance_budget` | Performance dentro do orçamento |
| PASS | critical | `asset_security` | Assets e scripts passaram pelo sandbox scanner |
| PASS | minor | `visual_quality` | Snapshots visuais e artes acima do limiar |
| PASS | major | `visual_snapshot_bundle` | Pacote de prints visuais validado |
| WARN | major | `studio_runtime_capture` | Capturas runtime do Studio pendentes; headless não é evidência live |
| PASS | critical | `agent_blackbox_scenario` | Agente completou o fluxo humano de compra |

## Bloqueios

- 1 critical failure(s)

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
