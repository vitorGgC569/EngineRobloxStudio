# siegehold

Tower defense medieval: ondas de inimigos, torres com upgrades, cristal a defender, partidas de 8 minutos.

**tower_defense** / tower defense medieval

    loop:        build -> defend -> upgrade
    topology:    single_arena
    progression: wave, 12 tiers
    currencies:  cash
    systems:     economy, progression, save, tower, analytics

Everything in this directory is derived from `game.json`. Change the game there
and recompile; editing `definition/` or `blueprint.json` by hand creates a
second description that can disagree with the first, which is the failure the
game model exists to prevent.

    rqe game validate  games/siegehold/game.json
    rqe game compile   games/siegehold/game.json
