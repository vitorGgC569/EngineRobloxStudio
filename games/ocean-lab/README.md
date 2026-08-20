# ocean-lab

A submarine lab tycoon: explore reefs, collect specimens, automate research.

**tycoon** / underwater research lab

    loop:        explore -> collect -> process -> upgrade -> unlock
    topology:    hub_and_zones
    progression: tiered, 8 tiers
    currencies:  credits, research
    systems:     economy, progression, save, inventory, analytics

Everything in this directory is derived from `game.json`. Change the game there
and recompile; editing `definition/` or `blueprint.json` by hand creates a
second description that can disagree with the first, which is the failure the
game model exists to prevent.

    rqe game validate  games/ocean-lab/game.json
    rqe game compile   games/ocean-lab/game.json
