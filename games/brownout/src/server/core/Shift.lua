--!strict
--[[
	Shift — the authoritative state of one night, and of everyone working it.

	Every system in this game reads the same three numbers: how much charge the
	generator has, how far the light reaches, and how long until dawn. They live
	here rather than in the system that ticks them, for one reason: the tick and
	the readers would otherwise have to be the same module, and the file that
	both simulates a generator and decides whether a player is in the dark is
	the file nobody can change safely.

	This module holds state and derives from it. It does not tick, it does not
	touch instances, and it does not talk to the network. `Power` does the first,
	`Outpost` the second, and `Power` the third.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Signal = Forge.Core.Signal

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Shift = {}

-- ================================== world ===================================

Shift.phase = "night" :: string
Shift.charge = Config.generator.startCharge
Shift.clock = Config.night.duration
--: Nights fully survived this server. Drives the payout and the difficulty.
Shift.nightsSurvived = 0
--: Set by Outpost once the generator exists; systems that need to point at it
--: must tolerate nil until then.
Shift.generator = nil :: BasePart?

--: (player, ring, chargeAdded, wattsAdded)
Shift.onDeposit = Signal.new()
--: (phase)
Shift.onPhase = Signal.new()
--: fired when charge reaches zero
Shift.onBlackout = Signal.new()

--[[
	Charge to lit radius.

	Deliberately not linear. A linear map spends the interesting half of the
	curve in the range where the player is already safe; this one keeps the
	light shrinking fast in the bottom third, which is where the game is.
]]
function Shift.radius(): number
	local L = Config.light
	local alpha = math.clamp(Shift.charge / Config.generator.maxCharge, 0, 1)
	return L.minRadius + (L.maxRadius - L.minRadius) * (alpha ^ 0.72)
end

--[[
	Charge lost per second right now.

	Three terms, and each is a design decision rather than an implementation
	detail: a base rate, a ramp that makes the end of the night the hard part,
	and a per-player load so a full server is a bigger machine and not an easier
	one.
]]
function Shift.drainRate(): number
	if Shift.phase ~= "night" then
		return 0
	end
	local G = Config.generator
	local elapsed = 1 - math.clamp(Shift.clock / Config.night.duration, 0, 1)
	local ramp = 1 + G.drainRamp * elapsed
	local crew = math.max(0, #Players:GetPlayers() - 1)
	return (G.baseDrain + crew * G.drainPerExtraPlayer) * ramp
end

function Shift.addCharge(amount: number)
	Shift.charge = math.clamp(Shift.charge + amount, 0, Config.generator.maxCharge)
end

--: A snapshot small enough to send every half second without thinking about it.
function Shift.snapshot(): { [string]: any }
	return {
		phase = Shift.phase,
		charge = Shift.charge,
		maxCharge = Config.generator.maxCharge,
		radius = Shift.radius(),
		clock = Shift.clock,
		night = Shift.nightsSurvived,
		drain = Shift.drainRate(),
		crew = #Players:GetPlayers(),
	}
end

-- ================================== crew ====================================
--[[
	Per-player runtime state.

	Runtime, not profile: what a player is carrying and how cold they are does
	not survive a rejoin and must not be written to a DataStore. The persistent
	half — watts and upgrades — lives in `Save`, and the two are deliberately
	different tables so that a system cannot accidentally persist a field that
	was only ever meant to last a night.
]]
export type Crew = {
	exposure: number,
	--: The ring spec of the cell in hand, or nil.
	carrying: any?,
	--: The model being carried, so it can be dropped rather than deleted.
	carried: Model?,
	--: Set while the player is dead, so the exposure tick skips them instead of
	--: reading a Humanoid that is on its way out.
	down: boolean,
}

local crew: { [Player]: Crew } = {}

function Shift.crewOf(player: Player): Crew
	local existing = crew[player]
	if existing then
		return existing
	end
	local fresh: Crew = { exposure = 0, carrying = nil, carried = nil, down = false }
	crew[player] = fresh
	return fresh
end

function Shift.forgetCrew(player: Player)
	crew[player] = nil
end

function Shift.eachCrew(): { [Player]: Crew }
	return crew
end

--[[
	Upgrade level, read from the save profile.

	Returns zero for a player whose profile has not loaded, which is the honest
	answer: a player with no profile has bought nothing. Systems must not stall
	waiting for one, because a stalled exposure tick is a player standing in the
	dark taking no damage and learning the wrong lesson about the game.
]]
function Shift.upgradeLevel(player: Player, id: string): number
	local profile = Forge.Save.get(player)
	if not profile or type(profile.upgrades) ~= "table" then
		return 0
	end
	return tonumber(profile.upgrades[id]) or 0
end

--: The cost of the next level of an upgrade, or nil when it is maxed.
function Shift.upgradeCost(spec: any, level: number): number?
	if level >= spec.max then
		return nil
	end
	return math.floor(spec.base * spec.growth ^ level + 0.5)
end

--[[
	The upgrade rules, as pure functions of a level.

	Split from their per-player wrappers deliberately. A rule that can only be
	evaluated by handing it a `Player` can only be tested inside a session that
	has one, and the live suite runs during bootstrap when it may not. These are
	the promises the design makes — a bigger lantern always reaches further, a
	heavier cell always costs more speed — and they are checkable on their own.
]]
Shift.rule = {}

function Shift.rule.lanternRadius(level: number): number
	return Config.exposure.lanternRadius + level * 4
end

function Shift.rule.sprintSpeed(level: number): number
	return Config.walk.sprint + level * 1.6
end

function Shift.rule.carryPenalty(level: number, grade: number): number
	--: Each level of the hauler rig takes 18% off the slow, never all of it: a
	--: fully-upgraded hauler is still slower carrying grade 3 than grade 1, so
	--: the choice of ring never stops being a choice.
	local relief = 1 - math.min(0.72, level * 0.18)
	return Config.cells.carrySlowPerGrade * grade * relief
end

function Shift.rule.couplerBonus(level: number): number
	return 1 + level * 0.12
end

--: Per-player wrappers, so the client and the server can never disagree about
--: how far a lantern reaches.
function Shift.lanternRadius(player: Player): number
	return Shift.rule.lanternRadius(Shift.upgradeLevel(player, "lantern"))
end

function Shift.sprintSpeed(player: Player): number
	return Shift.rule.sprintSpeed(Shift.upgradeLevel(player, "boots"))
end

function Shift.carryPenalty(player: Player, grade: number): number
	return Shift.rule.carryPenalty(Shift.upgradeLevel(player, "hauler"), grade)
end

function Shift.couplerBonus(player: Player): number
	return Shift.rule.couplerBonus(Shift.upgradeLevel(player, "coupler"))
end

--: What the client needs about itself. Sent on change, not on a timer.
function Shift.crewSnapshot(player: Player): { [string]: any }
	local state = Shift.crewOf(player)
	local profile = Forge.Save.get(player)
	local upgrades = {}
	for _, spec in Config.upgrades do
		local level = Shift.upgradeLevel(player, spec.id)
		table.insert(upgrades, {
			id = spec.id,
			label = spec.label,
			detail = spec.detail,
			level = level,
			max = spec.max,
			cost = Shift.upgradeCost(spec, level),
		})
	end
	return {
		watts = profile and profile.watts or 0,
		lifetime = profile and profile.lifetime or 0,
		exposure = state.exposure,
		maxExposure = Config.exposure.max,
		lantern = Shift.lanternRadius(player),
		carrying = state.carrying and {
			grade = state.carrying.grade,
			charge = state.carrying.charge,
			watts = state.carrying.watts,
		} or nil,
		upgrades = upgrades,
	}
end

return Shift
