--!strict
--[[
	Arsenal — the guns, and what makes one different from another.

	Written against real classes rather than invented ones. A player who has
	fired a rifle in any other shooter should be able to pick this one up and
	already know roughly what it does: the marksman rifle hits hard and slowly,
	the SMG is fast and vague, the shotgun is a decision you make at eight
	metres and regret at thirty.

	What is realism here and what is not
	------------------------------------

	**Kept:** damage falls off with distance, bullets take time to arrive and
	drop on the way, magazines are the size they are, aiming down sights costs
	movement speed, recoil climbs and has to be pulled down, and a hit to the
	head is worth several to the chest.

	**Dropped:** ammunition types, cleaning, jamming, stance-specific reload
	timings. Every one of those is realistic and none of them is a decision a
	player makes twice. Simulation is not the goal; *weight* is -- the sense
	that the thing in your hands has mass and consequences.

	Numbers are in Roblox studs and seconds
	---------------------------------------

	A stud is about a foot, so a 300-stud effective range is roughly ninety
	metres. `Forge.Weapon` reads `rpm`, `magazine`, `range`, `pellets` and
	`auto` directly; everything else here is read by `Fight`.
]]

local Arsenal = {}

export type Class = "sidearm" | "smg" | "rifle" | "shotgun" | "marksman" | "sniper"

export type Gun = {
	id: string,
	name: string,
	class: Class,
	--: Passed straight to `Forge.Weapon.define`.
	damage: number,
	rpm: number,
	magazine: number,
	reserve: number,
	pellets: number,
	range: number,
	auto: boolean,
	reload: number,

	--: Read by `Fight`.
	muzzle: number,       -- studs per second; decides lead and drop
	falloffStart: number, -- full damage out to here
	falloffEnd: number,   -- minimum damage beyond here
	falloffFloor: number, -- fraction of damage retained at falloffEnd
	spread: number,       -- degrees of cone, hip-fired and still
	adsSpread: number,    -- degrees when aiming down sights
	recoilUp: number,     -- degrees of climb per shot
	recoilSide: number,   -- degrees of horizontal wander per shot
	adsSpeed: number,     -- seconds to raise the sights
	adsZoom: number,      -- field-of-view multiplier when aimed
	scope: boolean,       -- draws a scope overlay rather than iron sights
	moveScale: number,    -- how much of your walk speed you keep while aimed
	penetration: number,  -- how many bodies one round passes through
}

