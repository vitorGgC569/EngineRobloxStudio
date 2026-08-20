# driftline

Corrida de rua com upgrades: ganhe dinheiro em provas, melhore o carro e desbloqueie novos circuitos.

**racing** / corrida upgrades ganhe

    loop:        race -> unlock -> upgrade
    topology:    linear_levels
    progression: tiered, 8 tiers
    currencies:  cash
    systems:     progression, save, economy, analytics

Everything in this directory is derived from `game.json`. Change the game there
and recompile; editing `definition/` or `blueprint.json` by hand creates a
second description that can disagree with the first, which is the failure the
game model exists to prevent.

    rqe game validate  games/driftline/game.json
    rqe game compile   games/driftline/game.json
