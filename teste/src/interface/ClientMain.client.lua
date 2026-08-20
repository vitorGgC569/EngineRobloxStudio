--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NetworkProtocol = require(ReplicatedStorage.Shared.NetworkProtocol)

local SurvivalHud = require(script.Parent.SurvivalHud)
local GunController = require(script.Parent.GunController)
local ZombieClientPresenter = require(script.Parent.ZombieClientPresenter)
local AtmosphereMood = require(script.Parent.AtmosphereMood)

local player = Players.LocalPlayer

-- Initialize Systems
local hud = SurvivalHud.new(player)
local gun = GunController.new(player)
local presenter = ZombieClientPresenter.new()
local atmosphere = AtmosphereMood.new(player)

local lastPlayerData: any = nil

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local syncDataEvent = remotes:WaitForChild(NetworkProtocol.Events.SYNC_PLAYER_DATA) :: RemoteEvent
local waveStateEvent = remotes:WaitForChild(NetworkProtocol.Events.WAVE_STATE_CHANGED) :: RemoteEvent

syncDataEvent.OnClientEvent:Connect(function(data)
	lastPlayerData = data
	hud:updateData(data)
	if data.equippedWeapon then
		gun:equipWeapon(data.equippedWeapon, data.equippedSkin)
	end
end)

waveStateEvent.OnClientEvent:Connect(function(state, wave)
	hud:updateWave(state, wave)
end)

local function onCharacter(character: Model)
	local hum = character:WaitForChild("Humanoid") :: Humanoid
	hum.HealthChanged:Connect(function(hp)
		hud:updateHealth(hp, hum.MaxHealth)
	end)
	if lastPlayerData and lastPlayerData.equippedWeapon then
		task.delay(0.2, function()
			gun:equipWeapon(lastPlayerData.equippedWeapon, lastPlayerData.equippedSkin)
		end)
	end
end

if player.Character then
	onCharacter(player.Character)
end
player.CharacterAdded:Connect(onCharacter)
