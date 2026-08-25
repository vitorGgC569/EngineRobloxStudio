--!strict
--[[
	RoundMachine — pure round-phase state machine emitting effects.

	A match is a loop of named phases (WAITING -> INTERMISSION -> ACTIVE ->
	ROUND_END). The machine owns only time and phase index; every real
	consequence comes back as an effect list the caller applies, which
	keeps it headless-testable in milliseconds and replayable from any
	seed or clock.

		local rm = RoundMachine.new({ phases = {
			{ name = "INTERMISSION", duration = 5 },
			{ name = "ACTIVE", duration = 90 },
			{ name = "ROUND_END", duration = 4 },
		}, rounds = 10 })

		for _, effect in rm:tick(dt) do apply(effect) end
]]

local RoundMachine = {}

export type Phase = {
	name: string,
	duration: number,
}

export type Config = {
	phases: { Phase },
	rounds: number?,
}

export type Effect = {
	kind: string,
	phase: string?,
	iteration: number,
}

type State = {
	index: number,
	elapsed: number,
	iteration: number,
	entering: boolean,
}

type Self = {
	phases: { Phase },
	totalRounds: number?,
	state: State,
	finished: boolean,
}

RoundMachine.__index = RoundMachine

function RoundMachine.new(config: Config): Self
	assert(#config.phases > 0, "RoundMachine needs phases")
	for _, phase in config.phases do
		assert(phase.duration > 0, ("phase %q needs a positive duration"):format(phase.name))
	end
	return setmetatable({
		phases = config.phases,
		totalRounds = config.rounds,
		state = { index = 1, elapsed = 0, iteration = 1, entering = true },
		finished = false,
	}, RoundMachine)
end

function RoundMachine.current(self: Self): string?
	if self.finished then
		return nil
	end
	return self.phases[self.state.index].name
end

function RoundMachine.iteration(self: Self): number
	return self.state.iteration
end

function RoundMachine.remaining(self: Self): number
	if self.finished then
		return 0
	end
	return math.max(0, self.phases[self.state.index].duration - self.state.elapsed)
end

function RoundMachine.tick(self: Self, dt: number): { Effect }
	local effects: { Effect } = {}
	if self.finished then
		return effects
	end
	local st = self.state
	st.elapsed += dt

	if st.entering then
		table.insert(effects, { kind = "phase_enter", phase = self.phases[st.index].name, iteration = st.iteration })
		st.entering = false
	end

	while st.elapsed >= self.phases[st.index].duration do
		st.elapsed -= self.phases[st.index].duration
		table.insert(effects, { kind = "phase_exit", phase = self.phases[st.index].name, iteration = st.iteration })
		if st.index < #self.phases then
			st.index += 1
			table.insert(effects, { kind = "phase_enter", phase = self.phases[st.index].name, iteration = st.iteration })
		else
			table.insert(effects, { kind = "round_end", iteration = st.iteration })
			if self.totalRounds and st.iteration >= self.totalRounds then
				self.finished = true
				st.elapsed = 0
				break
			end
			st.iteration += 1
			st.index = 1
			table.insert(effects, { kind = "round_enter", iteration = st.iteration })
			table.insert(effects, { kind = "phase_enter", phase = self.phases[st.index].name, iteration = st.iteration })
		end
	end
	return effects
end

return RoundMachine
