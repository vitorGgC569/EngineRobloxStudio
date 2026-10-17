# Authoring capability research — the theoretical ceiling

This document inventories what the Roblox platform actually exposes to a
program that wants to *build* a game, as opposed to *judge* one. Every claim
carries a source; anything unverified is marked.

Research cut-off: August 2026. Implementation alignment pass: 23 September
2026. The built-in Studio MCP federation described in section 0.1 is now
implemented in `rqe/bridge/studio_mcp.py`; lower sections remain capability
research unless they explicitly name an implementation.

---

## 0. Three findings that change the shape of the problem

### 0.1 Roblox ships its own Studio MCP server, and it has capabilities we concluded were impossible

Studio now contains a built-in MCP server (Assistant settings → Manage MCP
Servers → "Studio as MCP server"). Its tool surface:

| Group | Tools |
|---|---|
| Scripts | `script_read`, `multi_edit`, `script_search`, `script_grep` |
| Asset & generation | `generate_mesh`, `generate_material`, `generate_procedural_model`, `wait_job_finished`, `search_asset`, `insert_asset`, `upload_image`, `store_image` |
| DataModel | `subagent`, `search_game_tree`, `inspect_instance` |
| Execution | `execute_luau` |
| Playtest | `get_studio_state`, `start_stop_play`, `get_console_output`, `screen_capture` |
| **Input simulation** | `character_navigation`, `user_keyboard_input`, `user_mouse_input` |
| Docs/skills | `http_get`, `skill` |
| Sessions | `list_roblox_studios`; every targeted call carries `studio_id` |

Two things matter here.

**`user_keyboard_input` / `user_mouse_input` exist.** We measured that
`VirtualInputManager` is refused both in a LocalScript and in a plugin
(`lacking capability RobloxScript`), and concluded GUI clicks could not be
synthesised at all. Roblox's own server does it, because it runs at a privilege
level a third-party plugin does not get. This is a capability gap that is
*structural*, not a bug in our approach.

**The archived reference implementation used our exact architecture** — "a web
server built on `axum` that a Studio plugin long polls". The inverted-flow
design was correct. It is now also officially supported, which means the
question is federation, not replacement.

That federation is now concrete. `RobloxStudioMcpTransport` speaks the
built-in stdio MCP and selects an exact open Studio by `studio_id`, place
name, or place id; `FederatedStudioTransport` routes play/stop, viewport
capture, console, navigation, keyboard and mouse to Roblox's implementation
while retaining the RQE extension for product-specific probes, telemetry,
network/device controls, serialization and release provenance. It never starts
Roblox Studio itself. If no exact open Studio can be selected, it fails closed
instead of falling back to window focus or F5.

The earlier standalone server (`Roblox/studio-rust-mcp-server`, 6 tools:
`run_code`, `insert_model`, `get_console_output`, `start_stop_play`,
`run_script_in_play_mode`, `get_studio_mode`) is **archived**; engineering moved
to the built-in one.

### 0.2 The asset ceiling is largely gone — there are four independent paths

The earlier conclusion "I cannot create or upload assets" is **out of date**.

| Path | What it does | Where it runs | Persists? | Gate |
|---|---|---|---|---|
| `GenerationService` (Cube 3D) | text/image → mesh or **multi-part model** | in-experience Luau + Studio Assistant | Studio-generated → inventory + Toolbox; in-experience → **no** | ID-verified + Security toggle; 5 gen/min per experience; free in beta |
| `AssetService:CreateAssetAsync` / `CreateAssetVersionAsync` | upload Model, Plugin, Mesh (`EditableMesh`), Image (`EditableImage`) | **local Studio plugins** + **Open Cloud Luau tasks** | yes, real assetId | beta flag "CreateAssetAsync Luau API"; 30 req/min; not for published experiences; **Creator Store plugins blocked** |
| `EditableMesh` / `EditableImage` | procedural geometry and textures with **no upload at all** | client, published experiences (since Jan 2025) | no — runtime only | 13+, ID-verified, "Allow Mesh / Image APIs" in Game Settings → Security |
| Open Cloud Assets API | Audio, Decal, Image, Model, Mesh, Video; `.rbxm`/`.rbxmx` models **and animations**; FBX/glTF → Model | anywhere with an API key | yes | `asset:write` key; moderation |

