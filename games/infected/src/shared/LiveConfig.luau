--!strict
-- Pure, validated apply-overrides logic for live (no-republish) config tuning. A
-- LiveConfigService loads an override table from a DataStore and hands it here to apply
-- onto the GameConfig table in place. Only whitelisted, type- and range-checked numeric
-- tunables are touched, so a malformed, stale, or hostile override can never break the
-- game — anything not whitelisted or out of range is rejected and reported, not applied.

local LiveConfig = {}

export type Rule = { min: number, max: number }

-- Whitelist of tunable dotted paths → allowed numeric range. Deliberately conservative:
-- timings, headcounts, and prices only; nothing that could soft-lock a round.
LiveConfig.Whitelist = {
	["Round.IntermissionSeconds"] = { min = 5, max = 120 },
	["Round.BaseRoundSeconds"] = { min = 60, max = 900 },
	["Round.MaxRoundSeconds"] = { min = 60, max = 1200 },
	["Round.SecondsPerConversion"] = { min = 0, max = 120 },
	["Round.MinPlayersToStart"] = { min = 1, max = 30 },
	["Bots.TargetPlayers"] = { min = 1, max = 15 },
	["Bots.MaxBots"] = { min = 0, max = 29 },
	["Economy.CrateCostCoins"] = { min = 50, max = 1000000 },
} :: { [string]: Rule }

local function setPath(config: any, dotted: string, value: number): boolean
	local parts = string.split(dotted, ".")
	local node = config
	for i = 1, #parts - 1 do
		node = node[parts[i]]
		if type(node) ~= "table" then
			return false
		end
	end
	node[parts[#parts]] = value
	return true
end

-- Apply `overrides` onto `config` (mutated in place) using `whitelist`. Returns which keys
-- were applied and which were rejected (with a reason), for logging.
-- Override a round-modifier's weight (enable/disable/reweight an EVENT) by id. Keys look
-- like "Modifier.blackout.weight". Weight 0 removes it from rotation. This is what makes
-- events config-driven with no republish.
local function applyModifierWeight(config: any, modId: string, value: any): (boolean, string?)
	if type(value) ~= "number" or value ~= value then
		return false, "not a number"
	end
	if value < 0 or value > 100 then
		return false, "out of range [0, 100]"
	end
	if type(config.RoundModifiers) ~= "table" then
		return false, "no modifiers"
	end
	for _, mod in config.RoundModifiers do
		if mod.id == modId then
			mod.weight = value
			return true
		end
	end
	return false, "unknown modifier"
end

function LiveConfig.apply(
	config: any,
	overrides: { [string]: any },
	whitelist: { [string]: Rule }
): { applied: { [string]: number }, rejected: { [string]: string } }
	local applied: { [string]: number } = {}
	local rejected: { [string]: string } = {}
	for key, value in overrides do
		local modId = string.match(key, "^Modifier%.(.+)%.weight$")
		local rule = whitelist[key]
		if modId then
			local ok, reason = applyModifierWeight(config, modId, value)
			if ok then
				applied[key] = value
			else
				rejected[key] = reason :: string
			end
		elseif rule == nil then
			rejected[key] = "not whitelisted"
		elseif type(value) ~= "number" then
			rejected[key] = "not a number"
		elseif value ~= value then -- NaN
			rejected[key] = "NaN"
		elseif value < rule.min or value > rule.max then
			rejected[key] = ("out of range [%s, %s]"):format(tostring(rule.min), tostring(rule.max))
		elseif setPath(config, key, value) then
			applied[key] = value
		else
			rejected[key] = "bad path"
		end
	end
	return { applied = applied, rejected = rejected }
end

return LiveConfig
