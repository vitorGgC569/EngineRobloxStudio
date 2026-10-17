--!strict
--[[
	Beaconmile — the shift, played against Sim.

	No player and no road. Each scenario starts from Sim.newProfile and only
	moves that table through Sim, so a pass is the rule and not a copy of a
	tunable.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Sim = require(Shared:WaitForChild("Sim"))

return function(Testing)
	Testing.scenario("taking coal once fills the hands and a second take is refused", function(t)
		local profile = Sim.newProfile()
		local ok = Sim.takeCoal(profile)
		t:expect(ok == true, "a new profile could not take coal")
		t:expect(profile.carried == 1, "a take did not pick up one coal")

		local again = Sim.takeCoal(profile)
		t:expect(again ~= true, "a second take was accepted")
		t:expect(profile.carried == 1, "a refused take changed the load")
		t:expect(profile.carried >= Config.carryMax, "the refusal was not the carry cap")
	end)

	Testing.scenario("feeding bend spends the coal and lengthens that beacon", function(t)
		local profile = Sim.newProfile()
		Sim.takeCoal(profile)
		local before = profile.beacons.bend
		t:expect(type(before) == "number", "bend is not a beacon")

		local ok = Sim.feed(profile, "bend")
		t:expect(ok == true, "bend refused a carried coal")
		t:expect(profile.carried == 0, "feeding bend kept the coal")
		local grown = math.min(before + Config.beacon.feedSeconds, Config.beacon.burnCap)
		t:expect(profile.beacons.bend == grown, "bend did not gain the configured feed")
		t:expect((profile.beacons.bend :: number) > before, "bend did not get longer")
	end)

	Testing.scenario("a beacon already at the cap refuses the coal", function(t)
		local profile = Sim.newProfile()
		Sim.takeCoal(profile)
		profile.beacons.bend = Config.beacon.burnCap
		local carried = profile.carried
		local ok = Sim.feed(profile, "bend")
		t:expect(ok ~= true, "a full beacon accepted coal")
		t:expect(profile.carried == carried, "a full beacon spent coal")
		t:expect(profile.beacons.bend == Config.beacon.burnCap, "a refused feed changed the cap")
	end)

	Testing.scenario("feeding an unknown beacon is refused and keeps the coal", function(t)
		local profile = Sim.newProfile()
		Sim.takeCoal(profile)
		local carried = profile.carried
		local bend = profile.beacons.bend

		local ok = Sim.feed(profile, "nope")
		t:expect(ok ~= true, "an unknown beacon accepted coal")
		t:expect(profile.carried == carried, "a refused feed spent coal")
		t:expect(profile.beacons.bend == bend, "a refused feed changed bend")
	end)

	Testing.scenario("a tick that empties a beacon loses the shift", function(t)
		local profile = Sim.newProfile()
		local longest = 0
		for _, remaining in profile.beacons do
			if remaining > longest then
				longest = remaining
			end
		end
		Sim.tick(profile, longest)
		t:expect(profile.outcome == "lost", "emptying a beacon did not lose the shift")
		local out = false
		for _, remaining in profile.beacons do
			if remaining <= 0 then
				out = true
			end
		end
		t:expect(out, "the tick did not empty a beacon")
	end)

	Testing.scenario("a shift that keeps every beacon lit is won", function(t)
		local profile = Sim.newProfile()
		for id, remaining in profile.beacons do
			profile.beacons[id] = remaining + Config.shiftSeconds
		end
		Sim.tick(profile, Config.shiftSeconds)
		t:expect(profile.outcome == "won", "a lit shift was not won")
		t:expect(profile.elapsed >= Config.shiftSeconds, "the win arrived before the shift length")
		for _, remaining in profile.beacons do
			t:expect(remaining > 0, "a beacon went out during the winning tick")
		end
	end)

	Testing.scenario("a step past the clock does not burn fuel after the win", function(t)
		local profile = Sim.newProfile()
		profile.elapsed = Config.shiftSeconds - 0.1
		for id in profile.beacons do
			profile.beacons[id] = 0.2
		end
		Sim.tick(profile, 0.25)
		t:expect(profile.outcome == "won", "the shift should end while the beacons are still lit")
		for _, remaining in profile.beacons do
			t:expect(remaining > 0, "fuel after the finish line was burned")
		end
	end)
end
