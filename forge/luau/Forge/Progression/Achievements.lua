--!strict
--[[
	Achievements — a thing you did once, remembered for ever.

	Not quests, and the difference matters
	--------------------------------------

	`QuestEngine` runs objectives that are given, tracked and completed, and a
	completed quest is over. An achievement is the opposite shape: nobody hands
	it out, it watches counters that already exist, it fires once in a player's
	lifetime, and it stays. "Kill 10,000 enemies" is not a quest anybody
	accepted; it is a number that eventually crosses a line.

	That difference produces the two properties everything here is built on:

	  **Once, ever.** A player who has it does not get it again — not on
	  rejoin, not when the counter passes the threshold a second time, not when
	  an admin resets something. Awarding twice is worse than not awarding: it
	  is silent inflation of whatever the reward was.

	  **Retroactive.** A game adds an achievement for something players have
	  been doing for months. Their counters already qualify. It must fire on
	  next login, or the veterans — the people who most deserve it — are the
	  only ones who never get it.

		Achievements.define("slayer", { stat = "kills", target = 10000 })
		Achievements.evaluate(player, profile)   --> { "slayer" }

	Tiers, because one number is rarely one achievement
	--------------------------------------------------

	Kill 100, 1,000, 10,000. Declared as one achievement with thresholds rather
	than three achievements, so the progress bar knows what the next rung is
	and the definition does not repeat itself twice.
]]

local Achievements = {}

export type Definition = {
	id: string,
	label: string,
	stat: string,
	tiers: { number },
	hidden: boolean,
	reward: any?,
}

local definitions: { [string]: Definition } = {}
local order: { string } = {}

-- ================================= defining =================================
--[[
	Declare an achievement over a counter the game already keeps.

	`stat` names a field on the profile. This module never counts anything
	itself — a counter it owned would be a second number to keep in step with
	the real one, and the two would diverge the first time something awarded
	kills without going through here.
]]
function Achievements.define(id: string, spec: any)
	local tiers = spec.tiers
	if not tiers then
		tiers = { tonumber(spec.target) or 1 }
	end
	table.sort(tiers)

	if not definitions[id] then
		table.insert(order, id)
	end
	definitions[id] = {
		id = id,
		label = tostring(spec.label or id),
		stat = tostring(spec.stat),
		tiers = tiers,
		--[[
			Hidden achievements are shown only once earned.

			For anything whose name is a spoiler. They still appear in the
			earned list — hiding it after the fact would deny the player the
			one thing they earned.
		]]
		hidden = spec.hidden == true,
		reward = spec.reward,
	}
end

function Achievements.defineMany(table_: { [string]: any })
	for id, spec in table_ do
		Achievements.define(id, spec)
	end
end

-- ================================ evaluating ================================
--[[
	Where a profile records what it has already earned.

	Kept as `{ [id] = highestTier }` rather than a list of strings, so a tiered
	achievement remembers how far it got in one field, and asking "have they
	got tier 2" is a comparison rather than a scan.
]]
local function earnedTable(profile: any): { [string]: number }
	local earned = profile.achievements
	if typeof(earned) ~= "table" then
		earned = {}
		profile.achievements = earned
	end
	return earned
end

--[[
	Award everything this profile now qualifies for, and nothing twice.

	Returns the tiers crossed *this call*, so a caller can announce them. An
	empty list is the normal answer and costs a walk of the definitions, which
	is why this belongs on meaningful events and on login rather than in a
	heartbeat.

	Retroactive by construction: it compares the counter against the tiers with
	no memory of when the counter moved, so an achievement added today fires
	tomorrow for everybody who already qualified.
]]
function Achievements.evaluate(profile: any): { any }
	local earned = earnedTable(profile)
	local awarded = {}

	for _, id in order do
		local definition = definitions[id]
		local value = tonumber(profile[definition.stat]) or 0
		local already = earned[id] or 0

		for index, threshold in definition.tiers do
			if index <= already then
				continue
			end
			if value >= threshold then
				earned[id] = index
				table.insert(awarded, {
					id = id,
					label = definition.label,
					tier = index,
					tiers = #definition.tiers,
					threshold = threshold,
					reward = definition.reward,
				})
			else
				-- Tiers are sorted, so the first one not met ends this
				-- achievement. Continuing would award tier 3 to somebody who
				-- has not reached tier 2.
				break
			end
		end
	end

	return awarded
end

--: Has this player got it, at any tier?
function Achievements.has(profile: any, id: string, tier: number?): boolean
	local earned = earnedTable(profile)
	return (earned[id] or 0) >= (tier or 1)
end

--[[
	What is left, and how close they are.

	The shape an achievements screen wants: current value, the next rung, and
	the fraction between them. Hidden ones that are not yet earned are left
	out, which is what hidden means.
]]
function Achievements.progress(profile: any): { any }
	local earned = earnedTable(profile)
	local out = {}

	for _, id in order do
		local definition = definitions[id]
		local tier = earned[id] or 0
		if definition.hidden and tier == 0 then
			continue
		end

		local value = tonumber(profile[definition.stat]) or 0
		local next_ = definition.tiers[tier + 1]
		table.insert(out, {
			id = id,
			label = definition.label,
			stat = definition.stat,
			value = value,
			tier = tier,
			tiers = #definition.tiers,
			nextThreshold = next_,
			complete = tier >= #definition.tiers,
			-- Clamped, because a counter well past the last tier would
			-- otherwise render as a bar four times too long.
			fraction = next_ and math.clamp(value / next_, 0, 1) or 1,
		})
	end
	return out
end

function Achievements.describe(): { [string]: any }
	local tiered = 0
	for _, id in order do
		if #definitions[id].tiers > 1 then
			tiered += 1
		end
	end
	return {
		defined = #order,
		tiered = tiered,
		stats = (function()
			local seen: { [string]: boolean } = {}
			local list = {}
			for _, id in order do
				local stat = definitions[id].stat
				if not seen[stat] then
					seen[stat] = true
					table.insert(list, stat)
				end
			end
			table.sort(list)
			return list
		end)(),
	}
end

function Achievements.reset()
	table.clear(definitions)
	table.clear(order)
end

return Achievements
