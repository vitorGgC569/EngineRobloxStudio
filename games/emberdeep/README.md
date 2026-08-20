# emberdeep

Dungeon crawler em ruinas vulcanicas: explore salas, derrote guardioes, colete relicas, melhore armas na forja.

**roguelite** / ruins

    loop:        explore -> fight -> collect -> unlock
    topology:    linear_levels
    progression: checkpoint, 8 tiers
    currencies:  none
    systems:     progression, save, inventory, analytics

Everything in this directory is derived from `game.json`. Change the game there
and recompile; editing `definition/` or `blueprint.json` by hand creates a
second description that can disagree with the first, which is the failure the
game model exists to prevent.

    rqe game validate  games/emberdeep/game.json
    rqe game compile   games/emberdeep/game.json
