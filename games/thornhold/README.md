# thornhold

Defesa de castelo com heroi jogavel: comande torres e lute pessoalmente contra as hordas.

**tower_defense** / defesa castelo heroi

    loop:        build -> defend -> upgrade
    topology:    single_arena
    progression: wave, 12 tiers
    currencies:  cash
    systems:     economy, progression, save, tower, analytics

Everything in this directory is derived from `game.json`. Change the game there
and recompile; editing `definition/` or `blueprint.json` by hand creates a
second description that can disagree with the first, which is the failure the
game model exists to prevent.

    rqe game validate  games/thornhold/game.json
    rqe game compile   games/thornhold/game.json
