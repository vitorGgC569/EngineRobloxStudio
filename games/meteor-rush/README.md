# Meteor Rush

A compact, data-driven Roblox collection game built on Forge.

## Core loop

1. A meteor lands in the shared crater.
2. First player to reach it captures the core.
3. Carry the core back to your Decoder.
4. Decode a collectible space specimen.
5. Specimens generate Stardust every second and while you are offline.
6. Spend Stardust on movement, vault capacity and meteor magnet upgrades.
7. Every 90 seconds a meteor shower creates a short server-wide race.

The game deliberately has one map, six bases and one core loop. New content is rows
in `Content.lua`, not new systems.

## Engine systems used

- Forge.Save
- Forge.Net
- Forge.Core.Rng
- Forge.Loop.Hatch
- Forge.Telemetry
- Forge.Monetization
- Forge.UI / Feel

Monetization IDs are zero until the experience is published, so no purchase prompt
can accidentally target another product.
