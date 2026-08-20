--!strict
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local NetworkProtocol = require(ReplicatedStorage.Shared.NetworkProtocol)
local WeaponCatalog = require(ReplicatedStorage.Shared.WeaponCatalog)
local WeaponModeler = require(ReplicatedStorage.Shared.MeshKit.WeaponModeler)

local GunController = {}
GunController.__index = GunController

function GunController.new(player: Player)
	local self = setmetatable({}, GunController)
	self.player = player
	self.camera = Workspace.CurrentCamera
	self.equippedWeaponId = "service_pistol"
	self.equippedSkinId = "default_factory"
	self.lastFireTime = 0
	self.currentMag = 12
	self.isReloading = false
	self.equippedModel = nil :: Model?

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	self.fireRemote = remotes:WaitForChild(NetworkProtocol.Events.FIRE_WEAPON) :: RemoteEvent
	self.reloadRemote = remotes:WaitForChild(NetworkProtocol.Events.RELOAD_WEAPON) :: RemoteEvent

	self:setupInput()
	return self
end

function GunController:equipWeapon(weaponId: string, skinId: string?)
	self.equippedWeaponId = weaponId
	self.equippedSkinId = skinId or "default_factory"
	local def = WeaponCatalog.get(weaponId)
	if def then
		self.currentMag = def.magazineSize
	end

	-- Build 3D Weapon Model on Character Hand
	local character = self.player.Character
	if character then
		local rightHand = (character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm") or character:WaitForChild("RightHand", 2) or character:WaitForChild("Right Arm", 2)) :: BasePart?
		if rightHand then
			if self.equippedModel then
				self.equippedModel:Destroy()
			end
			local model = WeaponModeler.build(weaponId, self.equippedSkinId)
			model.Parent = character

			local handle = model.PrimaryPart or model:FindFirstChild("Handle") :: BasePart?
			if handle then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = rightHand
				weld.Part1 = handle
				handle.CFrame = rightHand.CFrame * CFrame.new(0, -1, -0.5) * CFrame.Angles(math.rad(-90), 0, 0)
				weld.Parent = handle
			end
			self.equippedModel = model
		end
	end
end

function GunController:fire()
	if self.isReloading then return end
	local now = os.clock()
	local weaponDef = WeaponCatalog.get(self.equippedWeaponId)
	if not weaponDef then return end

	local minInterval = 1.0 / weaponDef.fireRate
	if (now - self.lastFireTime) < minInterval then return end

	if weaponDef.category ~= "Melee" and self.currentMag <= 0 then
		-- Magazine empty
		return
	end

	self.lastFireTime = now
	if weaponDef.category ~= "Melee" then
		self.currentMag -= 1
	end

	-- Origin & Ray Direction from Center Viewport
	local cam = Workspace.CurrentCamera
	if not cam then return end

	local centerRay = cam:ViewportPointToRay(cam.ViewportSize.X / 2, cam.ViewportSize.Y / 2)
	local origin = cam.CFrame.Position
	local direction = centerRay.Direction

	-- Fire on Server
	self.fireRemote:FireServer(self.equippedWeaponId, origin, direction, nil)

	-- Client Muzzle Visuals & Sound
	if self.equippedModel then
		local handle = self.equippedModel.PrimaryPart
		if handle then
			local light = Instance.new("PointLight")
			light.Color = Color3.fromRGB(255, 200, 100)
			light.Brightness = 3.0
			light.Range = 12
			light.Parent = handle
			task.delay(0.05, function()
				light:Destroy()
			end)
		end
	end
end

function GunController:setupInput()
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			self:fire()
		elseif input.KeyCode == Enum.KeyCode.R then
			local def = WeaponCatalog.get(self.equippedWeaponId)
			if def and def.category ~= "Melee" and not self.isReloading then
				self.isReloading = true
				task.delay(def.reloadTime, function()
					self.currentMag = def.magazineSize
					self.isReloading = false
				end)
			end
		end
	end)
end

return GunController
