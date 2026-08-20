# veilmarket

Mercado de uma cidade portuaria: compre barato, revenda caro, negocie com mercadores e abra sua loja.

**tycoon** / city market

    loop:        collect -> process -> upgrade -> sell -> unlock -> buy
    topology:    grid_plots
    progression: tiered, 8 tiers
    currencies:  cash
    systems:     economy, progression, save, inventory, analytics, shop

Everything in this directory is derived from `game.json`. Change the game there
and recompile; editing `definition/` or `blueprint.json` by hand creates a
second description that can disagree with the first, which is the failure the
game model exists to prevent.

    rqe game validate  games/veilmarket/game.json
    rqe game compile   games/veilmarket/game.json
