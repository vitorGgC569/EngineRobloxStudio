--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Rng = Forge.Core.Rng
local Debug = Forge.Debug

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Enemies = {}
local enemyCount = 0

local function spawnEnemy(pos: Vector3)
	enemyCount += 1
	local model = Instance.new("Model")
	model.Name = "Enemy" .. enemyCount
	model:SetAttribute("Enemy", true)
	model:SetAttribute("Hp", 30)
	model:SetAttribute("Dead", false)
	model.PrimaryPart = nil

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Position = pos
	root.Anchored = false
	root.CanCollide = true
	root.Color = Color3.fromRGB(200, 60, 60)
	root.Material = Enum.Material.Neon
	root.Parent = model

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(1.5, 1.5, 1.5)
	head.Position = pos + Vector3.new(0, 2, 0)
	head.Anchored = false
	head.Color = Color3.fromRGB(220, 80, 80)
	head.Material = Enum.Material.SmoothPlastic
	head.Parent = model

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = head
	weld.Parent = root

	model.PrimaryPart = root
	model.Parent = Workspace:FindFirstChild("Actors") or Workspace

	-- simple chase loop
	task.spawn(function()
		while model.Parent and not model:GetAttribute("Dead") do
			task.wait(0.3)
			if not model.Parent then break end
			local target = nil
			local bestDist = 200
			for _, p in Players:GetPlayers() do
				local char = p.Character
				local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
				if hrp then
					local d = (hrp.Position - root.Position).Magnitude
					if d < bestDist then
						bestDist = d
						target = hrp
					end
				end
			end
			if target then
				local dir = (target.Position - root.Position)
				dir = Vector3.new(dir.X, 0, dir.Z)
				if dir.Magnitude > 0.1 then
					dir = dir.Unit
					root.CFrame = root.CFrame + dir * 0.6
				end
				-- damage if close
				if bestDist < 4 then
					-- handled by combat on player side; enemy deals contact damage
				end
			end
		end
		if model.Parent and model:GetAttribute("Dead") then
			-- death effect
			for _, part in model:GetChildren() do
				if part:IsA("BasePart") then
					part.Color = Color3.fromRGB(60, 60, 60)
					part.Material = Enum.Material.Slate
				end
			end
			task.delay(2, function() model:Destroy() end)
		end
	end)
	return model
end

function Enemies.start()
	local stream = Rng.stream("anime-arena.enemies")
	-- spawn initial wave
	task.spawn(function()
		task.wait(2)
		local radius = Config.arenaRadius
		for i = 1, Config.maxEnemies do
			local angle = (i / Config.maxEnemies) * math.pi * 2
			local pos = Vector3.new(math.cos(angle) * (radius * 0.5), 3, math.sin(angle) * (radius * 0.5))
			spawnEnemy(pos)
		end
		-- respawn loop
		while true do
			task.wait(8)
			local alive = 0
			for _, m in (Workspace:FindFirstChild("Actors") or Workspace):GetChildren() do
				if m:IsA("Model") and m:GetAttribute("Enemy") and not m:GetAttribute("Dead") then
					alive += 1
				end
			end
			if alive < Config.maxEnemies then
				local angle = stream:nextNumber() * math.pi * 2
				local pos = Vector3.new(math.cos(angle) * (radius * 0.6), 3, math.sin(angle) * (radius * 0.6))
				spawnEnemy(pos)
			end
		end
	end)
	Debug.info("enemies started")
end

return Enemies