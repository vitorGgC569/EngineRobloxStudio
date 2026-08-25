--!strict
--[[
	DamagePipeline — pure resolution of a landed strike, nothing attached.

	Takes the move and both fighters as plain data and answers what the strike
	meant: full hit, blocked, miss or immune. Mines Fighting-game's
	HitHandler: i-frames beat everything except ignoreIframes, strikes from
	behind slip past guard, blocks bleed 20% chip (minimum 1), guardbreak
	shatters the block for x1.15 damage and a fixed 2 s stun, and superArmor
	never softens damage — it only refuses stun and knockback.

	Rule order is deliberate:
	  1. attacker incapacitated   -> miss   (a stunned attacker lands nothing)
	  2. victim i-frames active   -> miss   (unless move.ignoreIframes)
	  3. victim already dead      -> immune (corpses take no further damage)
	  4. guardbreak against block -> hit    (broken guard, fixed stun, x1.15)
	  5. block holds              -> blocked (chip damage + blockstun)
	  6. nothing applied          -> hit    (full damage)

	Facing convention: facingDot = dot(victimLook, dirToAttacker), so > 0
	means the attacker stands in front of the victim and < 0 behind them.

	Pure in, pure out: no Instances, no services, no clocks. Numeric i-frame
	timestamps need `now`; without one they are treated as still active
	(fail-safe for server validation).
]]

local DamagePipeline = {}

export type Move = {
	damage: number,
	knockback: any?,
	guardbreak: boolean?,
	passthrough: boolean?,
	blockAnywhere: boolean?,
	ignoreIframes: boolean?,
	blockstun: number?,
	stun: number?,
	hitType: string?,
}

export type Fighter = {
	blocking: boolean?,
	facingDot: number?,
	iframes: any?,
	superArmor: boolean?,
	stunUntil: number?,
	stunned: boolean?,
	health: number?,
}

export type ResultKind = "hit" | "blocked" | "miss" | "immune"

export type Result = {
	kind: ResultKind,
	damageDealt: number,
	chipDamage: number,
	guardBroken: boolean,
	stunApplied: number?,
	knockbackDir: Vector3?,
	events: { string },
}

local BLOCK_CHIP_RATIO = 0.2
local GUARDBREAK_DAMAGE_MULTIPLIER = 1.15
local GUARDBREAK_STUN_SECONDS = 2

-- ============================== helpers ======================================

local function build(kind: ResultKind, dealt: number, chip: number, broken: boolean, stun: number?, kb: Vector3?, events: { string }): Result
	return {
		kind = kind,
		damageDealt = dealt,
		chipDamage = chip,
		guardBroken = broken,
		stunApplied = stun,
		knockbackDir = kb,
		events = events,
	}
end

local function ceilDamage(value: number): number
	return math.max(1, math.ceil(value))
end

local function iframesActive(victim: Fighter, now: number?): boolean
	local iframes = victim.iframes
	if iframes == nil then
		return false
	end
	if iframes == true then
		return true
	end
	if type(iframes) == "number" then
		if now == nil then
			return true
		end
		return (now :: number) < iframes
	end
	return false
end

local function attackerIncapacitated(attacker: Fighter?, now: number?): boolean
	if not attacker or attacker.superArmor then
		return false
	end
	if attacker.stunned == true then
		return true
	end
	local stunUntil = attacker.stunUntil
	if type(stunUntil) == "number" and now ~= nil and (now :: number) < stunUntil then
		return true
	end
	return false
end

-- Vectors pass through; plain {x,y,z} tables convert; bare numbers are
-- magnitudes whose direction only the caller knows (attacker facing).
local function knockbackDirOf(raw: any): (Vector3?, boolean)
	if typeof(raw) == "Vector3" then
		return raw, true
	end
	if type(raw) == "table" and type((raw :: any).x) == "number" then
		local vector = raw :: any
		return Vector3.new(vector.x, vector.y or 0, vector.z or 0), true
	end
	if type(raw) == "number" and raw ~= 0 then
		return nil, true
	end
	return nil, false
end

-- ============================== resolution ===================================

function DamagePipeline.resolve(move: Move, attacker: Fighter?, victim: Fighter, now: number?): Result
	assert(type(move.damage) == "number", "DamagePipeline.resolve: move.damage must be a number")
	assert(move.damage >= 0, "DamagePipeline.resolve: move.damage must be non-negative")

	local events: { string } = {}

	if attackerIncapacitated(attacker, now) then
		table.insert(events, "attacker_stunned")
		return build("miss", 0, 0, false, nil, nil, events)
	end

	if iframesActive(victim, now) and not move.ignoreIframes then
		table.insert(events, "iframes")
		return build("miss", 0, 0, false, nil, nil, events)
	end

	if (victim.health or 1) <= 0 then
		table.insert(events, "already_dead")
		return build("immune", 0, 0, false, nil, nil, events)
	end

	local armored = victim.superArmor == true

	if victim.blocking == true then
		if move.guardbreak then
			table.insert(events, "guardbreak")
			if armored then
				table.insert(events, "super_armor")
			end
			local stun = if armored then nil else GUARDBREAK_STUN_SECONDS
			return build("hit", ceilDamage(move.damage * GUARDBREAK_DAMAGE_MULTIPLIER), 0, true, stun, nil, events)
		end

		local behind = (victim.facingDot or 0) < 0
		local blockHolds = move.passthrough ~= true and (move.blockAnywhere == true or not behind)

		if blockHolds then
			table.insert(events, "blocked")
			table.insert(events, "chip")
			local chip = math.max(1, math.round(move.damage * BLOCK_CHIP_RATIO))
			local stun = nil :: number?
			if move.blockstun ~= nil then
				if armored then
					table.insert(events, "super_armor")
				else
					stun = move.blockstun
					table.insert(events, "blockstun")
				end
			end
			return build("blocked", chip, chip, false, stun, nil, events)
		end

		if behind then
			table.insert(events, "backstab")
		else
			table.insert(events, "passthrough")
		end
	end

	local stun = nil :: number?
	if type(move.stun) == "number" and not armored then
		stun = move.stun :: number
		table.insert(events, "stun")
	end

	local kb, wanted = knockbackDirOf(move.knockback)
	if wanted and armored then
		kb = nil
	elseif kb ~= nil then
		table.insert(events, "knockback")
	elseif wanted then
		table.insert(events, "knockback_unoriented")
	end

	if armored then
		table.insert(events, "super_armor")
	end

	return build("hit", ceilDamage(move.damage), 0, false, stun, kb, events)
end

return DamagePipeline
