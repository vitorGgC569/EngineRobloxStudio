--!strict
--[[
	Reference — what a reasonable number looks like.

	Forge gives an agent a parts bin and no manual. Every enemy's health, every
	weapon's cadence, every keyframe angle and every loot weight has to be
	invented from nothing, and the results read exactly like numbers invented
	from nothing: a husk with 90 health next to one with 7000, a bow that fires
	as fast as a rifle, a walk cycle whose arms swing ninety degrees.

	This is the manual. Not templates — nothing here is a genre, and nothing
	here decides what your game is. It is the set of proportions that hold
	across every action game ever balanced, expressed as numbers you can start
	from and then move on purpose.

		local baseline = Reference.enemy("brute")
		local weapon = Reference.weapon("bow")
		Reference.check("enemy", myEnemyTable)   --> what looks wrong, and why

	--- Why proportions and not values ---------------------------------------

	Absolute numbers are meaningless without the rest of the game: 90 health is
	generous against a weapon that does 8 and trivial against one that does
	200. So every entry here is expressed against a **reference frame** — a
	player with 100 health who deals 20 per hit — and `Reference.scale` moves
	the whole set if your game's frame differs.

	That is also why `check` is worth more than the tables. Being told your
	brute has 260 health is not useful; being told it takes 31 hits to kill and
	that anything past about 12 stops reading as a fight and starts reading as
	a chore is the thing an agent cannot derive.
]]

local Reference = {}

--[[
	The frame everything else is measured against.

	A player with 100 health who deals 20 per swing, killing an even opponent
	in five hits and dying in five. Change this and every ratio below moves
	with it, which is the point: the numbers are relationships, not constants.
]]
Reference.frame = {
	playerHealth = 100,
	playerDamage = 20,
	playerSpeed = 16,
	sprintSpeed = 26,
}

-- ================================= enemies ==================================
--[[
	Four shapes, by how long they take to kill and how hard they hit.

	`hitsToKill` is the number that matters and the one nobody thinks in.
	Under three and the enemy is a speed bump; past about twelve it stops
	being a fight and becomes a chore, and players describe that as "spongy"
	long before they can say why.

	`hitsToDie` is the other side: how many of its blows the player survives.
	Three or fewer is tense; one is a game people stop playing.
]]
Reference.enemies = {
	fodder = {
		hitsToKill = 2, hitsToDie = 12, speedRatio = 0.8,
		attackEvery = 1.8, reach = 7, armor = 0,
		note = "dies fast, dangerous only in numbers",
	},
	standard = {
		hitsToKill = 5, hitsToDie = 8, speedRatio = 0.85,
		attackEvery = 1.6, reach = 7, armor = 10,
		note = "the enemy the game is balanced around",
	},
	skirmisher = {
		hitsToKill = 3, hitsToDie = 6, speedRatio = 1.25,
		attackEvery = 1.1, reach = 6.5, armor = 0,
		note = "fast and fragile; the answer to a player who never moves",
	},
	brute = {
		hitsToKill = 11, hitsToDie = 3, speedRatio = 0.6,
		attackEvery = 2.4, reach = 10, armor = 40,
		note = "slow, telegraphed, and lethal if ignored",
	},
}

--[[
	Turn a shape into the numbers a Content file wants.

	Derived rather than tabulated, so a game with a different reference frame
	gets consistent enemies without editing anything here.
]]
function Reference.enemy(shape: string): { [string]: any }?
	local spec = Reference.enemies[shape]
	if not spec then
		return nil
	end
	local frame = Reference.frame
	return {
		health = math.floor(spec.hitsToKill * frame.playerDamage),
		damage = math.floor(frame.playerHealth / spec.hitsToDie),
		speed = math.floor(frame.playerSpeed * spec.speedRatio),
		armor = spec.armor,
		reach = spec.reach,
		attackEvery = spec.attackEvery,
		-- Score follows danger rather than health, so a brute is worth more
		-- than three fodder even though it has the same total hit points.
		score = math.floor(spec.hitsToKill * 3 + (12 - spec.hitsToDie) * 2),
		note = spec.note,
	}
end

