--!strict
-- Bot bodies. Real Roblox avatars with real animations.
--
-- Bots used to be five hand-welded Parts with no arms and no Animator, so they slid around
-- as rigid blocks — the single most obvious tell that they weren't players. We now build a
-- proper R15 avatar via HumanoidDescription (first-party, nothing to own or upload) and
-- drive the stock animation set on the server so every client sees it.
--
-- The old block rig is kept as a fallback: if the avatar API ever fails we degrade to a
-- worse-looking bot rather than a broken round.

local Players = game:GetService("Players")

local Rig = {}

-- Verified against the live engine with tests/asset-probe.lua — every id below loaded and
-- reported a non-zero track length. Do not add ids here without re-running that probe.
Rig.Animations = {
	idle = { 507766666, 507766951, 507766388 },
	walk = { 507777826 },
	run = { 507767714 },
	jump = { 507765000 },
	fall = { 507767968 },
	climb = { 507765644 },
}

-- Body colours to vary bots a little; a lobby of identical avatars reads as fake too.
local SKIN_TONES = {
	Color3.fromRGB(255, 204, 153),
	Color3.fromRGB(234, 184, 146),
	Color3.fromRGB(204, 142, 105),
	Color3.fromRGB(160, 105, 60),
	Color3.fromRGB(110, 72, 46),
	Color3.fromRGB(245, 225, 190),
}

local SHIRT_COLORS = {
	Color3.fromRGB(70, 90, 130),
	Color3.fromRGB(120, 70, 70),
	Color3.fromRGB(70, 110, 85),
	Color3.fromRGB(150, 120, 60),
	Color3.fromRGB(90, 80, 110),
	Color3.fromRGB(60, 60, 68),
}

local function pick<T>(list: { T }, rng: Random): T
	return list[rng:NextInteger(1, #list)]
end

-- Fallback: the original hand-built R6 block rig, unchanged in spirit. Ugly but reliable.
function Rig.buildFallback(name: string, rng: Random): (Model, Humanoid, BasePart)
	local model = Instance.new("Model")
	model.Name = name

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Transparency = 1
	root.CanCollide = false
	root.Parent = model

	local torso = Instance.new("Part")
	torso.Name = "Torso"
	torso.Size = Vector3.new(2, 2, 1)
	torso.Color = pick(SHIRT_COLORS, rng)
	torso.Parent = model

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(2, 1, 1)
	head.Color = pick(SKIN_TONES, rng)
	head.Parent = model

	local function weld(a: BasePart, b: BasePart, offset: CFrame)
		local motor = Instance.new("Motor6D")
		motor.Part0 = a
		motor.Part1 = b
		motor.C0 = offset
		motor.Parent = a
	end
	weld(root, torso, CFrame.new())
	weld(torso, head, CFrame.new(0, 1.5, 0))

	for i, side in { -1, 1 } do
		local leg = Instance.new("Part")
		leg.Name = (i == 1 and "Left" or "Right") .. "Leg"
		leg.Size = Vector3.new(1, 2, 1)
		leg.Color = Color3.fromRGB(50, 60, 80)
		leg.Parent = model
		weld(torso, leg, CFrame.new(side * 0.5, -2, 0))
	end

	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R6
	humanoid.HipHeight = 2
	humanoid.Parent = model

	model.PrimaryPart = root
	return model, humanoid, root
end

-- Preferred path: a genuine R15 avatar.
function Rig.build(name: string, rng: Random): (Model, Humanoid, BasePart)
	local ok, model = pcall(function()
		local desc = Instance.new("HumanoidDescription")
		desc.HeadColor = pick(SKIN_TONES, rng)
		desc.LeftArmColor = desc.HeadColor
		desc.RightArmColor = desc.HeadColor
		desc.TorsoColor = pick(SHIRT_COLORS, rng)
		desc.LeftLegColor = Color3.fromRGB(50, 60, 80)
		desc.RightLegColor = desc.LeftLegColor
		return Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R15)
	end)

	if not ok or model == nil or typeof(model) ~= "Instance" then
		warn("[INFECTED] avatar rig unavailable, using block fallback:", tostring(model))
		return Rig.buildFallback(name, rng)
	end

	local built = model :: Model
	built.Name = name
	local humanoid = built:FindFirstChildOfClass("Humanoid")
	local root = built:FindFirstChild("HumanoidRootPart")
	if humanoid == nil or root == nil or not root:IsA("BasePart") then
		built:Destroy()
		return Rig.buildFallback(name, rng)
	end

	-- Nothing should be able to shove a bot out of the world geometry.
	humanoid.BreakJointsOnDeath = false
	-- The stock "Animate" script is a LocalScript and never runs for a server-owned NPC,
	-- so remove it and drive animations ourselves (see Rig.animate).
	local stockAnimate = built:FindFirstChild("Animate")
	if stockAnimate then
		stockAnimate:Destroy()
	end

	return built, humanoid, root
end

-- Drive the default animation set from the server so every client sees the bot move.
-- Returns a cleanup function.
function Rig.animate(humanoid: Humanoid, rng: Random): () -> ()
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator == nil then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	local anim = animator :: Animator

	local function track(id: number): AnimationTrack?
		local animation = Instance.new("Animation")
		animation.AnimationId = "rbxassetid://" .. id
		local ok, loaded = pcall(function()
			return anim:LoadAnimation(animation)
		end)
		if not ok then
			return nil
		end
		return loaded
	end

	local idle = track(pick(Rig.Animations.idle, rng))
	local walk = track(Rig.Animations.walk[1])
	local run = track(Rig.Animations.run[1])
	local jump = track(Rig.Animations.jump[1])
	local fall = track(Rig.Animations.fall[1])

	if idle then
		idle.Priority = Enum.AnimationPriority.Idle
		idle.Looped = true
	end
	for _, t in { walk, run } do
		if t then
			t.Priority = Enum.AnimationPriority.Movement
			t.Looped = true
		end
	end

	local current: AnimationTrack? = nil
	local function play(t: AnimationTrack?, speed: number?)
		if t == current then
			if t and speed then
				t:AdjustSpeed(speed)
			end
			return
		end
		if current then
			current:Stop(0.15)
		end
		current = t
		if t then
			t:Play(0.15)
			if speed then
				t:AdjustSpeed(speed)
			end
		end
	end

	local conns: { RBXScriptConnection } = {}

	table.insert(
		conns,
		humanoid.Running:Connect(function(speed)
			if speed < 0.5 then
				play(idle)
			elseif speed > 15 then
				-- Scale the run cycle to actual speed so sprinting doesn't moonwalk.
				play(run, speed / 16)
			else
				play(walk, speed / 12)
			end
		end)
	)

	table.insert(
		conns,
		humanoid.StateChanged:Connect(function(_, new)
			if new == Enum.HumanoidStateType.Jumping then
				if jump then
					jump:Play(0.1)
				end
			elseif new == Enum.HumanoidStateType.Freefall then
				if fall then
					fall:Play(0.2)
				end
			elseif new == Enum.HumanoidStateType.Landed then
				if fall then
					fall:Stop(0.2)
				end
			end
		end)
	)

	play(idle)

	return function()
		for _, c in conns do
			c:Disconnect()
		end
		for _, t in { idle, walk, run, jump, fall } do
			if t then
				t:Stop(0)
				t:Destroy()
			end
		end
	end
end

return Rig
