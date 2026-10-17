--!strict
--[[
	Dress — the yard, made of things instead of boxes.

	Why this exists
	---------------

	The first playable build was a courtyard of coloured `Part`s: a slab for
	the floor, four rectangles for walls, cylinders for trainees. Every system
	worked, eleven scenarios passed, and a player who opened it said it had
	nothing in it. They were right, and the reason is written in this
	repository's own guide: **untextured boxes are the single most common
	reason a Roblox project reads as unfinished.**

	The fix cost nothing, which is the embarrassing part. `Forge.Catalog.ItchAssets`
	holds 538 CC0 models across 48 topics, 236 of them measured as carrying
	real colour, **already published to this account** -- so
	`InsertService:LoadAsset` works on them where it refuses almost every
	Creator Store id. `Place.put` picks one for a topic, loads it, scales it to
	a sane height, tints it if it arrived grey, and puts it down.

	What is dressed, and with what
	------------------------------

	    the altar        `altar`   -- there is literally one, and it is textured
	    the lanterns     `torch`
	    the clutter      `barrel`, `crate`, `bench`
	    outside          `bush`, `tree`, `rock`, `flower`
	    the trainees     **not from here** -- `Forge.Rig`, see below

	The trainees were tried from this catalogue first, on the `armor` topic,
	because all eleven of its models are measured as textured. They are armour
	*pieces*, and scaling a thigh guard to a person's height produced eleven
	white blobs. The lesson is narrower than "the catalogue is wrong": a topic
	name says what a model is *of*, not what shape it is, and the only way to
	find that out was to put one down and look at it.

	What it must not do
	-------------------

	**Never fail the game because an asset did not arrive.** `LoadAsset` is a
	network call against a service that has bad minutes. Every placement here
	falls back to the box that was there before, so a yard with no network is
	the yard from the last build rather than an empty plot -- and
	`Dress.report()` says how many actually landed, because inferring that from
	"no errors" is how you ship a grey game believing it is dressed.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Content = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Content"))

local Place = Forge.Catalog.Place
local ItchAssets = Forge.Catalog.ItchAssets
local Rng = Forge.Core.Rng
local Rig = Forge.Rig

local Dress = {}

--: Counted, not assumed. See the header.
local landed = 0
local asked = 0

local stream = Rng.stream("shonenyard.dress")

--[[
	One dressed thing, or nothing.

	`solid = false` by default and left that way for scenery: a player who can
	walk through a bush is not a bug worth a collision mesh per shrub, and a
	yard whose decoration blocks movement is a yard players get stuck in.
]]
local function put(topic: string, at: Vector3, parent: Instance,
                   options: any?): Instance?
	local o = options or {}
	asked += 1
	local model = Place.put(ItchAssets, {
		topic = topic,
		seed = math.floor(at.X * 73 + at.Z * 149 + (o.seed or 0)),
		at = at,
		parent = parent,
		yaw = o.yaw or stream:number(0, math.pi * 2),
		jitter = o.jitter,
		solid = o.solid,
		sizes = o.sizes,
	})
	if model ~= nil then
		landed += 1
	end
	return model
end

function Dress.report(): { [string]: any }
	return {
		asked = asked,
		landed = landed,
		--: The number that matters. A dressed yard is not "no errors", it is
		--: this being close to one.
		rate = if asked > 0 then landed / asked else 0,
		catalogue = ItchAssets.describe and ItchAssets.describe() or nil,
	}
end

-- ================================================================== the yard

--[[
	Scenery around the courtyard, outside the walls.

	Placed on a ring rather than scattered over a square, because what this is
	for is the horizon a player sees over the wall from inside -- and a random
	scatter puts most of its work where nobody looks.
]]
function Dress.surroundings(root: Instance, origin: Vector3, court: number)
	local folder = Instance.new("Folder")
	folder.Name = "Scenery"
	folder.Parent = root

	local half = court / 2
	for index = 1, 34 do
		local angle = index / 34 * math.pi * 2 + stream:number(-0.06, 0.06)
		local radius = half + stream:number(16, 78)
		local at = origin + Vector3.new(
			math.cos(angle) * radius, -1.6, math.sin(angle) * radius)

		--: Weighted toward trees and bushes: a treeline reads as a place, and
		--: a rock every third object reads as a quarry.
		local roll = stream:number()
		local topic = if roll < 0.42 then "tree"
			elseif roll < 0.74 then "bush"
			elseif roll < 0.88 then "rock"
			else "flower"
		put(topic, at, folder, { jitter = stream:number(0.85, 1.35) })
	end
end

--[[
	The courtyard's own clutter.

	Barrels and crates along the inside of the walls, benches facing in. This
	is what separates a training yard from a car park: the same floor with
	things somebody left on it.
]]
function Dress.clutter(root: Instance, origin: Vector3, court: number)
	local folder = Instance.new("Folder")
	folder.Name = "Clutter"
	folder.Parent = root

	local half = court / 2
	for index = 1, 14 do
		local along = stream:number(-half + 12, half - 12)
		local side = if stream:number() < 0.5 then -1 else 1
		local wall = if stream:number() < 0.5 then "x" else "z"
		local at = if wall == "x"
			then origin + Vector3.new(side * (half - 7), 0.4, along)
			else origin + Vector3.new(along, 0.4, side * (half - 7))
		local roll = stream:number()
		put(if roll < 0.45 then "barrel" elseif roll < 0.8 then "crate" else "bench",
			at, folder, { solid = false })
	end
end

--: Lanterns at the entrance and the corners. The one thing in the list that is
--: about light rather than about clutter, so it gets a real point light.
function Dress.lanterns(root: Instance, origin: Vector3, court: number)
	local folder = Instance.new("Folder")
	folder.Name = "Lanterns"
	folder.Parent = root

	local half = court / 2
	local spots = {
		Vector3.new(-17, 0, -half + 3), Vector3.new(17, 0, -half + 3),
		Vector3.new(-half + 8, 0, -half + 8), Vector3.new(half - 8, 0, -half + 8),
		Vector3.new(-half + 8, 0, half - 8), Vector3.new(half - 8, 0, half - 8),
	}
	for index, offset in spots do
		local at = origin + offset + Vector3.new(0, 1.2, 0)
		local torch = put("torch", at, folder, { seed = index * 31, jitter = 1.5 })
		--: The light regardless of whether the model arrived. A yard lit only
		--: where an asset happened to load is a yard whose lighting depends on
		--: the network.
		local anchor = Instance.new("Part")
		anchor.Name = "LanternGlow" .. index
		anchor.Size = Vector3.new(0.4, 0.4, 0.4)
		anchor.Position = at + Vector3.new(0, 4, 0)
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.Transparency = 1
		anchor.Parent = folder

		local light = Instance.new("PointLight")
		--: Six of these ring the yard. At 2.2 each they summed into a second
		--: sun; at 0.8 they are lanterns, which is what they are.
		light.Color = Color3.fromRGB(255, 186, 126)
		light.Brightness = 0.8
		light.Range = 18
		light.Parent = anchor
	end
end

-- =============================================================== the altar

--[[
	The real altar, on top of the plinth the blockout already built.

	The box stays underneath: it is the plinth, it has the prompt on it, and it
	is what the player walks up to. What changes is that the thing on top is a
	carved altar rather than a red rectangle.
]]
function Dress.altar(root: Instance, at: Vector3): Instance?
	local folder = Instance.new("Folder")
	folder.Name = "AltarDressing"
	folder.Parent = root
	return put("altar", at, folder, { seed = 7, jitter = 2.2, solid = false })
end

-- ============================================================== the trainees

--[[
	A real fighter per trainee, built from the engine rather than fetched.

	The first attempt used the `armor` topic on the grounds that all eleven of
	its models carry texture. What those models actually are is armour
	*pieces* -- `Armorthigh`, `Armorceinturethighs` -- and `Scale` dutifully
	sized a thigh guard to a person's height, so each trainee became a
	five-stud white blob floating over its pad. Textured, correctly scaled to
	the target, and completely wrong.

	`Forge.Rig` is the engine's own answer and it is better in every way that
	matters here: no network call, no scaling guess, a silhouette that is a
	person, and every knob the rarity needs already on the spec.

	How rarity reads, in four channels rather than one
	--------------------------------------------------

	    colour    the palette the reveal card and the HUD already use
	    size      a mythic stands a head above a common
	    weapon    staff at 5, greatsword at 4, sword at 3, none below
	    glow      rarity 4 and up carry it

	Four channels because a courtyard is looked at from thirty studs away in
	bad light, and colour alone at that distance is a grey figure next to a
	slightly different grey figure.
]]

--: Rarity to the engine's rig knobs. One table, so the world, the reveal card
--: and the HUD cannot disagree about what rare looks like.
local LOOK = {
	[1] = { colour = Color3.fromRGB(148, 152, 162), scale = 0.86, weapon = nil },
	[2] = { colour = Color3.fromRGB(104, 190, 126), scale = 0.92, weapon = nil },
	[3] = { colour = Color3.fromRGB(88, 158, 232), scale = 1.00, weapon = "sword" },
	[4] = { colour = Color3.fromRGB(206, 142, 62), scale = 1.10, weapon = "greatsword",
	        glow = true },
	[5] = { colour = Color3.fromRGB(226, 88, 108), scale = 1.24, weapon = "staff",
	        glow = true, spikes = true },
}

function Dress.trainee(parent: Instance, at: Vector3, fighterId: string,
                       facing: Vector3): boolean
	local fighter = Content.fighter(fighterId)
	if fighter == nil then
		return false
	end
	local look = LOOK[fighter.rarity] or LOOK[1]

	local ok, model = pcall(function()
		return Rig.build({
			name = fighter.name,
			scale = look.scale,
			shape = "biped",
			body = look.colour,
			accent = look.colour:Lerp(Color3.new(1, 1, 1), 0.35),
			eyes = if look.glow then Color3.fromRGB(255, 236, 190) else nil,
			glow = look.glow,
			spikes = look.spikes,
			weapon = look.weapon,
			--: Scenery, not an obstacle. A yard whose trainees block the
			--: walkway is a yard players get stuck in, and the pads are on the
			--: route between the altar and the rank stone.
			collide = false,
			detail = fighter.rarity >= 3,
		})
	end)
	if not ok or model == nil then
		return false
	end

	--: Anchored, because nothing here should be simulated. Twelve unanchored
	--: rigs standing on pads is a physics bill for a decoration, and one of
	--: them will eventually fall over and stay that way.
	for _, part in (model :: Model):GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
		end
	end

	local yaw = math.atan2(facing.X, facing.Z)
	;(model :: Model):PivotTo(CFrame.new(at) * CFrame.Angles(0, yaw, 0))
	model.Parent = parent
	landed += 1
	asked += 1
	return true
end

return Dress