Corrections to previously stated constraints:

- **Animations *are* uploadable via Open Cloud**, as `.rbxm`/`.rbxmx`
  (MIME `x-rbxm`, format auto-detected). Caveat from Roblox: the feature is
  "primarily to help you re-upload native data you previously downloaded"; files
  edited externally "might not upload successfully or function correctly".
- **Plugins cannot be uploaded via Open Cloud** ("discussions ongoing").
- `KeyframeSequenceProvider:RegisterKeyframeSequence()` returns a **temporary
  Studio-only** id. Not viable for a shipped game. The viable no-asset animation
  path is Motor6D/CFrame driven per-frame.

### 0.3 Roblox runs Luau headlessly on its own infrastructure

The **Open Cloud Luau Execution API** runs a script against a real place on
Roblox servers, with full DataModel and engine Luau access.

```
POST /cloud/v2/universes/{u}/luau-execution-session-task-binary-inputs
POST /cloud/v2/universes/{u}/places/{p}/luau-execution-session-tasks
POST /cloud/v2/universes/{u}/places/{p}/versions/{v}/luau-execution-session-tasks
GET  .../tasks/{task_id}
GET  .../tasks/{task_id}/logs
```

- up to **5 minutes** per task, **10 concurrent** per place
- `SavePlaceAsync` to persist changes
- large **binary payloads** in and out; `SerializationService` to deserialize RBXM
- scope `luau-execution-sessions:write`
- reference: `Roblox/place-ci-cd-demo`, `Roblox/open-cloud-execution-binary-payloads-example`

Combined with the **Place Publishing API**
(`POST /universes/v1/{u}/places/{p}/versions?versionType=Published`, accepts
`.rbxl` and `.rbxlx`), this is a complete build→execute→publish loop **with no
local Studio in it**.

Consequence: an authoring SDK written as pure Luau modules runs in **three**
places — local Studio plugin, published experience, and headless cloud task.
Write once, three execution surfaces. That is the single most important
architectural fact in this document.

---

## 1. Geometry and world fabrication

### Solid modelling at runtime — `GeometryService`

`UnionAsync`, `IntersectAsync`, `SubtractAsync` run during gameplay in published
experiences. Signature shape: a part, an array of parts, and an options table.

**July 2026 update**: solid modelling now supports **MeshParts**, plus new
**Fragment APIs** and a **Sweep API** (cutting operations).

What this unlocks for a builder library, concretely: carve doorways and windows
out of walls instead of assembling them from five boxes; sweep a profile along a
path for railings, mouldings and roads; fragment for destruction; boolean a
mesh against a mesh. This is the difference between "assembled from bricks" and
"modelled".

### Terrain

4×4×4 stud voxels, each with an occupancy (0–1) and a material.
`FillBlock`, `FillBall`, `FillCylinder`, `FillRegion`, `ReadVoxels`,
`WriteVoxels`. Known performance note from the community: `FillBlock` loops are
too slow for large procedural maps; `WriteVoxels` (material→density arrays over
a Region3) is the bulk path.

### Procedural mesh and texture without upload

`AssetService:CreateEditableMeshAsync()` — mesh from scratch or copied from an
owned asset, with vertex/triangle/normal editing in Luau.
`AssetService:CreateEditableImageAsync()` — pixel-level image authoring.

Applied through the `Content` type: `MeshPart`, `SurfaceGui`, `ImageLabel`.

Hard limits to design around:
- **Memory-budgeted**; creation "might return `nil`" if out of budget — must
  null-check every creation
