--!strict
local EconomyCatalog = {}

export type UpgradeDefinition = {
	id: string,
	name: string,
	category: "Fortification" | "Survival" | "Perk",
	maxLevel: number,
	baseCost: number,
	costMultiplier: number,
	effectPerLevel: number,
	unit: string,
	description: string,
}

EconomyCatalog.Upgrades = {
	barricade_durability = {
		id = "barricade_durability",
		name = "Reinforced Plating",
		category = "Fortification",
		maxLevel = 5,
		baseCost = 120,
		costMultiplier = 1.6,
		effectPerLevel = 25,
		unit = "%",
		description = "Adds steel rebar and thick timber to all constructed perimeter barriers.",
	},
	turret_auto = {
		id = "turret_auto",
		name = "Sentry Autoturret",
		category = "Fortification",
		maxLevel = 3,
		baseCost = 450,
		costMultiplier = 2.0,
		effectPerLevel = 1,
		unit = "Turret",
		description = "Deploys automated caliber turrets protecting safe zone choke points.",
	},
	health_regen = {
		id = "health_regen",
		name = "Stimulant Injectors",
		category = "Survival",
		maxLevel = 5,
		baseCost = 100,
		costMultiplier = 1.5,
		effectPerLevel = 2,
		unit = "HP/s",
		description = "Military micro-injectors that steadily regenerate survivor vitality in combat.",
	},
	max_stamina = {
		id = "max_stamina",
		name = "Adrenaline Conditioning",
		category = "Survival",
		maxLevel = 5,
		baseCost = 80,
		costMultiplier = 1.4,
		effectPerLevel = 20,
		unit = "Stamina",
		description = "Increases sprinting endurance and sprint recovery rate.",
	},
	scavenger_perk = {
		id = "scavenger_perk",
		name = "Resource Scavenger",
		category = "Perk",
		maxLevel = 5,
		baseCost = 150,
		costMultiplier = 1.7,
		effectPerLevel = 15,
		unit = "%",
		description = "Mastery in salvaging pristine weapon parts and electronics from fallen foes.",
	},
}

EconomyCatalog.Supplies = {
	ammo_box_pistol = { id = "ammo_box_pistol", name = "9mm Ammo Box (+36)", cost = 25, amount = 36, weaponCategory = "Pistol" },
	ammo_box_shotgun = { id = "ammo_box_shotgun", name = "12G Shell Pack (+24)", cost = 45, amount = 24, weaponCategory = "Shotgun" },
	ammo_box_rifle = { id = "ammo_box_rifle", name = "5.56 NATO Box (+90)", cost = 65, amount = 90, weaponCategory = "Rifle" },
	ammo_box_sniper = { id = "ammo_box_sniper", name = ".50 BMG Heavy Crate (+15)", cost = 110, amount = 15, weaponCategory = "Sniper" },
	medkit = { id = "medkit", name = "Tactical Trauma Kit (+75 HP)", cost = 60, healAmount = 75 },
	armor_vest = { id = "armor_vest", name = "Kevlar Vest (+50 Armor)", cost = 85, armorAmount = 50 },
}

EconomyCatalog.Prestige = {
	requirementWave = 20,
	baseBonusMultiplier = 1.25,
}

function EconomyCatalog.calculateUpgradeCost(upgradeId: string, currentLevel: number): number
	local def: UpgradeDefinition? = EconomyCatalog.Upgrades[upgradeId]
	if not def then return 999999 end
	if currentLevel >= def.maxLevel then return 0 end
	local mult: number = def.costMultiplier
	local base: number = def.baseCost
	return math.floor(base * (mult ^ currentLevel))
end

return EconomyCatalog
