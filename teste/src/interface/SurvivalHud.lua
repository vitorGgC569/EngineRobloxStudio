--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local WeaponCatalog = require(ReplicatedStorage.Shared.WeaponCatalog)
local SkinCatalog = require(ReplicatedStorage.Shared.SkinCatalog)

local SurvivalHud = {}
SurvivalHud.__index = SurvivalHud

function SurvivalHud.new(player: Player)
	local self = setmetatable({}, SurvivalHud)
	self.player = player

	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "SurvivalHudGui"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = playerGui
	self.screenGui = screenGui

	-- Bottom Left: Health & Armor & Scraps Container
	local statusContainer = Instance.new("Frame")
	statusContainer.Name = "StatusContainer"
	statusContainer.Size = UDim2.new(0, 240, 0, 95)
	statusContainer.Position = UDim2.new(0, 25, 1, -120)
	statusContainer.BackgroundColor3 = Color3.fromRGB(15, 18, 25)
	statusContainer.BackgroundTransparency = 0.35
	statusContainer.BorderSizePixel = 0
	statusContainer.Parent = screenGui

	local statusCorner = Instance.new("UICorner")
	statusCorner.CornerRadius = UDim.new(0, 10)
	statusCorner.Parent = statusContainer

	local statusStroke = Instance.new("UIStroke")
	statusStroke.Color = Color3.fromRGB(0, 200, 255)
	statusStroke.Transparency = 0.6
	statusStroke.Thickness = 1.2
	statusStroke.Parent = statusContainer

	-- Health Bar
	local hpBg = Instance.new("Frame")
	hpBg.Name = "HealthBackground"
	hpBg.Size = UDim2.new(1, -20, 0, 14)
	hpBg.Position = UDim2.new(0, 10, 0, 12)
	hpBg.BackgroundColor3 = Color3.fromRGB(35, 40, 50)
	hpBg.BorderSizePixel = 0
	hpBg.Parent = statusContainer

	local hpBgCorner = Instance.new("UICorner")
	hpBgCorner.CornerRadius = UDim.new(0, 7)
	hpBgCorner.Parent = hpBg

	local hpFill = Instance.new("Frame")
	hpFill.Name = "HealthFill"
	hpFill.Size = UDim2.new(1, 0, 1, 0)
	hpFill.BackgroundColor3 = Color3.fromRGB(240, 55, 60)
	hpFill.BorderSizePixel = 0
	hpFill.Parent = hpBg

	local hpFillCorner = Instance.new("UICorner")
	hpFillCorner.CornerRadius = UDim.new(0, 7)
	hpFillCorner.Parent = hpFill
	self.hpFill = hpFill

	-- Scraps Display
	local scrapsLabel = Instance.new("TextLabel")
	scrapsLabel.Name = "ScrapsLabel"
	scrapsLabel.Size = UDim2.new(1, -20, 0, 28)
	scrapsLabel.Position = UDim2.new(0, 10, 0, 55)
	scrapsLabel.BackgroundTransparency = 1
	scrapsLabel.Font = Enum.Font.GothamBold
	scrapsLabel.Text = "⚙ SCRAPS: 150"
	scrapsLabel.TextColor3 = Color3.fromRGB(255, 210, 60)
	scrapsLabel.TextSize = 16
	scrapsLabel.TextXAlignment = Enum.TextXAlignment.Left
	scrapsLabel.Parent = statusContainer
	self.scrapsLabel = scrapsLabel

	-- Bottom Right: Ammo & Weapon Container
	local weaponContainer = Instance.new("Frame")
	weaponContainer.Name = "WeaponContainer"
	weaponContainer.Size = UDim2.new(0, 220, 0, 85)
	weaponContainer.Position = UDim2.new(1, -245, 1, -110)
	weaponContainer.BackgroundColor3 = Color3.fromRGB(15, 18, 25)
	weaponContainer.BackgroundTransparency = 0.35
	weaponContainer.BorderSizePixel = 0
	weaponContainer.Parent = screenGui

	local weaponCorner = Instance.new("UICorner")
	weaponCorner.CornerRadius = UDim.new(0, 10)
	weaponCorner.Parent = weaponContainer

	local weaponStroke = Instance.new("UIStroke")
	weaponStroke.Color = Color3.fromRGB(0, 200, 255)
	weaponStroke.Transparency = 0.6
	weaponStroke.Thickness = 1.2
	weaponStroke.Parent = weaponContainer

	local weaponNameLabel = Instance.new("TextLabel")
	weaponNameLabel.Name = "WeaponName"
	weaponNameLabel.Size = UDim2.new(1, -20, 0, 24)
	weaponNameLabel.Position = UDim2.new(0, 10, 0, 10)
	weaponNameLabel.BackgroundTransparency = 1
	weaponNameLabel.Font = Enum.Font.GothamBold
	weaponNameLabel.Text = "OUTPOST P9"
	weaponNameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	weaponNameLabel.TextSize = 16
	weaponNameLabel.TextXAlignment = Enum.TextXAlignment.Right
	weaponNameLabel.Parent = weaponContainer
	self.weaponNameLabel = weaponNameLabel

	local ammoLabel = Instance.new("TextLabel")
	ammoLabel.Name = "AmmoLabel"
	ammoLabel.Size = UDim2.new(1, -20, 0, 36)
	ammoLabel.Position = UDim2.new(0, 10, 0, 38)
	ammoLabel.BackgroundTransparency = 1
	ammoLabel.Font = Enum.Font.GothamBlack
	ammoLabel.Text = "12 / 48"
	ammoLabel.TextColor3 = Color3.fromRGB(0, 240, 255)
	ammoLabel.TextSize = 24
	ammoLabel.TextXAlignment = Enum.TextXAlignment.Right
	ammoLabel.Parent = weaponContainer
	self.ammoLabel = ammoLabel

	-- Top Center: Wave Banner Container
	local waveContainer = Instance.new("Frame")
	waveContainer.Name = "WaveContainer"
	waveContainer.Size = UDim2.new(0, 200, 0, 50)
	waveContainer.Position = UDim2.new(0.5, -100, 0, 20)
	waveContainer.BackgroundColor3 = Color3.fromRGB(15, 18, 25)
	waveContainer.BackgroundTransparency = 0.35
	waveContainer.BorderSizePixel = 0
	waveContainer.Parent = screenGui

	local waveCorner = Instance.new("UICorner")
	waveCorner.CornerRadius = UDim.new(0, 8)
	waveCorner.Parent = waveContainer

	local waveStroke = Instance.new("UIStroke")
	waveStroke.Color = Color3.fromRGB(255, 60, 40)
	waveStroke.Transparency = 0.5
	waveStroke.Thickness = 1.2
	waveStroke.Parent = waveContainer

	local waveLabel = Instance.new("TextLabel")
	waveLabel.Name = "WaveLabel"
	waveLabel.Size = UDim2.new(1, 0, 1, 0)
	waveLabel.BackgroundTransparency = 1
	waveLabel.Font = Enum.Font.GothamBlack
	waveLabel.Text = "WAVE 1"
	waveLabel.TextColor3 = Color3.fromRGB(255, 80, 60)
	waveLabel.TextSize = 20
	waveLabel.Parent = waveContainer
	self.waveLabel = waveLabel

	-- Center Crosshair
	local crosshair = Instance.new("Frame")
	crosshair.Name = "Crosshair"
	crosshair.Size = UDim2.new(0, 6, 0, 6)
	crosshair.Position = UDim2.new(0.5, -3, 0.5, -3)
	crosshair.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	crosshair.BackgroundTransparency = 0.2
	crosshair.BorderSizePixel = 0
	crosshair.Parent = screenGui

	local crossCorner = Instance.new("UICorner")
	crossCorner.CornerRadius = UDim.new(1, 0)
	crossCorner.Parent = crosshair
	self.crosshair = crosshair

	return self
end

function SurvivalHud:updateData(data: any)
	if data.scraps then
		self.scrapsLabel.Text = "⚙ SCRAPS: " .. tostring(data.scraps)
	end
	if data.equippedWeapon then
		local wDef = WeaponCatalog.get(data.equippedWeapon)
		if wDef then
			self.weaponNameLabel.Text = string.upper(wDef.name)
			local cat = wDef.category
			local reserve = (data.ammo and data.ammo[cat]) or 0
			self.ammoLabel.Text = tostring(wDef.magazineSize) .. " / " .. tostring(reserve)
		end
	end
end

function SurvivalHud:updateWave(state: string, wave: number)
	if state == "Intermission" then
		self.waveLabel.Text = "INTERMISSION"
		self.waveLabel.TextColor3 = Color3.fromRGB(100, 220, 255)
	else
		self.waveLabel.Text = "WAVE " .. tostring(wave)
		self.waveLabel.TextColor3 = Color3.fromRGB(255, 80, 60)
	end
end

function SurvivalHud:updateHealth(current: number, max: number)
	local ratio = math.clamp(current / max, 0, 1)
	TweenService:Create(self.hpFill, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.new(ratio, 0, 1, 0)
	}):Play()
end

return SurvivalHud
