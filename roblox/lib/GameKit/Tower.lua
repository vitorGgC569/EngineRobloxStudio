--!strict
-- L6: towers and waves.
--
-- Authored because a real game asked for it. `siegehold` went through the
-- factory, the composer resolved `tower`, and it came back PLANNED -- so the
-- emitted game carried a stub that raises on first use. That is the honest
-- behaviour for a missing system, and it is not a shippable one.
--
-- The failure modes here are all about *arithmetic nobody checks*, which is why
-- this belongs in the SDK rather than in each tower game.
--
-- **An unwinnable wave must be knowable before the wave runs.** Total enemy
-- health against total damage-per-second the player could field is a division,
-- and every tower defense that ships an impossible level shipped it because
-- nobody did the division. `Tower.simulate` does it with no game running.
--
-- **A trivially winnable wave is the same defect.** A wave the player clears
-- without acting is content that cost as much to make and delivers nothing, and
-- it reads to a player as the game being broken rather than easy.
--
-- **Upgrade cost must outpace upgrade value, or the ladder collapses.** If tier
-- N+1 gives more damage per unit of currency than tier N, the optimal play is to
-- skip every intermediate tier, and the progression the economy designer priced
-- is not the one being played.
--
-- **Damage is applied in one place.** Two services each subtracting health is
-- how an enemy dies twice, pays out twice, and the economy inflates from a race
-- nobody can reproduce.
--
-- Placement and waves live behind an injected store keyed by UserId, exactly
-- like `Economy` and `Inventory`: persistence is `Save`'s problem, and a whole
-- defence can be simulated with a plain table.

local Analytics = require(script.Parent.Analytics)

local Tower = {}

export type TowerDefinition = {
	id: string,
	displayName: string,
	--- Damage per second at tier 1.
	damage: number,
	--- Studs. A tower that cannot reach the path is a tower that does nothing,
	--- and it looks identical to one that is simply weak.
	range: number,
	cost: number,
	currency: string,
	--- Cost and damage multipliers per upgrade tier, tier 1 implied at 1.0.
	upgrades: { { cost: number, damage: number } }?,
	tags: { string }?,
}

export type EnemyDefinition = {
	id: string,
	displayName: string,
	health: number,
	--- Studs per second along the path.
	speed: number,
	--- Paid to the player on death.
	bounty: number,
	--- Damage to the objective if it survives the path.
	leak: number,
	armour: number?,
}

export type WaveEntry = {
	enemyId: string,
	count: number,
	--- Seconds between spawns within this entry.
	interval: number?,
}

export type Wave = {
	index: number,
	entries: { WaveEntry },
	--- Seconds before the first spawn. The player's build window.
	prepare: number?,
}

export type Placement = {
	towerId: string,
	tier: number,
	position: { number },
}

export type Defence = {
	placements: { Placement },
	objectiveHealth: number,
	waveIndex: number,
}

export type Store = {
	get: (userId: number) -> Defence?,
	set: (userId: number, defence: Defence) -> (),
}

export type Tower = any

local function fail(message: string): never
	error("[Tower] " .. message, 0)
end

--- Damage per second a placement contributes, at its tier.
---
--- Tier 1 is the base definition; each upgrade multiplies. Kept as one function
--- because a second copy of this arithmetic in the UI is how a player is shown
--- a number the simulation disagrees with.
local function damageAt(definition: TowerDefinition, tier: number): number
	local damage = definition.damage
	local upgrades = definition.upgrades or {}
	for index = 1, tier - 1 do
		local step = upgrades[index]
		if step == nil then
			break
		end
		damage = damage * step.damage
	end
	return damage
end

local function costAt(definition: TowerDefinition, tier: number): number
	local cost = definition.cost
	local upgrades = definition.upgrades or {}
	for index = 1, tier - 1 do
		local step = upgrades[index]
		if step == nil then
			break
		end
		cost = cost + step.cost
	end
	return cost
end

function Tower.memoryStore(): Store
	local held: { [number]: Defence } = {}
	return {
		get = function(userId: number): Defence?
			return held[userId]
		end,
		set = function(userId: number, defence: Defence)
			held[userId] = defence
		end,
	}
end

