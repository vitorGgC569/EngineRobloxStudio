--!strict
-- Deterministic distance runner. The server owns time, energy and payouts;
-- presentation and theme belong to the caller. A finished run cannot pay twice.
local BarrierRun = {}
local Run = {}
Run.__index = Run

function BarrierRun.new(config: any, energy: number): any
	assert(energy == energy and energy >= 0 and energy < math.huge, "invalid energy")
	assert(config.speed > 0 and #config.gates > 0, "invalid course")
	local previous = 0
	for _, gate in config.gates do
		assert(gate.distance > previous and gate.cost > 0 and gate.reward >= 0, "invalid gate")
		previous = gate.distance
	end
	return setmetatable({config=config, energy=energy, initialEnergy=energy, distance=0,
		nextGate=1, broken=0, reward=0, finished=false, reason=nil}, Run)
end

function Run:step(dt: number): {any}
	assert(dt == dt and dt >= 0 and dt < math.huge, "invalid timestep")
	local events = {}
	if self.finished then return events end
	local destination = self.distance + self.config.speed * dt
	while self.nextGate <= #self.config.gates do
		local gate = self.config.gates[self.nextGate]
		if destination < gate.distance then break end
		self.distance = gate.distance
		if self.energy < gate.cost then
			self.finished = true; self.reason = "energy"
			return events
		end
		self.energy -= gate.cost
		self.reward += gate.reward
		self.broken += 1
		table.insert(events, {index=self.nextGate, distance=gate.distance, reward=gate.reward})
		self.nextGate += 1
	end
	local finish = self.config.gates[#self.config.gates].distance + 12
	self.distance = math.min(destination, finish)
	if self.distance >= finish then self.finished=true; self.reason="complete" end
	return events
end

function Run:cancel()
	self.finished=true; self.reason="cancelled"
end

return BarrierRun
