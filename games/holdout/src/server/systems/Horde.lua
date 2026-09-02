--!strict
--[[
	Horde — the dead, and what they want.

	Built on `Forge.Actor`, `Forge.AI` and `Forge.Combat` rather than on a loop
	that calls `Humanoid:MoveTo` at the nearest player. That difference is
	visible from the first minute of play: this valley has six hundred trees,
	ninety rocks and four ruins in it, and a mob that walks straight at you
	presses into the first trunk between you and stays there for the rest of
	the round.

	Three of them, and why not one
	------------------------------

	A single enemy type means every fight is the same fight, and the only thing
	that changes is how many. The three here each break a different habit:

	  * **Walkers** are slow, weak and numerous. They are the pressure -- never
	    a threat alone, always a problem in six. They punish standing still.

	  * **Runners** are fast, fragile, and arrive before you have finished
	    dealing with the walkers. They punish reloading at the wrong moment,
	    which is the decision a shooter is actually made of.

	  * **Brutes** are slow, enormously tough and hit hard enough to end a
	    fight. They punish having stayed in a corridor, because a corridor is
	    exactly where you cannot walk around one.

	The mix is weighted so a player meets walkers constantly, runners often
	enough to stay honest, and a brute rarely enough that it is an event.

	Damage comes from `Combat`, not from a timer
	--------------------------------------------

	A zombie's swing lands on the animation's `hit` marker, so moving the pose
	moves the hit window with it. There is no attack-timing constant in this
	file, which is the only way an attack ever looks like it connected.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Map = require(ReplicatedStorage.Shared.Map)

local Actor = Forge.Actor
local Anim = Forge.Anim
local Combat = Forge.Combat
local Rig = Forge.Rig
local Rng = Forge.Core.Rng
local Debug = Forge.Debug

local Horde = {}

--[[
	What the dead are, as numbers.

	`health` is in the same units `Arsenal` deals damage in, so these are
	readable against it directly: a walker at 90 is one M9 headshot or two body
	shots, a brute at 620 is a magazine. That relationship is the difficulty
	curve, and having both sides in the same unit is what makes it tunable
	without a spreadsheet.
]]
Horde.KINDS = {
	walker = {
		id = "walker", label = "Walker",
		health = 90, damage = 14, reach = 6.5, attackEvery = 1.5,
		speed = 7, aggro = 90,
		rig = { scale = 1.0, shape = "biped",
			body = Color3.fromRGB(96, 104, 84),
			accent = Color3.fromRGB(62, 58, 48),
			eyes = Color3.fromRGB(180, 60, 40) },
	},
	runner = {
		id = "runner", label = "Runner",
		health = 62, damage = 11, reach = 6, attackEvery = 0.85,
		speed = 19, aggro = 130,
		rig = { scale = 0.92, shape = "biped",
			body = Color3.fromRGB(118, 96, 78),
			accent = Color3.fromRGB(70, 44, 38),
			eyes = Color3.fromRGB(230, 120, 40) },
	},
	brute = {
		id = "brute", label = "Brute",
		health = 620, damage = 46, reach = 8.5, attackEvery = 2.4,
		speed = 6, aggro = 110,
		rig = { scale = 1.55, shape = "hulk", bulky = true,
			body = Color3.fromRGB(84, 78, 66),
			accent = Color3.fromRGB(48, 42, 36),
			eyes = Color3.fromRGB(210, 40, 30) },
	},
}

--: Walkers constantly, runners often enough to stay honest, a brute rarely
--: enough to be an event.
Horde.MIX = {
	{ id = "walker", weight = 68 },
	{ id = "runner", weight = 26 },
	{ id = "brute", weight = 6 },
}

--: How many are alive at once, per player. Flat counts make a solo game
--: crowded and a full server empty.
Horde.PER_PLAYER = 14
Horde.FLOOR = 10
Horde.CEILING = 90

Horde.killed = 0
local folder: Folder? = nil

local function population(): number
	local players = math.max(1, #Players:GetPlayers())
	return math.clamp(Horde.FLOOR + players * Horde.PER_PLAYER,
		Horde.FLOOR, Horde.CEILING)
end

-- ================================ one of them ===============================
local function build(kindId: string, at: Vector3): Model?
	local def = Horde.KINDS[kindId]
	if not def then
		return nil
	end
	local model = Rig.build({
		name = def.label,
		scale = def.rig.scale,
		shape = def.rig.shape,
		bulky = def.rig.bulky,
		body = def.rig.body,
		accent = def.rig.accent,
		eyes = def.rig.eyes,
		material = Enum.Material.SmoothPlastic,
		collide = true,
	})
	model.Parent = folder or Workspace

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.MaxHealth = def.health
		humanoid.Health = def.health
		humanoid.WalkSpeed = def.speed
		--: No name tag over a zombie. A health bar floating above the horde
		--: turns a fight into a spreadsheet, and knowing which one is nearly
		--: dead should come from watching it stagger.
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end
	model:PivotTo(CFrame.new(at + Vector3.new(0, 3, 0)))

	local animator = Anim.new(model)
	animator:setProfile(Anim.profiles.grounded)
	Anim.bind(animator, "heartbeat")

	--[[
		The swing lands when the animation says it does.

		`Combat.arc` is a cone rather than a point check, so a zombie that has
		turned most of the way toward you still connects -- and one facing away
		does not, however close it is standing.
	]]
	animator:onMarker(function(_clip, marker)
		if marker ~= "hit" then
			return
		end
		local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not (root and Combat.isAlive(model)) then
			return
		end
		local hits = Combat.arc(root.Position, root.CFrame.LookVector, {
			range = def.reach + 2,
			angle = 110,
			ignore = { model },
			filter = function(target)
				return Players:GetPlayerFromCharacter(target) ~= nil
			end,
		})
		for _, target in hits do
			Combat.damage(target, {
				amount = def.damage, source = model,
				direction = root.CFrame.LookVector,
				from = root.Position, kind = "zombie",
			})
		end
	end)

	if humanoid then
		humanoid.Died:Connect(function()
			Horde.killed += 1
			--: Left where it fell for a few seconds. A body that vanishes the
			--: instant it dies makes a fight feel like a score counter; one
			--: that lies in the grass makes the last minute readable.
			task.delay(6, function()
				model:Destroy()
			end)
		end)
	end

	local scale = def.rig.scale
	return Actor.spawn(model, "walker_brain", {
		home = at,
		leash = 260,
		tag = "zombie",
		animator = animator,
		data = { def = def },
		navigate = true,
		standoff = def.reach * 0.7,
		--: Agent size from the rig, not a constant. A brute genuinely does not
		--: fit where a runner does, and giving them one radius produces either
		--: a brute wedged in a doorway or a runner refusing to use one.
		agentParameters = {
			AgentRadius = 2.2 * scale * (def.rig.bulky and 1.4 or 1),
			AgentHeight = 5 * scale,
			AgentCanJump = false,
			WaypointSpacing = 4,
		},
	}) and model
end

-- ================================== the brain ===============================
local function defineBrain()
	Actor.defineBrain("walker_brain", {
		initial = "roam",
		states = {
			--[[
				Not standing still.

				A horde that waits at its spawn point until somebody walks into
				aggro range is a horde that is only ever where the designer put
				it. Wandering means the valley has dead in it wherever you go,
				and that a quiet ridge can stop being quiet.
			]]
			roam = {
				enter = function(self)
					self:setSpeed(self.data.def.speed * 0.45)
				end,
				update = function(self)
					self:wander(30)
				end,
				transitions = {
					{
						to = "chase",
						when = function(self)
							self.target = self:nearestPlayer(self.data.def.aggro, true)
							return self.target ~= nil
						end,
					},
				},
			},

			chase = {
				enter = function(self)
					self:setSpeed(self.data.def.speed)
					if self.animator then
						self.animator:play("lunge")
					end
				end,
				update = function(self)
					if self.target then
						self:pursue(self.target)
						self:face(self.target)
					end
				end,
				transitions = {
					{
						to = "strike",
						when = function(self)
							return self.target ~= nil
								and self:flatDistanceTo(self.target) <= self.data.def.reach
								and self:ready("swing", self.data.def.attackEvery)
						end,
					},
					{
						--: Lost them. Back to wandering rather than standing
						--: where they were last seen, which reads as a bug.
						to = "roam",
						when = function(self)
							return self.target == nil
								or not self.target.Parent
								or self:flatDistanceTo(self.target)
									> self.data.def.aggro * 1.6
						end,
					},
				},
			},

			strike = {
				enter = function(self)
					self:setSpeed(0)
					if self.animator then
						self.animator:play("slam")
					end
				end,
				update = function(self)
					if self.target then
						self:face(self.target)
					end
				end,
				transitions = {
					{
						to = "chase",
						when = function(self)
							return self:elapsed() > self.data.def.attackEvery * 0.8
						end,
					},
				},
			},
		},
	})
end

-- ================================== the wave ================================
--[[
	Where one appears.

	In a ring around the player rather than at fixed points, because fixed
	spawn points are learned in ten minutes and then avoided forever. The inner
	radius is far enough that nothing materialises in front of you; the outer
	is near enough that walking does not outrun the pressure.
]]
local function ringPoint(): Vector3?
	local players = Players:GetPlayers()
	if #players == 0 then
		return nil
	end
	local stream = Rng.stream("horde.ring")
	local pick = players[stream:integer(1, #players)]
	local character = pick and pick.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return nil
	end
	local angle = stream:number(0, math.pi * 2)
	local distance = stream:number(70, 190)
	local at = root.Position
		+ Vector3.new(math.sin(angle) * distance, 0, math.cos(angle) * distance)

	--: Onto the ground, not into it. The valley is a bowl, so a point sampled
	--: flat is metres off wherever the player is not.
	local half = Map.EXTENT / 2
	if math.abs(at.X) > half or math.abs(at.Z) > half then
		return nil
	end
	return Vector3.new(at.X, Horde.groundAt(at.X, at.Z), at.Z)
end

--: Filled in by `start`, from the world that owns the terrain's shape.
Horde.groundAt = function(_x: number, _z: number): number
	return 0
end

function Horde.start(groundAt: (number, number) -> number)
	Horde.groundAt = groundAt
	folder = Instance.new("Folder")
	folder.Name = "Horde"
	folder.Parent = Workspace

	defineBrain()

	Actor.population({
		id = "valley",
		max = population(),
		interval = 2.2,
		perTick = 3,
		anchor = Vector3.zero,
		radius = { 70, 190 },
		despawnBeyond = 420,
		create = function()
			local at = ringPoint()
			if not at then
				return nil
			end
			local pick = Rng.stream("horde.mix"):weighted(Horde.MIX)
			return build(pick.id, at)
		end,
	})

	--: The cap follows the population, so a server that fills up gets heavier
	--: rather than thinner.
	Players.PlayerAdded:Connect(function()
		Actor.setPopulationMax("valley", population())
	end)
	Players.PlayerRemoving:Connect(function()
		task.defer(function()
			Actor.setPopulationMax("valley", population())
		end)
	end)

	Debug.probe("horde", Horde.describe)
end

function Horde.describe(): { [string]: any }
	local alive, byKind = 0, {}
	if folder then
		for _, model in folder:GetChildren() do
			if model:IsA("Model") then
				local humanoid = model:FindFirstChildOfClass("Humanoid")
				if humanoid and humanoid.Health > 0 then
					alive += 1
					byKind[model.Name] = (byKind[model.Name] or 0) + 1
				end
			end
		end
	end
	return { alive = alive, killed = Horde.killed, cap = population(),
		byKind = byKind, kinds = 3 }
end

return Horde
