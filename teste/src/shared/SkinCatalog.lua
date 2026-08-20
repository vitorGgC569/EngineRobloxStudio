--!strict
local SkinCatalog = {}

export type SkinDefinition = {
	id: string,
	name: string,
	rarity: "Standard" | "Tactical" | "Rare" | "Epic" | "Legendary" | "Mythic",
	primaryColor: Color3,
	secondaryColor: Color3,
	accentColor: Color3,
	material: Enum.Material,
	emissive: boolean,
	neonColor: Color3?,
	particleStyle: string?,
	price: number,
	description: string,
}

SkinCatalog.Rarities = {
	Standard = { order = 1, color = Color3.fromRGB(180, 185, 190), label = "STANDARD" },
	Tactical = { order = 2, color = Color3.fromRGB(110, 160, 110), label = "TACTICAL" },
	Rare = { order = 3, color = Color3.fromRGB(80, 170, 255), label = "RARE" },
	Epic = { order = 4, color = Color3.fromRGB(190, 95, 255), label = "EPIC" },
	Legendary = { order = 5, color = Color3.fromRGB(255, 200, 60), label = "LEGENDARY" },
	Mythic = { order = 6, color = Color3.fromRGB(255, 65, 80), label = "MYTHIC" },
}

SkinCatalog.Skins = {
	default_factory = {
		id = "default_factory",
		name = "Factory Issue",
		rarity = "Standard",
		primaryColor = Color3.fromRGB(45, 48, 52),
		secondaryColor = Color3.fromRGB(25, 26, 28),
		accentColor = Color3.fromRGB(90, 95, 100),
		material = Enum.Material.Metal,
		emissive = false,
		price = 0,
		description = "Standard-issue gunmetal matte finish with stamped serial numbers.",
	},
	urban_camo = {
		id = "urban_camo",
		name = "Urban Phantom Camo",
		rarity = "Tactical",
		primaryColor = Color3.fromRGB(95, 105, 115),
		secondaryColor = Color3.fromRGB(40, 45, 50),
		accentColor = Color3.fromRGB(170, 180, 190),
		material = Enum.Material.Fabric,
		emissive = false,
		price = 150,
		description = "Disruptive geometric camouflage optimized for decayed metropolitan concrete environments.",
	},
	desert_hazard = {
		id = "desert_hazard",
		name = "Wasteland Hazard",
		rarity = "Rare",
		primaryColor = Color3.fromRGB(195, 150, 85),
		secondaryColor = Color3.fromRGB(50, 45, 40),
		accentColor = Color3.fromRGB(230, 180, 40),
		material = Enum.Material.RustyMetal,
		emissive = false,
		price = 350,
		description = "Desert-scorched yellow ceramic plating with industrial warning chevrons.",
	},
	cyber_neon = {
		id = "cyber_neon",
		name = "Cyberpunk Overdrive",
		rarity = "Epic",
		primaryColor = Color3.fromRGB(20, 22, 35),
		secondaryColor = Color3.fromRGB(15, 15, 20),
		accentColor = Color3.fromRGB(0, 240, 255),
		material = Enum.Material.SmoothPlastic,
		emissive = true,
		neonColor = Color3.fromRGB(0, 255, 240),
		particleStyle = "cyan_pulse",
		price = 800,
		description = "Anodized obsidian body laced with glowing cyan fiber-optic power conduits.",
	},
	crimson_dragon = {
		id = "crimson_dragon",
		name = "Blood Wyrm Crimson",
		rarity = "Legendary",
		primaryColor = Color3.fromRGB(140, 20, 30),
		secondaryColor = Color3.fromRGB(215, 170, 50),
		accentColor = Color3.fromRGB(255, 60, 40),
		material = Enum.Material.Foil,
		emissive = true,
		neonColor = Color3.fromRGB(255, 75, 40),
		particleStyle = "ember_trail",
		price = 1800,
		description = "Forged in dragon-fire with gilded brass accents and pulsing heat veins.",
	},
	void_singularity = {
		id = "void_singularity",
		name = "Dark Matter Singularity",
		rarity = "Mythic",
		primaryColor = Color3.fromRGB(10, 8, 18),
		secondaryColor = Color3.fromRGB(90, 20, 160),
		accentColor = Color3.fromRGB(210, 100, 255),
		material = Enum.Material.Glass,
		emissive = true,
		neonColor = Color3.fromRGB(200, 80, 255),
		particleStyle = "void_sparks",
		price = 3500,
		description = "Crafted from extracted anomalous rift glass with swirling cosmic purple aura.",
	},
}

function SkinCatalog.get(id: string): SkinDefinition?
	return SkinCatalog.Skins[id]
end

function SkinCatalog.getAll(): { [string]: SkinDefinition }
	return SkinCatalog.Skins
end

return SkinCatalog
