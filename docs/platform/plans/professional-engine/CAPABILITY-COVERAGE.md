# Cobertura do catálogo declarado de capacidades

Esta é uma correspondência de planejamento, não uma aprovação do catálogo nem da disponibilidade real de suas ferramentas. O conteúdo foi lido como dados para preservar todas as lacunas declaradas, incluindo afirmações históricas que precisam de atualização.

Fonte: [catálogo](C:/Users/vitor/OneDrive/Desktop/RobloxGamesMCP/quality/production-capabilities.v1.json); SHA-256 `5fe23246fc0d73eedf641093df96320cfc1989a3ea634c7390522a8a45b82519`. Hash registrado do manifesto coincide com o arquivo atual: **False**. A validação integral do catálogo não foi promovida por esta leitura.

“AVAILABLE” abaixo significa **status declarado pelo arquivo**. As falhas da auditoria prevalecem sobre afirmações genéricas de disponibilidade. Limites externos, quotas e betas são transcritos para revisão por ENV-04/06, sem tratá-los como fatos atuais confirmados.

O adapter headless de fixture deve continuar sem autoridade de produção. Uploader e actor real já existem; lacunas antigas que os chamam de ausentes precisam ser reclassificadas para integração/prova. APIs novas de teste e input também exigem reconciliação.

## project.definition.load

Status declarado: `AVAILABLE` / `STATICALLY_VALIDATED`. Backlog: **FAC-01**.

**Riscos declarados:**

- Individually valid inputs can still describe different product identities unless an alignment proof is required.

O catálogo não declara lacuna/limitação para esta entrada. A disponibilidade e os limites reais ainda dependem das verificações previstas.

## project.fixture.headless-runtime

Status declarado: `UNSUPPORTED` / `STATICALLY_VALIDATED`. Backlog: **QAT-02, QAT-07, REL-02**.

**Lacunas declaradas:**

- A fixture adapter cannot satisfy any production measurement or release requirement.

**Riscos declarados:**

- Fixture values can describe intended behavior while the real Workspace is empty or broken.

## project.identity.bind

Status declarado: `PARTIAL` / `STATICALLY_VALIDATED`. Backlog: **FAC-01, CTL-02, REL-01**.

**Lacunas declaradas:**

- Install/restart the plugin and execute a complete stamped release attempt against a live exact-build Studio session.

**Riscos declarados:**

- A caller-supplied expected product must never be echoed as runtime evidence; Studio reads only the build stamp.

## project.agent.orchestration

Status declarado: `PARTIAL` / `STATICALLY_VALIDATED`. Backlog: **FAC-02, FAC-03, FAC-04, FAC-05, FAC-06, FAC-07**.

**Lacunas declaradas:**

- A production runner must bind agent dispatch, retries, budgets and artifacts to the state machine.

**Riscos declarados:**

- Primitive correctness does not imply that an external agent runner respects locks or transitions.

## studio.lifecycle.manage

Status declarado: `PARTIAL` / `RUNTIME_VALIDATED`. Backlog: **ENV-04, ENV-05, CTL-02, CTL-06**.

**Lacunas declaradas:**

- Safe concurrent ownership of multiple Studio processes by PID, HWND, place, build and agent is not end-to-end validated.

**Riscos declarados:**

- A killed Studio can leave an apparently live long-poll session until it is explicitly retired.

## studio.mcp.gateway

Status declarado: `PARTIAL` / `STATICALLY_VALIDATED`. Backlog: **CTL-01, CTL-02, ENV-04**.

**Lacunas declaradas:**

- Every MCP operation needs a versioned schema, explicit session/build/player selectors and a verified mapping to the typed bridge.

**Riscos declarados:**

- Unversioned gateway method names can drift independently from the typed Studio Bridge command surface.

## build.rojo.package

Status declarado: `PARTIAL` / `STATICALLY_VALIDATED`. Backlog: **ENV-02, ENV-03, FAC-03, AST-05**.

**Lacunas declaradas:**

- A reusable build adapter with tool-version pinning, caching and isolated concurrent workers is missing.

**Riscos declarados:**

- An external Rojo binary or project change during compilation can make a candidate inconclusive.

## edit.datamodel.inspect

Status declarado: `AVAILABLE` / `STATICALLY_VALIDATED`. Backlog: **CTL-04**.

**Limitações declaradas:**

- A watch is bounded at 500 changes, so a value that ticks every frame loses its earliest history.

**Riscos declarados:**

- GetFullName paths are not unique when siblings share names.

## edit.datamodel.mutate

Status declarado: `PARTIAL` / `STATICALLY_VALIDATED`. Backlog: **CTL-08, FAC-04**.

**Lacunas declaradas:**

- Mutation fencing and idempotency are not enforced inside the plugin executor for every operation.

**Riscos declarados:**

