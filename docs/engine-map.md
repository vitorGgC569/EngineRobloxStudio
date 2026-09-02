```
FORGE ENGINE MAP
58 families, 232 modules, 1619 public functions

Run `forge find <concept>` before writing a system. It searches this,
the games, and the kits at once.

AI
  AI                     AI - crowd and companion intelligence for Forge games
  BehaviorTree           BehaviorTree - minimal SEQUENCE / FALLBACK tree with RUNNING status  [5]
  CrowdSeparation        CrowdSeparation - soft-body bubble separation for dense crowds  [3]
  EntityRefRegistry      EntityRefRegistry - stable keys to entities across systems and realms  [5]
  GroundLocomotion       GroundLocomotion - kinematic crowd movement with wall-stop and ground-  [2]
  MobCatalog             MobCatalog - weighted spawner specification  [3]
  Navigator              Navigator - waypoint following with stuck detection and recovery  [3]
  Perception             Perception - sight/hearing with a memory window  [5]
  SnapshotInterp         SnapshotInterp - client-side pose interpolation between network snapsh  [4]
  SystemMailbox          SystemMailbox - deferred event buffers between simulation phases  [6]
  TraitBrain             TraitBrain - weighted-trait AI brain with state hysteresis  [3]

Ability
  Ability                Ability - costs, cooldowns, cast windows and targeting  [15]

Access
  Access                 Access - the game is playable by people this engine had not considered  [13]

Actor
  Actor                  Actor - state machines, perception and population, for things that thi  [32]

Anim
  Anim                   Anim - layered procedural animation with markers  [24]
  Presets                Anim.Presets - a starter set of clips

Assets
  Assets                 Assets - one way to name and produce content  [22]

Audio
  Audio                  Audio - sound as data, pooled, grouped and ducked  [14]
  Bank                   Bank - sounds every game can play, so no game starts mute  [3]

Bench
  Bench                  Bench - measured cost, instead of a number from an empty room  [6]

Camera
  Camera                 Camera - where the player is looking, and who decides  [9]
  Viewmodel              Viewmodel - the weapon in your hands, that never clips into a wall  [6]

Capability
  Capability             Capability - ask Roblox what exists instead of assuming  [9]

Catalog
  Catalog                Catalog - Creator Store models this project has verified  [13]
  ItchAssets             ItchAssets - CC0 models published to this account, grouped by topic  [4]
  Place                  Place - put a catalogue model in the world so it looks like it belongs  [12]
  Prop                   Prop - rebuild a Creator Store model from baked geometry  [4]
  Scale                  Scale - how big a thing of this kind should be, in studs  [3]
  StoreAssets            StoreAssets - Creator Store assets that were fetched, opened and read  [4]
  StoreProps             StoreProps - geometry read out of real Creator Store models  [3]
  Textures               Textures - CC0 surface art published to this account, keyed by what it  [5]
  Tint                   Tint - colour for imported meshes that arrived without any  [3]

Cluster
  Cluster                Cluster - the engine stops assuming there is one server  [15]

Collab
  Collab                 Collab - more than one person editing without ruining each other's wor  [14]

Combat
  AbilitySystem          AbilitySystem - GUID-addressable casts with cast times and cooldowns  [9]
  AggroTable             AggroTable - symmetric threat with decay, assist sharing and rage latc  [6]
  AntiCheatMath          AntiCheatMath - movement violation classification  [4]
  AutoTarget             AutoTarget - which of these am I actually hitting? Not aggro, and not   [5]
  AutoTurret             AutoTurret - pure targeting and fire-cycle model for defensive units  [3]
  ClassRegistry          ClassRegistry - declarative class movesets with fail-loud validation  [5]
  Combat                 Combat - mechanism for hurting things  [29]
  ComboSequencer         ComboSequencer - data-driven attack chains with input buffering  [6]
  DamagePipeline         DamagePipeline - pure resolution of a landed strike, nothing attached  [1]
  EntityCatalog          EntityCatalog - combat units as validated data with special hooks  [5]
  FactionService         FactionService - data-driven hostility resolution  [3]
  HitGeometry            HitGeometry - analytical OBB / sphere / cone overlap tests  [5]
  HitValidator           HitValidator - statistical sanity checks for client-reported hits  [5]
  ProjectileSim          ProjectileSim - shared ballistic prediction for shot validation  [3]
  StatusEffects          StatusEffects - pure stack of timed status effects  [7]
  StunController         StunController - stackable stun timers keyed by caller-chosen ids  [6]
  UnitRunner             UnitRunner - deterministic table-based combat simulation  [3]

Companion
  Companion              Companion - things that follow you, and stay readable while they do  [2]
  Formation              Formation - where each follower stands, relative to whoever it follows  [3]
  Meander                Meander - what a follower does while nothing is happening  [2]

Core
  Boot                   Boot - a startup that waits for things instead of hoping about them  [11]
  Clock                  Clock - one time, agreed on by every server and every client  [15]
  Core                   Core - primitives with no Roblox opinions in them
  Cvars                  Cvars - named tunables inspectable by probes  [6]
  Ease                   !strict Ease - curves by name, so a curve choice can live in a data ta  [4]
  Rng                    Rng - seeded randomness in named streams  [18]
  Sched                  Sched - how work gets spread across frames  [12]
  Signal                 !strict Signal - Lua-side event  [9]
  SparseSet              SparseSet - add, remove and iterate a set of ids, all in constant time  [10]
  Spring                 Spring - damped harmonic motion for numbers and Vector3  [5]
  Trove                  !strict Trove - one object owns everything it created, and releases al  [7]

Data
  Data                   Data - content tables with a declared shape  [11]

Debug
  Debug                  Debug - how a running game explains itself  [20]

Destruction
  Destruction            Destruction - things coming apart, on a budget  [7]

Dialogue
  Dialogue               Dialogue - conversation as a graph of data  [9]

Economy
  Audit                  Audit - where the money comes from, where it goes, and how long it tak  [9]
  Balance                Balance - a multi-currency wallet with atomic spending  [7]
  BigNumber              BigNumber - arbitrary-magnitude numbers in scientific notation, pure L  [20]
  Economy                Economy - numbers, formulas, wallets and income for incremental games
  Formula                Formula - an immutable, renderable chain of arithmetic operations  [2]
  IncomeEngine           IncomeEngine - cached aggregation of passive income sources  [7]

Editor
  Editor                 Editor - the authoring surface over a Scene  [35]
  Gizmo                  Editor.Gizmo - the 3D manipulators  [7]
  Ui                     Editor.Ui - the overlay  [4]

Entity
  Entity                 Entity - composition instead of inheritance  [36]

Events
  Events                 Events - the spine everything else listens to  [13]

Examples
  Examples               Examples - one runnable demonstration per module  [4]

Feel
  Feel                   Feel - impact, weight and reaction  [17]

IK
  IK                     IK - putting a hand or a foot where the world is, not where the clip s  [7]

Input
  Input                  Input - actions, not keys  [18]

Interaction
  Interaction            Interaction - things a player can do to the world, in one registry  [9]

Inventory
  Inventory              Inventory - containers, stacks, equipment and transfers  [27]

LiveOps
  CrossServerService     CrossServerService - MessagingService binding for global channels  [4]
  EntitlementTags        EntitlementTags - validated gamepass/badge/group tags on a player  [3]
  FairnessBudget         FairnessBudget - assisted hands with an evidence-gated debit  [3]
  GachaFlow              GachaFlow - purchase-to-reveal state machine for loot boxes  [5]
  GlobalEffects          GlobalEffects - something is true for the whole server, for a while  [13]
  Leaderboard            Leaderboard - persistent cross-server rankings that reset cleanly  [10]
  LiveOps                LiveOps - changing a running game without shipping a new one  [17]
  Lottery                Lottery - cumulative-range loot rolls with contextual weights  [5]
  Luck                   Luck - shifting the odds toward the rare end, without breaking the eco  [6]
  MonteCarlo             MonteCarlo - headless strategy simulation for balance gates
  PromoCodes             PromoCodes - one-shot promotional redemptions with conditions  [2]
  SeasonalEvent          SeasonalEvent - temporary currency, spawn waves and milestone rewards  [3]
  TelemetrySync          TelemetrySync - cross-server counter merge with idempotent flush  [4]

Mark
  Mark                   Mark - tell the Quality Engine what it is looking at  [10]

Match
  ArenaLayout            ArenaLayout - declarative symmetric arena geometry  [1]
  CardCycle              CardCycle - deterministic deck / hand / next-card rotation  [6]
  DeployZone             DeployZone - server-authoritative AABB deploy regions per team  [3]
  Director               Director - match rotation with map voting and live admin override  [4]
  Match                  Match - competitive match primitives for Forge games
  MissionInstance        MissionInstance - several parties running the same content, in one ser  [14]
  Queue                  Queue - FIFO matchmaking with presence validation and forfeit handling  [8]
  RoundMachine           RoundMachine - pure round-phase state machine emitting effects  [5]
  TeamSpawns             TeamSpawns - team-tagged spawn selection  [4]
  WaveSpawner            WaveSpawner - timed waves scaled by player count  [2]
  WinResolver            WinResolver - ordered criteria cascade for ending a match  [1]

Material
  Material               Material - physically based surfaces  [16]

Monetization
  Monetization           Monetization - passes, products and receipts that cannot double-grant  [11]

Movement
  AccelMove              AccelMove - plane-velocity movement feel with split accel/brake  [3]
  Ballistics             Ballistics - shared spread cone and trajectory validation  [4]
  HitscanValidator       HitscanValidator - server-side validation for instant-shot weapons  [1]
  Movement               Movement - player feel and shooting validation
  Scoreboard             Scoreboard - K/D scoreboard with headshots and per-opponent detail  [4]
  StrafeJump             StrafeJump - quake-style air acceleration  [2]
  TeleportPads           TeleportPads - pad-to-pad teleport bookkeeping with per-pad cooldown  [3]

Nav
  Nav                    Nav - getting from here to there without walking into things  [14]

Net
  Net                    Net - a typed, validated, rate-limited bus between client and server  [15]
  RateLimit              RateLimit - continuous token buckets keyed by arbitrary strings  [4]
  RemoteProperty         RemoteProperty - replicated-property PROTOCOL, transport-free
  Serdes                 Serdes - binary codecs and frame batching over the Roblox `buffer` glo  [1]
  Validators             Validators - composable remote-payload validation, hostile-input grade  [12]

Netcode
  Netcode                Netcode - prediction, reconciliation, lag compensation and interpolati  [19]

Platform
  Platform               Platform - is this game actually playable on the device in front of yo  [7]

Progression
  Achievements           Achievements - a thing you did once, remembered for ever  [7]
  CrateRoll              CrateRoll - deterministic crate loot with pity and weighted tables  [2]
  DailyRewardCalendar    DailyRewardCalendar - login streaks over absolute UTC days, no Instanc  [4]
  Enchanting             Enchanting: costed upgrade rolls over item slots  [5]
  FishingMinigame        FishingMinigame: session GUID, bite windows and level-gated loot  [6]
  IdleGenerator          IdleGenerator - coin pickups with respawn and an upgrade pad  [6]
  IncomeTracker          IncomeTracker - a moving window of per-sample deltas for rate displays  [6]
  ModifierPipeline       ModifierPipeline - a number, and why it is that number  [6]
  OfflineEarnings        OfflineEarnings - how much an absent earner collects when they return  [1]
  PlaytimeLadder         PlaytimeLadder - rewards for time spent, without paying people to be a  [12]
  PrestigeVault          PrestigeVault - the sacrifice vault, as pure item bookkeeping  [3]
  Progression            Progression - levels, experience, points and unlocks, for any subject  [12]
  QuestEngine            QuestEngine - declarative multi-stage quests with count/time objective  [8]
  QuestRotation          QuestRotation - deterministic daily/periodic quest assignment  [3]
  RebirthLoop            RebirthLoop - prestige arithmetic stripped of every side effect  [5]
  RegeneratingResource   RegeneratingResource - capped resource with per-second regen and phase  [4]
  SeasonPass             SeasonPass - tiered pass progress with free/premium tracks  [3]
  TutorialFlow           TutorialFlow - server-validated tutorial steps with telemetry hooks  [6]
  UpgradeTree            UpgradeTree - a pure DAG of repeatable upgrades behind prerequisite ga  [7]

Quest
  Quest                  Quest - objectives as event filters  [18]

Reference
  Reference              Reference - what a reasonable number looks like  [5]

Rig
  Ragdoll                Ragdoll - a body that stops being animated and starts being physics  [6]
  Rig                    Rig - characters authored in code  [10]

Save
  DataStoreAdapter       DataStoreAdapter - the concrete Store behind Save's pure modules  [1]
  DeltaCounter           DeltaCounter - add-only counters that merge instead of overwrite  [6]
  Gatekeeper             Gatekeeper - the load lifecycle as a tiny state machine  [9]
  LiveConfig             LiveConfig - runtime tuning without republishing  [3]
  Migrator               Migrator - versioned, side-effect-free profile upgrades  [2]
  MultiSlot              MultiSlot - naming and selection rules for multi-slot saves  [3]
  ReceiptLedger          ReceiptLedger - append-only, idempotent grant history  [2]
  Save                   Save - player profiles that survive, migrate and do not corrupt  [10]
  ServerProfile          ServerProfile - session-locked profile for a non-player entity  [6]
  StatsDeriver           StatsDeriver - derived player stats from base + equipment + perks  [2]
  TransactionJournal     TransactionJournal - moving something between two owners, across a cra  [11]
  VersionRollback        VersionRollback - save-file version history with rollback points  [4]
  VersionRollbackStore   VersionRollbackStore - persists the version ring across servers  [2]

Scene
  Scene                  Scene - a place expressed as data, not as code  [31]

Social
  AdminChatBridge        AdminChatBridge - chat-driven admin commands with authorization  [3]
  AdminCommands          AdminCommands - permission-gated admin command surface  [3]
  GuildModel             GuildModel - persistent group with ranks, funds and upgrades  [7]
  ModerationKit          ModerationKit - decaying suspicion score with verdicts  [4]
  PartyModel             PartyModel - small cooperative group with leader controls and a ready-  [11]
  Permissions            Permissions - hierarchical ACL for shared entities (plots, servers, gu  [5]
  PlotPermissions        PlotPermissions - plot ownership with visitor capability toggles  [7]
  ServerModePlots        ServerModePlots - server-mode detection with map/theme selection  [4]
  Social                 Social - the player's relationship with everyone outside this server  [9]
  StaffFlags             StaffFlags - staff identity to capability flags  [3]
  TradeSession           TradeSession - two-party trade as an explicit state machine  [8]

State
  Replication            Replication - sending state changes to the clients that are allowed th  [9]
  State                  State - the session's own truth, and who is allowed to see it
  Store                  Store - one place the session's state lives, changed only by named act  [9]

Streaming
  Streaming              Streaming - a chunk layer over a Scene  [14]

Telemetry
  Telemetry              Telemetry - what actually happened, in a live game  [14]

Testing
  Testing                Testing - assertions about a game that is actually running  [21]

Travel
  CarryData              CarryData: player payload that crosses a place teleport  [3]
  Travel                 Travel - moving players between places, and arriving with something  [7]

Tycoon
  BlueprintSerializer    BlueprintSerializer - persist a placed layout as data, rebuild later  [2]
  CrossServerChannels    CrossServerChannels - global radio, shouts and ad rotation  [3]
  DropperChain           DropperChain - throughput-capped dropper production model  [3]
  GridPlacement          GridPlacement - pure placement math for tycoon building  [9]
  GroundLoot             GroundLoot - dropped physical items with temporary ownership  [4]
  NotificationKit        NotificationKit - queued player notifications and world floating text  [3]
  PickupCrate            PickupCrate - physical collectible crate model with anti-distance chec
  PlotAllocator          PlotAllocator - one plot per player, lowest free index first  [6]
  ResourceNodes          ResourceNodes - depleting resource nodes with replenish timers  [4]
  ThroughputLedger       ThroughputLedger - idempotent count of live dropped items  [5]
  Tycoon                 Tycoon - build-and-earn game primitives

UI
  AttributeInteractions  AttributeInteractions - Pretty-style hover/press driven by attributes  [2]
  DragDropBoard          DragDropBoard - shared drag-and-drop state for grid boards  [4]
  InputMode              InputMode - device classification and gamepad menu navigation  [6]
  InteractionRules       InteractionRules - shared cooldowns and input classification  [3]
  ItchIcons              ItchIcons - CC0 UI art published to this account, keyed by what it is   [8]
  Motion                 VisualKit.Motion - analytical spring solver with motion presets  [10]
  ObjectiveTracker       ObjectiveTracker - current objective text plus 3D marker plan  [5]
  PanelStateMachine      PanelStateMachine - modal panel lifecycle that always resolves  [7]
  QualityTierSelector    QualityTierSelector - post-processing tier by screen capability  [4]
  ResponsiveLayout       ResponsiveLayout - deterministic layout solver for phone/tablet/deskto  [3]
  UI                     UI - tokens and widgets, so an interface looks designed instead of ass  [10]
  VisualBinding          VisualKit.Binding - reactive data binding with text templates
  VisualComponent        VisualKit.Component - BaseComponent contract and core components
  VisualContainers       VisualContainers - M3-style containers as render plans
  VisualControls         VisualControls - input controls as stateful plans
  VisualGradient         VisualGradient - UIGradient plans from token colors  [2]
  VisualIcons            VisualIcons - token-keyed icon registry  [6]
  VisualLayouts          VisualLayouts - layout behavior as declarative plans  [3]
  VisualSpec             VisualKit.Spec - declarative UI spec with fail-closed conformance  [2]
  VisualStack            VisualKit.Stack - ordered screen stack with focus and input routing
  VisualState            VisualState - behaviour decorators for components (pract's pattern)  [1]
  VisualTheme            VisualTheme - runtime theme switching over computed role tables  [6]
  VisualTokens           VisualKit.Tokens - semantic roles from an M3 scheme, as pure data  [2]
  Widgets                Widgets - toast, tooltip and hotkey models  [2]

Visual
  Sky                    Visual.Sky - the "shader pack" layer  [11]
  Visual                 Visual - art direction as data  [17]

Weapon
  Stance                 Stance - what the shooter is doing, and what that costs in accuracy  [4]
  Sway                   Sway - the small motions that make a held weapon feel held  [5]
  Validate               Validate - deciding whether to believe a client that says it fired  [7]
  Weapon                 Weapon - the layer between "the player pressed fire" and "something to  [19]

Weather
  Weather                Weather - conditions that change while people are playing  [9]

World
  Areas                  Areas - where a player is allowed to be, and where they wake up  [13]
  Builders               Builders - idempotent find-or-create helpers for code-built worlds  [3]
  DayNightClock          DayNightClock - server-authoritative day/night cycle  [4]
  HubBuilder             WorldHubBuilder - procedural social hub spec with a graceful fallback  [2]
  Interactables          Interactables - physics playground models with server-owned state  [10]
  World                  World - terrain as a composable function, not a fixed generator  [13]

[n] is the count of public functions. `forge api --module <Name>`
prints one module's full surface.
```
