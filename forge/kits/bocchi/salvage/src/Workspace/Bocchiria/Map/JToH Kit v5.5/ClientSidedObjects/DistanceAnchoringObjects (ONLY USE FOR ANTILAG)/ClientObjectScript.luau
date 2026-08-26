local players = game:GetService("Players")

return function()
	local defaultDistance = script.DefaultDistance.Value
	local char = players.LocalPlayer.Character
	
	players.LocalPlayer.CharacterAdded:Connect(function(c)
		char = c
	end)
	
	local modelTable = {}
	
	for _,model in pairs(script.Parent:GetChildren()) do
		if model:IsA("Model") then
			local dynamicTable = {}
			local primary
			local truePrimarySelect = false
			
			for _,part in pairs(model:GetDescendants()) do
				if part:IsA("BasePart") then
					if (part.Anchored == true or part.Name == "Primary") and truePrimarySelect == false then
						primary = part
						truePrimarySelect = (part.Name == "Primary")
					elseif part.Anchored == false then
						table.insert(dynamicTable,part)
					end
				end
			end
			
			if primary == nil then continue end
			
			table.insert(modelTable, {
				["DynamicTable"] = dynamicTable,
				["Primary"] = primary,
				["MaxDistance"] = (model:FindFirstChild("CustomDistance") ~= nil and model.CustomDistance.Value) or defaultDistance,
			})
		end
	end
	
	while task.wait(.125) do
		if char ~= nil then
			for _,modelInfo in pairs(modelTable) do
				local distance = players.LocalPlayer:DistanceFromCharacter(modelInfo.Primary.Position)
				
				for _,dynamic in pairs(modelInfo.DynamicTable) do
					dynamic.Anchored = (distance > modelInfo.MaxDistance)
				end
			end
		end
	end
end