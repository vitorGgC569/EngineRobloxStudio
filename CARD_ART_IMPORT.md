# Card art import gate

The generated card art is stored locally and approved in `assets/asset-manifest.json`. Roblox UI image properties require a published Roblox asset ID, so the game intentionally keeps `runtimeAssetId = nil` until Studio import/upload is complete. This prevents broken `rbxasset://` references from reaching players.

| Card | Local preview | Runtime field |
|---|---|---|
| Copper Lynx Prospector | `assets/generated/cards/copper-lynx-prospector-v1.png` | `CardCatalog.Cards.copper_lynx_prospector.runtimeAssetId` |
| Mossback Badger Engineer | `assets/generated/cards/mossback-badger-engineer-v1.png` | `CardCatalog.Cards.mossback_badger_engineer.runtimeAssetId` |
| Storm Raven Surveyor | `assets/generated/cards/storm-raven-surveyor-v1.png` | `CardCatalog.Cards.storm_raven_surveyor.runtimeAssetId` |
| Gallery panel | `assets/generated/ui/card-gallery-panel-v1.png` | `CardGallery.BackgroundArt` |

After importing and moderating each image in Studio, set the corresponding numeric ID. The UI keeps a rarity-colored procedural fallback until the ID is present, and the continuous quality loop records the asset state.
