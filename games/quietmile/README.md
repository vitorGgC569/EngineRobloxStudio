# quietmile

Caminhada por uma vila abandonada: encontre cartas, reconstrua a historia, abra o portao final.

**collection** / caminhada vila abandonada

    loop:        collect -> unlock -> upgrade
    topology:    hub_and_zones
    progression: unlock_graph, 8 tiers
    currencies:  cash
    systems:     inventory, progression, save, economy, analytics

Everything in this directory is derived from `game.json`. Change the game there
and recompile; editing `definition/` or `blueprint.json` by hand creates a
second description that can disagree with the first, which is the failure the
game model exists to prevent.

    rqe game validate  games/quietmile/game.json
    rqe game compile   games/quietmile/game.json
