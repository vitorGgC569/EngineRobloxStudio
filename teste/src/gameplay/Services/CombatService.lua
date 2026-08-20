local WeaponCatalog, SkinCatalog
do
	local ok, rs = pcall(function() return game:GetService("ReplicatedStorage") end)
	if ok and rs and rs:FindFirstChild("Shared") then
		WeaponCatalog = require(rs.Shared.WeaponCatalog)
		SkinCatalog = require(rs.Shared.SkinCatalog)
	else
		WeaponCatalog = require(script.Parent.Parent.shared.WeaponCatalog)
		SkinCatalog = require(script.Parent.Parent.shared.SkinCatalog)
	end
end

local CombatService = {}
CombatService.__index = CombatService

export type HitResult = {
	hit: boolean,
	target: Instance?,
	damage: number,
	isHeadshot: boolean,
	isKill: boolean,
	hitPosition: Vector3,
}

function CombatService.new()
	local self = setmetatable({}, CombatService)
	return self
end

function CombatService:processShot(
	player: Player,
	weaponId: string,
	origin: Vector3,
	direction: Vector3,
	clientReportedTarget: Instance?
): HitResult
	local weaponDef = WeaponCatalog.get(weaponId)
	if not weaponDef then
		return { hit = false, damage = 0, isHeadshot = false, isKill = false, hitPosition = origin }
	end

	-- 1. Server distance check from player character
	local character = player.Character
	if not character or not character.PrimaryPart then
		return { hit = false, damage = 0, isHeadshot = false, isKill = false, hitPosition = origin }
	end

	local charPos = character.PrimaryPart.Position
	if (origin - charPos).Magnitude > 15 then
		-- Origin is too far from player character: suspicious/invalid
		origin = charPos + Vector3.new(0, 1.5, 0)
	end

	-- 2. Server-side Raycast Verification
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = { character }
	raycastParams.IgnoreWater = true

	local maxDist = weaponDef.range
	local normalizedDir = direction.Unit * maxDist
	local result = Workspace:Raycast(origin, normalizedDir, raycastParams)

	if not result or not result.Instance then
		return { hit = false, damage = 0, isHeadshot = false, isKill = false, hitPosition = origin + normalizedDir }
	end

	local hitPart = result.Instance
	local hitPos = result.Position
	local hitModel = hitPart:FindFirstAncestorOfClass("Model")

	if not hitModel then
		return { hit = true, target = hitPart, damage = 0, isHeadshot = false, isKill = false, hitPosition = hitPos }
	end

	-- Check if hit a Zombie
	local humanoid = hitModel:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return { hit = true, target = hitPart, damage = 0, isHeadshot = false, isKill = false, hitPosition = hitPos }
	end

	-- Check if it's a zombie model
	local isZombie = hitModel.Name:sub(1, 7) == "Zombie_" or hitModel:GetAttribute("ZombieType") ~= nil
	if not isZombie then
		return { hit = true, target = hitPart, damage = 0, isHeadshot = false, isKill = false, hitPosition = hitPos }
	end

	-- Headshot detection
	local isHeadshot = (hitPart.Name == "Head" or hitPart.Name == "LeftEye" or hitPart.Name == "RightEye")
	local baseDamage = weaponDef.damage
	local finalDamage = isHeadshot and (baseDamage * weaponDef.headshotMultiplier) or baseDamage

	local currentHp = humanoid.Health
	humanoid:TakeDamage(finalDamage)
	local isKill = humanoid.Health <= 0

	return {
		hit = true,
		target = hitModel,
		damage = finalDamage,
		isHeadshot = isHeadshot,
		isKill = isKill,
		hitPosition = hitPos,
	}
end

return CombatService
