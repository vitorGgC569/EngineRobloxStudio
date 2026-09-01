--!strict
--[[
	Loot — what is in the buildings, and how often.

	Shared so the client can name what it is standing over without asking, and
	so a test can exercise the tables without a world existing.

	Why loot lives in the ruins and not on the ground
	-------------------------------------------------

	A shooter's map is a set of arguments about where to go. Scattering ammunition
	evenly removes every one of them: nowhere is worth the walk. Putting it in
	four buildings means the buildings are worth the walk, the walk is
	dangerous, and the map has an opinion.

	Rarity is per container, not per item
	-------------------------------------

	A crate has a table; the table decides. That is one indirection more than
	rolling an item directly and it buys the thing the genre actually needs: a
	locker that only ever holds ammunition and a weapon rack that never does,
	so a player learns to read a room instead of opening everything.
]]

local Loot = {}

export type Drop = { id: string, kind: string, amount: number?, weight: number }

export type Container = {
	id: string,
	label: string,
	--: How many rolls this container makes when opened.
	rolls: number,
	--: Seconds before it can be looted again. Long enough that clearing a
	--: building means something and short enough that the map has a rhythm.
	respawn: number,
	drops: { Drop },
}

--[[
	Three containers, and they mean different things.

	`crate` is the common one and mostly pays ammunition -- a reason to enter a
	room, not a reason to cross the map. `locker` is the weapon source. `case`
	is rare, sits in one place per building, and is the reason two players
	arrive at the same doorway.
]]
Loot.containers = ({
	{
		id = "crate", label = "Supply Crate", rolls = 2, respawn = 90,
		drops = {
			{ id = "ammo.light", kind = "ammo", amount = 30, weight = 340 },
			{ id = "ammo.heavy", kind = "ammo", amount = 20, weight = 170 },
			{ id = "ammo.shell", kind = "ammo", amount = 12, weight = 120 },
			{ id = "bandage", kind = "heal", amount = 1, weight = 210 },
			{ id = "m9", kind = "gun", weight = 60 },
			{ id = "mp5", kind = "gun", weight = 22 },
		},
	},
	{
		id = "locker", label = "Arms Locker", rolls = 1, respawn = 180,
		drops = {
			{ id = "mp5", kind = "gun", weight = 200 },
			{ id = "m4", kind = "gun", weight = 120 },
			{ id = "m870", kind = "gun", weight = 110 },
			{ id = "sks", kind = "gun", weight = 44 },
			{ id = "m24", kind = "gun", weight = 9 },
			{ id = "ammo.heavy", kind = "ammo", amount = 40, weight = 160 },
		},
	},
	{
		--: One per building, and worth crossing the valley for. The M24 is
		--: only really available here, which is what makes the four buildings
		--: contested rather than convenient.
		id = "case", label = "Sealed Case", rolls = 3, respawn = 300,
		drops = {
			{ id = "m4", kind = "gun", weight = 120 },
			{ id = "sks", kind = "gun", weight = 90 },
			{ id = "m24", kind = "gun", weight = 46 },
			{ id = "armour", kind = "armour", amount = 50, weight = 130 },
			{ id = "medkit", kind = "heal", amount = 1, weight = 110 },
			{ id = "ammo.heavy", kind = "ammo", amount = 60, weight = 190 },
		},
	},
} :: any) :: { Container }

local byId: { [string]: Container } = {}
for _, container in Loot.containers do
	byId[container.id] = container
end

function Loot.container(id: string): Container?
	return byId[id]
end

--[[
	One roll from a container's table.

	`roll` is supplied rather than drawn, so what a crate contains is
	reproducible from a seed and the whole distribution can be exercised in a
	test with no random number generator involved.
]]
function Loot.roll(container: Container, roll: number): Drop
	local total = 0
	for _, drop in container.drops do
		total += drop.weight
	end
	local target = math.clamp(roll, 0, 0.999999) * total
	local acc = 0
	for _, drop in container.drops do
		acc += drop.weight
		if target < acc then
			return drop
		end
	end
	return container.drops[#container.drops]
end

--: Everything one opening produces. Rolls are independent, so a crate can pay
--: the same thing twice -- which is honest, and which is why `rolls` is small.
function Loot.open(container: Container, rng: () -> number): { Drop }
	local out = {}
	for _ = 1, container.rolls do
		table.insert(out, Loot.roll(container, rng()))
	end
	return out
end

--: What fraction of a container's rolls are guns. The number that decides
--: whether a building is worth entering, and the one worth asserting on.
function Loot.gunChance(container: Container): number
	local total, guns = 0, 0
	for _, drop in container.drops do
		total += drop.weight
		if drop.kind == "gun" then
			guns += drop.weight
		end
	end
	return if total > 0 then guns / total else 0
end

function Loot.describe(): { [string]: any }
	local out = {}
	for _, container in Loot.containers do
		out[container.id] = {
			rolls = container.rolls, respawn = container.respawn,
			gunChance = math.floor(Loot.gunChance(container) * 100),
			kinds = #container.drops,
		}
	end
	return out
end

return Loot
