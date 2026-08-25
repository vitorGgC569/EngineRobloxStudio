--!strict
--[[
	GameSession — multi-instance 2D game sessions on one screen.

	Splits, tests and demos run two games side by side: each session owns
	its frame, camera state and audio group name (unique per instance so
	audio does not cross). Pure bookkeeping of session identity/state.
]]

local GameSession = {}

export type SessionState = "created" | "loading" | "running" | "destroyed"

type Self = {
	id: string,
	slotIndex: number,
	state: SessionState,
	audioGroup: string,
	createdAt: number,
}

GameSession.__index = GameSession

local nextSlot = 1

function GameSession.new(config: { idPrefix: string?, clock: (() -> number)? }): Self
	local slot = nextSlot
	nextSlot += 1
	return setmetatable({
		id = (config.idPrefix or "session") .. "_" .. tostring(slot),
		slotIndex = slot,
		state = "created" :: SessionState,
		audioGroup = ("IsoAudioGroup_%d"):format(slot),
		createdAt = (config.clock or os.time)(),
	}, GameSession)
end

function GameSession.setState(self: Self, state: SessionState): ()
	assert(
		not (self.state == "destroyed" and state ~= "destroyed"),
		"cannot revive a destroyed session"
	)
	self.state = state
end

function GameSession.info(self: Self): { id: string, slot: number, state: SessionState }
	return { id = self.id, slot = self.slotIndex, state = self.state }
end

return GameSession
