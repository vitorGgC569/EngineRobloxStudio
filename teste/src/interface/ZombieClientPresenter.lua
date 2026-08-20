--!strict
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local NetworkProtocol = require(ReplicatedStorage.Shared.NetworkProtocol)

local ZombieClientPresenter = {}
ZombieClientPresenter.__index = ZombieClientPresenter

function ZombieClientPresenter.new()
	local self = setmetatable({}, ZombieClientPresenter)
	self:setupListeners()
	return self
end

function ZombieClientPresenter:createTracer(fromPos: Vector3, toPos: Vector3, weaponId: string, skinId: string)
	local distance = (toPos - fromPos).Magnitude
	local tracer = Instance.new("Part")
	tracer.Name = "BulletTracer"
	tracer.Size = Vector3.new(0.08, 0.08, distance)
	tracer.CFrame = CFrame.lookAt(fromPos, toPos) * CFrame.new(0, 0, -distance / 2)
	tracer.Anchored = true
	tracer.CanCollide = false
	tracer.CastShadow = false

	if skinId == "cyber_neon" then
		tracer.Color = Color3.fromRGB(0, 255, 240)
	elseif skinId == "crimson_dragon" then
		tracer.Color = Color3.fromRGB(255, 50, 40)
	elseif skinId == "void_singularity" then
		tracer.Color = Color3.fromRGB(190, 80, 255)
	else
		tracer.Color = Color3.fromRGB(255, 215, 120)
	end
	tracer.Material = Enum.Material.Neon
	tracer.Parent = Workspace

	TweenService:Create(tracer, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Transparency = 1,
		Size = Vector3.new(0.02, 0.02, distance)
	}):Play()

	Debris:AddItem(tracer, 0.15)
end

function ZombieClientPresenter:showDamageNumber(pos: Vector3, damage: number, isHeadshot: boolean)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "DamageIndicator"
	billboard.Size = UDim2.new(0, 70, 0, 35)
	billboard.StudsOffset = Vector3.new(0, 2, 0)
	billboard.AlwaysOnTop = true
	billboard.Adornee = Workspace.Terrain

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.Text = tostring(math.floor(damage))
	label.TextColor3 = isHeadshot and Color3.fromRGB(255, 60, 40) or Color3.fromRGB(255, 220, 80)
	label.TextSize = isHeadshot and 22 or 16
	label.TextStrokeTransparency = 0
	label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	label.Parent = billboard

	local anchor = Instance.new("Part")
	anchor.Size = Vector3.new(0.1, 0.1, 0.1)
	anchor.CFrame = CFrame.new(pos)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.Parent = Workspace
	billboard.Adornee = anchor
	billboard.Parent = anchor

	local targetCf = anchor.CFrame * CFrame.new(0, 2.5, 0)
	TweenService:Create(anchor, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		CFrame = targetCf
	}):Play()
	TweenService:Create(label, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		TextTransparency = 1,
		TextStrokeTransparency = 1
	}):Play()

	Debris:AddItem(anchor, 0.8)
end

function ZombieClientPresenter:setupListeners()
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local tracerEvent = remotes:WaitForChild(NetworkProtocol.Events.BULLET_TRACER) :: RemoteEvent
	local damageEvent = remotes:WaitForChild(NetworkProtocol.Events.DAMAGE_INDICATOR) :: RemoteEvent

	tracerEvent.OnClientEvent:Connect(function(fromPos, toPos, weaponId, skinId)
		self:createTracer(fromPos, toPos, weaponId, skinId)
	end)

	damageEvent.OnClientEvent:Connect(function(pos, damage, isHeadshot)
		self:showDamageNumber(pos, damage, isHeadshot)
	end)
end

return ZombieClientPresenter
