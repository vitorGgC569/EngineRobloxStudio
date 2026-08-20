# nightfall

Horror de sobrevivencia noturno em floresta com lanternas e criaturas.

**survival** / forest

    loop:        explore -> collect -> craft -> survive
    topology:    open_world
    progression: checkpoint, 8 tiers
    currencies:  none
    systems:     inventory, crafting, save, progression, analytics

Everything in this directory is derived from `game.json`. Change the game there
and recompile; editing `definition/` or `blueprint.json` by hand creates a
second description that can disagree with the first, which is the failure the
game model exists to prevent.

    rqe game validate  games/nightfall/game.json
    rqe game compile   games/nightfall/game.json
