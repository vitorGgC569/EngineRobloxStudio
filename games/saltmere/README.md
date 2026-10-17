# Saltmere

A tidal saltworks tycoon built on Forge.

The tide fills your pans, a harvest window lets you rake them, and what you leave behind spoils. Coarse salt refines into fine and smoked salt. The quay pays less the more of one grade you dump in a single tide. Crew rakes, grades and watches the spoil. The spring tide keeps the lighthouse and resets the marsh.

## Rodar

```bash
python forge/forge.py doctor saltmere
python forge/forge.py build saltmere
```

Open `saltmere.rbxlx` in Studio and press Play. Each player gets a plot on the quay.

The tide runs flood, settle, harvest, spoil. Rake a pan while it is ready, or let a hired raker take it at the start of spoil. Refine coarse into fine at the grader's bench, and fine into smoked at the smokehouse. Selling the same grade over and over in one tide pays less. The spring tide, from the lighthouse or the HUD, keeps the light and clears the marsh.

```bash
python forge/forge.py doctor saltmere
python forge/forge.py build saltmere
```

`rojo serve games/saltmere/default.project.json` syncs the place while Studio is open.

Rules live in `src/shared/Sim.lua`. Numbers live in `src/shared/Config.lua`. The design contract is `DESIGN.md`. The model in `game.json` is a coherent tycoon: collect, process, sell, upgrade, unlock, buy, prestige.