--[[
	Six guns, and they occupy different corners on purpose.

	The failure to avoid in a shooter's arsenal is the strictly-better gun: if
	the rifle beats the SMG at every range, the SMG is a tutorial. Each of these
	wins somewhere and loses elsewhere -- the SMG owns the first ten metres, the
	rifle owns twenty to sixty, the marksman owns everything past that and
	cannot defend itself when a runner closes.
]]
Arsenal.guns = ({
	{
		id = "m9", name = "M9", class = "sidearm",
		damage = 34, rpm = 450, magazine = 15, reserve = 90, pellets = 1,
		range = 400, auto = false, reload = 1.6,
		muzzle = 1150, falloffStart = 60, falloffEnd = 220, falloffFloor = 0.45,
		spread = 2.4, adsSpread = 0.7, recoilUp = 1.1, recoilSide = 0.4,
		adsSpeed = 0.16, adsZoom = 0.85, scope = false,
		moveScale = 0.78, penetration = 1,
	},
	{
		id = "mp5", name = "MP5", class = "smg",
		damage = 25, rpm = 800, magazine = 30, reserve = 210, pellets = 1,
		range = 500, auto = true, reload = 2.1,
		muzzle = 1250, falloffStart = 55, falloffEnd = 190, falloffFloor = 0.38,
		spread = 3.1, adsSpread = 1.2, recoilUp = 0.7, recoilSide = 0.45,
		adsSpeed = 0.18, adsZoom = 0.8, scope = false,
		moveScale = 0.8, penetration = 1,
	},
	{
		id = "m4", name = "M4A1", class = "rifle",
		damage = 32, rpm = 750, magazine = 30, reserve = 210, pellets = 1,
		range = 800, auto = true, reload = 2.4,
		muzzle = 2900, falloffStart = 140, falloffEnd = 420, falloffFloor = 0.5,
		spread = 2.6, adsSpread = 0.55, recoilUp = 0.95, recoilSide = 0.38,
		adsSpeed = 0.22, adsZoom = 0.68, scope = false,
		moveScale = 0.72, penetration = 1,
	},
	{
		--[[
			Eight pellets, and a full hit kills.

			At 11 damage a pellet this was 88 -- twelve short of a kill -- so
			the gun needed two shots at seventy rounds a minute, which measured
			at 0.86 seconds and lost to every other gun in the arsenal at every
			range including point blank. A shotgun that cannot end a fight in
			one shot has no reason to exist, and the whole class was a tutorial
			weapon by accident.

			At 13 it is 104 up close and still two pellets and an apology at
			forty studs, which is exactly the shape the class should have.
		]]
		id = "m870", name = "Remington 870", class = "shotgun",
		damage = 13, rpm = 85, magazine = 6, reserve = 48, pellets = 8,
		range = 260, auto = false, reload = 3.4,
		muzzle = 1300, falloffStart = 22, falloffEnd = 95, falloffFloor = 0.2,
		spread = 6.5, adsSpread = 4.4, recoilUp = 3.6, recoilSide = 1.1,
		adsSpeed = 0.24, adsZoom = 0.88, scope = false,
		moveScale = 0.7, penetration = 1,
	},
	{
		id = "sks", name = "SKS", class = "marksman",
		damage = 58, rpm = 220, magazine = 10, reserve = 80, pellets = 1,
		range = 1200, auto = false, reload = 2.8,
		muzzle = 2350, falloffStart = 260, falloffEnd = 700, falloffFloor = 0.62,
		spread = 2.2, adsSpread = 0.3, recoilUp = 2.1, recoilSide = 0.5,
		adsSpeed = 0.3, adsZoom = 0.42, scope = true,
		moveScale = 0.55, penetration = 2,
	},
	{
		--: One shot, one body, and a bolt cycle long enough that missing is a
		--: real punishment. Nothing else in the arsenal can reach this far and
		--: nothing else is this helpless up close.
		--: 85, not 105. Above 100 it one-shot a body at every range out to six
		--: hundred studs, which leaves nothing for a headshot to be worth and
		--: nothing for the distance to cost.
		id = "m24", name = "M24", class = "sniper",
		damage = 85, rpm = 45, magazine = 5, reserve = 40, pellets = 1,
		range = 2200, auto = false, reload = 3.6,
		muzzle = 2700, falloffStart = 500, falloffEnd = 1600, falloffFloor = 0.75,
		spread = 3.0, adsSpread = 0.05, recoilUp = 4.5, recoilSide = 0.6,
		adsSpeed = 0.42, adsZoom = 0.16, scope = true,
		moveScale = 0.4, penetration = 3,
	},
} :: any) :: { Gun }

--[[
	Where a round landed, and what that is worth.

	Three zones, not eleven. A limb/torso/head split is the one every player
	already understands, and the finer the model gets the more a fight is
	decided by hitbox trivia rather than by aim.
]]
Arsenal.ZONES = {
	head = { multiplier = 3.2, name = "Head" },
	torso = { multiplier = 1.0, name = "Body" },
	limb = { multiplier = 0.72, name = "Limb" },
}

local byId: { [string]: Gun } = {}
for _, gun in Arsenal.guns do
	byId[gun.id] = gun
end

function Arsenal.get(id: string): Gun?
	return byId[id]
end

function Arsenal.ids(): { string }
	local out = {}
	for _, gun in Arsenal.guns do
		table.insert(out, gun.id)
	end
	return out
