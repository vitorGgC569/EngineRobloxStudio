--!strict
--[[
	Destruction — things coming apart, on a budget.

	Every game wants breakable scenery and almost none ship it, because the
	naive version is a trap: a crate that shatters into forty unanchored parts
	is forty new physics bodies, replicated to every client, and a room full of
	crates is a server that stops. The interesting problem is not how to break
	something — it is how to break a hundred things and still hold a frame.

	So the whole module is built around a budget:

	  * a global cap on live debris, oldest recycled first;
	  * shards that sleep and anchor once they stop moving, so their physics
	    cost is one frame each rather than forever;
	  * a fade and a lifetime, because debris that persists is debris that
	    accumulates for the whole session.

		Destruction.define("crate", {
			shards = 8, spread = 14, life = 6,
			material = Enum.Material.WoodPlanks,
		})

		Destruction.break_(crate, { from = hitPosition })

	--- What this deliberately does not do -----------------------------------

	Real fracture. Voronoi shattering of arbitrary geometry is expensive to
	compute and worse to replicate, and at Roblox's scale nobody can tell it
	from a handful of well-thrown boxes tinted to match. The shards here are
	sampled from the source object's own parts, so a stone crate throws stone
	and a wooden one throws wood without anybody authoring either.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Destruction = {}

export type Recipe = {
	shards: number?,
	spread: number?,
	life: number?,
	upward: number?,
	spin: number?,
	scale: number?,
	material: Enum.Material?,
	sleepAfter: number?,
}

Destruction.config = {
	--[[
		Total live debris, everywhere.

		The single number that decides whether this module is a feature or an
		outage. Past it, the oldest shard is recycled rather than a new one
		created, so a room full of breaking crates degrades into fewer shards
		per crate instead of into a frame budget nobody has.
	]]
	budget = 160,
	-- Anchored once it has stopped: a settled shard costs nothing.
	sleepAfter = 2.5,
	sleepSpeed = 1.5,
	life = 8,
}

local recipes: { [string]: Recipe } = {}
local live: { any } = {}
local conn: RBXScriptConnection? = nil
local totals = { broken = 0, shards = 0, recycled = 0 }

function Destruction.define(name: string, recipe: Recipe)
	recipes[name] = recipe
end

function Destruction.defineMany(table_: { [string]: Recipe })
	for name, recipe in table_ do
		recipes[name] = recipe
	end
end

function Destruction.recipe(name: string): Recipe?
	return recipes[name]
end

-- ================================== debris ==================================
local function container(): Folder
	local existing = Workspace:FindFirstChild("Effects")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "Effects"
	folder.Parent = Workspace
	return folder
end

local function retire(entry: any)
	if entry.part and entry.part.Parent then
		entry.part:Destroy()
	end
	entry.part = nil
end

--[[
	Make room, oldest first.

	Recycling rather than refusing: a crate that breaks into nothing because
	the budget was full reads as a bug, whereas a crate that breaks into three
	shards instead of eight reads as distance.
]]
local function makeRoom(needed: number)
	while #live + needed > Destruction.config.budget and #live > 0 do
		retire(table.remove(live, 1))
		totals.recycled += 1
	end
end

local function watch()
	if conn then
		return
	end
	conn = RunService.Heartbeat:Connect(function()
		local now = os.clock()
		for index = #live, 1, -1 do
			local entry = live[index]
			local part = entry.part
			if not part or not part.Parent then
				table.remove(live, index)
				continue
			end

			if now - entry.born > entry.life then
				retire(entry)
				table.remove(live, index)
				continue
			end

			--[[
				Sleep what has stopped.

				A shard that has come to rest is still a simulated body until
				something says otherwise, and a hundred resting bodies cost
				roughly what a hundred moving ones do. Anchoring on stillness is
				the difference between debris you can afford and debris you
				cannot.
			]]
			if not entry.asleep
				and now - entry.born > entry.sleepAfter
				and part.AssemblyLinearVelocity.Magnitude < Destruction.config.sleepSpeed then
				part.Anchored = true
				entry.asleep = true
			end

			-- Fade over the last second rather than vanishing.
			local remaining = entry.life - (now - entry.born)
			if remaining < 1 then
				part.Transparency = 1 - math.max(0, remaining)
			end
		end

		if #live == 0 and conn then
			conn:Disconnect()
			conn = nil
		end
	end)
end

-- =================================== break ==================================
local function sampleParts(subject: Instance): { BasePart }
	local parts = {}
	if subject:IsA("BasePart") then
		table.insert(parts, subject)
	end
	for _, d in subject:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
		end
	end
	return parts
end

--[[
	Break something apart.

	The shards inherit colour and material from the object's own parts, so a
	stone wall throws stone and a wooden crate throws wood with nothing
	authored per object. `from` is where the blow came from: debris that flies
	away from the impact reads as caused, debris that flies in every direction
	reads as an explosion.

	Returns how many shards were actually made, which is not always what was
	asked for — the budget has the final say.
]]
function Destruction.break_(subject: Instance, options: any?): number
	local opts = options or {}
	local recipe: Recipe = recipes[opts.recipe or subject.Name] or {}

	local source = sampleParts(subject)
	if #source == 0 then
		return 0
	end

	local centre = source[1].Position
	if subject:IsA("Model") then
		centre = subject:GetPivot().Position
	end

	local wanted = opts.shards or recipe.shards or 6
	makeRoom(wanted)
	local room = math.max(0, Destruction.config.budget - #live)
	local count = math.min(wanted, room)

	local spread = opts.spread or recipe.spread or 16
	local upward = opts.upward or recipe.upward or 12
	local life = opts.life or recipe.life or Destruction.config.life
	local sleepAfter = opts.sleepAfter or recipe.sleepAfter or Destruction.config.sleepAfter
	local scale = opts.scale or recipe.scale or 1
	local from = opts.from

	local parent = container()
	for index = 1, count do
		local donor = source[((index - 1) % #source) + 1]

		local shard = Instance.new("Part")
		shard.Name = "Shard"
		shard.Size = Vector3.new(
			math.max(0.2, donor.Size.X * 0.22 * scale * (0.6 + math.random() * 0.8)),
			math.max(0.2, donor.Size.Y * 0.22 * scale * (0.6 + math.random() * 0.8)),
			math.max(0.2, donor.Size.Z * 0.22 * scale * (0.6 + math.random() * 0.8))
		)
		shard.Color = donor.Color
		shard.Material = opts.material or recipe.material or donor.Material
		shard.CanCollide = false
		shard.CastShadow = false
		shard.CFrame = CFrame.new(centre + Vector3.new(
			(math.random() - 0.5) * donor.Size.X,
			(math.random() - 0.5) * donor.Size.Y,
			(math.random() - 0.5) * donor.Size.Z
		)) * CFrame.Angles(math.random() * 6.28, math.random() * 6.28, math.random() * 6.28)
		shard.Parent = parent

		local away
		if from then
			local push = shard.Position - from
			away = push.Magnitude > 0.01 and push.Unit or Vector3.new(0, 1, 0)
		else
			away = Vector3.new(math.random() - 0.5, 0, math.random() - 0.5)
			away = away.Magnitude > 0.01 and away.Unit or Vector3.new(1, 0, 0)
		end

		shard.AssemblyLinearVelocity = away * spread * (0.6 + math.random() * 0.8)
			+ Vector3.new(0, upward * (0.5 + math.random()), 0)
		shard.AssemblyAngularVelocity = Vector3.new(
			(math.random() - 0.5) * 2, (math.random() - 0.5) * 2, (math.random() - 0.5) * 2
		) * (opts.spin or recipe.spin or 14)

		table.insert(live, {
			part = shard,
			born = os.clock(),
			life = life,
			sleepAfter = sleepAfter,
			asleep = false,
		})
	end

	totals.broken += 1
	totals.shards += count
	watch()

	if opts.destroy ~= false then
		subject:Destroy()
	end
	return count
end

function Destruction.clear()
	for _, entry in live do
		retire(entry)
	end
	table.clear(live)
end

function Destruction.liveCount(): number
	return #live
end

function Destruction.describe(): { [string]: any }
	local asleep = 0
	for _, entry in live do
		if entry.asleep then
			asleep += 1
		end
	end
	return {
		context = RunService:IsServer() and "server" or "client",
		recipes = (function()
			local names = {}
			for name in recipes do
				table.insert(names, name)
			end
			table.sort(names)
			return names
		end)(),
		live = #live,
		asleep = asleep,
		budget = Destruction.config.budget,
		broken = totals.broken,
		shards = totals.shards,
		recycled = totals.recycled,
	}
end

return Destruction
