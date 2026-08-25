--!strict
--[[
	GachaFlow — purchase-to-reveal state machine for loot boxes.

	The flow guards the classic gacha failure modes: double-click buys
	twice (reentrancy lock), the reveal skips the drama (staged timing
	plan), and a rare drop goes unnoticed (announce threshold). Pure
	states and a timing plan; the server performs the actual debit/roll.
]]

local GachaFlow = {}

export type Stage = "idle" | "purchasing" | "revealing" | "done"

export type RevealPlan = {
	stages: { { kind: string, duration: number } },
	announce: boolean,
}

type Self = {
	stage: Stage,
	reentrancy: boolean,
	announceThreshold: number,
	dramaticPause: number,
	spinDuration: number,
	lastRarity: number?,
}

GachaFlow.__index = GachaFlow

function GachaFlow.new(config: {
	announceThreshold: number?,
	dramaticPause: number?,
	spinDuration: number?,
}): Self
	return setmetatable({
		stage = "idle" :: Stage,
		reentrancy = false,
		announceThreshold = config.announceThreshold or 3,
		dramaticPause = config.dramaticPause or 0.6,
		spinDuration = config.spinDuration or 2,
		lastRarity = nil,
	}, GachaFlow)
end

-- Begin one opening; refuses while another is in flight.
function GachaFlow.begin(self: Self): boolean
	if self.reentrancy then
		return false
	end
	self.reentrancy = true
	self.stage = "purchasing"
	return true
end

function GachaFlow.commitPurchase(self: Self, rarityTier: number): ()
	assert(self.stage == "purchasing", "begin() first")
	self.lastRarity = rarityTier
	self.stage = "revealing"
end

function GachaFlow.abort(self: Self): ()
	self.stage = "idle"
	self.reentrancy = false
	self.lastRarity = nil
end

function GachaFlow.finish(self: Self): ()
	self.stage = "done"
	self.reentrancy = false
end

-- Presentation plan for the reveal; announce flips above threshold.
function GachaFlow.revealPlan(self: Self): RevealPlan
	local rarity = self.lastRarity or 1
	return {
		stages = {
			{ kind = "pause", duration = self.dramaticPause },
			{ kind = "spin", duration = self.spinDuration },
			{ kind = "reveal", duration = 0.2 },
		},
		announce = rarity >= self.announceThreshold,
	}
end

return GachaFlow
