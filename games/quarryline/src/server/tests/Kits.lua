--!strict
--[[
	Live scenarios for the harvested library.

	Why this file exists
	--------------------

	Extraction is easy to declare and hard to be sure of. The harvester reported
	two hundred and sixty-one pieces shelved and every one of them was true on
	disk -- and eighty-nine animations, thirty-nine tools and fourteen HUDs were
	still unreachable from Luau, because `Catalog.fromKit` had been written when
	a kit held nothing but props and answered only for `Model` and `BasePart`.

	Nothing in a file count catches that. The only thing that catches it is
	asking the running game for a piece and seeing whether one comes back.

	So these assert reachability, not inventory. A shelf that empties because
	somebody re-harvested is a tuning change; a shelf that cannot be read at all
	is the library not existing.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Catalog = Forge.Catalog
local Debug = Forge.Debug

return function(Testing)

--[[
	Absent kits are not a failure; unreachable ones are.

	This asserted that a shelf exists, which made it a test of what the *place*
	ships rather than of whether the engine can read a kit. The published build
	deliberately ships none -- the machines are built from code and no game
	logic touches a harvested piece, so mounting 130MB of somebody else's
	content into a live experience buys nothing.

	What is worth asserting is the reachability, and that only means anything
	when there is something to reach. So: skip when the place has no kits, and
	fail hard when it has them and cannot read them.
]]
Testing.scenario("the mounted kits are visible to the engine", function(t)
	local shelves = Catalog.kitShelves()
	local mounted = ReplicatedStorage:FindFirstChild("Kits")
	if not mounted or #mounted:GetChildren() == 0 then
		Debug.info("no kits mounted in this place; shelf checks skipped")
		return
	end
	t:expect(#shelves > 0,
		"kits are mounted in ReplicatedStorage but the Catalog reports no shelf")
	Debug.info(string.format("shelves: %s", table.concat(shelves, ", ")))
end)

Testing.scenario("every shelf hands back a real instance", function(t)
	--[[
		The class each shelf must answer for.

		This is the exact assertion that was missing. A `Tool` is not a `Model`
		and a `KeyframeSequence` is not a `BasePart`, so a lookup hardcoded to
		props returns nil for three of these five and reports nothing wrong.
	]]
	local expected = {
		character = "Model",
		prop = "Model",
		tool = "Tool",
		--: Keyframe data, which plays.
		animation = "KeyframeSequence",
		--: A pointer at an upload on somebody else's account, which does not.
		--: Shelved apart precisely so the difference is countable.
		["animation-id"] = "Animation",
		gui = "ScreenGui",
		vehicle = "Model",
	}

	--[[
		Same rule as the scenario above, and it was missed there.

		That one learned to skip a place with no kits; this one kept asserting
		that at least three shelves answer, so a build that deliberately ships
		without kits failed on a library it never claimed to have. Fixing half
		of a wrong assumption leaves a test that is wrong in a narrower way.
	]]
	local mounted = ReplicatedStorage:FindFirstChild("Kits")
	if not mounted or #mounted:GetChildren() == 0 then
		Debug.info("no kits mounted in this place; reachability checks skipped")
		return
	end

	local checked = 0
	for _, shelf in Catalog.kitShelves() do
		local names = Catalog.kitShelf(shelf)
		if #names == 0 then
			continue
		end
		local className = expected[shelf]
		t:expect(className ~= nil,
			string.format("shelf '%s' has no expected class; the harvester grew a "
				.. "category this test does not know about", shelf))

		--[[
			`expect` records; it does not abort.

			So the line after a failed nil-check still runs, and indexing the
			nil it just reported turns a clear failure message into
			"attempt to index nil with 'IsA'" -- which is this scenario
			obscuring its own finding.
		]]
		local piece = Catalog.fromKit(names[1], className)
		if not piece then
			t:expect(false, string.format(
				"%s/%s is mounted but Catalog.fromKit(%q, %q) returned nil",
				shelf, names[1], names[1], className))
			continue
		end

		t:expect(piece:IsA(className), string.format(
			"%s/%s came back as a %s, not a %s", shelf, names[1],
			piece.ClassName, className))
		piece:Destroy()
		checked += 1
	end

	t:expect(checked >= 3,
		"fewer than three shelves answered; the library is mounted but not usable")
	Debug.info(string.format("%d shelves answered with a live instance", checked))
end)

Testing.scenario("a harvested character is a character, not a pile of parts", function(t)
	--[[
		A rig with no Humanoid is scenery.

		The harvester classifies on exactly this, so if a shelf called
		`character` hands back something without one, the classifier and the
		shelf have drifted apart and every enemy in the library is furniture.
	]]
	local names = Catalog.kitShelf("character")
	if #names == 0 then
		Debug.info("no character shelf mounted in this place")
		return
	end

	local withHumanoid = 0
	for index = 1, math.min(#names, 6) do
		local rig = Catalog.fromKit(names[index], "Model")
		if rig then
			if rig:FindFirstChildOfClass("Humanoid") then
				withHumanoid += 1
			end
			rig:Destroy()
		end
	end

	t:expect(withHumanoid > 0, string.format(
		"none of the first %d pieces on the character shelf has a Humanoid",
		math.min(#names, 6)))
	Debug.info(string.format("%d of %d sampled rigs carry a Humanoid",
		withHumanoid, math.min(#names, 6)))
end)

end
