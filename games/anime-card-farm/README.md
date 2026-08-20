# anime-card-farm

Colecao de cartas de anime numa fazenda: esteiras entregam cartas, abra pacotes, monte o album por raridade, melhore as esteiras e venda duplicatas.

**collection** / farm

    loop:        collect -> unlock -> upgrade
    topology:    hub_and_zones
    progression: unlock_graph, 8 tiers
    currencies:  cash
    systems:     inventory, progression, save, economy, analytics

Everything in this directory is derived from `game.json`. Change the game there
and recompile; editing `definition/` or `blueprint.json` by hand creates a
second description that can disagree with the first, which is the failure the
game model exists to prevent.

    rqe game validate  games/anime-card-farm/game.json
    rqe game compile   games/anime-card-farm/game.json
