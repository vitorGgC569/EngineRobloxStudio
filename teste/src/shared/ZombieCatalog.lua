--!strict
local ZombieCatalog = {}

export type ZombieDefinition = {
	id: string,
	name: string,
	type: "Swarm" | "Agile" | "Ranged" | "Tank" | "Boss",
	maxHealth: number,
	walkSpeed: number,
	damage: number,
	attackRate: number, -- attacks per second
	attackRange: number, -- studs
	detectionRadius: number, -- studs
	scrapReward: number,
	xpReward: number,
	bodyScale: { height: number, width: number, depth: number },
	primaryColor: Color3,
	eyeGlowColor: Color3,
	description: string,
}

ZombieCatalog.Zombies = {
	walker = {
		id = "walker",
		name = "Decayed Shambler",
		type = "Swarm",
		maxHealth = 65,
		walkSpeed = 11,
		damage = 14,
		attackRate = 1.0,
		attackRange = 4.5,
		detectionRadius = 75,
		scrapReward = 8,
		xpReward = 15,
		bodyScale = { height = 1.0, width = 1.0, depth = 1.0 },
		primaryColor = Color3.fromRGB(75, 88, 70),
		eyeGlowColor = Color3.fromRGB(240, 200, 50),
		description = "Standard reanimated corpse. Vulnerable alone, lethal in dense corridors.",
	},
	runner = {
		id = "runner",
		name = "Feral Sprinter",
		type = "Agile",
		maxHealth = 45,
		walkSpeed = 22,
		damage = 18,
		attackRate = 1.6,
		attackRange = 4.0,
		detectionRadius = 120,
		scrapReward = 14,
		xpReward = 25,
		bodyScale = { height = 0.95, width = 0.85, depth = 0.85 },
		primaryColor = Color3.fromRGB(95, 60, 55),
		eyeGlowColor = Color3.fromRGB(255, 60, 30),
		description = "Hyper-aggressive mutated infected that sprints relentlessly towards gunfire sounds.",
	},
	spitter = {
		id = "spitter",
		name = "Bile Spitter",
		type = "Ranged",
		maxHealth = 85,
		walkSpeed = 10,
		damage = 22,
		attackRate = 0.6,
		attackRange = 60.0,
		detectionRadius = 90,
		scrapReward = 20,
		xpReward = 35,
		bodyScale = { height = 1.1, width = 1.15, depth = 1.1 },
		primaryColor = Color3.fromRGB(50, 85, 45),
		eyeGlowColor = Color3.fromRGB(80, 255, 60),
		description = "Distended infected firing corrosive caustic bile globes from medium distance.",
	},
	brute = {
		id = "brute",
		name = "Armored Crusher",
		type = "Tank",
		maxHealth = 380,
		walkSpeed = 8,
		damage = 45,
		attackRate = 0.7,
		attackRange = 6.0,
		detectionRadius = 60,
		scrapReward = 65,
		xpReward = 110,
		bodyScale = { height = 1.45, width = 1.5, depth = 1.4 },
		primaryColor = Color3.fromRGB(45, 48, 55),
		eyeGlowColor = Color3.fromRGB(255, 120, 20),
		description = "Massive armored mutation capable of tearing down reinforced barricades effortlessly.",
	},
	nightmare_boss = {
		id = "nightmare_boss",
		name = "Goliath Overlord",
		type = "Boss",
		maxHealth = 1800,
		walkSpeed = 12,
		damage = 70,
		attackRate = 0.9,
		attackRange = 8.5,
		detectionRadius = 250,
		scrapReward = 350,
		xpReward = 600,
		bodyScale = { height = 2.1, width = 2.2, depth = 2.0 },
		primaryColor = Color3.fromRGB(30, 20, 35),
		eyeGlowColor = Color3.fromRGB(255, 30, 80),
		description = "Apex biological calamity emitting a terrifying roar that summons swarms of sprinters.",
	},
}

function ZombieCatalog.get(id: string): ZombieDefinition?
	return ZombieCatalog.Zombies[id]
end

function ZombieCatalog.getAll(): { [string]: ZombieDefinition }
	return ZombieCatalog.Zombies
end

return ZombieCatalog
