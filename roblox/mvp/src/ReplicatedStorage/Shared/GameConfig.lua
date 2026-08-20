local GameConfig = {
	GameName = "Miner's Ridge Tycoon",
	MaxPlayers = 8,
	StartingCurrency = 1000,
	BasicPackPrice = 100,
	BasicPackId = "basic_mining_pack",
	StarterCardId = "field_lantern",
	MaxFloor = 5,
	-- One plot per player slot: a server that seats 8 and builds 4 turns half
	-- its players away at the door.
	PlotNames = { "PlotA", "PlotB", "PlotC", "PlotD", "PlotE", "PlotF", "PlotG", "PlotH" },

	-- World scale. The first build used 38x36 plots inside a 171x170 map, which
	-- reads as a diorama rather than a place. These are the numbers a tycoon
	-- needs for a plot to hold a growing build without the camera fighting it.
	World = {
		-- A tycoon plot has to hold a belt, a growing tower and room to walk
		-- round both. 118 was still cramped once the conveyor went in.
		plotSize = 172,
		plotGap = 38,
		centreAisle = 90,
		gridOrigin = Vector3.new(0, 0, -430),
		groundPadding = 200,
		--- Each purchased floor stacks this high on the plot tower.
		floorHeight = 22,
	},
}

return GameConfig