- Arbitrary edit execution can bypass reusable APIs and contaminate source-of-truth state.

## runtime.lifecycle.measure

Status declarado: `AVAILABLE` / `RUNTIME_VALIDATED`. Backlog: **CTL-02, QAT-05, QAT-07**.

**Riscos declarados:**

- Run mode does not revert generated instances and a second pass can measure a duplicated world.

O catálogo não declara lacuna/limitação para esta entrada. A disponibilidade e os limites reais ainda dependem das verificações previstas.

## runtime.world.measure

Status declarado: `AVAILABLE` / `RUNTIME_VALIDATED`. Backlog: **CTL-07, WRL-05, QAT-01**.

**Riscos declarados:**

- A failed navmesh control probe makes a NoPath result inconclusive rather than a level defect.

O catálogo não declara lacuna/limitação para esta entrada. A disponibilidade e os limites reais ainda dependem das verificações previstas.

## runtime.visual-quality.snapshot

Status declarado: `PARTIAL` / `STATICALLY_VALIDATED`. Backlog: **CTL-03, QAT-04, QAT-01**.

**Lacunas declaradas:**

- Install and restart the plugin, then measure a pinned exact-build runtime session to promote this capability beyond static validation.

**Riscos declarados:**

- Self-declared classification can hide untagged geometry unless eligibility is derived independently from the Workspace; ray budgets must fail as truncated rather than silently reducing coverage.

## player.actor.synthetic

Status declarado: `AVAILABLE` / `RUNTIME_VALIDATED`. Backlog: **QAT-02, WRL-01**.

**Riscos declarados:**

- A synthetic rig is not a Player and cannot prove client-only or Player-authorized behavior.

O catálogo não declara lacuna/limitação para esta entrada. A disponibilidade e os limites reais ainda dependem das verificações previstas.

## player.actor.real

Status declarado: `PARTIAL` / `E2E_VALIDATED`. Backlog: **CTL-05, CTL-06, QAT-03**.

**Lacunas declaradas:**

- Unattended, multi-player-equivalent client allocation is not available.

**Riscos declarados:**

- A foreground F5 can land in the wrong application unless HWND focus is proven immediately before input.

## client.observe

Status declarado: `AVAILABLE` / `RUNTIME_VALIDATED`. Backlog: **CTL-02, CTL-04, UIX-02**.

**Riscos declarados:**

- Server logs cannot reveal a LocalScript failure and image assignment does not prove that moderated content rendered.
- A client read answers for one player's machine. Two clients in the same session can disagree, and neither disagrees with the server in a way the server can see.

O catálogo não declara lacuna/limitação para esta entrada. A disponibilidade e os limites reais ainda dependem das verificações previstas.

## client.actions.supported

Status declarado: `PARTIAL` / `E2E_VALIDATED`. Backlog: **CTL-01, CTL-05, CTL-06**.

**Lacunas declaradas:**

- There is no generic player-equivalent pointer or touch UI input adapter.

**Riscos declarados:**

- Direct remote invocation can become a white-box shortcut if used before a black-box human-mode failure.

## client.gui.click

Status declarado: `UNSUPPORTED` / `NOT_VALIDATED`. Backlog: **CTL-01, CTL-05, CTL-06**.

**Lacunas declaradas:**

- Games must expose the same server-authoritative action seam used by the button; direct clicking is unavailable.

**Riscos declarados:**

- Pretending a click happened would produce false E2E evidence.

## capture.camera.control

Status declarado: `AVAILABLE` / `RUNTIME_VALIDATED`. Backlog: **CTL-03**.

**Riscos declarados:**

- A camera command can target a different session if reads are not pinned.

O catálogo não declara lacuna/limitação para esta entrada. A disponibilidade e os limites reais ainda dependem das verificações previstas.

## capture.viewport.evidence

Status declarado: `PARTIAL` / `VISUALLY_VALIDATED`. Backlog: **CTL-03, CTL-06, QAT-04**.

**Lacunas declaradas:**

- Device emulation, deterministic resolution matrix and release-run capture integration are incomplete.

**Riscos declarados:**

- Desktop-region capture records any overlapping foreground window unless identity and focus are checked around every frame.

## capture.visual.review

Status declarado: `PARTIAL` / `STATICALLY_VALIDATED`. Backlog: **QAT-04, FAC-07**.

**Lacunas declaradas:**

- Run a credentialed, representative and calibrated capture review before raising this capability above STATICALLY_VALIDATED/PARTIAL.

**Riscos declarados:**

- A vision model can misjudge severity or visible detail; model findings remain advisory until deterministic evidence corroborates them.

## assets.discovery.preview

Status declarado: `PARTIAL` / `STATICALLY_VALIDATED`. Backlog: **AST-01, AST-06, ENV-06**.

**Lacunas declaradas:**

- A live, cached, ranked search run with complete licensing receipts is still required.

