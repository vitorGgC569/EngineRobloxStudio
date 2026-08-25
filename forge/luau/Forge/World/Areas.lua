--!strict
--[[
	Areas — where a player is allowed to be, and where they wake up.

	Every game with more than one place to stand needs the same four answers,
	and every one of them gets rebuilt badly per game:

	  which areas exist, and how they connect
	  whether this player may enter this one yet
	  where they were when they left
	  where they respawn if the answer to the third is "somewhere they can no
	  longer go"

	That last one is the one that bites. A player unlocks a zone, plays there,
	the zone is removed in an update or their unlock is revoked, and they
	respawn inside geometry that is no longer theirs — or worse, inside nothing
	at all. An area system that cannot answer "where should this player be
	*now*" is a fall through the world waiting to happen.

		Areas.define("crystal_caves", {
			requires = { level = 12 },
			from = { "hub" },
			spawn = CFrame.new(0, 40, 200),
		})

		Areas.mayEnter(player, "crystal_caves")   --> false, "needs level 12"
		Areas.enter(player, "crystal_caves")
		Areas.respawnFor(player)                  --> the best legal area

	Server-authoritative, and it has to be
	--------------------------------------

	Entry is a permission, so it is decided where permissions are decided.
	A client that asks to teleport is asking, not telling: `enter` re-checks
	every time rather than trusting that the UI only offered legal doors.
]]

local Signal = require(script.Parent.Parent.Core.Signal)

local Areas = {}

export type Area = {
	id: string,
	label: string,
	requires: { [string]: any },
	from: { string },
	spawn: CFrame?,
	safe: boolean,
}

local areas: { [string]: Area } = {}
local located: { [Player]: string } = {}
local order: { string } = {}

Areas.entered = Signal.new() -- (player, areaId, fromAreaId)
Areas.refused = Signal.new() -- (player, areaId, reason)

--[[
	How a requirement is checked.

	Injected rather than assumed, because "level 12" lives in whatever this
	game calls a profile and this module has no business knowing. The default
	reads an attribute, which is right often enough to be a useful default and
	obvious enough to be worth replacing.
]]
Areas.satisfies = function(player: Player, key: string, want: any): boolean
	local have = player:GetAttribute(key)
	if typeof(want) == "number" then
		return typeof(have) == "number" and have >= want
	end
	return have == want
end

-- ================================= defining =================================
function Areas.define(id: string, area: any?)
	local spec = area or {}
	if not areas[id] then
		table.insert(order, id)
	end
	areas[id] = {
		id = id,
		label = tostring(spec.label or id),
		requires = spec.requires or {},
		--[[
			Which areas this one can be reached from.

			Empty means "from anywhere", which is what a hub is. Naming the
			edges is what stops a player walking from the tutorial straight
			into the endgame because both had a door.
		]]
		from = spec.from or {},
		spawn = spec.spawn,
		--[[
			Whether this is somewhere a player can always be put.

			The fallback for `respawnFor`. A game needs at least one, and a
			game with none has nowhere to put a player whose area vanished.
		]]
		safe = spec.safe == true,
	}
end

function Areas.defineMany(table_: { [string]: any })
	for id, spec in table_ do
		Areas.define(id, spec)
	end
end

-- ================================ permission ================================
--[[
	May this player enter, and if not, why not.

	The reason is half the value. "You cannot go there" is a dead end; "needs
	level 12" is a goal, and it is the same string the UI should be showing on
	the locked door.
]]
function Areas.mayEnter(player: Player, id: string): (boolean, string?)
	local area = areas[id]
	if not area then
		return false, string.format("there is no area called '%s'", id)
	end

	for key, want in area.requires do
		if not Areas.satisfies(player, key, want) then
			return false, string.format("needs %s %s", key, tostring(want))
		end
	end

	if #area.from > 0 then
		local current = located[player]
		if not current or not table.find(area.from, current) then
			return false, string.format(
				"%s is only reachable from %s", area.label, table.concat(area.from, ", "))
		end
	end

	return true
end

--[[
	Move a player, if they are allowed.

	Re-checks rather than trusting the caller. The caller is usually a remote,
	and a remote is a request from somebody who may have written their own
	client.
]]
function Areas.enter(player: Player, id: string): (boolean, string?)
	local allowed, reason = Areas.mayEnter(player, id)
	if not allowed then
		Areas.refused:Fire(player, id, reason)
		return false, reason
	end

	local previous = located[player]
	located[player] = id
	Areas.entered:Fire(player, id, previous)
	return true
end

--: Put a player somewhere without asking. For admin moves and for recovery,
--: which are the two cases where the rules are the problem rather than the
--: guard.
function Areas.place(player: Player, id: string)
	local previous = located[player]
	located[player] = id
	Areas.entered:Fire(player, id, previous)
end

function Areas.locate(player: Player): string?
	return located[player]
end

function Areas.forget(player: Player)
	located[player] = nil
end

-- ================================ respawning ================================
--[[
	Where this player should be right now.

	Their own area if they may still be in it, otherwise the first safe area
	they qualify for, otherwise the first safe area at all. The cascade exists
	because every step of it happens: unlocks get revoked, areas get removed,
	and a player whose saved area no longer admits them still has to appear
	somewhere with a floor.

	Returns nil only when the game defines no safe area, which is a
	configuration error rather than a runtime one — and one worth finding at
	startup rather than at a respawn.
]]
function Areas.respawnFor(player: Player): (string?, CFrame?)
	local current = located[player]
	if current and areas[current] then
		local allowed = Areas.mayEnter(player, current)
		-- Checked ignoring the `from` edges: a player already standing in an
		-- area does not need a route into it, only the right to be there.
		local area = areas[current]
		local qualifies = true
		for key, want in area.requires do
			if not Areas.satisfies(player, key, want) then
				qualifies = false
				break
			end
		end
		if allowed or qualifies then
			return current, area.spawn
		end
	end

	for _, id in order do
		local area = areas[id]
		if area.safe then
			local qualifies = true
			for key, want in area.requires do
				if not Areas.satisfies(player, key, want) then
					qualifies = false
					break
				end
			end
			if qualifies then
				return id, area.spawn
			end
		end
	end

	for _, id in order do
		if areas[id].safe then
			return id, areas[id].spawn
		end
	end
	return nil, nil
end

-- ================================= reading ==================================
--: Everywhere this player could go from where they are, with reasons for the
--: places they cannot. The shape a map screen wants.
function Areas.availableTo(player: Player): { any }
	local out = {}
	for _, id in order do
		local allowed, reason = Areas.mayEnter(player, id)
		table.insert(out, {
			id = id,
			label = areas[id].label,
			allowed = allowed,
			reason = reason,
			current = located[player] == id,
		})
	end
	return out
end

function Areas.describe(): { [string]: any }
	local safe = {}
	for _, id in order do
		if areas[id].safe then
			table.insert(safe, id)
		end
	end
	local population: { [string]: number } = {}
	for _, id in located do
		population[id] = (population[id] or 0) + 1
	end
	return {
		areas = #order,
		safeAreas = safe,
		population = population,
		--[[
			A game with no safe area cannot respawn anybody.

			Surfaced rather than discovered: it is a one-line configuration
			mistake whose symptom is a player falling for ever.
		]]
		hasNowhereSafe = #safe == 0,
	}
end

function Areas.reset()
	table.clear(areas)
	table.clear(located)
	table.clear(order)
end

return Areas
