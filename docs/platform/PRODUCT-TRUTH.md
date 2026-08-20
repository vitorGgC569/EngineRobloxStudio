# Product truth boundary

`rqe.product_truth` prevents a release run from judging one product with the
intent, semantics or visual thresholds of another.  It is engine
infrastructure, not a contract for a particular game.

## Trusted artifact chain

The chain has four static documents and one runtime receipt:

1. `ProductIntent` names the product, its product semantics and the exact
   hashes of the contract, visual spec, reference benchmark and calibration.
2. `ReferenceBenchmark` contains content-addressed snapshots and numeric
   observations from products independent of the candidate.
3. `VisualCalibrationReceipt` maps every visual acceptance, capture and score
   number to frozen benchmark observations, including derivation method and
   tool version.
4. The contract and visual spec carry the same `productId` and explicit
   semantic bindings to the intent.
5. `RuntimeProductIdentityReceipt` measures the product, contract and spec ids
   in Studio and binds them to the run, build, place and hashes above.

All paths are project-relative, root-bound and symlink-free.  All JSON inputs
reject duplicate keys and non-finite numbers.  Owned schemas cannot be
substituted through a document's `$schema` field.

## Generic semantic bindings

The intent declares three lists: `worldRoles`, `uiSurfaces` and
`gameplayVerbs`.  This makes product identity stronger than renaming a spec.

The contract must expose:

```json
{
  "productId": "product-id",
  "productTruth": {
    "intentId": "product-id.intent",
    "semanticBindings": {
      "worldRoles": {"production-floor": ["world_floor_exists"]},
      "uiSurfaces": {"collection-gallery": ["gallery_is_usable"]},
      "gameplayVerbs": {"collect-item": ["collect_item_e2e"]}
    }
  }
}
```

Every semantic id must be present exactly once as a binding and every bound
requirement id must exist in the contract.

The visual spec must expose:

```json
{
  "productId": "product-id",
  "productTruth": {
    "intentId": "product-id.intent",
    "calibrationId": "product-id.visual-calibration",
    "semanticBindings": {
      "worldRoles": {
        "production-floor": {
          "landmarkIds": ["production"],
          "regionSetIds": ["production-regions"],
          "viewpointIds": ["production"]
        }
      },
      "uiSurfaces": {
        "collection-gallery": {
          "landmarkIds": [],
          "regionSetIds": [],
          "viewpointIds": ["gallery-mobile"]
        }
      }
    }
  }
}
```

Unknown and empty references block.  A mining landmark cannot satisfy a
product intent that requires a card-production floor and collection gallery.

## API

`assess_product_truth(...)` returns `READY` with a complete bundle or
`BLOCKED` with coded issues.  It never returns a partially trusted bundle.
`load_product_truth(...)` is the raising variant.  Both require external
hashes for the intent and runtime receipt plus the expected run id, build id
and place hash from immutable run/build provenance.

`required_calibration_targets(contract, spec)` enumerates the v1 numeric
policy surface.  It covers contract visual-score floors and the spec's palette,
object cardinality/scale, region metrics, landmark sampling/visibility,
viewpoint resolution/camera/rubric and evaluation coverage.  New visual schema
versions block until they receive an explicit target registry.

Call `bundle.verify_unchanged()` immediately before consuming the bundle to
detect a time-of-check/time-of-use mutation.

## Honest current limits

- Product truth is now mandatory in `rqe release`: the build compiler embeds a
  hash-bound `RQEProductIdentity` Configuration, `product.identity` measures it
  from the running DataModel, and the release stores the runtime receipt plus
  this assessment. This path is `STATICALLY_VALIDATED`; the changed plugin has
  not yet been installed/restarted and exercised against a live stamped place.
- The active first-game contract and visual spec do not yet carry `productId`
  or semantic bindings, and `rqe.project.json` does not bind an approved intent,
  so the current candidate intentionally cannot pass this boundary.
- `candidateDerived: false` and the independence decision are accountable
  attestations, not cryptographic proof of authorship.  Content hashes prove
  what was frozen, not that the person who labelled a source was truthful.
  Signed approvals or an authenticated product-director control plane remain
  necessary for adversarial provenance.
- The module validates reference observations and threshold lineage; it does
  not extract measurements from screenshots.  A separate calibrated reference
  measurement tool must produce those observations.
- A semantic binding proves that the intended role is represented by a real
  contract requirement and visual target.  It does not prove that the probe is
  implemented, that a referenced script is enabled, or that the requirement is
  satisfiable.  The measurement-plan compiler must reject unmapped/dead probes,
  and runtime/E2E evidence must still pass them.
- A VLM finding is not made blocking here.  Corroboration and score/blocking
  policy belong to the release gate and require separate calibration.
