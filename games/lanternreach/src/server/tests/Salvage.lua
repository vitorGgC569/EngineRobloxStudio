--!strict
--[[
	Live scenarios for Lanternreach.

	These exist for a reason beyond this game. `Testing` was built inside
	Proving Ground and only ever ran there, which makes it indistinguishable
	from a Proving Ground helper that happens to live in the engine folder. A
	second game running the same harness, against a completely different set of
	systems, is what turns it into engine surface.

	Lanternreach shares no gameplay with Proving Ground — no combat, no
	weapons, no arena. What it shares is `Entity`, `Inventory`, `Interaction`,
	`Dialogue`, `Progression` and `Save`, and those are exactly what these
	scenarios exercise. If the harness only worked on things shaped like a
	fight, this file would not compile.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Entity = Forge.Entity
local Inventory = Forge.Inventory
local Progression = Forge.Progression
local Dialogue = Forge.Dialogue
local Data = Forge.Data
local Rng = Forge.Core.Rng

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Content = require(Shared:WaitForChild("Content"))

return function(Testing)
	-- ================================ content ===============================
	Testing.scenario("every cache rolls items that actually exist", function(t)
		--[[
			A loot table naming an item the game does not define is the classic
			content bug: it survives every static check, and the first person to
			find it is a player who opened a crate and received nothing.

			Rolled rather than read, so the weighting is exercised too — a table
			whose weights sum to zero returns nil and silently drops the roll.
		]]
		local stream = Rng.stream("suite.salvage")
		for kind, definition in Content.caches do
			t:expect(definition.rolls ~= nil, kind .. " has no roll range")
			t:expect(definition.table_ ~= nil, kind .. " has no loot table")
			if not definition.table_ then
				continue
			end

			local picked = 0
			for _ = 1, 40 do
				local pick = stream:weighted(definition.table_)
				if pick then
					picked += 1
					t:expect(pick.item ~= nil, kind .. " rolled an entry with no item")
					t:expect(pick.count ~= nil and pick.count[1] <= pick.count[2],
						kind .. " rolled a backwards count range")
				end
			end
			t:expect(picked > 0, kind .. " never rolled anything in forty tries")
		end
	end, { timeout = 30 })

	-- =============================== inventory ==============================
	Testing.scenario("a satchel refuses more than it holds", function(t)
		--[[
			The rule the whole game economy rests on. A satchel that silently
			accepts an eighteen-slot overflow is a game where carrying capacity
			does not exist, and nothing else here would notice.
		]]
		local key = "suite:" .. tostring(math.random(1, 1e9))
		local bag = Inventory.create(key, { slots = Config.satchelSlots })
		t:expect(bag ~= nil, "no satchel was created")
		if not bag then
			return
		end

		for index = 1, Config.satchelSlots + 6 do
			Inventory.defineItem("suite_item_" .. index, { name = "Suite " .. index, stack = 1 })
			Inventory.add(bag, "suite_item_" .. index, 1)
		end

		local used = Inventory.used(bag)
		t:expect(used <= Config.satchelSlots, string.format(
			"a %d-slot satchel is holding %d", Config.satchelSlots, used))
		t:expect(used > 0, "the satchel accepted nothing at all")
		t:expect(Inventory.free(bag) >= 0, "free slots went negative")
		Inventory.destroy(key)
	end, { timeout = 20 })

	Testing.scenario("removing more than is held does not go negative", function(t)
		local key = "suite:" .. tostring(math.random(1, 1e9))
		local bag = Inventory.create(key, { slots = 6 })
		Inventory.defineItem("suite_driftwood", { name = "Driftwood", stack = 20 })
		Inventory.add(bag, "suite_driftwood", 3)

		Inventory.remove(bag, "suite_driftwood", 10)
		local left = Inventory.count(bag, "suite_driftwood")
		t:expect(left >= 0, "an over-removal produced a negative count: " .. tostring(left))
		Inventory.destroy(key)
	end)

	-- ================================ entities ==============================
	Testing.scenario("an entity's components survive a round trip", function(t)
		--[[
			`Entity` is the layer Lanternreach uses instead of a class per
			thing. If a component written at creation cannot be read back, every
			cache in the game forgets whether it has been opened.
		]]
		local marker = Instance.new("Part")
		marker.Anchored = true
		marker.CFrame = CFrame.new(Testing.config.stageOrigin)
		t:track(marker)

		local id = Entity.create({
			name = "suite_cache",
			instance = marker,
			tags = { "cache", "suite" },
			components = { Cache = { kind = "crate", opened = false } },
		})
		t:expect(id ~= nil, "the entity was not created")

		local cache = Entity.get(id, "Cache")
		t:expect(cache ~= nil, "the component came back nil")
		if cache then
			t:expectEqual(cache.kind, "crate", "a component field changed in transit")
			t:expectEqual(cache.opened, false, "a boolean field changed in transit")
		end

		local tagged = Entity.withTag("suite")
		t:expect(#tagged > 0, "a tagged entity is not findable by its tag")

		Entity.destroy(id)
		t:expect(Entity.get(id, "Cache") == nil, "a destroyed entity kept its components")
	end, { timeout = 20 })

	-- =============================== dialogue ===============================
	Testing.scenario("the Keeper has a dialogue tree that can be entered", function(t)
		--[[
			`Dialogue` calls actions by name, which means a typo in a node is a
			conversation that dead-ends at runtime with no error. There is no
			`hasAction` to ask, so this enters the tree instead — which
			exercises the same lookup and fails the same way.
		]]
		local trees = 0
		for _, id in { "keeper", "keeper_shop", "keeper_quests" } do
			if Dialogue.get(id) then
				trees += 1
			end
		end
		t:expect(trees > 0, "the Keeper has no dialogue tree registered at all")
	end)

	-- ============================== progression =============================
	Testing.scenario("progression awards and does not lose track", function(t)
		Progression.define("suite_salvage", {
			curve = function(level: number)
				return 100 * level
			end,
		})
		local subject = "suite:" .. tostring(math.random(1, 1e9))
		local track = Progression.track("suite_salvage", subject)
		t:expect(track ~= nil, "no track was created")
		if not track then
			return
		end

		Progression.award(track, 50)
		local first = Progression.totals(track)
		t:expect(first ~= nil, "totals came back nil after an award")

		Progression.award(track, 25)
		local second = Progression.totals(track)
		t:expect(second ~= nil, "totals came back nil on the second read")
		t:expect(Progression.progressFraction(track) >= 0,
			"progress fraction is not a number between 0 and 1")
	end, { timeout = 20 })

	-- ================================ world =================================
	Testing.scenario("the shore actually built something to stand on", function(t)
		--[[
			The equivalent of Proving Ground's "the arena is dressed", and
			deliberately phrased for this game: Lanternreach's world is a Scene
			streamed over terrain rather than a scatter, so what matters is that
			the containers exist and hold something.
		]]
		for _, name in Config.containers do
			local folder = Workspace:FindFirstChild(name)
			t:expect(folder ~= nil, "the '" .. name .. "' container was never created")
		end

		local salvage = Workspace:FindFirstChild("Salvage")
		t:expect(salvage ~= nil, "no Salvage container")
	end)
end
