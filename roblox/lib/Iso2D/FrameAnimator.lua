--!strict
--[[
	FrameAnimator — frame-based animation clock with groups.

	Animations are frame sequences with per-frame hold time, grouped by
	prefix ("Walk"/"Stay"/"Idle"); the animator owns only timing: which
	frame is visible now and whether the sequence looped. Presentation
	binds frames; tests verify the clock.
]]

local FrameAnimator = {}

export type Sequence = {
	frames: { string },
	holdSeconds: number,
	loop: boolean,
}

type Playback = {
	groupName: string,
	sequence: Sequence,
	startedAt: number,
}

type Self = {
	playback: Playback?,
	clock: () -> number,
}

FrameAnimator.__index = FrameAnimator

function FrameAnimator.new(clock: (() -> number)?): Self
	return setmetatable({ playback = nil, clock = clock or os.clock }, FrameAnimator)
end

function FrameAnimator.play(self: Self, groupName: string, sequence: Sequence): ()
	assert(#sequence.frames > 0, "sequence needs frames")
	assert(sequence.holdSeconds > 0, "hold must be positive")
	self.playback = { groupName = groupName, sequence = table.clone(sequence), startedAt = self.clock() }
end

function FrameAnimator.stop(self: Self): ()
	self.playback = nil
end

-- Returns { frame=..., loopCount=..., finished=bool } for the current time.
function FrameAnimator.present(self: Self): (string?, number?, boolean?)
	local playback = self.playback
	if not playback then
		return nil, nil, nil
	end
	local seq = playback.sequence
	local elapsed = self.clock() - playback.startedAt
	local frameIndex = math.floor(elapsed / seq.holdSeconds)
	if not seq.loop and frameIndex >= #seq.frames then
		return seq.frames[#seq.frames], 0, true
	end
	local index = (frameIndex % #seq.frames) + 1
	return seq.frames[index], math.floor(frameIndex / #seq.frames), false
end

return FrameAnimator
