local rs = game:GetService("ReplicatedStorage")
local tweenService = game:GetService("TweenService")
local players = game:GetService("Players")
local changeLighting = rs:WaitForChild("ChangeLighting")

local function roundColor(color: Color3): Color3
    return Color3.fromRGB(math.round(color.R * 255), math.round(color.G * 255), math.round(color.B * 255))
end

local function configCheck(config, configValue)
	local foundValue = config:FindFirstChild(configValue)
	if foundValue == nil then return false end

	return (foundValue:IsA("ValueBase") and not (foundValue:IsA("BoolValue") and foundValue.Value == false))
end

local function evaluateToucher(part,touch)
	if not touch.Parent then return false end

	local yesplr = (configCheck(part,"SupportPlayers") and players:GetPlayerFromCharacter(touch.Parent) == players.LocalPlayer)
	
	local colorSpecific = not (configCheck(part,"ColorSpecific") and (roundColor(touch.Color) ~= roundColor(part.Color)))
	local yesbox = (configCheck(part,"SupportPushboxes") and (touch.Name == "Pushbox" or touch:FindFirstChild("IsBox") ~= nil) and colorSpecific)

	return (yesplr or yesbox)
end


return function()   
	for _,lc in pairs(script.Parent:GetDescendants()) do
		if lc:IsA("BasePart") and lc:FindFirstChild("LightingConfiguration") and lc.LightingConfiguration:IsA("ModuleScript") then
			local db = false
			local config = require(lc.LightingConfiguration)
			
			lc.Touched:Connect(function(t)
				if evaluateToucher(lc,t) and db == false then
					db = true
					changeLighting:Fire(config)
					task.delay(.25,function()
						db = false
					end)
				end
			end)
		end
	end
end