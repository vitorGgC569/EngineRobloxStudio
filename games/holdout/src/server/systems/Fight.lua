--!strict
--[[
	Fight — carrying a gun, firing it, and deciding what a shot did.

	`Forge.Weapon` already owns the hard half: cooldown, magazine, reload,
	bloom, per-pellet spread and the raycast. `Movement.HitscanValidator` owns
	the rate gate and the reach check. `Combat.HitValidator.Lockout` owns
	stopping one shot registering twice. This is the part that is this game:
	which zone was hit, what the distance cost, and whether the thing on the
	other end dies.

	The client aims and the server shoots
	-------------------------------------

	The client sends where it was looking. It does not send what it hit, how
	far away that was, or how much damage it did -- all three are recomputed
	here from the character's own position. A client that could name its target
	is a client that hits through walls, and this is the one place in a shooter
	where being careless is not recoverable.

	The one thing the client is believed about
	------------------------------------------

	Its aim direction, and only within a cone. `Ballistics.withinAngle` rejects
	a direction that does not match where the character is facing, so a claim of
	"I was looking behind me" fails even though the server cannot see the
	player's mouse.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Arsenal = require(ReplicatedStorage.Shared.Arsenal)
local Posture = require(ReplicatedStorage.Shared.Posture)
local Guns = require(script.Parent.Guns)

local Weapon = Forge.Weapon
local Ballistics = Forge.Movement.Ballistics
local HitscanValidator = Forge.Movement.HitscanValidator
local HitValidator = Forge.Combat.HitValidator

local Fight = {}

--: How far off the character's facing a claimed aim direction may be. Wide,
--: because a mouse moves faster than a torso turns and a tight cone punishes
--: flicking rather than cheating.
Fight.AIM_TOLERANCE = 75

Fight.carried = {} :: { [Player]: string }
local validators: { [string]: any } = {}
local lockout = HitValidator.Lockout.new({ window = 0.12 })

--: Which limb belongs to which zone. R15 names, because that is what a Roblox
--: character is; anything unrecognised is a limb, which is the forgiving
--: answer and the right default.
local ZONE = {
	Head = "head",
	UpperTorso = "torso", LowerTorso = "torso", HumanoidRootPart = "torso",
	Torso = "torso",
}

--[[
	Every gun the arsenal names, registered with the engine once.

	`Weapon.define` is the engine's shape and `Arsenal.spec` is the translation,
	so the arsenal stays a list of guns rather than a list of engine
	configuration.
]]
function Fight.start()
	for _, gun in Arsenal.guns do
		Weapon.define(gun.id, Arsenal.spec(gun))
		validators[gun.id] = HitscanValidator.new({
			range = gun.range,
			--: The rate gate, in seconds between rounds. `Weapon` enforces this
			--: too; having it here as well means a client that finds a way past
			--: one still meets the other.
			cooldown = 60 / gun.rpm * 0.9,
		})
	end
end

function Fight.give(player: Player, id: string): (boolean, any)
	local gun = Arsenal.get(id)
	local character = player.Character
	if not gun then
		return false, "no such weapon"
	end
	if not character then
		return false, "no character"
	end
	Weapon.equip(character, id)
	Guns.hold(character, id)
	Fight.carried[player] = id
	local held, reserve = Weapon.ammo(character)
	player:SetAttribute("gun", gun.name)
	player:SetAttribute("ammo", held)
	player:SetAttribute("reserve", reserve)
	return true, { id = id, name = gun.name, ammo = held, reserve = reserve,
		scope = gun.scope, zoom = gun.adsZoom, adsSpeed = gun.adsSpeed }
end

local function publishAmmo(player: Player, character: Model)
	local held, reserve = Weapon.ammo(character)
	player:SetAttribute("ammo", held)
	player:SetAttribute("reserve", reserve)
end

--[[
	Which zone a part belongs to, and who it belongs to.

	Returns the humanoid so the caller does not have to walk the hierarchy
	twice, and nil for anything that is not a body -- a tree is a hit and not a
	casualty, and telling them apart here keeps the damage code from having to.
]]
local function bodyOf(part: BasePart?): (Humanoid?, string, Model?)
	if not part then
		return nil, "limb", nil
	end
	local model = part:FindFirstAncestorOfClass("Model")
	local humanoid = model and model:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil, "limb", nil
	end
	return humanoid, ZONE[part.Name] or "limb", model
end

--[[
	One trigger pull.

	`Weapon.fire` does the spread, the raycast and the ammunition; everything
	after the loop is this game deciding what the shots meant.
]]
function Fight.shoot(player: Player, direction: Vector3, aiming: boolean?,
                     posture: string?): (boolean, any)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local head = character and character:FindFirstChild("Head")
	if not (character and root and root:IsA("BasePart")) then
		return false, "no character"
	end
	local id = Fight.carried[player]
	local gun = id and Arsenal.get(id)
	if not gun then
		return false, "nothing to fire"
	end

	--: Claimed aim, checked against where the torso actually points. The
	--: server cannot see a mouse; it can see that a player is not facing the
	--: way they say they are.
	if direction.Magnitude < 0.01 then
		return false, "no direction"
	end
	direction = direction.Unit
	if not Ballistics.withinAngle(
			{ x = root.CFrame.LookVector.X, y = root.CFrame.LookVector.Y,
			  z = root.CFrame.LookVector.Z },
			{ x = direction.X, y = direction.Y, z = direction.Z },
			Fight.AIM_TOLERANCE) then
		return false, "aim rejected"
	end

	local validator = validators[id]
	local allowed = validator and validator:tryFire(tostring(player.UserId))
	if not allowed then
		return false, "too fast"
	end

	--: Spread comes from the gun, the posture and whether they are aiming.
	--: All three compound, which is what makes lying down and aiming worth the
	--: seconds it costs.
	local base = if aiming then gun.adsSpread else gun.spread
	local spread = base * Posture.spread(posture or "stand", aiming, false, false)

	local origin = (if head and head:IsA("BasePart") then head.Position
		else root.Position) + direction * 2
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }

	local result = Weapon.fire(character, origin, direction, {
		spread = spread, params = params,
	})
	if not result or result.ok == false then
		return false, tostring(result and result.reason or "misfire")
	end
	publishAmmo(player, character)

	local hits = {}
	for _, shot in result.shots or {} do
		local humanoid, zone, model = bodyOf(shot.instance)
		local distance = shot.distance or 0
		if humanoid and model then
			--: One shot may not register twice on the same target, which is
			--: what a duplicated remote or a lagged retry produces.
			if lockout:register(player, model, os.clock()) then
				local damage = Arsenal.damageAt(gun, distance, zone)
				humanoid:TakeDamage(damage)
				table.insert(hits, {
					at = shot.position, zone = zone, damage = damage,
					distance = distance,
					victim = model.Name,
					killed = humanoid.Health <= 0,
				})
			end
		else
			table.insert(hits, { at = shot.position, zone = "world",
				distance = distance })
		end
	end
	--: Where the tracer starts. The raycast leaves the eye -- firing from the
	--: muzzle puts rounds through walls the player is standing behind -- but a
	--: line drawn from the forehead looks wrong, so the *drawing* starts at the
	--: barrel while the *shot* does not.
	local muzzle = Guns.muzzle(character)
	return true, { hits = hits, ammo = select(1, Weapon.ammo(character)),
		spread = spread, shots = #(result.shots or {}),
		from = muzzle or origin }
end

function Fight.reload(player: Player): (boolean, any)
	local character = player.Character
	if not character then
		return false, "no character"
	end
	if not Weapon.reload(character) then
		return false, "cannot reload"
	end
	local gun = Arsenal.get(Fight.carried[player] or "")
	task.delay(gun and gun.reload or 2, function()
		if player.Character == character then
			publishAmmo(player, character)
		end
	end)
	return true, { seconds = gun and gun.reload or 2 }
end

function Fight.drop(player: Player)
	local character = player.Character
	if character then
		Weapon.unequip(character)
		Guns.clear(character)
	end
	Fight.carried[player] = nil
	lockout:clear(player)
	player:SetAttribute("gun", nil)
	player:SetAttribute("ammo", nil)
	player:SetAttribute("reserve", nil)
end

function Fight.describe(): { [string]: any }
	local armed = 0
	for _ in Fight.carried do
		armed += 1
	end
	return { armed = armed, defined = #Weapon.ids(),
		guns = Arsenal.describe() }
end

return Fight
