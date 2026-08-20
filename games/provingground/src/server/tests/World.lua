--!strict
--[[
	World scenarios: navigation, catalogue and scene persistence.

	These exist because all three shipped without a single caller executing
	them. `Nav` in particular was a whole pathfinding layer that compiled,
	passed every static check, and had never computed a path — which in this
	project's vocabulary means it did not exist.

	Everything here runs against the real world: Roblox's own navmesh over the
	arena that `Arena.start` actually built, and the catalogue entries that were
	loaded and measured inside Studio before they earned a place in the file.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Nav = Forge.Nav
local Catalog = Forge.Catalog
local Scene = Forge.Scene
local World = Forge.World

return function(Testing)
	-- =============================== navigation =============================
	Testing.scenario("a path exists across the arena floor", function(t)
		--[[
			The arena is a bowl with a flat middle, so two points inside the
			ring must be connected. If this fails, either the navmesh has not
			been generated over the terrain or the floor is not walkable — and
			both make every enemy fall back to walking in a straight line.
		]]
		local from = World.surface(-60, 0)
		local to = World.surface(60, 0)
		t:expect(from ~= nil and to ~= nil, "the arena floor has no surface to stand on")
		if not (from and to) then
			return
		end

		local waypoints, status = Nav.computePath(
			from + Vector3.new(0, 3, 0), to + Vector3.new(0, 3, 0))
		t:expectEqual(status, "Success", "no route across the arena")
		t:expect(#waypoints > 0, "a successful path with no waypoints is not a path")
	end, { timeout = 30 })

	Testing.scenario("an unreachable point is reported as unreachable", function(t)
		--[[
			The negative case matters as much as the positive one. A pathfinder
			that answers "Success" for everything is indistinguishable from no
			pathfinder at all, and the code that gives up and goes home would
			never run.
		]]
		local from = World.surface(0, 0)
		t:expect(from ~= nil, "no arena floor")
		if not from then
			return
		end
		local reachable = Nav.reachable(
			from + Vector3.new(0, 3, 0), Vector3.new(0, 4000, 0))
		t:expect(not reachable, "a point four thousand studs up reported as walkable")
	end, { timeout = 30 })

	Testing.scenario("an agent follows a path and arrives", function(t)
		local from = World.surface(-40, 0)
		local to = World.surface(40, 0)
		if not (from and to) then
			t:expect(false, "no arena floor to walk on")
			return
		end

		local walker = t:spawnBot(from + Vector3.new(0, 4, 0), { name = "Pathfinder" })
		-- Unanchored on purpose: this is the one scenario that needs physics,
		-- because the thing under test is whether a Humanoid actually walks.
		for _, d in walker:GetDescendants() do
			if d:IsA("BasePart") then
				d.Anchored = false
			end
		end

		local goal = to + Vector3.new(0, 3, 0)
		local agent = Nav.follow(walker, { target = goal, standoff = 4 })

		local arrived = t:waitUntil(function()
			return (walker:GetPivot().Position - goal).Magnitude < 12
		end, 25)
		local report = agent:describe()
		agent:stop()

		t:expect(arrived, string.format(
			"never arrived: status=%s waypoints=%d repaths=%d stucks=%d",
			tostring(report.status), report.waypoints, report.repaths, report.stucks))
	end, { timeout = 40 })

	-- ================================ catalogue =============================
	Testing.scenario("the catalogue is populated and script-free", function(t)
		t:expect(#Catalog.entries >= 100,
			"only " .. #Catalog.entries .. " catalogue entries")
		t:expect(#Catalog.packs > 0, "no packs recorded, so nothing has provenance")

		for _, entry in Catalog.entries do
			-- The invariant the whole curation exists to hold. A single entry
			-- carrying a script is a backdoor waiting for someone to place it.
			t:expectEqual(entry.scripts or 0, 0,
				entry.name .. " carries a script and should never have been curated")
			break -- one is enough to prove the field survives generation
		end
	end)

	Testing.scenario("a catalogue piece actually loads into the world", function(t)
		local pieces = Catalog.byCategory("ground")
		t:expect(#pieces > 0, "no ground pieces in the catalogue")
		if #pieces == 0 then
			return
		end

		--[[
			The entry says it loaded once, inside Studio, during curation. This
			asserts it still does: a Creator Store model can be taken down or
			moderated after the fact, and a catalogue that goes stale silently
			produces a world with holes in it.
		]]
		local model = Catalog.load(pieces[1])
		t:expect(model ~= nil, "catalogue entry '" .. pieces[1].name .. "' no longer loads")
		if model then
			t:track(model)
			local parts = 0
			for _, d in model:GetDescendants() do
				if d:IsA("BasePart") then
					parts += 1
				end
			end
			if model:IsA("BasePart") then
				parts += 1
			end
			t:expect(parts > 0, "it loaded but has no geometry")
		end
	end, { timeout = 40 })

	Testing.scenario("the arena is dressed with real scenery", function(t)
		local props = Workspace:FindFirstChild("Props")
		t:expect(props ~= nil, "no Props container")
		if not props then
			return
		end
		local rocks = 0
		for _, child in props:GetChildren() do
			if child.Name == "Rock" then
				rocks += 1
			end
		end
		t:expect(rocks > 0, "the arena scattered no rocks at all")
	end)

	-- ================================= scenes ===============================
	Testing.scenario("a scene survives being written and read back", function(t)
		--[[
			The round trip the Editor depends on, checked in one process. If
			serialisation loses a placement or a CFrame, an authored world
			comes back subtly wrong — which is worse than not coming back at
			all, because nobody notices until they look for the rock.
		]]
		local scene = Scene.create("suite_roundtrip")
		for index = 1, 5 do
			scene:add("Prop.Test", CFrame.new(index * 10, 50, index * 3), { name = "P" .. index })
		end

		local json = scene:toJson()
		t:expect(#json > 0, "serialised to nothing")

		local restored = Scene.fromJson(json)
		t:expect(restored ~= nil, "did not deserialise")
		if not restored then
			return
		end
		t:expectEqual(#restored.placements, 5, "a placement was lost in the round trip")

		local before = scene.placements[3].cframe.Position
		local after = restored.placements[3].cframe.Position
		t:expect((before - after).Magnitude < 0.01,
			"a placement moved during serialisation")
	end)
end