- `Destroy()` exists specifically to free budget
- **do not replicate** — server/client sync is manual
- can only be created from assets **you own** (or the group's, if group-owned)
- a reported client limit of **8** concurrent `EditableMesh`/`EditableImage`
  instances (community report; treat as needing verification)
- Roblox still calls it beta and says the memory budget and permission
  restrictions may be re-tuned

---

## 2. Materials, lighting and the "professional look" surface

This is the highest-leverage art-direction area and it is **entirely
scriptable and entirely free** — no assets, no uploads, no moderation.

### Lighting

- `Lighting.Technology = Future` — shadow mapping and specular highlights from
  *all* light types, environment reflections. Recommended default for new
  projects.
- `Atmosphere` — Density, Offset, Haze, Glare, Color, Decay. Repeatedly
  described as the single biggest control for *sense of scale and distance*.
- `Clouds` (parented to `Terrain`) — also modulates directional brightness.
- `ClockTime`, `GeographicLatitude`, `OutdoorAmbient`, `Ambient`,
  `ExposureCompensation`, `EnvironmentDiffuseScale`, `EnvironmentSpecularScale`.

### Post-processing

`BloomEffect`, `SunRaysEffect`, `ColorCorrectionEffect`, `DepthOfFieldEffect`,
`BlurEffect`. A community-cited "portfolio-grade" starting stack: Bloom ~1.5,
SunRays ~0.25, ColorCorrection Contrast ~0.2, DepthOfField with a tight
`InFocusRadius` for bokeh.

These numbers are exactly the kind of thing a **mood preset token set** should
encode — one named preset per intended feeling, versioned, diffable, and
measurable from a screenshot.

### Materials

- `MaterialService` + `MaterialVariant` — override built-in materials with
  custom PBR sets
- `SurfaceAppearance` — PBR on MeshParts (ColorMap, NormalMap, RoughnessMap,
  MetalnessMap)
- **Texture Generator** (Studio → Window → 3D): 1024×1024 PBR from a text
  prompt, producing albedo/normal/roughness that attach to MeshParts. Exposed
  as the MCP tool `generate_material`.

---

## 3. UI

Flexbox shipped in **August 2024**, all platforms:

- `UIListLayout.HorizontalFlex` / `VerticalFlex` (`UIFlexAlignment`)
- `UIFlexItem.FlexMode` = `Fill` | `Grow` | `Shrink` | `Custom`, per-child override
- `GuiObject.AutomaticSize` in the fill direction is interpreted as **automatic
  flex basis**

Plus the rest of the modern set: `UIPadding`, `UICorner`, `UIStroke`,
`UIGradient`, `UIScale`, `UIAspectRatioConstraint`, `UIPageLayout`,
`UITableLayout`, `CanvasGroup`, `ScrollingFrame`, `FontFace`.

Note for the record: the UI defects we measured — alphabetical tab order from
`SortOrder`, hand-computed offsets, no spacing scale — were all avoidable with
this set. There is enough here for a real design-token system (spacing scale,
type scale, elevation, motion curves) with no custom framework.

---

## 4. Audio

The **AudioAPI** node graph has been production since late 2024 and is the
default surface for anything beyond a one-shot click.

Instances: `AudioPlayer`, `AudioEmitter`, `AudioListener`, `AudioDeviceOutput`,
`AudioDeviceInput`, `AudioFader`, `AudioEqualizer`, `AudioLimiter`,
`AudioCompressor`, `AudioReverb`, `AudioDistortion`, `AudioChorus`,
`AudioFlanger`, `AudioPitchShifter` — connected by **`Wire`** instances.
Directional audio supported.

The convergent production pattern:

- **global** (music, UI, narration): `AudioPlayer` → `AudioDeviceOutput`
- **world** (footsteps, weapons, ambience): `AudioPlayer` → `AudioEmitter` →
  `AudioListener`, position-respecting

Why this matters for an asset-constrained builder: a routing graph with filters,
reverb and pitch turns a *small* number of uploaded source sounds into a full
soundscape. The multiplier per uploaded asset is very high — which is exactly
what you want when moderation is the bottleneck.

---

## 5. Interaction, characters, VFX

- **`DragDetector`** — parent it to any `BasePart` or `Model` and the object
  becomes draggable across mouse, touch, gamepad and VR, **with zero lines of
  code**. Drag styles, axis and movement limits, anchored parts stay where
  released, and scripts can react to drive logic. Doors, drawers, levers,
  sliders, throwables.
- `ProximityPrompt`, `ClickDetector`.
- `TweenService`; constraints (`SpringConstraint`, `AlignPosition`,
  `AlignOrientation`, `HingeConstraint`, `PrismaticConstraint`, `RopeConstraint`).
- `HumanoidDescription` + `Players:CreateHumanoidModelFromDescription`.
- VFX: `ParticleEmitter` (flipbooks, `Squash`, `Shape`/`ShapeStyle`), `Beam`,
  `Trail`, `Highlight`, `Explosion`, `Smoke`, `Fire`, `Sparkles`.

### Animation — three real paths, ranked

1. **Procedural Motor6D/CFrame** driven per-frame. No asset, no upload, no
   moderation, works everywhere. Poses map to `Motor6D` by the name of `Part1`.
2. **Uploaded `Animation` assets** via Open Cloud `.rbxm`/`.rbxmx`, with the
   caveat that externally-authored files may not process correctly.
3. **`plugin:ImportFbxRig` / `plugin:ImportFbxAnimation`** from a local Studio
   plugin (`ImportFbxAnimation(rigModel, isR15)` now returns an `Instance` and
   yields).

Not viable: `RegisterKeyframeSequence` (Studio-only temporary id).

---

## 6. Data, liveops, and the instruments for "is it fun"

- `DataStoreService` v2 with `UpdateAsync`, `OrderedDataStore`
- `MemoryStoreService` — SortedMap, Queue, HashMap
- `MessagingService`, `TeleportService` (reserved servers, teleport data)
- **`AnalyticsService`** — this is the official instrument for the question the
  engine currently cannot answer:
  - **Funnel events** — onboarding drop-off, progression stalls, shop
    abandonment
  - **Economy events** — sinks, sources, average wallet balance
  - **Custom events** with custom fields for segmentation
  - dashboards appear under Analytics on the Creator Dashboard once emitted

Over 1,000 experiences reportedly use funnel/economy analytics. This is the
difference between proving the conveyor moves and knowing the second upgrade is
priced wrong.

---

## 7. Plugin-only privileges — why a local plugin still matters

Things only a local Studio plugin can do, which no in-experience script and no
cloud task can:

- `plugin:ImportFbxRig`, `plugin:ImportFbxAnimation`
- `StudioService:PromptImportFile` / `PromptImportFiles`
- `AssetService:CreateAssetAsync` (**local plugins only** — Creator Store
  plugins are blocked pending a permission system)
- `ChangeHistoryService:TryBeginRecording` / `FinishRecording` — **mandatory**
  for any agent editing a human's place; without it the human cannot undo us
- `plugin:Union` / `plugin:Separate` (edit-mode CSG)
- `Selection`, toolbars, docked widgets
- `InsertService:LoadAsset`

---

## 8. External toolchain

The mature professional Luau stack, all usable from CI:

| Tool | Role |
|---|---|
| **Rojo** | filesystem ⇄ place sync |
| **Rokit** | toolchain manager (successor to Foreman/Aftman) |
| **Wally** | package manager (Cargo-inspired) |
| **Selene** | linter |
| **StyLua** | formatter |
| **luau-lsp** | language server / type checking |
| **TestEZ** | unit testing |
| **Lune** | **standalone Luau runtime** — run Luau in CI with no Roblox at all |

Off-platform generation paths worth noting:

- **Blender headless Python** → FBX/glTF → Open Cloud Assets API (Model). A real
  procedural-mesh pipeline that does not depend on Cube's quality.
- **numpy → wav/ogg** → Open Cloud Assets API (Audio). Moderation is the gate,
  not the code.

---

## 9. Asset discovery

- **Creator Store API** — queries Studio assets (meshes, models, audio); the
  documented entry point is Toolbox Service in the Open Cloud reference. Returns
  JSON.
- **Marketplace/Catalog API** (`catalog.roblox.com/v1/search/items/details`) —
  avatar items, a different corpus.
- MCP tools `search_asset` / `insert_asset` cover the same ground from inside
  Studio.

Note against our own history: we previously retrieved public anime decal ids via
the toolbox service successfully, but **0/8 loaded** when probed client-side in a
real session. That failure was never explained and remains open — likely
ownership/permission on `Content` rather than the search itself.

---

## 10. What professional actually means — the design knowledge, not the API list

Roblox's own environmental-art curriculum describes the professional pipeline,
and it is not "place more parts":

1. **Greybox** — build the level in simple shapes before any scripting or art.
   Test gameplay, find layout problems while the level is still cheap to change.
2. **Modular kit** — author a *few* assets designed to combine, then build the
   whole environment from them. "You don't need to manually create each
   individual asset."
3. **Trim sheet** — one UV-wrapped texture sheet shared across the kit is what
   makes distinct objects feel like they belong to the same world.
4. **Props and set dressing** last.

The unit of professional work is the **kit**, not the part. Our `WorldKit`
composes parts; the ceiling described here composes kits.

Other encodable knowledge, all of it measurable by the bridge we already have:

- **Scale grammar** — door widths, corridor widths, ceiling heights, jump gaps,
  stair rise/run — all derived from character metrics and all verifiable by
  raycast and pathfinding
- **Sightlines and landmark hierarchy** — what must be visible from where
- **Silhouette contrast** — readability at distance
- **Colour hierarchy** — where the eye is sent
- **Negative space** — the thing a density metric cannot see

---

## 11. The honest ceiling — what stays human or blocked

One-time human actions (a person clicks once, then the pipeline is unblocked):

- 13+ **ID verification** for the account/group
- **"Allow Mesh / Image APIs"** toggle in Game Settings → Security
- Studio beta flag **"CreateAssetAsync Luau API"**
- Open Cloud API keys with the right scopes

Permanently human or unbounded:

- **Moderation** of every uploaded asset — human + Roblox, unbounded latency
- **Developer products and gamepasses** — created in the Creator Dashboard
- Experience icon, thumbnails, making the place public
- Creator Store plugin distribution cannot use `CreateAssetAsync` (yet)

Quality ceilings acknowledged by Roblox itself:

- Cube generates **single objects** only, needs manual scaling, and texture
  quality is stated as needing improvement
- `Editable*` remains beta with a re-tunable memory budget and permission model

`RELEASE_CANDIDATE` therefore remains the true ceiling of full automation, which
matches what the release gate already models.

---

## 12. Summary of the theoretical ceiling

Layered, from what exists today to what the platform permits:

| Layer | Today | Platform ceiling |
|---|---|---|
| **L0 tokens** | none | palette + harmony rules, scale grammar, motion curves, lighting moods, type/spacing scale — all versioned and diffable |
| **L1 primitives** | `Build.part/cylinder/wedge/round` | same, plus `GeometryService` sweep/fragment/boolean-on-mesh |
| **L2 fabrication** | none | CSG at runtime, `EditableMesh`, `EditableImage`, terrain `WriteVoxels`, Cube generation |
| **L3 kits** | none | modular kits + trim sheets, `Package` reuse |
| **L4 composition** | hand-placed per map | blockout grammar, landmark hierarchy, sightline solver |
| **L5 presentation** | a palette and one Sky | Future lighting, Atmosphere, Clouds, 5 post effects, AudioAPI graph, VFX, camera language |
| **L6 systems** | per-game services | economy/progression/save/shop/UI design system as SDK |
| **L7 genre templates** | none | tycoon / simulator / obby / TD, each with tokens, camera, onboarding, mobile |
| **Assets** | search only, no generation | Cube, `CreateAssetAsync`, `Editable*`, Open Cloud, Blender/numpy off-platform |
| **Execution** | one local Studio | local plugin **+ published experience + headless cloud**, 10 concurrent tasks per place |
| **Instruments** | geometry/runtime/visual | plus `AnalyticsService` funnels, economy and custom events |

The binding constraint is no longer platform capability. Almost everything
needed to build professionally is scriptable, and therefore exposable to an
agent as a typed command surface — which is exactly what the bridge already is.

---

## Sources

- [Connect to the Roblox Studio MCP server — Creator Hub](https://create.roblox.com/docs/studio/mcp)
- [Roblox/studio-rust-mcp-server (archived)](https://github.com/Roblox/studio-rust-mcp-server)
- [Introducing the Open Source Studio MCP Server — DevForum](https://devforum.roblox.com/t/introducing-the-open-source-studio-mcp-server/3649365)
- [Luau Execution — Creator Hub](https://create.roblox.com/docs/cloud/reference/features/luau-execution)
- [[Beta] Open Cloud Engine API for Executing Luau — DevForum](https://devforum.roblox.com/t/beta-open-cloud-engine-api-for-executing-luau/3172185)
- [Roblox/place-ci-cd-demo](https://github.com/Roblox/place-ci-cd-demo)
- [Roblox/open-cloud-execution-binary-payloads-example](https://github.com/Roblox/open-cloud-execution-binary-payloads-example)
- [Assets — Open Cloud reference](https://create.roblox.com/docs/cloud/reference/features/assets)
- [Open Cloud Upload Support for More Asset Types — DevForum](https://devforum.roblox.com/t/open-cloud-upload-support-for-more-asset-types/4022082)
- [Introducing Open Cloud Assets API — DevForum](https://devforum.roblox.com/t/introducing-open-cloud-assets-api/2245171)
- [[Beta] Lua Asset Creation for Creator Tooling with CreateAssetAsync — DevForum](https://devforum.roblox.com/t/beta-lua-asset-creation-for-creator-tooling-with-createassetasync/3294134)
- [[Beta] Cube 3D Generation Tools and APIs for Creators — DevForum](https://devforum.roblox.com/t/beta-cube-3d-generation-tools-and-apis-for-creators/3558947)
- [Introducing Roblox Cube — Roblox Newsroom](https://about.roblox.com/newsroom/2025/03/introducing-roblox-cube)
- [GenerationService — Creator Hub](https://create.roblox.com/docs/reference/engine/classes/GenerationService)
- [[Client Beta] In-experience Mesh & Image APIs in published experiences — DevForum](https://devforum.roblox.com/t/client-beta-in-experience-mesh-image-apis-now-available-in-published-experiences/3267293)
- [[Full Release] Improved Constructive Solid Geometry (CSG) APIs — DevForum](https://devforum.roblox.com/t/full-release-improved-constructive-solid-geometry-csg-apis/4065505)
- [[Studio Beta] Solid Modeling on Meshes & new Fragment and Sweep APIs — DevForum](https://devforum.roblox.com/t/studio-beta-solid-modeling-on-meshes-new-fragment-and-sweep-apis/4515374)
- [GeometryService — Creator Hub](https://create.roblox.com/docs/reference/engine/classes/GeometryService)
- [Terrain — Creator Hub](https://create.roblox.com/docs/reference/engine/classes/Terrain)
- [Audio objects — Creator Hub](https://create.roblox.com/docs/audio/objects)
- [New Audio API Features: Directional Audio, AudioLimiter and More — DevForum](https://devforum.roblox.com/t/new-audio-api-features-directional-audio-audiolimiter-and-more/3282100)
- [List and flex layouts — Creator Hub](https://create.roblox.com/docs/ui/list-flex-layouts)
- [Flex Features for UIListLayout Client Release — DevForum](https://devforum.roblox.com/t/flex-features-for-uilistlayout-client-release/3096190)
- [3D drag detectors — Creator Hub](https://create.roblox.com/docs/ui/3D-drag-detectors)
- [Announcing DragDetectors! — DevForum](https://devforum.roblox.com/t/announcing-dragdetectors/2641956)
- [KeyframeSequenceProvider — Creator Hub](https://create.roblox.com/docs/reference/engine/classes/KeyframeSequenceProvider)
- [Plugin — Roblox API Reference](https://robloxapi.github.io/ref/class/Plugin.html)
- [ChangeHistoryService — Roblox API Reference](https://robloxapi.github.io/ref-temp/class/ChangeHistoryService.html)
- [Texture Generator — creator-docs](https://github.com/Roblox/creator-docs/blob/main/content/en-us/studio/texture-generator.md)
- [Creator Store queries — Creator Hub](https://create.roblox.com/docs/projects/assets/api)
- [Place publishing — Creator Hub](https://create.roblox.com/docs/cloud/guides/usage-place-publishing)
- [AnalyticsService — Creator Hub](https://create.roblox.com/docs/reference/engine/classes/AnalyticsService)
- [Analytics: Track funnel and economy events — DevForum](https://devforum.roblox.com/t/analytics-track-funnel-and-economy-events-to-grow-your-experience-faster/3060398)
- [Analytics: Track any custom event — DevForum](https://devforum.roblox.com/t/analytics-track-any-custom-event-you-want-and-use-custom-fields-for-segmentation/3163688)
- [Develop polished assets (modular kits, trim sheets) — creator-docs](https://github.com/Roblox/creator-docs/blob/main/content/en-us/tutorials/curriculums/environmental-art/develop-polished-assets.md)
- [Greybox a playable area — Creator Hub](https://create.roblox.com/docs/tutorials/curriculums/core/building/greybox-a-playable-area)
- [Luau Toolchain Guide: Rojo, Selene, StyLua & Wally (2026)](https://www.oflight.co.jp/en/columns/luau-developer-toolchain-rojo-selene-wally-2026)
- [Lune — standalone Luau runtime](https://lune-org.github.io/docs/)
