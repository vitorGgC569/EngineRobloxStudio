# Catálogo de Reuso — Funcionalidades de Jogos

Inventário funcional extraído dos projetos do usuário em `Desktop\projetos\`,
mapeado para módulos genéricos candidatos às bibliotecas da RQE
(`roblox/lib/Core|GameKit|WorldKit`, `forge/luau/Forge`). Cada linha indica a
fonte exata para mineração de implementação.

**Legenda de fontes:** `brr`=BrainRotRoyale · `bocchi`=bocchi-upgrade-tree ·
`bb`=brickblast-roblox · `infected`=roblox-infected · `vesteria`=vesteria ·
`fight`=Fighting-game · `haven`=minershaven · `rojo`=roblox-rojo-game ·
`lapskaus`=roblox-lapskaus · `jecs`=RPGJECS · `2d`=2d-adventure ·
`maze`=maze-world · `quake`=robloquake · `halo`=HaloAndHorns

---

## 1. Partidas & Rodadas

| Módulo | Fonte | Arquivos-chave | O que generaliza |
|---|---|---|---|
| `Matchmaking.Queue` | brr | `src/server/Main.server.luau`, `RemoteEvents.luau` | Fila FIFO com party-size configurável, dedupe, validação de presença, forfeit por saída |
| `MatchPhaseMachine` | lapskaus | `server/services/GameService.ts`, `shared/enums` | NotStarted→Starting→Playing→Results por contagem mínima; CharacterAutoLoads manual |
| `RoundMachine` (FSM pura) | infected | `src/shared/RoundMachine.luau` (+specs) | WAITING→INTERMISSION→ACTIVE→ROUND_END retornando lista `{Effect}`; tempo injetado; grace window, extensão, cap |
| `Match.WinResolver` | brr | `GameManager/init.luau` (`CheckTimer`, `GetTotalTowerHP`) | Cascata de critérios/tiebreakers (king tower → coroas → tempo → overtime → %HP → draw), cleanup agendado |
| `TeamSpawns` | lapskaus | `server/services/RespawnService.ts` | Spawns por tag CollectionService com lift offset |
| `ArenaBuilder` | brr | `server/MapGenerator/init.luau` | Blueprint declarativo de arena (chão/rio/pontes/spawns), rebuild idempotente |
| `WaveSpawner` | fight + teste/ (RQE) | `ServerStorage/zombies/*` respawn por clone; `WaveService.lua` | Onda substitui morto por clone; config por instância em pasta Configurations |
| `Match.Director` | quake | `src/server/director.luau` | Rotação/votação/admin ao vivo; lógica pura isolada com um único seam no engine |

## 2. Cartas & Táticas

| Módulo | Fonte | Arquivos-chave | O que generaliza |
|---|---|---|---|
| `CardCycle` | brr | `GameManager/init.luau` (`ShuffleDeck`), `TroopData.DEFAULT_DECK` | Deck 8 + mão 4 + next, Fisher-Yates com seed, reciclagem automática |
| `EntityCatalog` | brr | `src/shared/TroopData.luau` | Unidades data-driven: custo/hp/dano/speed/range + ganchos `special` (splash/lifesteal/buff/spawn) + stats de torres |
| `DeployZoneValidator` | brr | `MapGenerator.GetDeployZone` | AABB por time validado server-side antes de debitar recurso |
| `AutoTurret` | brr | `MapGenerator.CreateTower`, `UpdateTowerAttacks` | Entidade estática com stats em Attributes, targeting nearest-first, cooldown, healthbar |
| `CombatSim.UnitRunner` | brr | `GameManager.UpdateTroops/FindTarget/AttackTarget` | Loop de unidades como tabelas server-side (sem Humanoid); especiais plugados por flag; visual desacoplado |
| `RegeneratingResource` (elixir) | brr | `UpdateElixir/GetElixirRate` | Regen linear com cap + multiplicador por fase + throttle de replicação |

## 3. Combate & Armas

| Módulo | Fonte | Arquivos-chave | O que generaliza |
|---|---|---|---|
| `CombatValidator` (validação) | vesteria | `contents/manager_damage.lua` (1.749 linhas), `modules/damage.lua` | Pipeline server-side: alvo atacável, GUID de habilidade, janela ±125 ms, amostragem 5 pontos, ângulo 7° vs curva preditiva, maxHitLockout, crítico/dodge/mitigação VIT |
| `DamagePipeline` (resolução) | fight | `ServerStorage/HitHandler/init.lua` | Assinatura paramétrica: kb/gb/passthrough/blockanywhere/ignoreiframe/blockstun; frontalidade, chip dmg ÷5, guardbreak stun+highlight, super armor |
| `ComboSequencer` | fight | `Classes/SwordDude.server.lua` etc. | Cadeia data-driven com buffer ~0,2 s, reset timeout 0,5 s, último hit com knockback forte |
| `ClassRegistry` | fight | `ServerStorage/ClassData.lua`, `ReplicatedStorage/MoveInfo.lua` | Movesets 100% data-driven: speeds/health/stamina/nomes/cooldowns/stacks por classe |
| `StunController` | fight | `HitHandler/StunHandler.lua` | Stun empilhável sem yield; re-stun estende só se restar menos; watcher restaura |
| `GuardSystem` | fight | `block.server.lua` + HitHandler | Block com walkspeed/jump reduzidos, bloqueio traseiro ignorado, break por gb |
| `StatusEffectService` | vesteria + fight | `manager_statusEffect.lua`; `effects.lua` | Ticks com duração salvos (sobrevivem reconexão), revogação por sourceType, persistência no save; slow/cripple/sleep/DoT/regen/modificadores % |
| `AbilitySystem` | vesteria | `manager_ability.lua`, `ability_utilities.lua` | Cast por GUID com estados idle/casting/executing/cooldown; cooldowns consultáveis/resetáveis |
| `HitGeometry` | vesteria | `modules/detection.lua` | Boxcast/spherecast analíticos (projeção em OBB), closest-target — sem física real |
| `ProjectileSim` (preditivo) | vesteria | `modules/projectile_predictive.lua`, `projectile.lua` | Simulação compartilhada C/S: gravidade fixa, raycast segmentado, bezier de trajetória p/ validação do tiro |
| `FactionService` | vesteria | `damage.lua`, `detection.lua` | Hostilidade data-driven: damagable/friendly/neutral, PVP opt-in whitelist/global, pets/party respeitados |
| `HitscanWeapon` | lapskaus | `server/services/WeaponService.ts` | Câmera enviada pelo cliente, cooldown por jogador, raycast 1000 studs, headshot por nome de part |
| `AntiCheatMath` | infected | `src/shared/AntiCheatMath.luau` | Classificador de violação de movimento (teleport/speed escalonados por janela) |
| `Ballistics` (spread/bloom) | infected | `src/shared/Ballistics.luau` | Mira = projeção do cone que o servidor sorteia; compartilhado mira/tracer/servidor |
| `AggroTable` (ameaça simétrica) | halo | ModifierService/Threat patterns | Decaimento contínuo, ameaça compartilhada 25%, medo como ameaça negativa, rageLatch |

## 4. IA & Many-Agents

| Módulo | Fonte | Arquivos-chave | O que generaliza |
|---|---|---|---|
| `TraitAI` | jecs | `systems/mob_brain.luau` | Roleta ponderada wander/chase/flee/circle por traits sorteadas; histerese de estado com duração; tick 8 Hz |
| `GroundSnapLocomotion` | jecs | `systems/mob_move.luau` | Raycasts a 20 Hz: wall-stop 1 stud, ground-snap, step-up limitado, edge-stop, replica só se delta>0.05 |
| `CrowdSeparation` | jecs | `systems/mob_avoid.luau` | Bolhas de vizinhança raio=Size×0.25, acumula vetor de separação (~150 agentes, 10 Hz) |
| `MobSpawner` | jecs | `systems/SpawnMob.luau` | Anel aleatório com throttle, weightedChoice de tamanho, hitbox invisível CollisionGroup NPC, atributos p/ cliente |
| `ProxyReplication` | jecs | `syncMobs.luau` (client) | Replicação nativa de Parts invisíveis; cliente observa ChildAdded e monta visual por atributo MobType/MobSize |
| `SnapshotInterpolator` | jecs | `move.luau` (client) | Blend prev→rendered→next com span dinâmico (100 ms, clamp 1/120–0.25 s), nunca rebina pose renderizada |
| `EntityRefRegistry` | jecs | `std/ref.luau` | Chave arbitrária (UserId, Part) → entidade estável com cache e limpeza |
| `MiniBehaviorTree` | jecs | `std/bt.luau` | SEQUENCE/FALLBACK/RUNNING minimalista |
| `SystemMailbox` | jecs | `std/mailbox.luau` | Buffers de eventos entre fases como componente ECS (push/drain, invalidação hot-reload) |
| `Scheduler por fases` | jecs | `std/scheduler.luau`, `phases.luau` | Sistemas como entidades com DependsOn(phase); profiling por fase via debug.profilebegin |
| `NPCBrain` (FSM zumbi) | fight | `zombies/*/ROBLOX_ZombieAI.lua` | Idle/Search/Pursuit/Attack com config por instância (FOV/aggro/chanceOfBoredom) |
| `BotBrain` | infected | `src/shared/BotBrain.luau`, `BotVision.luau` | Pathfinding com stuck-recovery, LOS, personalidades/dificuldades, memória e audição — agentes autônomos p/ cenários E2E |

## 5. Movimento & FPS

| Módulo | Fonte | Arquivos-chave | O que generaliza |
|---|---|---|---|
| `AccelMove` (movement feel) | lapskaus | `MovementController.ts`, `MovementConfig.ts` | LinearVelocity modo Plane; taxa distinta aceleração(8)/frenagem(6); rebind em CharacterAdded; desliga na morte |
| `QuakeStrafeJump` | quake | camada engine/produto | Aceleração lateral por produto escalar + interpolação `qwplerp` |
| `ViewModelController` | lapskaus | `ViewmodelController.ts` | Esqueleto p/ equip/sway/recoil (estado inicial apenas — projetar) |
| `CombatScoreboard` | lapskaus | `PlayerService.ts` | K/D por oponente (Maps), headshots, recordKill |
| `TeleportPads` | haven | `StarterPhysics`/`Physics.client.lua` | Teleporte de ore entre upgraders via tags + tween client-side |

## 6. Economia & Progressão

| Módulo | Fonte | Arquivos-chave | O que generaliza |
|---|---|---|---|
| `Wallet.Balance` multi-moeda | bocchi | `ReplicatedStorage/Balance.luau`, `Currency/init.luau` | Registro declarativo de moedas (cor/ícone/UI page), operações imutáveis, `canAfford→remainder` atômico sem TOCTOU |
| Big numbers (`alyanum`) | bocchi | `Packages/alyanum`, `Packets.luau` | Mantissa/expoente até tetrate; aritmética própria + codec de rede binário |
| `Math.FormulaBuilder` | bocchi | `ReplicatedStorage/Formula.luau` | Builder fluente imutável add/sub/mul/div/pow/log com renderização textual ("x * 2 + 5") |
| `Income.Engine` | bocchi | `Controllers/GenerationController.luau` | Agregação Add/Mul/Pow por contribuinte com cache invalidável, tick fixo, multiplicador gamepass |
| `UpgradeTree.Controller` (DAG) | bocchi | `ButtonController.luau`, botões `Info.luau` | Nós com Cost(n), MaxAmount, Roots (visibilidade condicional), Effect plugável, refresh em cascata |
| `RebirthLoop` | haven | `Main/RebirthHandler.server.lua` | Curva de preço por vidas, fusão mono-item, wipe com hooks OnWipe/OnAward/OnAnnounce, marcos de recompensa |
| `PrestigeVault` (sacrifício) | haven | `Sacrifice.server.lua` | Cofre Safekeeping soulbound, tiers com tags que alteram prefixo/multiplicadores |
| `DailyRewardCalendar` | haven + infected | `DailyRewards.server.lua`; `DailyReward.luau`(spec) | Dia absoluto + streak, marcos modulares no ciclo, jackpot % saldo, drops físicos, melhor streak em OrderedDataStore |
| `OfflineEarnings` | haven + infected | `PlayerDataGuardian` bloco TimeAway | Income × tempo fora com cap temporal e cap relativo ao saldo |
| `IncomeTracker` | haven | `MPSCalc.server.lua` | Janela móvel de amostras, média → AverageIncome, reset em eventos especiais |
| `IdleGenerator` + `UpgradePath` | rojo | `Economy/TycoonService.lua` | Coin pickups com cooldown/respawn, upgrade pad com debounce, custo base+nível×step, renda passiva loop |
| `LootLottery` | haven | `ReplicatedStorage/LotteryLib.lua`, `CrateItems.lua` | Pool por faixas cumulativas cujo tamanho é peso; pesos por contexto (VIP/clover/premium/faixa de riqueza); preview cliente + confirmação servidor |
| `GachaPurchaseFlow` | haven | `Main/MysteryBox.server.lua` | Anti-reentrância, delay dramático, classificação Wow!/OMG!!, anúncio global de prêmios raros via DataStore |
| `PromoCodes` | haven + bocchi | `TwitterCode.server.lua` | One-shot persistido, condições por tag/gamepass |
| `SeasonalEvent` + `ScavengerHunt` | haven | `CloverEvent/EggScript/EventShop` | Moeda temporária, spawn wave com densidade por nº de jogadores, coleta ≤12 studs, recompensas em marcos |
| `EntitlementTags` | haven + bb | `VirtualStore/PerkHandler.server.lua` | Validação contínua PlayerOwnsAsset/badge/grupo → tags que gateiam sistemas inteiros |
| `Leaderboard.OrderedBoard` | bocchi + haven | `LeaderboardController.luau`; `LinkedLeaderboard.server.lua` | Top-N periódico com throttle, render SurfaceGui físico, filtro de ban, conversão big number |
| `CrateRoll` determinístico | infected | `src/shared/CrateRoll.luau` (+spec) | Loot roll reproduzível testado headless |
| `Quests` (rotação) | infected | `src/shared/Quests.luau` (+spec) | Rotação determinística por período+userId |
| `SeasonPass` | infected | `src/shared/SeasonPass.luau` | Progresso de passe com rewards |
| `QuestEngine` (estágios) | rojo | `Quests/QuestService.lua` (+spec TestEZ) | Definições declarativas com objetivos de contagem (tag+distância) e de tempo (dt condicional), encadeamento por atributo |
| `TutorialFlow` | haven | `TutorialStepListener.server.lua` | Passo corrente server-side validado; cada passo inicia/finaliza missões com telemetria attempts/tempo |
| `ProgressionHooks` | vesteria | `manager_profession/bounty/quest.lua` | XP de profissão, claim de bounty validando kill, triggers de quest desacoplados |

## 7. Persistência & Dados

| Módulo | Fonte | Arquivos-chave | O que generaliza |
|---|---|---|---|
| `Save.ServerProfile` | bocchi | `DataController.luau` | ProfileService chaveado por PrivateServerId/JobId (entidade não-player): dono, permissões, reconcile, migrações inline |
| `MultiSlotSaves` | haven | `Saving.lua`, `PlayerDataGuardian` | Slots com sufixos, versionamento por timestamp resolvido via GetSortedAsync, QuickLoad prefetch das 3 slots, BindToClose |
| `SaveService` versões/rollback | vesteria | `datastoreInterface.lua` (36 KB) | Versão global + increment local, OrderedDataStore de versões p/ rollback, recovery por slot+versão, merge de defaults |
| `BlueprintSerializer` | haven | `InventoryPersistance/init.server.lua` | Layout {ItemId, pos relativa, direção} ↔ modelos; layouts JSON trocáveis in-game |
| Delta-merge add-only | quake | `src/server/statstore.luau` (757 linhas) | UpdateAsync merge de deltas (retry incapaz de dupla-contagem), leaderboards nomeados por (stat, scope, período), fail-closed correto |
| `ReceiptLedger` idempotente | bb + infected | `ProfilePersistence.luau`; receipts dev-products | Append-only reconciliado por união; nunca sobrescrever com cópia incompleta |
| `SaveGatekeeper` | bb | `ProfilePersistence.luau` | Máquina Pending/Loaded/Failed: decisão save/wait/skip, sessão read-only em falha, notificação única |
| `ProfileMigrator` | bb | `ProfilePersistence.luau` | Versionamento + tabela MIGRATIONS |
| `LiveConfig` | infected | `LiveConfig.luau` + `LiveConfigService.luau` | Tuning ao vivo (tempos/preços/pesos) via DataStore sem republish |
| PlayerState schema + derivador | vesteria | `manager_player.lua`, `datastoreInterface.lua` | Schema documentado em comentário; stats derivados recalculados de base+equip+perks |

## 8. Social & Meta

| Módulo | Fonte | Arquivos-chave | O que generaliza |
|---|---|---|---|
| `GroupService` (guilds) | vesteria | `manager_guild.lua` (44 KB) | Guild única via UpdateAsync atômico, ranks, invite/exile, upgrades custados, doações, hall teleportado, chat replicado |
| `TradeSession` | vesteria | `manager_trade.lua` | Máquina de estados 2-partes, invites com CD, valida espaço de inventário antes de aceitar, bloqueio se DataSaveFailed |
| `PartyService` | vesteria | `manager_party.lua` | Máx 6, líder/power-user, ready-check para teleporte em grupo, resume pós-teleporte |
| `ModerationKit` | vesteria | `manager_pvp/security/exploit/challenge.lua` | PVP opt-in, duelos com wager GUID, suspicion score com histórico UpdateAsync, escape rope |
| `PlotPermissions` | haven | `Multiplayer.server.lua`, `TycoonLib` | Ownership por proximidade (raio 1.25×), convite de visitantes com Build/Buy/Sell alternáveis, broadcast por plot |
| `Permissions.Service` | bocchi | `DataController.RefreshPermLevel` | Owner(3)/Manager(2)/Trusted(1)/Default(0)/Banned(-1) em atributo; gate por ação nomeada configurável in-game |
| `Admin.CmdrKit` | bocchi | `Cmdr/Commands/*Server.luau`, `Hooks` | Hook BeforeRun por nível + comandos padrão set/give/reset/print/walkspeed |
| `StaffFlags` | haven | `AdminHunter/Whitelist.server.lua` | Grupos/userIds → poderes administrativos |
| `ServerModePlots` | haven | `IslandManager.server.lua`, `MapLoader` | Main vs VIP/private carrega mapas distintos; tema Mars por gamepass (reskin recursivo, gravidade, sky) |

## 9. Mundo & Tycoon

| Módulo | Fonte | Arquivos-chave | O que generaliza |
|---|---|---|---|
| `GridPlacement` ⭐ | haven | `ReplicatedStorage/PlacementModule.lua` (1039 linhas) | Interseção raio-plano, roundToGrid(3 studs), extents rotacionados, clamp de plot, AABB anti-colisão ghost azul/vermelho, multi-offset, axis-lock magnético, wobble por mola analítica, place() retorna CFrames p/ servidor validar |
| `DropperChain` + `ThroughputCap` | haven | `PlayerDataGuardian` (DropCount/Limit/Level) | Produção pausa quando pasta atinge teto (=50+25×nível, +premium); remoção libera automaticamente |
| `PickupCrate` | haven | `ResearchCrateScript.server.lua` + variantes | Touched com checagem de distância (anti-cheat 30 studs), chances por VIP, animação de consumo, Owner opcional |
| `PhysicsInteractable` família | rojo | `World/Interactables/*.lua` | SpinPlatform (push/atrito 0.96/frame), PendulumSeat (hinge+ropes on-demand), ProximityDoor (poll+tween attrs), PromptDoor (DoorGroup sync), RailSlide (impulsos + walkspeed restore) |
| `DeclarativeWorldBuilder` | rojo | `World/Builders/*.lua` | find-or-create idempotentes, presets físicos centralizados, tags CollectionService, CityLayout com zoning e getOverlaps() |
| `WorldHubBuilder` | bb | `server/world/HubBuilder.luau` (~2600 linhas) | Hub procedural completo (ilhas/portais/pontes/billboards de status dinâmicos) com fallback gracioso mínimo |
| `ResourceNodes`/`GroundLoot` | vesteria | `manager_item/treasure/resources.lua` | Nós com depletion/replenish, itens físicos com dono temporário, baús com estado blocked |
| `NotificationKit` + `WorldFloatingText` | haven | `Notifications/Notify.lua`, `Currency.lua` | Popups empilhados com tween/som, "+$" billboardado com jitter e áudio |
| `CrossServerRadio` | haven | `RadioControl.server.lua` | Modo global pago validando AssetTypeId==3; propagação DataStore OnUpdate |
| `CrossServerShout` + `AdRotator` | haven | `Shouter/ChatAds.server.lua` | Mensagem filtrada com whitelist de URLs, publicada a todos os servidores; rotação de ads |
| Day/Night server | vesteria + haven | `manager_dayNightCycle.lua`; `RealisticTimeOfDay` | Clock server com perks sensíveis a horário; ciclo em minutos reais |

## 10. UI/UX

| Módulo | Fonte | Arquivos-chave | O que generaliza |
|---|---|---|---|
| `PanelKit` | bb | `src/client/ui/*Panel.luau` | Painéis com estados loading/checking sempre resolvidos (timeout), notificações empilhadas, result composer por modo |
| `DragDropBoardClient` | bb | `BlockBlastClient.client.luau` | Drag&drop unificado mouse/touch com ghost preview usando as MESMAS regras puras do servidor |
| `ResponsiveLayoutSolver` | bb | `SoloLayout.luau` (+tests) | Grid/offsets determinísticos de viewport+insets+uiScale; breakpoint compartilhado com qualidade visual |
| `ThemeTokenSystem` | bb | `VisualTokens.luau`, `StageVisuals.luau` | Tokens IDENTITY/FLAVOR/ENERGY, presets derivados validados, contraste verificado, transição animada |
| `QualityTierSelector` | bb | `VisualQuality.luau` | Tier Full/Reduced de pós-processamento por tela; separação explícita da preferência Reduced Motion |
| `ObjectiveTracker` | rojo | `UI/ArrowController.lua`, `QuestUI.lua` | Texto de objetivo + seta BillboardGui AlwaysOnTop seguindo alvo por tag/name |
| `UnifiedInputMode` + `GamepadNav` | haven | `GUI/Input.lua`, `ArrowHandler.lua` | Detecção keyboard/gamepad/touch define modo; navegação por setas no botão mais próximo |
| Toast/Tooltip/Hotkey/Pager | bocchi | controllers client | Widgets pequenos de HUD |
| `Iso2dEngine` (pacote) | 2d | `src/*.lua` | Mapper mundo↔tela letterbox-aware (`Calc`), Physics2D AABB com modos/resolução de lado, ScrollingMap player-centrado, DepthSorter painter + fade de foco, TweenWalker diagonais normalizadas + idle, DirectionalAnimPicker banda 20°, FrameAnimator gif prefixos Walk/Stay/IDLE, SpatialAudio2D emitter/listener wire, UnifiedInput thumbstick nativo, IsoGameSession multi-instância |

## 11. LiveOps & Telemetria

| Módulo | Fonte | Arquivos-chave | O que generaliza |
|---|---|---|---|
| `CrossServerTelemetry` | bb | `Telemetry.luau` | Merge idempotente de contadores cross-server dentro de UpdateAsync (deltas, skip-write zero, NaN-safe) |
| `ActionThrottle` | bb | `UIControlRules.luau` | Mesma implementação de cooldown no cliente (UX) e servidor (segurança) |
| Retention funnel | halo | `RetentionService` | Funnel nativo + shards diários sem hot key |
| `Onboarding` funnel | quake | `src/server/onboarding.luau` | Eventos ordenados por inevitabilidade, flag first-session, skip em Studio, plataforma em CustomField |
| Analytics padronizados | haven | `Analytics/init.server.lua` + bindables | Ganho/gasto com fonte, erros por severidade, progression, wins de gacha (GameAnalytics HMAC) |
| Simulation harness Monte Carlo | bb | `SimulationHarness.luau` (+tests) | Joga o jogo inteiro logicamente (160 placements, fairness floor) sem render — gate de balanceamento em CI |
| Fairness budget | bb | `HandGenerator.luau` | Débito de assistência só com evidência de efeito; perfis de dificuldade com membro neutro canônico |

## 12. Infra & Rede transversal

| Módulo | Fonte | Arquivos-chave | O que generaliza |
|---|---|---|---|
| Remotes bus com rate-limit token bucket | infected | `src/shared/Remotes.luau` | Spec declarativa por canal (nome+validador+rate), contador de violações exposto ao Anti-Cheat |
| Validators compostos | infected | `src/shared/Validators.luau` | number/integer/str/oneOf/vector3/unitVector3/shape/optional; rejeita NaN/inf/chaves desconhecidas |
| CommandBus ok/code | halo | `src/Shared/API/CommandBus.lua` + Validators | Dispatcher puro com envelopes, origens GUI/Network/Automation/Internal, comandos test-only protegidos |
| RemoteProperty per-client | Weaver | `Internals/RemoteProperty.luau` | Valor default global + valores por-cliente sobre 1 RemoteEvent |
| serdes buffer datatypes | YetAnotherNet | `lib/serdes/datatypes/**` | Pares write/read compactos (Vector3 12B, CFrame 48B, Identifier 2B) + batching por identifier |
| Zonas espaciais LBVH | QuickZone | `src/Core/Scheduler.luau`, `Utils/LinearBVH.luau` | BVH linear Morton codes, frame budget, SoA/pooling — adoção direta recomendada |
| Signal ConnectParallel | Weaver | `Util/Signal.luau` | Parallel Luau, Once, Wait |
| Coverage/evidence manifests | quake | `docs/coverage/*.md`, `FIDELITY.md` | Metodologia de status normativos com evidência citada por linha — blueprint da validation ladder |

---

## Priorização sugerida para implementação na biblioteca

**Onda 1 — alto valor, fonte madura (jogos publicados/testados):**
1. `GridPlacement` (haven) — joia da coroa, tycoons inteiros dependem disso
2. `Remotes bus` + `Validators` (infected) — endurece o Forge/Net existente
3. `Wallet.Balance` + `FormulaBuilder` + `Income.Engine` (bocchi) — economia idle completa
4. `CombatValidator` + `DamagePipeline` (vesteria + fight) — duas metades complementares do combate
5. `RoundMachine` (infected) + `MatchQueue`/`WinResolver` (brr) — partidas completas

**Onda 2 — sistemas distintos:**
6. `LootLottery` + `GachaPurchaseFlow` + `DailyRewardCalendar` + `OfflineEarnings` (haven)
7. `TraitAI` + `GroundSnapLocomotion` + `CrowdSeparation` + `ProxyReplication` (jecs)
8. `Guild/Trade/Party` (vesteria) + `Permissions.Service` (bocchi)
9. `QuestEngine` (rojo) + `TutorialFlow` (haven) + `ProgressionHooks`
10. `RebirthLoop` + `PrestigeVault` + `BlueprintSerializer` (haven)

**Onda 3 — polish e nichos:**
11. `PanelKit` + `ThemeTokenSystem` + `ResponsiveLayoutSolver` (bb)
12. `PhysicsInteractable` família (rojo) + `DeclarativeWorldBuilder`
13. `Iso2dEngine` (2d) — pacote isolado
14. `AccelMove`/FPS kit (lapskaus/quake) — referências
