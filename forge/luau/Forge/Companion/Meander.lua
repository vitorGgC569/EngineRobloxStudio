--!strict
--[[
	Meander — what a follower does while nothing is happening.

	Why this exists at all
	----------------------

	A squad that holds perfect formation while its leader stands still reads as
	furniture. The shipped system this comes from puts it plainly: followers
	should drift near their slot "so they don't just stand there -- frozen
	statues unless they're in combat".

	It is the cheapest possible aliveness. No animation, no AI, no pathfinding:
	pick a point near the slot, walk to it, wait, pick another. What makes it
	work is entirely in the timing:

	  * **It waits for the leader, not for itself.** Strolling begins only after
	    the *leader* has been still for a couple of seconds. A follower that
	    wanders the moment it reaches its slot is a follower that never arrives.

	  * **Each one desyncs.** The pause between strolls is randomised per
	    follower, so a group of six does not step off together. Synchronised
	    idling is more obviously mechanical than no idling at all.

	  * **It surrenders instantly.** The moment the leader moves or the follower
	    is given something to do, the target snaps back to the slot. Anything
	    that has to finish its stroll first is a follower that lags a step
	    behind for ever.

	Purely cosmetic, and best run on the client: nothing here is authoritative,
	and replicating a wander is paying for jitter.
]]

local Meander = {}

export type Config = {
	enabled: boolean?,
	--: How long the leader must be still before anyone strolls.
	leaderStillSeconds: number?,
	--: How far from its slot a follower will wander.
	radius: number?,
	--: Studs per second while strolling. Keep this above whatever speed the
	--: mover uses to decide facing, or a strolling follower walks sideways.
	speed: number?,
	pauseMin: number?,
	pauseMax: number?,
}

export type State = {
	--: Nil while holding formation; a point in leader space while strolling.
	targetX: number?,
	targetZ: number?,
	--: Seconds left before the next stroll begins.
	waiting: number,
	--: Kept so a follower's rhythm is its own and stays its own.
	seed: number,
}

local DEFAULTS = {
	enabled = true,
	leaderStillSeconds = 2,
	radius = 6,
	speed = 4,
	pauseMin = 1.5,
	pauseMax = 4,
}

local function setting(config: Config?, key: string): any
	local value = config and (config :: any)[key]
	if value ~= nil then
		return value
	end
	return (DEFAULTS :: any)[key]
end

--[[
	One follower's wandering state.

	The initial wait is randomised rather than zero, so a squad that spawns
	together does not take its first step together.
]]
function Meander.new(seed: number?, config: Config?): State
	local low = setting(config, "pauseMin")
	local high = setting(config, "pauseMax")
	local key = seed or math.random()
	return {
		targetX = nil,
		targetZ = nil,
		waiting = low + (high - low) * ((key * 0.6180339887) % 1),
		seed = key,
	}
end

--[[
	Advance one follower, and say where it should be heading.

	`leaderStillFor` is the leader's stillness, not this follower's -- the
	distinction is the whole behaviour. `busy` is anything that outranks
	idling: a target, an order, a fight.

	Returns the offset from the follower's formation slot, in leader space.
	Zero means "stand in your slot", which is also what it returns the instant
	the leader moves.
]]
function Meander.step(state: State, dt: number, leaderStillFor: number,
                      busy: boolean, config: Config?): (number, number)
	if not setting(config, "enabled") or busy then
		state.targetX = nil
		state.targetZ = nil
		return 0, 0
	end

	if leaderStillFor < setting(config, "leaderStillSeconds") then
		--[[
			The leader moved, so everyone goes home immediately.

			Not "walks home" -- the target is cleared and the mover's own
			easing carries the follower back. A follower that finishes its
			stroll first is permanently a step behind the group.
		]]
		state.targetX = nil
		state.targetZ = nil
		return 0, 0
	end

	if state.targetX == nil then
		state.waiting -= dt
		if state.waiting > 0 then
			return 0, 0
		end

		--: A point in the disc around the slot. Square-rooting the radius
		--: keeps the distribution even instead of clustering at the centre.
		local radius = setting(config, "radius")
		local angle = ((state.seed * 12.9898 + os.clock() * 0.7) % 1) * math.pi * 2
		local distance = radius * math.sqrt((state.seed * 78.233 + os.clock() * 0.3) % 1)
		state.targetX = math.cos(angle) * distance
		state.targetZ = math.sin(angle) * distance
		return state.targetX, state.targetZ
	end

	--: Arrival is decided in the mover, which knows where the follower really
	--: is. This only decides when to pick the next point, and it does that by
	--: distance travelled at the stroll speed.
	local speed = setting(config, "speed")
	local travelled = speed * dt
	local x, z = state.targetX :: number, state.targetZ :: number
	local remaining = math.sqrt(x * x + z * z)

	if remaining <= travelled then
		state.targetX = nil
		state.targetZ = nil
		local low = setting(config, "pauseMin")
		local high = setting(config, "pauseMax")
		--: Re-randomised every time, so followers that happen to sync up drift
		--: apart again rather than staying locked.
		state.waiting = low + (high - low) * ((state.seed * 4.7 + os.clock()) % 1)
		return 0, 0
	end

	return x, z
end

function Meander.describe(): { [string]: any }
	return { defaults = DEFAULTS }
end

return Meander
