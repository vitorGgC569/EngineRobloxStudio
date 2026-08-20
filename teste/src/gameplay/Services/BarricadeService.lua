--!strict
local BarricadeService = {}
BarricadeService.__index = BarricadeService

export type BarricadeState = {
	model: Model,
	health: number,
	maxHealth: number,
	tier: number,
	broken: boolean,
}

function BarricadeService.new()
	local self = setmetatable({}, BarricadeService)
	self._barricades = {} :: { [Model]: BarricadeState }
	return self
end

function BarricadeService:register(model: Model)
	local health = model:GetAttribute("Health") or 200
	local maxHealth = model:GetAttribute("MaxHealth") or 200
	local tier = model:GetAttribute("Tier") or 1

	local state: BarricadeState = {
		model = model,
		health = health,
		maxHealth = maxHealth,
		tier = tier,
		broken = false,
	}
	self._barricades[model] = state
end

function BarricadeService:damageBarricade(model: Model, amount: number): boolean
	local state = self._barricades[model]
	if not state or state.broken then return false end

	state.health = math.max(0, state.health - amount)
	model:SetAttribute("Health", state.health)

	if state.health <= 0 then
		state.broken = true
		-- Visual feedback: planks become transparent / non-collidable
		for _, part in ipairs(model:GetChildren()) do
			if part:IsA("BasePart") and part.Name:sub(1, 6) == "Plank_" then
				part.Transparency = 0.8
				part.CanCollide = false
			end
		end
		return true -- destroyed
	end
	return false
end

function BarricadeService:repairBarricade(player: Player, model: Model, repairAmount: number): boolean
	local state = self._barricades[model]
	if not state then return false end

	state.health = math.min(state.maxHealth, state.health + repairAmount)
	state.broken = false
	model:SetAttribute("Health", state.health)

	for _, part in ipairs(model:GetChildren()) do
		if part:IsA("BasePart") and part.Name:sub(1, 6) == "Plank_" then
			part.Transparency = 0
			part.CanCollide = true
		end
	end

	return true
end

return BarricadeService