-- ================================= weapons ==================================
--[[
	Cadence and damage move together, always.

	Damage per second is the number a player feels; rate and damage are the two
	dials that produce it. A weapon that is better on both is not a weapon, it
	is an upgrade, and a roster where one option dominates is a roster with one
	option.

	So each entry here lands within about 20% of the same DPS and differs in
	*how* it gets there — which is what makes a choice a choice.
]]
Reference.weapons = {
	blade = {
		rpm = 115, hits = 1, dpsRatio = 1,
		spreadDegrees = 0, range = 9, charge = false,
		note = "the baseline; everything else is measured against it",
	},
	rifle = {
		rpm = 260, hits = 1, dpsRatio = 0.95,
		spreadDegrees = 1.5, range = 500, charge = false,
		note = "sustained, punished by movement through spread",
	},
	cannon = {
		rpm = 55, hits = 1, dpsRatio = 1.05,
		spreadDegrees = 3, range = 350, charge = false,
		note = "slow and heavy; a miss costs a full cycle",
	},
	bow = {
		rpm = 70, hits = 1, dpsRatio = 1.1,
		spreadDegrees = 0.2, range = 700, charge = true,
		note = "highest damage, paid for with a draw",
	},
	shotgun = {
		rpm = 75, hits = 8, dpsRatio = 1.15,
		spreadDegrees = 9, range = 90, charge = false,
		note = "devastating close, useless beyond its cone",
	},
}

function Reference.weapon(shape: string): { [string]: any }?
	local spec = Reference.weapons[shape]
	if not spec then
		return nil
	end
	local frame = Reference.frame
	local baseline = frame.playerDamage * (115 / 60) -- blade DPS
	local perSecond = baseline * spec.dpsRatio
	local shotsPerSecond = spec.rpm / 60

	return {
		mode = spec.range > 20 and "projectile" or "hitscan",
		damage = math.floor((perSecond / shotsPerSecond) / spec.hits + 0.5),
		rpm = spec.rpm,
		pellets = spec.hits,
		range = spec.range,
		spread = { min = spec.spreadDegrees, max = spec.spreadDegrees * 3 },
		charge = spec.charge and { time = 0.85, minRatio = 0.3 } or nil,
		note = spec.note,
	}
end

-- ================================ animation =================================
--[[
	Angles and durations that read as motion rather than as a machine.

	The two mistakes an agent makes here are both about scale. Arms that swing
	ninety degrees in a walk look like semaphore; an attack that lasts a fifth
	of a second is over before it is seen. These are the ranges inside which
	things look like bodies.
]]
Reference.motion = {
	walk = { armSwing = 22, legSwing = 26, cadence = 1.6,
		note = "arms roughly the same as legs, opposed" },
	run = { armSwing = 38, legSwing = 44, cadence = 2.4,
		note = "bigger and faster, not just faster" },
	lightAttack = { duration = 0.5, windup = 0.35, hitAt = 0.5,
		note = "the hit lands halfway; a hit at the end feels late" },
	heavyAttack = { duration = 1.15, windup = 0.48, hitAt = 0.63,
		note = "half the clip is telegraph, or it cannot be read" },
	dodge = { duration = 0.45, iframesFrom = 0.05, iframesTo = 0.67,
		note = "invulnerable for the middle two thirds" },
	flinch = { duration = 0.34, note = "short enough not to interrupt play" },
	idleSway = { degrees = 3, rate = 0.9, note = "a still character reads as broken" },
}

-- ================================== loot ====================================
--[[
	How often a reward should appear.

	The trap is a table where everything is roughly equal, which produces a
	game with no highs. A rare drop is only rare if the common one is genuinely
	common, and players need roughly four sessions between memorable moments
	for them to stay memorable.
]]
Reference.rarity = {
	common = { weight = 60, note = "most of what you see" },
	uncommon = { weight = 25 },
	rare = { weight = 12 },
	exceptional = { weight = 3, note = "roughly one in thirty pickups" },
}

Reference.economy = {
	sessionMinutes = 12,
	rewardsPerSession = 8,
	--: What a session's income should buy, so progress is felt but not free.
	sessionsPerPurchase = 3,
}

