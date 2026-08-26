local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Utils = require(ReplicatedStorage.Utils)

local virtualPlayerCount = 0
local generation = nil
local label = script.Parent.BillboardGui.TextLabel
local playersTouching = {} :: {[Player]: RBXScriptConnection}
local animationPerCharacter = {} :: {[Model]: AnimationTrack}

script.Parent.Touched:Connect(function(otherPart)
	local player = Players:GetPlayerFromCharacter(otherPart.Parent)
	if (player == nil) then
		return
	end
	if (playersTouching[player] == nil and otherPart.Parent.Humanoid.Health > 0) then
		playersTouching[player] = otherPart.Parent.Humanoid.Died:Once(function()
			playersTouching[player] = nil
			refresh()
		end)
	end
	
	refresh()
end)

script.Parent.TouchEnded:Connect(function(otherPart)
	local player = Players:GetPlayerFromCharacter(otherPart.Parent)
	if (player == nil) then
		return
	end
	if (playersTouching[player] ~= nil) then
		playersTouching[player]:Disconnect()
		playersTouching[player] = nil
	end
	refresh()
end)

function refresh()
	local multi = virtualPlayerCount
	for i, player in pairs(Players:GetPlayers()) do
		local character = player.Character
		if (character ~= nil) then
			local connection = playersTouching[player]
			if (animationPerCharacter[character] == nil) then
				animationPerCharacter[character] = character:FindFirstChildOfClass("Humanoid"):FindFirstChildOfClass("Animator"):LoadAnimation(script.Parent.PrayAnimation)
			end
			if (connection ~= nil) then
				if (not animationPerCharacter[character].IsPlaying) then
					animationPerCharacter[character]:Play()
				end
				multi = multi + 1
			else
				animationPerCharacter[character]:Stop()
			end
		end 
	end
	if (Utils.CalculateGeneration ~= nil) then
		generation = Utils.CalculateGeneration("Shrine"):mul(multi)
		label.Text = `+{string.upper(generation:toString())}/s`
	end
	label.Visible = multi > 0
end

local t = 0
RunService.Heartbeat:Connect(function(dt)
	t += dt
	if (t > 1) then
		t -= 1
		if (generation ~= nil) then
			refresh()
			Utils.AddCurrencies(generation)
		end
	end	
end)

Utils.AddShrineVirtualPlayer = function(amount: number)
	virtualPlayerCount += amount
	refresh()
end

refresh()