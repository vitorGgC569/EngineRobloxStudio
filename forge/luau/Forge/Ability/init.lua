--!strict
--[[
	Ability — costs, cooldowns, cast windows and targeting.

	Everything a game calls a "skill", a "spell", an "attack" or a "tool use"
	is the same shape: check whether it can run, pay for it, wait a moment,
	then do something. Writing that shape once means a new ability is data plus
	one function, and it is impossible to forget the cooldown.

		Ability.define("dash", {
			cooldown = 4,
			cost = { stamina = 24 },
			targeting = "direction",
			cast = 0,
			run = function(ctx) ... end,
		})

		Ability.use("player:1", "dash", { direction = look })

	Resources are not owned here. You register a resolver once and Ability
	stops caring whether stamina lives in a profile, a component or a table:

		Ability.resources(function(subject, kind) return pool(subject, kind) end,
		                  function(subject, kind, amount) spend(subject, kind, amount) end)
]]

local Events = require(script.Parent.Events)

local Ability = {}

type Definition = {
	name: string?,
	cooldown: number?,
	cost: { [string]: number }?,
	cast: number?, -- wind-up before `run` fires
	targeting: string?, -- "self" | "direction" | "point" | "entity"
	range: number?,
	charges: number?,
	globalCooldown: number?,
	condition: ((ctx: any) -> boolean)?,
	run: (ctx: any) -> ()?,
	onStart: ((ctx: any) -> ())?,
	onCancel: ((ctx: any) -> ())?,
	[string]: any,
}

local definitions: { [string]: Definition } = {}
local cooldowns: { [string]: { [string]: number } } = {} -- subject -> id -> readyAt
local chargeState: { [string]: { [string]: number } } = {}
local casting: { [string]: any } = {}
local globalUntil: { [string]: number } = {}

local getResource: ((subject: string, kind: string) -> number)? = nil
local spendResource: ((subject: string, kind: string, amount: number) -> boolean)? = nil

function Ability.resources(getter: (subject: string, kind: string) -> number, spender: (subject: string, kind: string, amount: number) -> boolean)
	getResource = getter
	spendResource = spender
end

function Ability.define(id: string, definition: Definition)
	definition.cooldown = definition.cooldown or 0
	definition.cast = definition.cast or 0
	definition.targeting = definition.targeting or "self"
	definitions[id] = definition
end

function Ability.defineMany(table_: { [string]: Definition })
	for id, definition in table_ do
		Ability.define(id, definition)
	end
end

function Ability.get(id: string): Definition?
	return definitions[id]
end

function Ability.ids(): { string }
	local out = {}
	for id in definitions do
		table.insert(out, id)
	end
	table.sort(out)
	return out
end

-- ================================ cooldowns =================================
local function subjectCooldowns(subject: string): { [string]: number }
	local map = cooldowns[subject]
	if not map then
		map = {}
		cooldowns[subject] = map
	end
	return map
end

function Ability.remaining(subject: string, id: string): number
	local readyAt = subjectCooldowns(subject)[id]
	if not readyAt then
		return 0
	end
	return math.max(0, readyAt - os.clock())
end

function Ability.ready(subject: string, id: string): boolean
	return Ability.remaining(subject, id) <= 0 and os.clock() >= (globalUntil[subject] or 0)
end

function Ability.resetCooldown(subject: string, id: string)
	subjectCooldowns(subject)[id] = nil
end

function Ability.charges(subject: string, id: string): number
	local definition = definitions[id]
	if not definition or not definition.charges then
		return Ability.ready(subject, id) and 1 or 0
	end
	local map = chargeState[subject]
	local current = map and map[id]
	return current == nil and definition.charges or current
end

-- ================================ execution =================================
--[[
	Returns (ok, reason). The reason string is the point: a UI that says
	"not enough stamina" instead of nothing at all comes free, and a test can
	assert on *why* an ability was refused.
]]
function Ability.canUse(subject: string, id: string, context: any?): (boolean, string?)
	local definition = definitions[id]
	if not definition then
		return false, "unknown"
	end
	if casting[subject] then
		return false, "casting"
	end
	if not Ability.ready(subject, id) then
		return false, "cooldown"
	end
	if definition.charges and Ability.charges(subject, id) <= 0 then
		return false, "nocharges"
	end

	if definition.cost and getResource then
		for kind, amount in definition.cost do
			if getResource(subject, kind) < amount then
				return false, "resource:" .. kind
			end
		end
	end

	if definition.condition then
		local ctx = context or {}
		ctx.subject = subject
		ctx.ability = id
		if not definition.condition(ctx) then
			return false, "condition"
		end
	end

	return true, nil
end

function Ability.use(subject: string, id: string, context: any?): (boolean, string?)
	local ok, reason = Ability.canUse(subject, id, context)
	if not ok then
		Events.emit("ability.refused", { subject = subject, ability = id, reason = reason })
		return false, reason
	end

	local definition = definitions[id] :: Definition
	local ctx = context or {}
	ctx.subject = subject
	ctx.ability = id
	ctx.definition = definition

	if definition.cost and spendResource then
		for kind, amount in definition.cost do
			spendResource(subject, kind, amount)
		end
	end

	local map = subjectCooldowns(subject)
	if definition.charges then
		local charges = chargeState[subject] or {}
		chargeState[subject] = charges
		charges[id] = Ability.charges(subject, id) - 1
		-- a spent charge starts its own refill timer
		task.delay(definition.cooldown, function()
			charges[id] = math.min(definition.charges :: number, (charges[id] or 0) + 1)
		end)
	else
		map[id] = os.clock() + definition.cooldown
	end

	if definition.globalCooldown then
		globalUntil[subject] = os.clock() + definition.globalCooldown
	end

	Events.emit("ability.started", { subject = subject, ability = id })
	if definition.onStart then
		pcall(definition.onStart, ctx)
	end

	local function fire()
		casting[subject] = nil
		if definition.run then
			local success, err = pcall(definition.run, ctx)
			if not success then
				warn(string.format("[Ability] '%s' errored: %s", id, tostring(err)))
			end
		end
		Events.emit("ability.used", { subject = subject, ability = id })
	end

	if definition.cast > 0 then
		-- A cast window is interruptible by design: that is what makes a
		-- telegraph mean something.
		casting[subject] = { ability = id, until_ = os.clock() + definition.cast, ctx = ctx }
		task.delay(definition.cast, function()
			local current = casting[subject]
			if current and current.ability == id then
				fire()
			end
		end)
	else
		fire()
	end

	return true, nil
end

function Ability.cancel(subject: string, reason: string?)
	local current = casting[subject]
	if not current then
		return false
	end
	casting[subject] = nil
	local definition = definitions[current.ability]
	if definition and definition.onCancel then
		pcall(definition.onCancel, current.ctx)
	end
	Events.emit("ability.cancelled", { subject = subject, ability = current.ability, reason = reason })
	return true
end

function Ability.isCasting(subject: string): boolean
	return casting[subject] ~= nil
end

function Ability.clearSubject(subject: string)
	cooldowns[subject] = nil
	chargeState[subject] = nil
	casting[subject] = nil
	globalUntil[subject] = nil
end

function Ability.describe(): { [string]: any }
	local castingCount = 0
	for _ in casting do
		castingCount += 1
	end
	return {
		defined = Ability.ids(),
		casting = castingCount,
		hasResourceResolver = getResource ~= nil,
	}
end

return Ability
