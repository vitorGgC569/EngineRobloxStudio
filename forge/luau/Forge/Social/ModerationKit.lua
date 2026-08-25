--!strict
--[[
	ModerationKit — decaying suspicion score with verdicts.

	Reports accumulate severity points with timestamps; the score decays
	linearly so old sins fade, and thresholds map to verdicts. The state
	is serializable, so history rides inside the offender's own save.
]]

local ModerationKit = {}

export type Report = {
	severity: number,
	at: number,
}

export type Verdict = "clean" | "warn" | "ban"

type Self = {
	warnThreshold: number,
	banThreshold: number,
	decayPerHour: number,
	clock: () -> number,
	history: { [number]: { Report } },
}

ModerationKit.__index = ModerationKit

function ModerationKit.new(config: {
	warnThreshold: number?,
	banThreshold: number?,
	decayPerHour: number?,
	clock: (() -> number)?,
}): Self
	local ban = config.banThreshold or 25
	return setmetatable({
		warnThreshold = config.warnThreshold or math.max(1, math.floor(ban * 0.4)),
		banThreshold = ban,
		decayPerHour = config.decayPerHour or 1,
		clock = config.clock or os.time,
		history = {},
	}, ModerationKit)
end

function ModerationKit.report(self: Self, userId: number, severity: number): ()
	assert(severity >= 1 and severity <= 5, "severity is 1..5")
	self.history[userId] = self.history[userId] or {}
	table.insert(self.history[userId], { severity = severity, at = self.clock() })
end

function ModerationKit.score(self: Self, userId: number): number
	local reports = self.history[userId]
	if not reports then
		return 0
	end
	local now = self.clock()
	local total = 0
	for _, report in reports do
		local hours = math.max(0, (now - report.at) / 3600)
		local value = report.severity - hours * self.decayPerHour
		if value > 0 then
			total += value
		end
	end
	return total
end

-- Drops fully decayed entries; keeps the serializable state small.
function ModerationKit.compact(self: Self, userId: number): ()
	local reports = self.history[userId]
	if not reports then
		return
	end
	local now = self.clock()
	local kept: { Report } = {}
	for _, report in reports do
		local value = report.severity - math.max(0, (now - report.at) / 3600) * self.decayPerHour
		if value > 0 then
			table.insert(kept, report)
		end
	end
	self.history[userId] = kept
end

function ModerationKit.verdict(self: Self, userId: number): Verdict
	local score = self:score(userId)
	if score >= self.banThreshold then
		return "ban"
	elseif score >= self.warnThreshold then
		return "warn"
	end
	return "clean"
end

return ModerationKit