--- Check a tower and enemy catalogue before anything is placed.
---
--- Every problem found here would otherwise appear once per placement or once
--- per wave, which is how one mispriced upgrade becomes forty findings.
function Tower.validate(
	towers: { TowerDefinition },
	enemies: { EnemyDefinition },
	waves: { Wave }
): { string }
	local problems: { string } = {}

	local towerIds: { [string]: TowerDefinition } = {}
	for _, definition in ipairs(towers) do
		if type(definition.id) ~= "string" or definition.id == "" then
			table.insert(problems, "every tower needs a non-empty id")
			continue
		end
		if towerIds[definition.id] ~= nil then
			table.insert(problems, string.format("tower %q is defined twice", definition.id))
			continue
		end
		towerIds[definition.id] = definition

		if type(definition.damage) ~= "number" or definition.damage <= 0 then
			table.insert(problems, string.format("tower %q does no damage", definition.id))
		end
		if type(definition.range) ~= "number" or definition.range <= 0 then
			table.insert(problems, string.format(
				"tower %q has no range, so it can never reach the path", definition.id))
		end
		if type(definition.cost) ~= "number" or definition.cost < 0 then
			table.insert(problems, string.format("tower %q has no cost", definition.id))
		end

		-- The ladder check. A tier that buys more damage per unit of currency
		-- than the tier below it makes every intermediate tier a mistake to buy,
		-- and the priced progression stops being the played one.
		local previousRatio: number? = nil
		for tier = 1, #(definition.upgrades or {}) + 1 do
			local cost = costAt(definition, tier)
			local ratio = if cost > 0 then damageAt(definition, tier) / cost else math.huge
			if previousRatio ~= nil and ratio > previousRatio then
				table.insert(problems, string.format(
					"tower %q tier %d gives more damage per unit of currency than tier %d "
					.. "(%.3f vs %.3f); the optimal play is to skip the tier below it",
					definition.id, tier, tier - 1, ratio, previousRatio))
			end
			previousRatio = ratio
		end
	end

	local enemyIds: { [string]: EnemyDefinition } = {}
	for _, definition in ipairs(enemies) do
		if type(definition.id) ~= "string" or definition.id == "" then
			table.insert(problems, "every enemy needs a non-empty id")
			continue
		end
		if enemyIds[definition.id] ~= nil then
			table.insert(problems, string.format("enemy %q is defined twice", definition.id))
			continue
		end
		enemyIds[definition.id] = definition
		if type(definition.health) ~= "number" or definition.health <= 0 then
			table.insert(problems, string.format("enemy %q has no health", definition.id))
		end
		if type(definition.speed) ~= "number" or definition.speed <= 0 then
			table.insert(problems, string.format(
				"enemy %q never moves, so it never reaches the objective", definition.id))
		end
		if type(definition.bounty) ~= "number" or definition.bounty < 0 then
			table.insert(problems, string.format("enemy %q pays a negative bounty", definition.id))
		end
	end

	if #waves == 0 then
		table.insert(problems, "a tower defense with no waves has no game in it")
	end
	local seenIndex: { [number]: true } = {}
	for _, wave in ipairs(waves) do
		if seenIndex[wave.index] then
			table.insert(problems, string.format("wave %d is declared twice", wave.index))
		end
		seenIndex[wave.index] = true
		if #wave.entries == 0 then
			table.insert(problems, string.format("wave %d spawns nothing", wave.index))
		end
		for _, entry in ipairs(wave.entries) do
			if enemyIds[entry.enemyId] == nil then
				table.insert(problems, string.format(
					"wave %d spawns unknown enemy %q", wave.index, entry.enemyId))
			end
			if type(entry.count) ~= "number" or entry.count < 1 or entry.count % 1 ~= 0 then
				table.insert(problems, string.format(
					"wave %d spawns a non-whole count of %q", wave.index, entry.enemyId))
			end
		end
	end

	return problems
end

export type WaveReport = {
	index: number,
	enemies: number,
	totalHealth: number,
	--- Seconds the wave takes to walk the path, if nothing kills it.
	duration: number,
	--- Damage the placed towers deliver over that window.
	deliverable: number,
	--- Health that survives, and therefore leaks into the objective.
	leaked: number,
	bounty: number,
	clearable: boolean,
	--- Deliverable over required. Below 1 the wave cannot be cleared; far above
	--- it the wave clears itself.
	margin: number,
}

export type SimulationReport = {
	waves: { WaveReport },
	objectiveHealth: number,
	survived: boolean,
	failedAtWave: number?,
	totalBounty: number,
}