**Riscos declarados:**

- Remote metadata can omit licensing facts or change after selection.

## assets.create.validate

Status declarado: `PARTIAL` / `STATICALLY_VALIDATED`. Backlog: **AST-02, AST-03, CHR-01**.

**Lacunas declaradas:**

- Professional generation and optimization adapters for every required asset kind are not connected.

**Riscos declarados:**

- Syntactically valid files can still be aesthetically poor, unrigged or too expensive at runtime.

## assets.integrate

Status declarado: `PARTIAL` / `RUNTIME_VALIDATED`. Backlog: **AST-07**.

**Lacunas declaradas:**

- Automatic source integration is still missing: an id that resolves is not an id that has been wired into a game, and nothing here does the wiring.

**Riscos declarados:**

- An approved asset ID can be bound to the wrong semantic target without runtime visual and audio proof.

## publish.roblox.assets

Status declarado: `PARTIAL` / `STATICALLY_VALIDATED`. Backlog: **AST-04, AST-07, ENV-06**.

**Lacunas declaradas:**

- A credentialed live upload, moderation and integration cycle has not been validated.

**Riscos declarados:**

- Credentials, creator permissions and moderation are external state and must never be inferred from a staged package.

## publish.experience.deploy

Status declarado: `GAP` / `NOT_VALIDATED`. Backlog: **REL-01, REL-03, REL-04, REL-06**.

**Lacunas declaradas:**

- Open Cloud place publication, universe/place targeting, rollout verification and rollback receipts are missing.

**Riscos declarados:**

- A local release candidate is not proof that the same bytes reached the intended Roblox universe and place.

## multiplayer.live.scenarios

Status declarado: `GAP` / `NOT_VALIDATED`. Backlog: **CTL-06, NET-03, QAT-08, OPS-06**.

**Lacunas declaradas:**

- Multi-client and multi-server allocation, synchronization, assertions and teardown are missing.

**Riscos declarados:**

- Single-player success cannot reveal cross-player state leaks, replication races or server authority defects.

## persistence.live.lifecycle

Status declarado: `GAP` / `NOT_VALIDATED`. Backlog: **DAT-01, DAT-02, DAT-03, DAT-04, DAT-06**.

**Lacunas declaradas:**

- DataStore test environments, fault injection, rejoin orchestration and immutable save receipts are missing.

**Riscos declarados:**

- Fixture-backed state can mask lost writes, duplicate grants, migration failures and rejoin defects.

## monetization.secure.purchase

Status declarado: `GAP` / `NOT_VALIDATED`. Backlog: **DAT-05, DAT-07**.

**Lacunas declaradas:**

- Product provisioning, sandbox purchase, receipt replay and grant reconciliation adapters are missing.

**Riscos declarados:**

- A client-visible price or simulated grant is not proof of a valid Roblox receipt.

## release.immutable.candidate

Status declarado: `PARTIAL` / `STATICALLY_VALIDATED`. Backlog: **REL-01, REL-02, QAT-01, QAT-08, REL-05**.

**Lacunas declaradas:**

- Product alignment needs live validation; capture, visual review, asset approval, persistence, multiplayer and monetization must all be integrated before industrial release.

**Riscos declarados:**

- A structurally sound gate remains incomplete when required producers are absent or not integrated.

## assets.author.publish

Status declarado: `AVAILABLE` / `RUNTIME_VALIDATED`. Backlog: **AST-04, ENV-06**.

**Limitações declaradas:**

- Requires the "CreateAssetAsync Luau API" beta enabled in Studio > File > Beta Features. The method is present on AssetService without it and refuses the call, so its presence cannot be used to detect the gate.
- Moderation is asynchronous and outside this pipeline: a published id is not an approved id, and asset 103055152891653 read back as Reviewing immediately after publishing.
- Rate limited to 30 uploads per minute.

**Riscos declarados:**

- Publishing is irreversible from this side: the asset exists on Roblox and enters moderation.
- Moderation latency is unbounded, so a published id is not an approved id.

## edit.datamodel.primitives

Status declarado: `PARTIAL` / `STATICALLY_VALIDATED`. Backlog: **CTL-08, QAT-07**.

**Lacunas declaradas:**

- No live Studio run has exercised these commands; they remain STATICALLY_VALIDATED until measured against a real DataModel.

**Riscos declarados:**

- Mutations are at-most-once: a timeout leaves the caller unable to distinguish applied from not applied without re-reading.

## runtime.telemetry.measure

Status declarado: `PARTIAL` / `STATICALLY_VALIDATED`. Backlog: **QAT-05, OPS-01**.

**Lacunas declaradas:**

- No live sampling run has been measured against a running place.

**Riscos declarados:**

- Sampling holds a command thread open for the requested window.

## runtime.world.primitives

