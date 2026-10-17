# producer-probe

Quero um simulator de criaturas inspirado em recifes e cavernas, publico 9-15 anos, mobile-first, com loja e sessoes de 12 minutos.

**simulator** / reef cave

    loop:        collect -> sell -> upgrade -> unlock -> buy
    topology:    hub_and_zones
    progression: tiered, 8 tiers
    currencies:  cash
    systems:     economy, progression, save, inventory, analytics, shop

Everything in this directory is derived from `game.json`. Change the game there
and recompile; editing `definition/` or `blueprint.json` by hand creates a
second description that can disagree with the first, which is the failure the
game model exists to prevent.

    rqe game validate  games/producer-probe/game.json
    rqe game compile   games/producer-probe/game.json
    python rqe.py release games/producer-probe --static-only

The release command is expected to remain blocked until a human-approved
ProductIntent, an independent reference benchmark, its complete calibration,
approved production assets and product-specific E2E scenarios replace the
typed placeholders. A scaffold is an operational release project, not release
evidence.
