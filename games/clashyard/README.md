# clashyard

Arena PvP de curta duracao: escolha um campeao, lute em partidas de tres minutos, suba de rank.

**tycoon** / arena

    loop:        collect -> process -> upgrade -> sell -> unlock
    topology:    grid_plots
    progression: tiered, 8 tiers
    currencies:  cash
    systems:     economy, progression, save, inventory, analytics

Everything in this directory is derived from `game.json`. Change the game there
and recompile; editing `definition/` or `blueprint.json` by hand creates a
second description that can disagree with the first, which is the failure the
game model exists to prevent.

    rqe game validate  games/clashyard/game.json
    rqe game compile   games/clashyard/game.json