-- ================================== check ===================================
--[[
	What looks wrong about this table, and why.

	The most useful thing in this module. Being handed a baseline does not stop
	an agent inventing 7000 health; being told "that is 350 hits to kill, and
	past about twelve a fight reads as a chore" does.

	Returns a list of plain-language notes. Empty means nothing stood out — not
	that the numbers are good, which is a judgement no table can make.
]]
function Reference.check(kind: string, table_: any): { string }
	local notes = {}
	local frame = Reference.frame

	if kind == "enemy" then
		local health = tonumber(table_.health)
		if health then
			local hits = health / frame.playerDamage
			if hits < 1.5 then
				table.insert(notes, string.format(
					"%d health is under two hits: this enemy dies before the player registers it",
					health))
			elseif hits > 14 then
				table.insert(notes, string.format(
					"%d health is %.0f hits. Past about twelve a fight stops reading as a fight and starts reading as a chore",
					health, hits))
			end
		end

		local damage = tonumber(table_.damage)
		if damage then
			local survives = frame.playerHealth / math.max(1, damage)
			if survives < 2 then
				table.insert(notes, string.format(
					"%d damage kills the player in %.1f hits, which is a game people stop playing",
					damage, survives))
			elseif survives > 20 then
				table.insert(notes, string.format(
					"%d damage means the player survives %.0f hits; the enemy is scenery",
					damage, survives))
			end
		end

		local speed = tonumber(table_.speed)
		if speed and speed > frame.sprintSpeed then
			table.insert(notes, string.format(
				"speed %d is faster than the player can sprint (%d), so disengaging is impossible",
				speed, frame.sprintSpeed))
		end

		local armor = tonumber(table_.armor)
		if armor and armor > 300 then
			table.insert(notes, string.format(
				"armour %d reduces damage by over 75%%, which reads as the weapon being broken",
				armor))
		end

	elseif kind == "weapon" then
		local damage = tonumber(table_.damage)
		--[[
			Melee declares a cooldown and ranged declares a rate.

			The same fact in two units, and a check that only understood one of
			them would silently pass every sword in the game. Converted here
			rather than at each call site, because the conversion is a fact
			about weapons rather than a fact about any one game.
		]]
		local rpm = tonumber(table_.rpm)
		local cooldown = tonumber(table_.cooldown)
		if not rpm and cooldown and cooldown > 0 then
			rpm = 60 / cooldown
		end
		if rpm and damage then
			local shotsPerSecond = rpm / 60
			local dps = damage * shotsPerSecond * (tonumber(table_.pellets) or 1)

			--[[
				A magazine changes what "per second" means.

				Rate times damage is *burst* DPS, and for anything that has to
				stop and reload it is not the number a player feels. The hand
				cannon in this repository measured at twice the baseline and
				was flagged as dominant; six shots at 260rpm followed by a 1.5s
				reload is 35 damage per second sustained, which is the baseline
				almost exactly. The gun was fine and the check was measuring
				the wrong thing — so it now measures a full cycle.
			]]
			local magazine = tonumber(table_.magazine)
			local reloadTime = tonumber(table_.reloadTime)
			if magazine and magazine > 0 and magazine < math.huge
				and reloadTime and reloadTime > 0 then
				local cycle = (magazine / shotsPerSecond) + reloadTime
				dps = (magazine * damage * (tonumber(table_.pellets) or 1)) / cycle
			end

			local baseline = frame.playerDamage * (115 / 60)
			if dps > baseline * 2 then
				table.insert(notes, string.format(
					"%.0f damage per second is more than twice the baseline; nothing else in the roster will be picked",
					dps))
			elseif dps < baseline * 0.4 then
				table.insert(notes, string.format(
					"%.0f damage per second is under half the baseline; this weapon is a downgrade rather than a choice",
					dps))
			end
		end
		if rpm and rpm > 900 then
			table.insert(notes, string.format(
				"%d rounds per minute is faster than the network will carry cleanly",
				math.floor(rpm)))
		end

	elseif kind == "clip" then
		local duration = tonumber(table_.duration)
		if duration then
			if duration < 0.18 then
				table.insert(notes, string.format(
					"%.2fs is shorter than a player can perceive as a motion", duration))
			elseif duration > 2.5 then
				table.insert(notes, string.format(
					"%.2fs takes control away for long enough to feel like a cutscene", duration))
			end
		end
		if table_.markers and #table_.markers == 0 and duration and duration > 0.4 then
			table.insert(notes,
				"a clip this long with no markers is a pose with no timing; nothing can hook the moment it matters")
		end
	end

	return notes
end

--[[
	Move the whole reference frame.

	A game where the player has 1000 health and deals 200 is the same game with
	a zero on the end, and every table here should move with it rather than
	being re-derived by hand.
]]
function Reference.scale(playerHealth: number, playerDamage: number)
	Reference.frame.playerHealth = playerHealth
	Reference.frame.playerDamage = playerDamage
end

function Reference.describe(): { [string]: any }
	local enemies, weapons = {}, {}
	for name in Reference.enemies do
		table.insert(enemies, name)
	end
	for name in Reference.weapons do
		table.insert(weapons, name)
	end
	table.sort(enemies)
	table.sort(weapons)
	return {
		frame = table.clone(Reference.frame),
		enemyShapes = enemies,
		weaponShapes = weapons,
		checks = { "enemy", "weapon", "clip" },
	}
end

return Reference
