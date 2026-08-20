--!strict
local NetworkProtocol = {}

NetworkProtocol.Events = {
	-- Combat & Weapons
	FIRE_WEAPON = "FireWeapon",
	RELOAD_WEAPON = "ReloadWeapon",
	EQUIP_WEAPON = "EquipWeapon",
	EQUIP_SKIN = "EquipSkin",
	BULLET_TRACER = "BulletTracer",
	DAMAGE_INDICATOR = "DamageIndicator",
	ZOMBIE_HIT = "ZombieHit",

	-- Horde & Waves
	WAVE_STATE_CHANGED = "WaveStateChanged",
	ZOMBIE_SPAWNED = "ZombieSpawned",
	ZOMBIE_DIED = "ZombieDied",

	-- Economy & Safezone Shop
	BUY_WEAPON = "BuyWeapon",
	BUY_SKIN = "BuySkin",
	BUY_SUPPLY = "BuySupply",
	PURCHASE_UPGRADE = "PurchaseUpgrade",
	SYNC_PLAYER_DATA = "SyncPlayerData",

	-- Base Defense
	BUILD_BARRICADE = "BuildBarricade",
	REPAIR_BARRICADE = "RepairBarricade",
	BARRICADE_DAMAGED = "BarricadeDamaged",

	-- Leaderboards & Notifications
	ANNOUNCE_EVENT = "AnnounceEvent",
}

return NetworkProtocol
