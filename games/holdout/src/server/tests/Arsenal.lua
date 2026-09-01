--!strict
--[[
	holdout — what has to stay true about the guns.

	Written before the shooting was, because an arsenal is a set of
	relationships and every one of them is silently breakable by a tuning pass.
	Two of these already caught something on the first run:

	  * The shotgun did 88 damage in a full hit -- twelve short of a kill -- so
	    it needed two shots at seventy rounds a minute and lost to every other
	    gun in the game at every range including point blank. A shotgun that
	    cannot end a fight up close is a tutorial weapon nobody chooses.

	  * The sniper did 105 and one-shot a body at six hundred studs, which left
	    nothing for a headshot to be worth and nothing for distance to cost.

	Neither is visible in the source and neither would have been felt for weeks.

	What these assert and what they do not
	--------------------------------------

	**Relationships, not numbers.** "The shotgun wins up close" survives every
	balance pass; "the shotgun does 13 a pellet" turns tuning into a red build.
	The exact figures live in `Arsenal` and are meant to move.

	**Time to kill is not the whole gun.** A sidearm loses on paper to every
	rifle and earns its place on handling -- how fast the sights come up and how
	much speed you keep behind them. The dominance check below therefore reads
	every hit zone, because a sniper that loses on body shots at every range is
	still the only gun that ends a fight with one headshot at any of them.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Arsenal = require(ReplicatedStorage.Shared.Arsenal)

local RANGES = { 8, 25, 50, 100, 200, 400, 800, 1600 }
local HEALTH = 100

return function(Testing)
	Testing.scenario("no gun is better than another everywhere", function(t)
		--[[
			Across every range *and* every hit zone. Body shots alone report
			the sniper as dominated by the pistol, which is true and useless:
			the sniper's whole role is the one thing that comparison cannot see.
		]]
		local beaten = {}
		for _, a in Arsenal.guns do
			for _, b in Arsenal.guns do
				if a.id == b.id then
					continue
				end
				local always = true
				for _, range in RANGES do
					for zone in Arsenal.ZONES do
						if Arsenal.timeToKill(a, HEALTH, range, zone)
								>= Arsenal.timeToKill(b, HEALTH, range, zone) then
							always = false
							break
						end
					end
					if not always then
						break
					end
				end
				if always then
					table.insert(beaten, a.name .. " beats " .. b.name .. " everywhere")
				end
			end
		end
		t:expect(#beaten == 0, table.concat(beaten, "; "))
	end)

	Testing.scenario("the shotgun ends a fight up close and cannot reach", function(t)
		local gun = Arsenal.get("m870")
		t:expect(gun ~= nil, "the shotgun is gone")
		if not gun then
			return
		end
		t:expect(Arsenal.shotsToKill(gun, HEALTH, 8, "torso") == 1,
			"a full hit at point blank does not kill")
		t:expect(Arsenal.shotsToKill(gun, HEALTH, 150, "torso") >= 3,
			"the shotgun still works at a hundred and fifty studs")

		--: And nothing else may take its corner. If a rifle kills as fast at
		--: eight studs, the shotgun has no reason to be picked up.
		local mine = Arsenal.timeToKill(gun, HEALTH, 8, "torso")
		for _, other in Arsenal.guns do
			if other.class ~= "shotgun" and other.class ~= "sniper" then
				t:expect(Arsenal.timeToKill(other, HEALTH, 8, "torso") >= mine,
					other.name .. " kills as fast as the shotgun point blank")
			end
		end
	end)

	Testing.scenario("the sniper owns the head at any distance", function(t)
		local gun = Arsenal.get("m24")
		if not gun then
			t:expect(false, "the sniper is gone")
			return
		end
		for _, range in RANGES do
			t:expect(Arsenal.shotsToKill(gun, HEALTH, range, "head") == 1,
				string.format("a headshot at %d studs did not kill", range))
		end
		--: And it must not do the same to a body, or range costs nothing and
		--: aim stops mattering.
		t:expect(Arsenal.shotsToKill(gun, HEALTH, 400, "torso") > 1,
			"the sniper one-shots a body at range")
	end)

	Testing.scenario("distance always costs and never pays", function(t)
		--: Falloff has to be monotonic. A gun that hits harder further away is
		--: a sign-flipped constant, and it is exactly the kind of thing that
		--: survives review and is felt as "this gun is weird".
		for _, gun in Arsenal.guns do
			local last = math.huge
			for _, range in RANGES do
				local now = Arsenal.falloff(gun, range)
				t:expect(now <= last + 1e-6,
					string.format("%s hits harder at %d studs than nearer",
						gun.name, range))
				t:expect(now > 0,
					string.format("%s does nothing at all at %d studs",
						gun.name, range))
				last = now
			end
			t:expect(Arsenal.falloff(gun, 0) == 1,
				gun.name .. " is not at full damage at zero range")
		end
	end)

	Testing.scenario("a head is worth more than a body and a body more than a limb",
		function(t)
			t:expect(Arsenal.ZONES.head.multiplier > Arsenal.ZONES.torso.multiplier,
				"a headshot is not worth more than a body shot")
			t:expect(Arsenal.ZONES.torso.multiplier > Arsenal.ZONES.limb.multiplier,
				"a limb is not worth less than a body")
			--: And a limb still has to matter. A multiplier low enough to be
			--: ignorable turns every fight into a torso-only game.
			t:expect(Arsenal.ZONES.limb.multiplier > 0.5,
				"limb shots are worth so little they may as well miss")
		end)

	Testing.scenario("aiming costs speed, and the heavier the gun the more",
		function(t)
			--: The trade that makes the arsenal a set of choices rather than a
			--: ladder. Without it the sniper is a rifle that also zooms.
			local order = { "m9", "mp5", "m4", "m870", "sks", "m24" }
			local lastMove, lastAds = math.huge, 0
			for _, id in order do
				local gun = Arsenal.get(id)
				if not gun then
					continue
				end
				t:expect(gun.moveScale < 1,
					gun.name .. " costs nothing to aim")
				t:expect(gun.adsSpread < gun.spread,
					gun.name .. " is no more accurate aimed than hip-fired")
				lastMove, lastAds = gun.moveScale, gun.adsSpeed
			end
			local light = Arsenal.get("m9")
			local heavy = Arsenal.get("m24")
			if light and heavy then
				t:expect(heavy.adsSpeed > light.adsSpeed,
					"the sniper comes up as fast as the pistol")
				t:expect(heavy.moveScale < light.moveScale,
					"the sniper is as mobile as the pistol")
				t:expect(heavy.adsZoom < light.adsZoom,
					"the sniper does not magnify more than the pistol")
			end
		end)

	Testing.scenario("every gun the arsenal names is complete", function(t)
		--: A gun missing a field reads as nil somewhere in `Fight` and produces
		--: a weapon that does no damage or fires forever, three systems away
		--: from the omission.
		local required = { "id", "name", "class", "damage", "rpm", "magazine",
			"reserve", "pellets", "range", "reload", "muzzle", "falloffStart",
			"falloffEnd", "falloffFloor", "spread", "adsSpread", "recoilUp",
			"recoilSide", "adsSpeed", "adsZoom", "moveScale", "penetration" }
		for _, gun in Arsenal.guns do
			for _, field in required do
				t:expect((gun :: any)[field] ~= nil,
					string.format("%s has no '%s'", gun.id, field))
			end
			t:expect(gun.falloffEnd > gun.falloffStart,
				gun.id .. " falls off before it starts")
			t:expect(gun.range >= gun.falloffEnd,
				gun.id .. " stops carrying before it stops falling off")
			t:expect(Arsenal.spec(gun).damage == gun.damage,
				gun.id .. " does not survive translation to the engine's shape")
		end
	end)
end