end

--: The shape `Forge.Weapon.define` wants. Kept as a translation rather than
--: storing the engine's field names here, so the arsenal reads as a list of
--: guns and not as a list of engine configuration.
function Arsenal.spec(gun: Gun): { [string]: any }
	return {
		mode = "hitscan",
		damage = gun.damage,
		rpm = gun.rpm,
		pellets = gun.pellets,
		range = gun.range,
		magazine = gun.magazine,
		reserve = gun.reserve,
		auto = gun.auto,
		reloadTime = gun.reload,
		clip = "shoot",

		--[[
			Bloom, recoil and falloff are tables in the engine, not numbers.

			`spread = gun.spread` was passed as a bare number and
			`Weapon.define` threw on `def.spread.min` -- which killed the whole
			server bootstrap, so nobody was ever armed, nothing was ever
			located, and the posture code never ran either. One wrong shape,
			four features silently absent.
		]]
		spread = {
			min = gun.adsSpread,
			--: The cone a held trigger climbs to. Three times the hip-fired
			--: figure: a burst should stop being a burst.
			max = gun.spread * 3,
			perShot = gun.spread * 0.22,
			recover = 5,
		},
		recoil = {
			pitch = gun.recoilUp, yaw = gun.recoilSide, recover = 9,
		},
		--[[
			The engine's falloff is switched off deliberately.

			`Weapon.fire` can apply distance falloff itself, and `Fight`
			already applies `Arsenal.damageAt` -- which also knows about hit
			zones, which the engine's does not. Leaving both on halves every
			long-range shot twice, and the symptom is a rifle that feels weak
			for no reason anybody can point at.
		]]
		falloff = false,
	}
end

--[[
	What a round is worth at a distance.

	Linear between the two thresholds rather than a curve. A player has to be
	able to feel where a gun stops working, and an exponential falloff makes
	that boundary mushy -- the shot that used to kill in three now kills in
	four, and nobody can say why.
]]
function Arsenal.falloff(gun: Gun, distance: number): number
	if distance <= gun.falloffStart then
		return 1
	end
	if distance >= gun.falloffEnd then
		return gun.falloffFloor
	end
	local t = (distance - gun.falloffStart) / (gun.falloffEnd - gun.falloffStart)
	return 1 - t * (1 - gun.falloffFloor)
end

--: What one round does to one target, before armour and before the pipeline.
function Arsenal.damageAt(gun: Gun, distance: number, zone: string): number
	local zoneEntry = Arsenal.ZONES[zone] or Arsenal.ZONES.torso
	return gun.damage * Arsenal.falloff(gun, distance) * zoneEntry.multiplier
end

--: How many rounds to put something down, at a distance, in a zone. The
--: number the whole arsenal is actually tuned against.
function Arsenal.shotsToKill(gun: Gun, health: number, distance: number,
                             zone: string): number
	local per = Arsenal.damageAt(gun, distance, zone) * gun.pellets
	if per <= 0 then
		return math.huge
	end
	return math.ceil(health / per)
end

--: Seconds to put something down, including the time between shots. Two guns
--: with the same shots-to-kill are not the same gun if one of them is a bolt
--: action, and this is the number that says so.
function Arsenal.timeToKill(gun: Gun, health: number, distance: number,
                            zone: string): number
	local shots = Arsenal.shotsToKill(gun, health, distance, zone)
	if shots == math.huge then
		return math.huge
	end
	return (shots - 1) * (60 / gun.rpm)
end

function Arsenal.describe(): { [string]: any }
	local rows = {}
	for _, gun in Arsenal.guns do
		rows[gun.id] = {
			class = gun.class,
			ttk80 = Arsenal.timeToKill(gun, 100, 80, "torso"),
			dps = gun.damage * gun.pellets * (gun.rpm / 60),
		}
	end
	return rows
end

return Arsenal
