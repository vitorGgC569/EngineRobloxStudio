--!strict
--- Ready-made behaviours: attach one to geometry and it works.
---
---     Behaviours.World   doors, lifts, platforms, hazards, day and night
---     Behaviours.Play    pickups, chests, switches, checkpoints, rounds, shops
---     Behaviours.Life    health, spawners, guards, turrets, teams
---     Behaviours.Story   conversations, quests, NPCs who remember you
---     Behaviours.Combat  hitboxes, weapons, enemies, levels
---
--- **These are examples that happen to be finished.** Every one is forty to
--- eighty lines of ordinary Luau built on `Core`, and the intended use when one
--- does not fit is to copy it and change it — not to add another option.
---
--- Everything returns a handle with `destroy`, and everything owns a `Trove`,
--- so tearing one down really does disconnect what it made.

local Behaviours = {}

Behaviours.World = require(script.World)
Behaviours.Play = require(script.Play)
Behaviours.Life = require(script.Life)
Behaviours.Story = require(script.Story)
Behaviours.Combat = require(script.Combat)

--- What is available, without reading the source.
function Behaviours.catalogue(): { [string]: { string } }
	local out: { [string]: { string } } = {}
	for group, module in pairs(Behaviours) do
		if type(module) == "table" then
			local names = {}
			for name, value in pairs(module) do
				if type(value) == "function" then
					table.insert(names, name)
				end
			end
			table.sort(names)
			out[group] = names
		end
	end
	return out
end

return Behaviours
