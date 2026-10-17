--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Net = Forge.Net
local Debug = Forge.Debug

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local CombatSys = {}
local playerState: { [Player]: any } = {}

local function stateFor(player: Player)
	local s = playerState[player]
	if not s then
		s = { combo = 0, lastAttack = 0, hp = 100, maxHp = 100, stamina = 100, level = 1, xp = 0 }
		playerState[player] = s
	end
	return s
end

function CombatSys.start()
	-- Melee combo
	Net.on("Attack", function(player: Player, payload: any)
		local kind = tostring((payload or {}).kind or "slash")
		local state = stateFor(player)
		local now = os.clock()
		if now - state.lastAttack > Config.comboWindow then
			state.combo = 0
		end
		state.combo = (state.combo % 3) + 1
		state.lastAttack = now
		local damage = 10 + state.combo * 5
		-- find nearest enemy in range
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not root then return { ok = false, reason = "no character" } end
		local nearest, nearestDist = nil, 12
		for _, m in Workspace:GetDescendants() do
			if m:IsA("Model") and m:GetAttribute("Enemy") and not m:GetAttribute("Dead") and m.PrimaryPart then
				local d = (m.PrimaryPart.Position - root.Position).Magnitude
				if d < nearestDist then
					nearestDist = d
					nearest = m
				end
			end
		end
		if nearest then
			local hp = (nearest:GetAttribute("Hp") or 30) - damage
			nearest:SetAttribute("Hp", hp)
			Net.fireNear(root.Position, 120, "Hit", { pos = nearest.PrimaryPart.Position, amount = damage, crit = state.combo == 3 })
			if hp <= 0 then
				nearest:SetAttribute("Dead", true)
				-- award xp
				state.xp += Config.xpPerKill
				if state.xp >= state.level * 50 then
					state.xp -= state.level * 50
					state.level += 1
					Net.fire(player, "LevelUp", { level = state.level })
				end
				Net.fire(player, "XpGain", { amount = Config.xpPerKill, total = state.xp })
			end
		end
		return { ok = true, combo = state.combo }
	end)

	-- Fireball
	Net.on("Fireball", function(player: Player, payload: any)
		local state = stateFor(player)
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not root then return { ok = false } end
		local dir = Vector3.new(tonumber((payload or {}).x) or 0, tonumber((payload or {}).y) or 0, tonumber((payload or {}).z) or 0)
		if dir.Magnitude < 0.1 then dir = root.CFrame.LookVector end
		dir = dir.Unit
		-- spawn projectile
		local proj = Instance.new("Part")
		proj.Name = "Fireball"
		proj.Size = Vector3.new(2, 2, 2)
		proj.Shape = Enum.PartType.Ball
		proj.Color = Color3.fromRGB(255, 120, 40)
		proj.Material = Enum.Material.Neon
		proj.Anchored = false
		proj.CanCollide = false
		proj.CFrame = root.CFrame + dir * 4
		proj.Parent = Workspace:FindFirstChild("Effects") or Workspace
		local bv = Instance.new("BodyVelocity")
		bv.Velocity = dir * 80
		bv.MaxForce = Vector3.new(1e5, 1e5, 1e5)
		bv.Parent = proj
		game:GetService("Debris"):AddItem(proj, 3)
		-- damage on touch
		proj.Touched:Connect(function(hit)
			if not proj.Parent then return end
			local model = hit:FindFirstAncestorOfClass("Model")
			if model and model:GetAttribute("Enemy") and not model:GetAttribute("Dead") then
				local hp = (model:GetAttribute("Hp") or 30) - 25
				model:SetAttribute("Hp", hp)
				Net.fireNear(proj.Position, 120, "Hit", { pos = model.PrimaryPart and model.PrimaryPart.Position or proj.Position, amount = 25, crit = false })
				if hp <= 0 then
					model:SetAttribute("Dead", true)
					state.xp += Config.xpPerKill
					if state.xp >= state.level * 50 then
						state.xp -= state.level * 50
						state.level += 1
						Net.fire(player, "LevelUp", { level = state.level })
					end
					Net.fire(player, "XpGain", { amount = Config.xpPerKill, total = state.xp })
				end
				proj:Destroy()
			end
		end)
		return { ok = true }
	end)

	-- Dash
	Net.on("Dash", function(player: Player, payload: any)
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not root then return { ok = false } end
		local dx = tonumber((payload or {}).x) or 0
		local dz = tonumber((payload or {}).z) or 0
		local dir = Vector3.new(dx, 0, dz)
		if dir.Magnitude < 0.1 then dir = root.CFrame.LookVector * Vector3.new(1,0,1) end
		dir = Vector3.new(dir.X, 0, dir.Z).Unit
		root.CFrame = root.CFrame + dir * 18
		return { ok = true }
	end)

	-- Handle player join for state sync
	local function onCharacter(player, char)
		char:WaitForChild("HumanoidRootPart", 10)
		local s = stateFor(player)
		Net.fire(player, "StateSync", { level = s.level, xp = s.xp, hp = s.hp, maxHp = s.maxHp })
	end
	Players.PlayerAdded:Connect(function(player)
		local s = stateFor(player)
		player.CharacterAdded:Connect(function(char)
			onCharacter(player, char)
		end)
		if player.Character then
			onCharacter(player, player.Character)
		end
	end)
	for _, p in Players:GetPlayers() do
		local s = stateFor(p)
		if p.Character then
			Net.fire(p, "StateSync", { level = s.level, xp = s.xp, hp = s.hp, maxHp = s.maxHp })
		end
		p.CharacterAdded:Connect(function(char)
			onCharacter(p, char)
		end)
	end

	Debug.info("combat started")
end

function CombatSys.stateFor(player) return stateFor(player) end
return CombatSys