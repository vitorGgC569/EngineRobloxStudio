--!strict
local BarricadeModeler = {}

function BarricadeModeler.build(tier: number, cf: CFrame): Model
	local model = Instance.new("Model")
	model.Name = "Barricade_Tier" .. tier

	local maxHealth = 200 * (1 + (tier - 1) * 0.5)

	-- Posts
	local leftPost = Instance.new("Part")
	leftPost.Name = "LeftPost"
	leftPost.Size = Vector3.new(0.8, 5, 0.8)
	leftPost.CFrame = cf * CFrame.new(-3.5, 2.5, 0)
	leftPost.Anchored = true
	leftPost.Color = Color3.fromRGB(80, 55, 40)
	leftPost.Material = Enum.Material.WoodPlanks
	leftPost.Parent = model

	local rightPost = Instance.new("Part")
	rightPost.Name = "RightPost"
	rightPost.Size = Vector3.new(0.8, 5, 0.8)
	rightPost.CFrame = cf * CFrame.new(3.5, 2.5, 0)
	rightPost.Anchored = true
	rightPost.Color = Color3.fromRGB(80, 55, 40)
	rightPost.Material = Enum.Material.WoodPlanks
	rightPost.Parent = model

	-- Planks
	local plankCount = 4 + tier
	for i = 1, plankCount do
		local yOffset = 0.8 + (i - 1) * (3.6 / plankCount)
		local plank = Instance.new("Part")
		plank.Name = "Plank_" .. i
		plank.Size = Vector3.new(7.2, 0.65, 0.3)
		plank.CFrame = cf * CFrame.new(0, yOffset, 0) * CFrame.Angles(0, 0, math.rad((i % 2 == 0) and 2 or -2))
		plank.Anchored = true
		plank.Color = (tier >= 3) and Color3.fromRGB(90, 95, 105) or Color3.fromRGB(110, 80, 55)
		plank.Material = (tier >= 3) and Enum.Material.DiamondPlate or Enum.Material.WoodPlanks
		plank.Parent = model
	end

	-- Reinforcement Crossbeam for tier 2+
	if tier >= 2 then
		local cross1 = Instance.new("Part")
		cross1.Name = "CrossSteel1"
		cross1.Size = Vector3.new(8.5, 0.4, 0.25)
		cross1.CFrame = cf * CFrame.new(0, 2.5, 0.2) * CFrame.Angles(0, 0, math.rad(35))
		cross1.Anchored = true
		cross1.Color = Color3.fromRGB(60, 65, 70)
		cross1.Material = Enum.Material.CorrodedMetal
		cross1.Parent = model

		local cross2 = Instance.new("Part")
		cross2.Name = "CrossSteel2"
		cross2.Size = Vector3.new(8.5, 0.4, 0.25)
		cross2.CFrame = cf * CFrame.new(0, 2.5, 0.2) * CFrame.Angles(0, 0, math.rad(-35))
		cross2.Anchored = true
		cross2.Color = Color3.fromRGB(60, 65, 70)
		cross2.Material = Enum.Material.CorrodedMetal
		cross2.Parent = model
	end

	-- Interaction Prompt
	local promptPart = Instance.new("Part")
	promptPart.Name = "InteractionPart"
	promptPart.Size = Vector3.new(2, 2, 2)
	promptPart.CFrame = cf * CFrame.new(0, 2.5, 0)
	promptPart.Transparency = 1
	promptPart.CanCollide = false
	promptPart.Anchored = true
	promptPart.Parent = model
	model.PrimaryPart = promptPart

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "RepairPrompt"
	prompt.ActionText = "Repair Barricade"
	prompt.ObjectText = "Perimeter Defense"
	prompt.HoldDuration = 1.0
	prompt.MaxActivationDistance = 9.0
	prompt.Parent = promptPart

	model:SetAttribute("Health", maxHealth)
	model:SetAttribute("MaxHealth", maxHealth)
	model:SetAttribute("Tier", tier)

	return model
end

return BarricadeModeler