--- What happens if this defence meets these waves, with no game running.
---
--- Deliberately a coarse model: total damage against total health over the
--- window the wave is alive. It cannot tell you a tower is badly placed, and it
--- does not claim to. What it does catch is the class of defect that makes a
--- level unplayable regardless of placement -- and that is the one that ships.
function Tower.simulate(
	towers: { TowerDefinition },
	enemies: { EnemyDefinition },
	waves: { Wave },
	defence: Defence,
	pathLength: number
): SimulationReport
	if type(pathLength) ~= "number" or pathLength <= 0 then
		fail("pathLength must be positive; it is what turns enemy speed into a time window")
	end

	local towerIds: { [string]: TowerDefinition } = {}
	for _, definition in ipairs(towers) do
		towerIds[definition.id] = definition
	end
	local enemyIds: { [string]: EnemyDefinition } = {}
	for _, definition in ipairs(enemies) do
		enemyIds[definition.id] = definition
	end

	local dps = 0
	for _, placement in ipairs(defence.placements) do
		local definition = towerIds[placement.towerId]
		if definition == nil then
			fail(string.format("placement names unknown tower %q", placement.towerId))
		end
		dps += damageAt(definition, placement.tier or 1)
	end

	local objective = defence.objectiveHealth
	local reports: { WaveReport } = {}
	local failedAt: number? = nil
	local totalBounty = 0

	local ordered = table.clone(waves)
	table.sort(ordered, function(a, b)
		return a.index < b.index
	end)

	for _, wave in ipairs(ordered) do
		local count = 0
		local health = 0
		local bounty = 0
		local leakPerHealth = 0
		local slowest = 0

		for _, entry in ipairs(wave.entries) do
			local enemy = enemyIds[entry.enemyId]
			if enemy == nil then
				fail(string.format("wave %d spawns unknown enemy %q", wave.index, entry.enemyId))
			end
			count += entry.count
			health += enemy.health * entry.count
			bounty += enemy.bounty * entry.count
			leakPerHealth = math.max(leakPerHealth, enemy.leak / math.max(enemy.health, 1))
			slowest = math.max(slowest, pathLength / enemy.speed)
		end

		-- The window is the slowest enemy's walk, plus the spawn spacing: a wave
		-- that trickles in is alive far longer than one that arrives at once,
		-- and using only the walk would overstate every drawn-out wave.
		local spacing = 0
		for _, entry in ipairs(wave.entries) do
			spacing = math.max(spacing, (entry.interval or 0) * (entry.count - 1))
		end
		local duration = slowest + spacing
		local deliverable = dps * duration
		local leaked = math.max(health - deliverable, 0)

		if leaked > 0 then
			objective -= leaked * leakPerHealth
		end
		totalBounty += bounty

		local clearable = leaked <= 0
		if not clearable and failedAt == nil and objective <= 0 then
			failedAt = wave.index
		end

		table.insert(reports, {
			index = wave.index,
			enemies = count,
			totalHealth = health,
			duration = duration,
			deliverable = deliverable,
			leaked = leaked,
			bounty = bounty,
			clearable = clearable,
			margin = if health > 0 then deliverable / health else math.huge,
		})
	end

	return {
		waves = reports,
		objectiveHealth = objective,
		survived = objective > 0,
		failedAtWave = failedAt,
		totalBounty = totalBounty,
	}
end

--- Waves that cannot be cleared, and waves that clear themselves.
---
--- Both are defects and they need opposite fixes, so they are reported
--- separately rather than as one "balance" number.
function Tower.problems(report: SimulationReport, policy: { [string]: any }?): { string }
	local settings = policy or {}
	local trivialAbove = settings.trivialMargin or 4.0
	local tightBelow = settings.tightMargin or 1.0

	local problems: { string } = {}
	for _, wave in ipairs(report.waves) do
		if wave.margin < tightBelow then
			table.insert(problems, string.format(
				"wave %d cannot be cleared: the placed towers deliver %.0f damage over %.0fs "
				.. "against %.0f health (%.2fx). No placement fixes a shortfall this size",
				wave.index, wave.deliverable, wave.duration, wave.totalHealth, wave.margin))
		elseif wave.margin > trivialAbove then
			table.insert(problems, string.format(
				"wave %d clears itself at %.1fx: it costs as much to author as a real wave "
				.. "and reads to a player as the game being broken rather than easy",
				wave.index, wave.margin))
		end
	end
	if not report.survived then
		table.insert(problems, string.format(
			"the objective falls at wave %s; the run ends before the content does",
			tostring(report.failedAtWave)))
	end
	return problems