Status declarado: `PARTIAL` / `STATICALLY_VALIDATED`. Backlog: **WRL-02, WRL-03, WRL-05**.

**Lacunas declaradas:**

- Not yet exercised against a live place.

**Riscos declarados:**

- world.terrain writes are destructive and snap to the 4-stud voxel grid.

## player.drive.complete

Status declarado: `PARTIAL` / `STATICALLY_VALIDATED`. Backlog: **CTL-05, QAT-03**.

**Lacunas declaradas:**

- Not yet exercised against a live place.

**Riscos declarados:**

- actor.activate fires the game's own handler; twice is two uses, so it is at-most-once.
- Teleporting deliberately skips the navigability proof that walking provides.

## assets.geometry.author

Status declarado: `AVAILABLE` / `RUNTIME_VALIDATED`. Backlog: **AST-03, AST-04, CHR-01, ENV-06**.

**Limitações declaradas:**

- Geometry must arrive as vertices and triangles. `CreateAssetAsync` takes an `EditableMesh`, not a model file, so importing a .glb or .fbx remains the Studio 3D Importer -- a person and a dialog.
- Requires the "CreateAssetAsync Luau API" beta, the same gate as image publishing.
- Moderation is asynchronous: a published id is not an approved id.

**Riscos declarados:**

- Blender is an external dependency; a missing install is a named blocker, not a silent no-op.

## client.ui.measure

Status declarado: `PARTIAL` / `STATICALLY_VALIDATED`. Backlog: **UIX-01, UIX-02, CTL-03, QAT-07**.

**Lacunas declaradas:**

- Not yet exercised against a live client session.

**Riscos declarados:**

- gui_text writes the Text property directly and can leave a form in a state no player could reach.

## capture.camera.deterministic

Status declarado: `PARTIAL` / `STATICALLY_VALIDATED`. Backlog: **CTL-03, QAT-04**.

**Lacunas declaradas:**

- No live capture-and-compare cycle has been measured against a running place.

**Riscos declarados:**

- Moving the camera changes what every later capture in the same session sees.
- A camera left Scriptable after a capture stays frozen for the player.

## runtime.session.shape

Status declarado: `PARTIAL` / `STATICALLY_VALIDATED`. Backlog: **CTL-06, GAM-01**.

**Lacunas declaradas:**

- Not yet exercised against a live session.

## assets.media.author

Status declarado: `PARTIAL` / `STATICALLY_VALIDATED`. Backlog: **AST-02, AST-04, CHR-02, CHR-03**.

**Lacunas declaradas:**

- No generated audio or animation has been uploaded, so the format assumption is unverified against the live API.

**Riscos declarados:**

- An externally authored .rbxmx is a candidate for upload, not a certainty: Roblox processes animations on import from Studio.

## quality.rules.invoke

Status declarado: `PARTIAL` / `STATICALLY_VALIDATED`. Backlog: **QAT-01, QAT-02, FAC-08**.

**Lacunas declaradas:**

- Requires a live Studio session; nothing here has been run against one.

## edit.code.author

Status declarado: `AVAILABLE` / `RUNTIME_VALIDATED`. Backlog: **CTL-09, FAC-08**.

**Limitações declaradas:**

- No source map from a runtime stack frame back to the repository file, so a traceback names the DataModel path rather than the file an agent wrote.

**Riscos declarados:**

- Reloading gives a module a new identity; anything already holding the old table keeps it, so a live session is not fully updated.
- Source written into the place is lost on a Rojo rebuild unless it is also saved to the repository.

## edit.transform.place

Status declarado: `AVAILABLE` / `RUNTIME_VALIDATED`. Backlog: **WRL-07, CTL-08**.

**Limitações declaradas:**

- No alignment to a named face of a rotated model, and no multi-part layout: one placement at a time.

**Riscos declarados:**

- Alignment uses axis-aligned bounding boxes, so a rotated part aligns by its box rather than by its face.

## assets.library.import

Status declarado: `BLOCKED` / `RUNTIME_VALIDATED`. Backlog: **AST-01, AST-06, ENV-06**.

**Lacunas declaradas:**

- InsertService:LoadAsset answers 'User is not authorized to access Asset.' for third-party models from a local unpublished place, measured against five separate free models. Search and verification work; the fetch does not.
- Open Cloud returns metadata and moderation state for any public asset but never the bytes: assetdelivery v1 and v2 and cloud/v2/assets all answer 401 to an API key, because model content is gated on a browser session rather than on a key.

**Limitações declaradas:**

- Edit context only, by design: LoadAsset hangs rather than fails in a running place.
- The remaining path is a human dragging from the Studio Toolbox panel and saving the result as .rbxm into a kit folder, which `forge kit harvest` already handles.

**Riscos declarados:**

- Toolbox results are largely keyword spam; a title says nothing about what is inside.
- An imported model carries another author's work and its provenance has to travel with it.
