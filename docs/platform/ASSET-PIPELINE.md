# Asset pipeline: discovery to integration

This vertical gives an agent a typed, evidence-preserving path for meshes,
audio, animations, and icon images. It is independent of the release gate and
does not mutate a place. Its output is an approved asset manifest plus an
integration bundle that another measured build step can apply.

The core rule is that upload, publication, moderation, permission, and
integration are different facts. An HTTP success from Create Asset proves only
that Roblox accepted an asynchronous operation. It never proves that the asset
exists, passed moderation, can load in the target experience, or was integrated.

## Official capability baseline (checked 2026-08-11)

Only official Roblox documentation was used for this baseline:

- [Assets API usage guide](https://create.roblox.com/docs/cloud/guides/usage-assets)
  documents the 20 MB upload ceiling, supported formats, `POST
  /assets/v1/assets`, asynchronous operation polling, API-key/OAuth scopes, and
  moderation results.
- [Creator Store Open Cloud surface](https://create.roblox.com/docs/cloud/reference/features/creator-store)
  documents the Beta `POST /toolbox-service/v2/assets:search` endpoint and asset
  details endpoint. Search does not prove acquisition or usage permission.
- [Thumbnails API](https://create.roblox.com/docs/cloud/reference/features/thumbnails)
  documents unauthenticated Stable asset thumbnails at `GET /v1/assets`.
- [Project assets](https://create.roblox.com/docs/projects/assets) explains that
  imported assets must pass moderation before users can use them and that asset
  IDs are integrated through `rbxassetid://...` content properties.
- [Asset privacy](https://create.roblox.com/docs/projects/assets/privacy)
  explains that Restricted assets also require creator/experience permission.
- [Creator Store distribution](https://create.roblox.com/docs/production/creator-store)
  documents ownership, distribution, legal, moderation, and seller requirements.

The HTTP serializer and response state machine are `STATICALLY_VALIDATED` by a
fake transport. No credentialed request was made, so live Open Cloud behaviour
is `NOT_VALIDATED`. A run must record real remote responses before promoting
that label.

## Capability matrix

| Capability | Adapter state | Honest boundary |
| --- | --- | --- |
| Local draft creation | `AVAILABLE` | Records inputs and provenance; makes no validity claim. |
| Local format validation | `AVAILABLE` | Deterministic checks only; semantic/visual quality is still separate. |
| Local catalog search/previews | `AVAILABLE` | Has no Roblox publication or moderation evidence. |
| Creator Store search | `AVAILABLE`, Beta | Result license is deliberately `verified=false`; acquisition and permissions remain blocked. |
| Roblox thumbnails | `AVAILABLE`, Stable | A typed `PreviewResult` exposes HTTP/empty-result blockers; a thumbnail is not approval or permission evidence. |
| Create Asset | `BLOCKED` without credential | Requires Assets read/write API-key permissions or OAuth `asset:read asset:write`, plus an explicit user/group creator. |
| Moderation refresh | `BLOCKED` without credential or approval | Pending/unspecified moderation returns `BLOCKED`; only explicit `MODERATION_STATE_APPROVED` yields `approved`. |
| Experience icon assignment | `UNAVAILABLE` in this adapter | Logical `icon` uploads image content as a Decal; assigning a universe icon needs a separate documented workflow. |
| Place integration | Plan only | The integration bundle is immutable input to a later build/playtest; generating it does not prove the place uses the asset. |

Custom FBX, glTF, GLB, RBXM, and RBXMX 3D content is sent as Roblox asset type
`Model`. The official API's raw `Mesh` upload accepts only Roblox-delivered mesh
data, so this pipeline never relabels arbitrary custom geometry as raw Mesh.

## State machine

```text
draft -> validated -> uploading -> published -> approved
   |         |           |            |
   +------> rejected <----+------------+
   +------> unavailable <-+------------+
```

- `draft`: a file and its creation provenance were recorded.
- `validated`: deterministic local checks passed and the payload hash was
  measured. Rights evidence is mandatory.
- `uploading`: Create Asset returned an operation path. This is not publication.
- `published`: a remote ID exists, but approval is pending or unspecified. The
  pipeline outcome remains `BLOCKED`.
- `approved`: an operation or metadata response explicitly returned Roblox
  approval.
- `rejected`: local content validation or a remote upload/moderation decision
  failed.
- `unavailable`: a provider cannot perform the requested capability.

`MODERATION_STATE_NOT_APPROVED`, `nil`, an unknown value, a truncated response,
HTTP 401/403, and missing credentials can never compare equal to approval.

## Vertical workflow

1. Create a `LocalDraftRequest` with a file, name, description, logical kind,
   license record, source URI, creation tool/prompt, and previews.
2. Run `LocalAssetValidator`. It measures the file hash and format limits. A
   property the standard library cannot inspect, such as non-WAV audio duration,
   must arrive as measured metadata plus a `measurementEvidence` reference;
   otherwise validation is `BLOCKED`.
3. Build a `PublicationPackage`. Its ID hashes content, metadata, creator,
   provider, rights record, and integration targets. Changing any of them creates
   a different package.
4. Call `PublicationCoordinator.publish`. It rechecks the source hash, stages an
   immutable content-addressed payload, then acquires a per-package exclusive
   claim. The claim and receipt prevent a normal retry from issuing a second
   Create Asset request.
5. Poll with `PublicationCoordinator.refresh`. Pending operations and moderation
   remain retryable blockers. The receipt is stored per package; there is no
   global `latest` file.
6. Put approved records and explicit symbolic targets in an asset manifest.
   `AssetManifestValidator` blocks every `production-required` asset that lacks
   approval, remote ID, moderation evidence, verified license, provenance,
   preview, or integration target.
7. Build an `IntegrationBundle`. It maps each approved record to an
   `rbxassetid://ID` URI. Apply it through a separate server-authoritative build
   step, then measure the resulting place; the bundle itself is not runtime
   evidence.

## Idempotence and crash behaviour

Packages and receipts live under caller-selected run/build directories. A
second publish of a receipted package returns the cached remote state without a
second POST. A hard crash after request dispatch can leave the exclusive claim
behind. That ambiguity intentionally blocks automatic replay; an operator or a
future reconciliation job must inspect the remote operation before removing the
claim. The pipeline prefers a visible blocker to a duplicate billable upload.

The `Idempotency-Key` request header is sent as a correlation hint, but the
local ledger is the enforced mechanism; Roblox's current Assets guide does not
document server-side idempotency semantics for Create Asset.

## Security and human boundaries

- Credentials are injected into `RobloxOpenCloudConfig`; they are excluded from
  dataclass representations and never written to packages or receipts.
- Rights are not inferred from a search result, prompt, filename, or creator
  name. Creator Store acquisition/permission and third-party licenses need
  explicit evidence.
- Upload quotas, ID verification, creator/group permissions, Restricted asset
  permissions, moderation, seller onboarding, and legal agreements are external
  gates. They are reported as `BLOCKED` or `UNAVAILABLE`, never as success.
- Visual fidelity, loop quality, animation retargeting, loudness, topology, and
  in-game fit need dedicated measurement/scenario evidence beyond this local
  technical validator.

## Files

- `rqe/assets/models.py`: lifecycle, evidence, capabilities, result types.
- `rqe/assets/providers/`: provider protocol, local provider, Open Cloud adapter.
- `rqe/assets/drafts.py` and `validation.py`: creation records and local checks.
- `rqe/assets/publication.py`: content-addressed packages, exclusive claims,
  receipts, retry-safe coordinator.
- `rqe/assets/manifest.py` and `integration.py`: production evidence gate and
  immutable integration plan.
- `schemas/asset-*.schema.json`: catalog, manifest, and publication contracts.
- `tests/test_assets.py`: fake-HTTP and deterministic local coverage.
