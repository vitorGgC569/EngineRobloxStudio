--!strict
--[[
	Range — what shooting means in this game.

	Forge supplies the trigger (cadence, spread, ammo, recoil, falloff), the
	projectile and the damage pipeline. Every decision below is this game's:
	that there are exactly two ranged weapons, that the bow rewards a full draw
	and the hand cannon rewards standing still, that targets are worth points
	and come back after eight seconds.

	--- Where authority lives ----------------------------------------------

	The client sends a direction and nothing else. It does not send where the
	muzzle is, how long it drew for, what it hit or how much damage it did —
	the server owns all of that, because each one of those is a number a
	modified client would be delighted to choose for itself.

	The charge in particular: the client says "I started drawing" and "I let
	go", and the server times the gap with its own clock. A client that claims
	a full draw after 50ms gets the 50ms shot.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Net = Forge.Net
local Combat = Forge.Combat
local Weapon = Forge.Weapon
local Save = Forge.Save
local Debug = Forge.Debug
local Rng = Forge.Core.Rng
local Rig = Forge.Rig
local World = Forge.World

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Content = require(Shared:WaitForChild("Content"))


local Range = {}

local targetHealth = Debug.tunable("range.targetHealth", 60)
local targetRespawn = Debug.tunable("range.targetRespawn", 8)
local targetScore = Debug.tunable("range.targetScore", 15)
local bullseyeBonus = Debug.tunable("range.bullseyeBonus", 2.0)

-- ================================= loadout ==================================
local held: { [Player]: number } = {}
local carried: { [Player]: any } = {}

local function characterOf(player: Player): Model?
	local character = player.Character
	if character and Combat.isAlive(character) then
		return character
	end
	return nil
end

local function currentId(player: Player): string
	return Content.ranged[held[player] or 1]
end

--[[
	Push the weapon's state down to the one client that needs it.

	Sent on every change rather than polled: ammo that updates a fifth of a
	second late is ammo the player does not trust.
]]
local function syncWeapon(player: Player)
	local character = characterOf(player)
	if not character then
		return
	end
	local ammo, reserve = Weapon.ammo(character)
	Net.fire(player, "Weapon", {
		id = Weapon.equippedId(character),
		ammo = ammo,
		reserve = reserve == math.huge and -1 or reserve,
		reloading = Weapon.isReloading(character),
		spread = Weapon.currentSpread(character),
	})
end

--[[
	Put the weapon in the hand, for real.

	Built on the server so every client sees it. A shooting system whose weapon
	exists only as a number on the HUD is one the player never believes: they
	pull a trigger and an arrow appears out of their sternum.
]]
local function showWeapon(player: Player, character: Model)
	local previous = carried[player]
	if previous then
		previous:release()
		carried[player] = nil
	end

	local def = Weapon.definition(currentId(player))
	if not def or not def.model then
		return
	end
	local model = Rig.buildWeapon(def.model, {
		color = def.color,
		name = def.model,
	})
	carried[player] = Rig.grip(character, model, { hand = def.hand, parent = character })
end

function Range.equip(player: Player, character: Model)
	held[player] = held[player] or 1
	Weapon.equip(character, currentId(player))
	showWeapon(player, character)
	syncWeapon(player)
end

local function onSwap(player: Player)
	local character = characterOf(player)
	if not character then
		return
	end
	held[player] = ((held[player] or 1) % #Content.ranged) + 1
	Weapon.equip(character, currentId(player))
	showWeapon(player, character)
	syncWeapon(player)
	Net.fire(player, "Notify", { text = Weapon.definition(currentId(player)).label })
end

-- ================================== targets =================================
local targets: { Model } = {}

--[[
	A practice target: post, board, bullseye.

	Built from parts rather than pulled from an asset id on purpose — the
	bullseye has to be a separate part so a hit on it can be told apart from a
	hit on the board, and that is the only thing making this target worth
	shooting twice.
]]
local function buildTarget(position: Vector3, facing: Vector3): Model
	local model = Instance.new("Model")
	model.Name = "Target"

	local look = CFrame.lookAt(position, position + facing)

	local post = Instance.new("Part")
	post.Name = "Post"
	post.Size = Vector3.new(0.6, 7, 0.6)
	post.CFrame = look * CFrame.new(0, 3.5, 0)
	post.Color = Color3.fromRGB(84, 62, 44)
	post.Material = Enum.Material.Wood
	post.Anchored = true
	post.Parent = model

	local board = Instance.new("Part")
	board.Name = "Board"
	board.Size = Vector3.new(5.4, 5.4, 0.5)
	board.CFrame = look * CFrame.new(0, 7.6, 0)
	board.Color = Color3.fromRGB(158, 126, 88)
	board.Material = Enum.Material.WoodPlanks
	board.Anchored = true
	board.Parent = model

	local ring = Instance.new("Part")
	ring.Name = "Ring"
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(0.16, 3.4, 3.4)
	-- Cylinders point along X, so it has to be rolled to face the shooter.
	ring.CFrame = look * CFrame.new(0, 7.6, -0.33) * CFrame.Angles(0, math.rad(90), 0)
	ring.Color = Color3.fromRGB(232, 232, 226)
	ring.Material = Enum.Material.SmoothPlastic
	ring.Anchored = true
	ring.Parent = model

	local eye = Instance.new("Part")
	eye.Name = "Bullseye"
	eye.Shape = Enum.PartType.Cylinder
	eye.Size = Vector3.new(0.18, 1.1, 1.1)
	eye.CFrame = look * CFrame.new(0, 7.6, -0.42) * CFrame.Angles(0, math.rad(90), 0)
	eye.Color = Color3.fromRGB(196, 58, 48)
	eye.Material = Enum.Material.SmoothPlastic
	eye.Anchored = true
	eye.Parent = model

	model.PrimaryPart = board
	model:SetAttribute("MaxHealth", targetHealth())
	model:SetAttribute("Health", targetHealth())
	-- The marker Combat.killed filters on. Without it a dead target would run
	-- down the enemy scoring path and ask for a husk definition that is not
	-- there.
	model:SetAttribute("RangeTarget", true)
	model:SetAttribute("Facing", facing)
	model:SetAttribute("Spot", position)
	return model
end

local function placeTargets(parent: Instance)
	local stream = Rng.stream("range.targets")
	local count = 0
	for i = 1, 9 do
		local angle = (i / 9) * math.pi * 2 + stream:number(-0.18, 0.18)
		local distance = stream:number(58, 104)
		local x, z = math.cos(angle) * distance, math.sin(angle) * distance
		local ground = World.surface(x, z)
		if ground then
			-- Facing the centre: the arena is where the shooter stands.
			local facing = (Vector3.new(0, ground.Y, 0) - ground)
			facing = facing.Magnitude > 0.01 and facing.Unit or Vector3.new(0, 0, 1)
			local model = buildTarget(ground, Vector3.new(facing.X, 0, facing.Z).Unit)
			model.Parent = parent
			table.insert(targets, model)
			count += 1
		end
	end
	return count
end

local function respawnTarget(model: Model)
	local spot = model:GetAttribute("Spot") :: Vector3
	local facing = model:GetAttribute("Facing") :: Vector3
	local parent = model.Parent
	model:Destroy()

	local index = table.find(targets, model)
	if index then
		table.remove(targets, index)
	end

	task.delay(targetRespawn(), function()
		if not parent or not parent.Parent then
			return
		end
		local fresh = buildTarget(spot, facing)
		fresh.Parent = parent
		table.insert(targets, fresh)
	end)
end

--[[
	A target coming apart.

	Nine planks with a shove, deleted after three seconds. Cheap, and the
	alternative — the model simply vanishing — makes a hit feel like a
	networking failure rather than a result.
]]
local function shatter(model: Model, from: Vector3)
	local origin = model:GetPivot().Position
	for i = 1, 9 do
		local shard = Instance.new("Part")
		shard.Size = Vector3.new(math.random(6, 16) / 10, math.random(6, 20) / 10, 0.4)
		shard.CFrame = CFrame.new(origin + Vector3.new(
			math.random(-22, 22) / 10,
			math.random(-14, 22) / 10,
			math.random(-6, 6) / 10
		))
		shard.Color = i <= 2 and Color3.fromRGB(196, 58, 48) or Color3.fromRGB(158, 126, 88)
		shard.Material = Enum.Material.WoodPlanks
		shard.CanCollide = false
		shard.Parent = Workspace:FindFirstChild("Effects") or Workspace

		local push = (origin - from)
		push = push.Magnitude > 0.01 and push.Unit or Vector3.new(0, 1, 0)
		shard.AssemblyLinearVelocity = push * math.random(12, 26)
			+ Vector3.new(math.random(-8, 8), math.random(6, 18), math.random(-8, 8))
		shard.AssemblyAngularVelocity = Vector3.new(math.random(-9, 9), math.random(-9, 9), math.random(-9, 9))

		task.delay(3, function()
			shard:Destroy()
		end)
	end
end

-- =================================== firing =================================
local function onDrawStart(player: Player)
	local character = characterOf(player)
	if character then
		Weapon.beginCharge(character)
	end
end

local function onDrawCancel(player: Player)
	local character = characterOf(player)
	if character then
		Weapon.cancelCharge(character)
	end
end

local function onReload(player: Player)
	local character = characterOf(player)
	if character and Weapon.reload(character) then
		syncWeapon(player)
		task.delay(Weapon.definition(currentId(player)).reloadTime + 0.05, function()
			if player.Parent then
				syncWeapon(player)
			end
		end)
	end
end

--[[
	The shot.

	Note what is *not* trusted: the origin comes from the server's copy of the
	character, the charge from the server's own timer, the damage from the
	weapon definition, and the hit from the server's raycast. The client
	contributed one unit vector.
]]
local function onShoot(player: Player, payload: any)
	local character = characterOf(player)
	if not character then
		return
	end

	local direction = payload.dir
	if typeof(direction) ~= "Vector3" or direction.Magnitude < 0.01 then
		return
	end
	direction = direction.Unit

	local head = character:FindFirstChild("Head") :: BasePart?
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local anchor = head or root
	if not anchor then
		return
	end
	-- Out in front of the chest, not inside it: a projectile born at the
	-- shooter's centre collides with the shooter's own arm.
	local origin = anchor.Position + direction * 2.2

	local ignore = { character }
	local def = Weapon.definition(Weapon.equippedId(character) or "")

	local result = Weapon.fire(character, origin, direction, {
		ignore = ignore,
		onHit = function(model, position, normal, damage)
			if model and model ~= character and Combat.isAlive(model) then
				local bonus = 1
				-- The bullseye is the reason to aim rather than to point.
				if model:GetAttribute("RangeTarget") and (position - model:GetPivot().Position).Magnitude < 0.9 then
					bonus = bullseyeBonus()
				end
				local ctx = Combat.damage(model, {
					amount = damage * bonus,
					source = player,
					kind = "ranged",
					direction = direction,
					-- `from` is what makes a block directional. Without it an
					-- arrow in the back counts as a blocked arrow, and the
					-- rule that you cannot block what you cannot see quietly
					-- stops applying to everything ranged.
					from = origin,
				})
				if ctx then
					Net.fireNear(position, 160, "Hit", {
						pos = position,
						amount = ctx.dealt,
						crit = bonus > 1,
						blocked = false,
						dir = direction,
						kind = "ranged",
					})
					Debug.count("range.hits")
				end
			end
			Net.fireNear(position, 160, "Impact", {
				pos = position,
				normal = normal,
				onFlesh = model ~= nil,
			})
		end,
	})

	if not result.ok then
		-- "cooldown" is the ordinary case and says nothing worth a packet;
		-- "empty" is the one the player has to be told about.
		if result.reason == "empty" then
			Net.fire(player, "Notify", { text = "out of arrows" })
		end
		syncWeapon(player)
		return
	end

	Debug.count("range.shots")

	--[[
		Tell the neighbourhood.

		The shooter already drew its own tracer the instant it pulled — it is
		in the payload so that client can skip drawing a second one. Everyone
		else needs this to see anything at all.
	]]
	local first = result.shots[1]
	Net.fireNear(origin, 220, "Shot", {
		shooter = player,
		id = Weapon.equippedId(character),
		origin = origin,
		dir = direction,
		seed = result.seed,
		charge = result.charge,
		spread = result.spread,
		mode = def and def.mode or "projectile",
		-- Hitscan has no flight, so the endpoint has to travel with the shot.
		hitPos = first and first.position or nil,
	})

	syncWeapon(player)
end

-- ==================================== start =================================
function Range.start()
	local props = Workspace:FindFirstChild("Props") or Workspace

	Net.on("DrawStart", onDrawStart)
	Net.on("DrawCancel", onDrawCancel)
	Net.on("Shoot", onShoot)
	Net.on("Reload", onReload)
	Net.on("SwapWeapon", onSwap)

	local placed = placeTargets(props)

	--[[
		Targets score and come back; enemies are Fight's business.

		Both systems listen to the same signal, which is only safe because each
		one filters for what it owns. Without the attribute check this handler
		would fire on every husk that dies and quietly double the score.
	]]
	Combat.killed:Connect(function(model, source, ctx)
		if not model:GetAttribute("RangeTarget") then
			return
		end
		shatter(model, ctx and ctx.direction and (model:GetPivot().Position - ctx.direction * 10) or model:GetPivot().Position)
		respawnTarget(model)

		if typeof(source) == "Instance" and source:IsA("Player") then
			local profile = Save.get(source)
			if profile then
				profile.score += targetScore()
				Net.fire(source, "StateSync", profile)
				Net.fire(source, "Notify", { text = string.format("target  (+%d)", targetScore()) })
			end
		end
		Debug.count("range.targets")
	end)

	Players.PlayerRemoving:Connect(function(player)
		held[player] = nil
		-- The weld dies with the character, but the handle would keep the
		-- model alive in memory for as long as the table held it.
		local carriedWeapon = carried[player]
		if carriedWeapon then
			carriedWeapon:release()
			carried[player] = nil
		end
	end)

	Debug.probe("range", function()
		local alive = 0
		for _, model in targets do
			if model.Parent and Combat.isAlive(model) then
				alive += 1
			end
		end
		return {
			weapons = Weapon.ids(),
			targets = alive,
			targetsPlaced = placed,
			liveProjectiles = Combat.projectileCount(),
		}
	end)

	Debug.info(string.format("range ready (%d targets, %d weapons)", placed, #Weapon.ids()))
end

return Range
