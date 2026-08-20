# last-vigil

Tower defense de terror 3D The Last Vigil nas ruinas de uma abadia durante a noite. Recolha brasas do relicario, acenda e melhore lanternas de protecao, defenda o sino contra ondas de peregrinos sem rosto e sobreviva ate o amanhecer em uma sessao de 10 minutos.

**tower_defense** / faceless pilgrims

    loop:        build -> defend -> upgrade
    topology:    single_arena
    progression: wave, 12 tiers
    currencies:  cash
    systems:     economy, progression, save, tower, analytics

Everything in this directory is derived from `game.json`. Change the game there
and recompile; editing `definition/` or `blueprint.json` by hand creates a
second description that can disagree with the first, which is the failure the
game model exists to prevent.

    rqe game validate  games/last-vigil/game.json
    rqe game compile   games/last-vigil/game.json
    python rqe.py release games/last-vigil --static-only

The release command is expected to remain blocked until a human-approved
ProductIntent, an independent reference benchmark, its complete calibration,
approved production assets and product-specific E2E scenarios replace the
typed placeholders. A scaffold is an operational release project, not release
evidence.
