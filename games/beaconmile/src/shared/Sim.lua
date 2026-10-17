--!strict
-- Beaconmile rules. No instances. Systems apply what this returns.

local Config = require(script.Parent.Config)

local Sim = {}

export type Profile = {
	version: number,
	carried: number,
	elapsed: number,
	outcome: string,
	beacons: { [string]: number },
}

local function beaconIds(): { string }
	local ids = {}
	for _, beacon in Config.beacons do
		table.insert(ids, beacon.id)
	end
	return ids
end

function Sim.beaconIds(): { string }
	return beaconIds()
end

function Sim.newProfile(): Profile
	local beacons = {}
	for _, id in beaconIds() do
		beacons[id] = Config.beacon.burnSeconds
	end
	return {
		version = 1,
		carried = 0,
		elapsed = 0,
		outcome = "running",
		beacons = beacons,
	}
end

function Sim.clone(profile: Profile): Profile
	local beacons = {}
	for id, remaining in profile.beacons do
		beacons[id] = remaining
	end
	return {
		version = profile.version,
		carried = profile.carried,
		elapsed = profile.elapsed,
		outcome = profile.outcome,
		beacons = beacons,
	}
end

function Sim.restart(profile: Profile)
	-- A finished shift must not load as a permanent game over. The same table
	-- stays in place so Save is still flushing the record it loaded.
	local fresh = Sim.newProfile()
	profile.version = fresh.version
	profile.carried = fresh.carried
	profile.elapsed = fresh.elapsed
	profile.outcome = fresh.outcome
	profile.beacons = fresh.beacons
end

function Sim.reopen(profile: Profile): (boolean, string?)
	if profile.outcome == "running" then
		return false, "running"
	end
	Sim.restart(profile)
	return true, nil
end

function Sim.takeCoal(profile: Profile): (boolean, string?)
	if profile.outcome ~= "running" then
		return false, "over"
	end
	if profile.carried >= Config.carryMax then
		return false, "full"
	end
	profile.carried += 1
	return true, nil
end

function Sim.feed(profile: Profile, beaconId: string): (boolean, string?)
	if profile.outcome ~= "running" then
		return false, "over"
	end
	if profile.beacons[beaconId] == nil then
		return false, "bad_id"
	end
	if profile.carried < 1 then
		return false, "empty"
	end
	-- Spending coal that cannot add burn time would empty the player's hands
	-- and leave the beacon where it was.
	if profile.beacons[beaconId] >= Config.beacon.burnCap then
		return false, "full"
	end
	profile.carried -= 1
	local nextRemaining = profile.beacons[beaconId] + Config.beacon.feedSeconds
	if nextRemaining > Config.beacon.burnCap then
		nextRemaining = Config.beacon.burnCap
	end
	profile.beacons[beaconId] = nextRemaining
	return true, nil
end

function Sim.tick(profile: Profile, dt: number)
	if profile.outcome ~= "running" then
		return
	end
	if dt < 0 then
		dt = 0
	end
	-- A step that runs past the clock must not also burn the fuel that was
	-- still there when the shift ended. The finish line is the shorter of
	-- the requested dt and the time left on the clock.
	local left = Config.shiftSeconds - profile.elapsed
	if left < dt then
		dt = left
	end
	if dt < 0 then
		dt = 0
	end
	profile.elapsed += dt
	local anyOut = false
	for id, remaining in profile.beacons do
		local nextRemaining = remaining - dt
		if nextRemaining < 0 then
			nextRemaining = 0
		end
		profile.beacons[id] = nextRemaining
		if nextRemaining <= 0 then
			anyOut = true
		end
	end
	if anyOut then
		profile.outcome = "lost"
	elseif profile.elapsed >= Config.shiftSeconds then
		profile.outcome = "won"
	end
end

return Sim
