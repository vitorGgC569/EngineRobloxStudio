--!strict
-- Pure movement-violation classifier (no Roblox services, unit-testable). Split out from
-- AntiCheatService so the escalation policy has tests. Given a player's horizontal
-- displacement over one check window, classify it:
--   "teleport" : a jump beyond the per-window teleport budget — a hard cheat, snap now
--   "speed"    : movement above the fastest legit speed for the window — escalate
--   "ok"       : within tolerance
-- Both thresholds scale with the window length so a legit sprinter is never false-flagged
-- over a longer window; teleportStuds > maxSpeed so teleport is always the severe tier.
-- Note: teleport and speed are SEPARATE triggers. The old service compared against
-- max(speedLimit, teleportBudget) as a single bar, which let a moderate (~1.5x) speed
-- hack slip through whenever the teleport budget sat above the speed limit.

local AntiCheatMath = {}

export type Verdict = "ok" | "speed" | "teleport"

function AntiCheatMath.classify(
	horizontal: number,
	interval: number,
	maxSpeed: number,
	teleportStuds: number
): Verdict
	if horizontal > teleportStuds * interval then
		return "teleport"
	end
	if horizontal > maxSpeed * interval then
		return "speed"
	end
	return "ok"
end

return AntiCheatMath
