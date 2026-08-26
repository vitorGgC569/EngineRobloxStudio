local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packets = require(ReplicatedStorage.Packets)
local Utils = require(ReplicatedStorage.Utils)

script.Parent.ClickPart.ClickDetector.MouseClick:Connect(function()
	Packets.cubeClicked.sendToAll()
	Utils.AddCurrencies(Utils.CalculateGeneration("Cube"))
end)