local Pages = require(script.Pages)

local Currency = {}

Currency.Bocchi = {
	LayoutOrder = 1,
	Color = Color3.fromRGB(255, 170, 255),
	Image = 18238179475,
	Page = Pages.Main
}

Currency.Nijika = {
	LayoutOrder = 2,
	Color = Color3.fromRGB(255, 255, 127),
	Image = 15401117874,
	Page = Pages.Main
}

Currency.Guitars = {
	LayoutOrder = 4,
	Color = Color3.fromRGB(255, 170, 0),
	Image = 16990987829,
	Page = Pages.Misc
}

Currency.Drums = {
	LayoutOrder = 5,
	Color = Color3.fromRGB(255, 170, 127),
	Image = 115113133784242,
	Page = Pages.Misc
}

export type Currency = "Bocchi" | "Nijika" | "Guitars" | "Drums"

return Currency
