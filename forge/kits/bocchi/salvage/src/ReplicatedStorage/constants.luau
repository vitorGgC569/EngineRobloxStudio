local RunService = game:GetService("RunService")
local constants = {}

constants.ASSETS = game:GetService("StarterGui").Assets

if (RunService:IsClient()) then
	constants.LOCAL_PLAYER = assert(game:GetService("Players").LocalPlayer)
	constants.MOUSE = constants.LOCAL_PLAYER:GetMouse()
	constants.PLAYER_GUI = constants.LOCAL_PLAYER.PlayerGui
	constants.INTERFACE = constants.PLAYER_GUI:WaitForChild("Interface")
	constants.PLAYER_SCRIPTS = constants.LOCAL_PLAYER.PlayerScripts
end

constants.BUTTONS = workspace:WaitForChild("Buttons"):GetChildren()


return constants