end

function Tower.define(
	towers: { TowerDefinition },
	enemies: { EnemyDefinition },
	waves: { Wave },
	store: Store,
	objectiveHealth: number
): Tower
	if type(store) ~= "table" or type(store.get) ~= "function" or type(store.set) ~= "function" then
		fail("store must provide get and set")
	end
	if type(objectiveHealth) ~= "number" or objectiveHealth <= 0 then
		fail("the objective needs health above zero, or the game is over before it starts")
	end

	local problems = Tower.validate(towers, enemies, waves)
	if #problems > 0 then
		-- Refused at definition rather than at the first placement. A catalogue
		-- with a broken tower placed forty times produces forty reports of one
		-- mistake.
		fail("the catalogue does not validate: " .. table.concat(problems, "; "))
	end

	local self = {} :: any
	self.towers = {}
	for _, definition in ipairs(towers) do
		self.towers[definition.id] = definition
	end
	self.enemies = enemies
	self.waves = waves
	self.store = store
	self.objectiveHealth = objectiveHealth

	local function defenceFor(player: Player): Defence
		local existing = store.get(player.UserId)
		if existing ~= nil then
			return existing
		end
		local fresh: Defence = {
			placements = {},
			objectiveHealth = objectiveHealth,
			waveIndex = 0,
		}
		store.set(player.UserId, fresh)
		return fresh
	end

	--- Check placement without changing the store.
	---
	--- Purchase flows use this before spending so a spatial refusal cannot take
	--- currency. `place` repeats the check immediately before committing; there
	--- is no yield between that check and the write.
	function self.canPlace(
		player: Player,
		towerId: string,
		position: { number }
	): (boolean, string?)
		if self.towers[towerId] == nil then
			return false, string.format("unknown tower %q", towerId)
		end
		if type(position) ~= "table" or #position ~= 3 then
			return false, "a position is three numbers"
		end
		local defence = defenceFor(player)
		for _, existing in ipairs(defence.placements) do
			local dx = existing.position[1] - position[1]
			local dz = existing.position[3] - position[3]
			if math.sqrt(dx * dx + dz * dz) < 1 then
				return false, string.format(
					"a %s already stands within one stud of that point", existing.towerId)
			end
		end
		return true, nil
	end

	--- Place a tower, or say why not.
	---
	--- Returns the placement and nil, or nil and a reason. Never a bare boolean:
	--- "could not place" and "placed" are not the only two outcomes a caller
	--- needs to distinguish, and a false that could mean four things is how a UI
	--- shows "cannot afford" for a tower that overlaps another.
	function self.place(
		player: Player,
		towerId: string,
		position: { number }
	): (Placement?, string?)
		local allowed, reason = self.canPlace(player, towerId, position)
		if not allowed then
			return nil, reason
		end

		local defence = defenceFor(player)
		local placement: Placement = { towerId = towerId, tier = 1, position = position }
		table.insert(defence.placements, placement)
		store.set(player.UserId, defence)
		Analytics.custom(player, "tower_placed", 1, { towerId = towerId })
		return placement, nil
	end

	--- Upgrade a placed tower one tier.
	function self.upgrade(player: Player, index: number): (number?, string?)
		local defence = defenceFor(player)
		local placement = defence.placements[index]
		if placement == nil then
			return nil, string.format("no tower at index %d", index)
		end
		local definition = self.towers[placement.towerId]
		local ceiling = #(definition.upgrades or {}) + 1
		if placement.tier >= ceiling then
			return nil, string.format(
				"%s is already at its top tier (%d)", placement.towerId, ceiling)
		end
		placement.tier += 1
		store.set(player.UserId, defence)
		Analytics.custom(player, "tower_upgraded", 1, {
			towerId = placement.towerId, tier = placement.tier,
		})
		return placement.tier, nil
	end

	--- Total damage per second currently placed.
	function self.damage(player: Player): number
		local total = 0
		for _, placement in ipairs(defenceFor(player).placements) do
			total += damageAt(self.towers[placement.towerId], placement.tier)
		end
		return total
	end

	--- Whether the player's current defence survives the remaining waves.
	function self.forecast(player: Player, pathLength: number): SimulationReport
		return Tower.simulate(towers, enemies, waves, defenceFor(player), pathLength)
	end

	function self.defence(player: Player): Defence
		return defenceFor(player)
	end

	return self
end

Tower.damageAt = damageAt
Tower.costAt = costAt

return Tower
