# tidepool

Simulator de coleta de criaturas em recifes e cavernas submarinas, com loja, ranking e sessoes de 12 minutos.

**simulator** / reef cave

    loop:        collect -> sell -> upgrade -> unlock -> buy
    topology:    hub_and_zones
    progression: tiered, 8 tiers
    currencies:  cash
    systems:     economy, progression, save, inventory, analytics, shop, leaderboard

Everything in this directory is derived from `game.json`. Change the game there
and recompile; editing `definition/` or `blueprint.json` by hand creates a
second description that can disagree with the first, which is the failure the
game model exists to prevent.

    rqe game validate  games/tidepool/game.json
    rqe game compile   games/tidepool/game.json
