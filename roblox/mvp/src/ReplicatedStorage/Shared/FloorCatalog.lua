local FloorCatalog = {
	[1] = {level = 1, name = "Groundworks", price = 0, incomeMultiplier = 1.0, cardSlots = 1, color = Color3.fromRGB(55, 196, 181)},
	[2] = {level = 2, name = "Copperline Gallery", price = 250, incomeMultiplier = 1.08, cardSlots = 2, color = Color3.fromRGB(242, 193, 83)},
	[3] = {level = 3, name = "Deep Lantern Deck", price = 750, incomeMultiplier = 1.18, cardSlots = 3, color = Color3.fromRGB(211, 121, 58)},
	[4] = {level = 4, name = "Stormglass Loft", price = 1800, incomeMultiplier = 1.32, cardSlots = 4, color = Color3.fromRGB(184, 107, 255)},
	[5] = {level = 5, name = "Crown Vein Observatory", price = 4200, incomeMultiplier = 1.5, cardSlots = 5, color = Color3.fromRGB(255, 113, 105)},
}

function FloorCatalog.get(level)
	return FloorCatalog[level]
end

function FloorCatalog.next(level)
	return FloorCatalog[(level or 1) + 1]
end

return FloorCatalog
