--!strict
--[[
	QuestFocus — which of the day's errands the tracker should point at.

	Three quests are always in flight and the player has one pair of eyes,
	so "show them the quests" is not an answer; the tracker needs one. The
	rule this module implements: finish what is closest to done, because
	that is the action available right now. On a tie, take the richer
	reward, because that is the one a player regrets leaving.

	A quest that names no water (sell, rarity, variety, weather, perfect,
	big, mutation) is hunted in the deepest water the player owns. Callers
	pass `zones` in config order -- shallow to deep -- so the last element
	is that zone without anything here sorting anything.

	Pure on purpose: no requires, no engine types. The headless harness
	asserts the ranking with no Studio anywhere, and the client uses the
	exact function the tests do.
]]

local QuestFocus = {}

export type Focus = {
	id: string,
	kind: string,
	label: string,
	progress: number,
	target: number,
	fraction: number,
	done: boolean,
	zoneId: string,
	rewardCoins: number,
}

--[[
	Pick the focus, or nil when there is nothing left to chase.

	`progress` overrides the stored value per quest id when the caller is
	holding livelier numbers than the save (the client's copy can trail a
	ProfileSync by a frame). Claimed quests are invisible here: the tracker
	points at work, and the Quests board is where claiming already lives.
]]
function QuestFocus.pick(quests: { any }?, progress: { [string]: number }?, zones: { string }?): Focus?
	local fallbackZone = if zones and #zones > 0 then zones[#zones] else "shallows"
	local best: any = nil
	local bestFraction = -1
	local bestReward = -1

	for _, quest in quests or {} do
		if not quest.claimed then
			local target = math.max(tonumber(quest.target) or 1, 1)
			local value = tonumber((progress and progress[quest.id]) or quest.progress) or 0
			local fraction = math.min(value / target, 1)
			local reward = tonumber(quest.rewardCoins) or 0
			if fraction > bestFraction or (fraction == bestFraction and reward > bestReward) then
				best = quest
				bestFraction = fraction
				bestReward = reward
			end
		end
	end

	if not best then
		return nil
	end

	local target = math.max(tonumber(best.target) or 1, 1)
	local value = tonumber((progress and progress[best.id]) or best.progress) or 0
	return {
		id = tostring(best.id or "quest"),
		kind = tostring(best.kind or "zone"),
		label = tostring(best.label or "A day's work"),
		progress = math.min(value, target),
		target = target,
		fraction = math.min(value / target, 1),
		done = value >= target,
		zoneId = tostring(best.zoneId or fallbackZone),
		rewardCoins = tonumber(best.rewardCoins) or 0,
	}
end

--[[
	The tracker line: one sentence, a count, and -- when it is finished --
	where to go. Sales read in coins because their progress *is* money;
	everything else counts things, because that is what the quest asked
	for.
]]
function QuestFocus.line(focus: Focus?): string?
	if not focus then
		return nil
	end
	if focus.done then
		return string.format("%s -- claim it at the Quests board", focus.label)
	end
	local shown = if focus.kind == "sell"
		then "$" .. tostring(math.floor(focus.progress))
		else tostring(math.floor(focus.progress))
	return string.format("%s (%s/%d)", focus.label, shown, focus.target)
end

return QuestFocus
