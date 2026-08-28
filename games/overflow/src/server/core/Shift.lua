--!strict
--[[
	Shift — the authoritative state of one shift, and the rules over it.

	Holds state and derives from it. It does not tick, it does not touch
	instances, and it does not talk to the network — `Play` does the first and
	the third, `Mill` and `Line` the second. The reason for the split is that
	the file which both simulates a belt and decides whether a sort was correct
	is the file nobody can change safely.

	Everything a test would want to assert is a pure function here, so the live
	suite can check the rules without running a shift.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Signal = Forge.Core.Signal

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Shift = {}

Shift.phase = "running" :: string
Shift.score = 0
Shift.sorts = 0
Shift.strikes = 0
Shift.streak = 0
--: The best score this server has seen, so a shift has something to beat even
--: when nobody has played before.
Shift.best = 0
--: Seconds left in the between-shift breather.
Shift.breather = 0

--: (kind, chuteId, correct)
Shift.onResolved = Signal.new()
--: (phase)
Shift.onPhase = Signal.new()

-- ================================== rules ===================================
--[[
	How far along the difficulty ramp this shift is, 0 to 1.

	Driven by correct sorts rather than by elapsed time, and that is the design:
	a player who is struggling is not also being accelerated, and a player who
	is good gets the speed they earned. A clock would punish hesitation twice.
]]
function Shift.ramp(): number
	return math.clamp(Shift.sorts / Config.line.rampSorts, 0, 1)
end

--[[
	Belt speed now, and the crate interval that goes with it.

	The brake scales the result rather than subtracting from the ramp, and the
	difference is the whole upgrade. Subtracting moved the player backwards
	along a curve that is already clamped at zero, so at the start of a shift —
	the moment the upgrade was sold on — `speed(0)` and `speed(4)` returned the
	same number and four levels of Line Brake did nothing at all. The live suite
	caught it on the first run; nothing else could have, because the belt still
	moved and the shift still played.

	Scaled, it helps everywhere and helps most late, when the curve is steep.
]]
local function brakeRelief(brakeLevel: number): number
	return math.min(0.35, (brakeLevel or 0) * 0.09)
end

function Shift.speed(brakeLevel: number): number
	local L = Config.line
	local base = L.startSpeed + (L.maxSpeed - L.startSpeed) * Shift.ramp()
	return base * (1 - brakeRelief(brakeLevel))
end

function Shift.interval(brakeLevel: number): number
	local L = Config.line
	local base = L.startInterval + (L.minInterval - L.startInterval) * Shift.ramp()
	return base * (1 + brakeRelief(brakeLevel))
end

--[[
	The score multiplier, from the current streak.

	Steps rather than a smooth curve, because the player has to be able to feel
	it arrive. A number that creeps up by 0.03 a sort is a number nobody knows
	they have.
]]
function Shift.multiplier(): number
	local S = Config.shift
	return math.min(S.maxMultiplier, 1 + math.floor(Shift.streak / S.streakStep))
end

--: How many strikes this player is allowed before the horn.
function Shift.allowedStrikes(bufferLevel: number): number
	return Config.shift.strikes + (bufferLevel or 0)
end

--: The cost of the next level, or nil when it is maxed.
function Shift.upgradeCost(spec: any, level: number): number?
	if level >= spec.max then
		return nil
	end
	return math.floor(spec.base * spec.growth ^ level + 0.5)
end

function Shift.upgradeLevel(player: Player, id: string): number
	local profile = Forge.Save.get(player)
	if not profile or type(profile.upgrades) ~= "table" then
		return 0
	end
	return tonumber(profile.upgrades[id]) or 0
end

--: How wide a chute's catch window is for this player.
function Shift.span(reachLevel: number): number
	return Config.chutes.span + (reachLevel or 0) * 1.2
end

--: How long a pulled gate stays open for this player.
function Shift.gateSeconds(holdLevel: number): number
	return Config.gate.openSeconds + (holdLevel or 0) * 0.2
end

-- ================================ scoring ===================================
--[[
	Resolve one crate against one chute.

	Returns `(correct, points, coins)`. Pure: it reads the streak but does not
	write it, so a test can ask "what would this be worth" without moving the
	game. `Play` applies the result.
]]
function Shift.valueOf(kind: string, chuteId: string): (boolean, number, number)
	local S = Config.shift
	if kind ~= chuteId then
		return false, 0, 0
	end
	return true, S.scorePerSort * Shift.multiplier(), S.coinsPerSort
end

function Shift.reset()
	Shift.score = 0
	Shift.sorts = 0
	Shift.strikes = 0
	Shift.streak = 0
	Shift.phase = "running"
end

function Shift.snapshot(queue: { string }, speed: number, allowed: number): { [string]: any }
	return {
		phase = Shift.phase,
		score = Shift.score,
		best = Shift.best,
		sorts = Shift.sorts,
		strikes = Shift.strikes,
		allowedStrikes = allowed,
		streak = Shift.streak,
		multiplier = Shift.multiplier(),
		speed = speed,
		ramp = Shift.ramp(),
		queue = queue,
		breather = Shift.breather,
		crew = #Players:GetPlayers(),
	}
end

--: What the client needs about itself. Sent on change, not on a timer.
function Shift.crewSnapshot(player: Player): { [string]: any }
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
		coins = profile and profile.coins or 0,
		lifetime = profile and profile.lifetime or 0,
		bestScore = profile and profile.bestScore or 0,
		shifts = profile and profile.shifts or 0,
		upgrades = upgrades,
	}
end

return Shift
