--!strict
local WeaponCatalog = {}

export type WeaponDefinition = {
	id: string,
	name: string,
	category: "Melee" | "Pistol" | "Rifle" | "Shotgun" | "Sniper" | "Heavy",
	damage: number,
	headshotMultiplier: number,
	fireRate: number, -- rounds per second
	magazineSize: number,
	reloadTime: number, -- seconds
	range: number, -- studs
	spread: number, -- degrees
	recoil: { vertical: number, horizontal: number },
	price: number,
	unlockedByDefault: boolean,
	description: string,
}

WeaponCatalog.Weapons = {
	combat_knife = {
		id = "combat_knife",
		name = "Tactical Trench Knife",
		category = "Melee",
		damage = 45,
		headshotMultiplier = 2.0,
		fireRate = 2.2,
		magazineSize = 0,
		reloadTime = 0,
		range = 7,
		spread = 0,
		recoil = { vertical = 0, horizontal = 0 },
		price = 0,
		unlockedByDefault = true,
		description = "Standard issue tactical serrated combat knife. Silent and deadly up close.",
	},
	service_pistol = {
		id = "service_pistol",
		name = "Outpost P9 Service Pistol",
		category = "Pistol",
		damage = 26,
		headshotMultiplier = 2.2,
		fireRate = 4.0,
		magazineSize = 12,
		reloadTime = 1.4,
		range = 150,
		spread = 0.8,
		recoil = { vertical = 1.2, horizontal = 0.3 },
		price = 0,
		unlockedByDefault = true,
		description = "Reliable 9mm semi-automatic sidearm with high ergonomics and quick reload.",
	},
	tactical_shotgun = {
		id = "tactical_shotgun",
		name = "Enforcer 12G Pump Shotgun",
		category = "Shotgun",
		damage = 18,
		headshotMultiplier = 1.5,
		fireRate = 1.1,
		magazineSize = 8,
		reloadTime = 2.6,
		range = 75,
		spread = 4.5,
		recoil = { vertical = 4.0, horizontal = 1.0 },
		price = 350,
		unlockedByDefault = false,
		description = "Heavy pump-action 12-gauge shotgun devastating against clustered infected hordes.",
	},
	assault_rifle = {
		id = "assault_rifle",
		name = "Vanguard AR-556 Assault Rifle",
		category = "Rifle",
		damage = 32,
		headshotMultiplier = 2.0,
		fireRate = 9.5,
		magazineSize = 30,
		reloadTime = 2.0,
		range = 280,
		spread = 1.4,
		recoil = { vertical = 1.8, horizontal = 0.6 },
		price = 750,
		unlockedByDefault = false,
		description = "Standard gas-operated assault rifle balancing continuous firepower and precision.",
	},
	marksman_sniper = {
		id = "marksman_sniper",
		name = "Apex .50 Anti-Materiel Rifle",
		category = "Sniper",
		damage = 185,
		headshotMultiplier = 3.0,
		fireRate = 0.7,
		magazineSize = 5,
		reloadTime = 3.2,
		range = 600,
		spread = 0.1,
		recoil = { vertical = 6.5, horizontal = 0.5 },
		price = 1500,
		unlockedByDefault = false,
		description = "Heavy bolt-action precision rifle capable of neutralizing brute infected with a single cranial shot.",
	},
	plasma_minigun = {
		id = "plasma_minigun",
		name = "Havoc Rotary Pulse Minigun",
		category = "Heavy",
		damage = 24,
		headshotMultiplier = 1.7,
		fireRate = 18.0,
		magazineSize = 150,
		reloadTime = 4.5,
		range = 200,
		spread = 3.2,
		recoil = { vertical = 1.5, horizontal = 1.2 },
		price = 3200,
		unlockedByDefault = false,
		description = "Experimental high-energy rotary weapon delivering catastrophic suppression.",
	},
}

function WeaponCatalog.get(id: string): WeaponDefinition?
	return WeaponCatalog.Weapons[id]
end

function WeaponCatalog.getAll(): { [string]: WeaponDefinition }
	return WeaponCatalog.Weapons
end

return WeaponCatalog
