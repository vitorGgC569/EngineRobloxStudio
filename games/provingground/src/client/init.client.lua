--!strict
--[[
	Proving Ground — client.

	Input, animation and feedback. It sends intent and never state: the server
	decides whether a swing happened, what it hit and how much it hurt. The
	client's job is to make that decision feel immediate.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Content = require(Shared:WaitForChild("Content"))

local Net = Forge.Net
local Anim = Forge.Anim
local Rig = Forge.Rig
local Feel = Forge.Feel
local UI = Forge.UI
local Input = Forge.Input
local Audio = Forge.Audio
local Visual = Forge.Visual
local Netcode = Forge.Netcode
local Combat = Forge.Combat
local Weapon = Forge.Weapon
local Spring = Forge.Core.Spring

local Hud = require(script:WaitForChild("ui"):WaitForChild("Hud"))

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera

Net.define({
	StateSync = { dir = "s2c" },
	Notify = { dir = "s2c" },
	Hit = { dir = "s2c" },
	Breath = { dir = "s2c" },
	Stamina = { dir = "s2c" },

	Shot = { dir = "s2c" },
	Impact = { dir = "s2c" },
	Weapon = { dir = "s2c" },

	Dodge = { dir = "c2s", rate = 3, shape = { dir = "Vector3" } },
	SetBlock = { dir = "c2s", rate = 8, shape = { on = "boolean" } },
	SetSprint = { dir = "c2s", rate = 8, shape = { on = "boolean" } },

	Shoot = { dir = "c2s", rate = 14, shape = { dir = "Vector3" } },
	DrawStart = { dir = "c2s", rate = 8 },
	DrawCancel = { dir = "c2s", rate = 8 },
	Reload = { dir = "c2s", rate = 4 },
	SwapWeapon = { dir = "c2s", rate = 3 },
})

-- The client needs the same weapon numbers the server has, for the tracer it
-- draws before the server answers and for the numbers on the HUD. It never
-- calls Weapon.fire: reading the definitions is not authority.
Content.load()

Anim.registerAll(require(ReplicatedStorage.Forge.Anim.Presets))

-- Declared here, above the Netcode command that closes over them. Written
-- lower down they resolve to nil globals inside the prediction, which
-- compiles and does nothing.
local animator = nil
local combo, lastAttack, lastDodge, blocking = 0, 0, 0, false

--[[
	The predicted half of the attack.

	`predict` is everything the player should see immediately; `rollback` is what
	to take back if the server says no. Keeping them next to each other is the
	only way they stay in agreement.
]]
Netcode.define("attack", {
	predict = function(data)
		if animator then
			animator:play("attack_" .. combo)
		end
		Feel.shake(combo == 3 and 0.35 or 0.14)
		Audio.play("swing", { pitch = combo == 3 and 0.85 or nil })
	end,
	rollback = function(_data, reason)
		-- A refused swing stops mid-animation and gives the combo step back,
		-- so a rejected third hit does not leave the chain believing it landed.
		if animator then
			animator:stop("attack_" .. combo)
		end
		combo = math.max(0, combo - 1)
		lastAttack = 0
		if reason ~= "cooldown" then
			UI.toast("swing refused: " .. reason, { color = UI.theme.color.textDim, duration = 1.5 })
		end
	end,
})

Feel.mount()
Hud.init()

Visual.autoQuality()

--[[
	Derived from `ashen_dusk`, lifted for readability.

	The preset is a mood, and applied straight it made the arena floor almost
	black — atmospheric, and impossible to read an enemy against. In a game
	whose entire loop is seeing an attack coming, legibility beats mood every
	time. Ambient up, fog pushed back, saturation less crushed.
]]
Visual.defineLook("arena_dusk", (function()
	local look = table.clone(Visual.presets.ashen_dusk)
	look.brightness = 2.1
	look.ambient = Color3.fromRGB(84, 74, 76)
	look.outdoorAmbient = Color3.fromRGB(148, 128, 128)
	look.fogStart = 120
	look.fogEnd = 620
	look.colorCorrection = table.clone(look.colorCorrection)
	look.colorCorrection.saturation = -0.1
	look.colorCorrection.brightness = 0.03
	look.depthOfField = nil -- blur reads as "can't see" in a fight
	return look
end)())

-- No `Visual.apply` here: `Sky.setHour` below writes the same properties and
-- would win anyway. Two sources for one look is how they drift apart.

--[[
	Sky, clouds and water, but the clock is held rather than cycled.

	An arena whose light changes mid-fight is a readability problem: the same
	enemy silhouette has to work at every hour, and it will not. Golden hour is
	picked and pinned.
]]
local Sky = require(ReplicatedStorage.Forge.Visual.Sky)
Sky.install()
-- `pin`, not `setHour`: the place file's ClockTime replicates in afterwards
-- and would win, leaving the arena lit at 9am while the code says golden hour.
Sky.pin(18.2)

--[[
	Combat audio.

	These were marketplace ids I had no way to check, and the first one the game
	actually reached logged "Asset type does not match requested type" on every
	hit — an id I had written down as a sound that is not one. Guessed ids are
	not content; they are errors with a delay.

	`rbxasset://` files ship inside the Roblox client. They cost no download,
	they cannot 404, and they work with no internet and no marketplace. They are
	placeholders and they sound like placeholders — but they are honest, and the
	cue names are what the game refers to, so swapping in real assets later is a
	one-line change per line.

	`cooldown` stops a three-hit combo from stacking three identical swings into
	one smear.
]]
Audio.defineMany({
	["swing"] = { id = "rbxasset://sounds/swoosh.mp3", volume = 0.35, pitch = { 0.9, 1.15 }, cooldown = 0.08 },
	["hit.flesh"] = { id = "rbxasset://sounds/snap.mp3", volume = 0.55, pitch = { 0.88, 1.12 }, cooldown = 0.03 },
	["hit.crit"] = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.7, pitch = { 1.0, 1.1 } },
	["hit.blocked"] = { id = "rbxasset://sounds/metal.ogg", volume = 0.5, pitch = { 0.9, 1.0 } },
	["hurt"] = { id = "rbxasset://sounds/uuhhh.mp3", volume = 0.6, pitch = { 0.7, 0.8 }, cooldown = 0.2 },
	["shot.bow"] = { id = "rbxasset://sounds/swoosh.mp3", volume = 0.4, pitch = { 1.25, 1.4 }, cooldown = 0.05 },
	["shot.cannon"] = { id = "rbxasset://sounds/collide.wav", volume = 0.5, pitch = { 0.85, 0.95 }, cooldown = 0.03 },
	["reload"] = { id = "rbxasset://sounds/switch.wav", volume = 0.35, pitch = { 1.1, 1.2 } },
	["impact.world"] = { id = "rbxasset://sounds/bass.mp3", volume = 0.3, pitch = { 0.9, 1.2 }, cooldown = 0.04 },
})
--[[
	Every action the game has, on every device.

	This replaced ContextActionService bindings that named MouseButton1 and Q
	directly. Nothing below refers to a key, so the phone port is the three
	`touch` tables and nothing else.
]]
Input.defineActions({
	strike = {
		keyboard = Enum.UserInputType.MouseButton1,
		gamepad = Enum.KeyCode.ButtonR2,
		touch = { label = "Strike", order = 1, size = 88 },
	},
	dodge = {
		keyboard = Enum.KeyCode.Q,
		gamepad = Enum.KeyCode.ButtonL2,
		touch = { label = "Dodge", order = 2 },
	},
	block = {
		keyboard = Enum.UserInputType.MouseButton2,
		gamepad = Enum.KeyCode.ButtonL1,
		touch = { label = "Block", order = 3 },
	},
	sprint = {
		keyboard = Enum.KeyCode.LeftShift,
		gamepad = Enum.KeyCode.ButtonL3,
		touch = { label = "Run", order = 4 },
	},
	shoot = {
		keyboard = Enum.KeyCode.F,
		gamepad = Enum.KeyCode.ButtonR1,
		touch = { label = "Shoot", order = 5, size = 78 },
	},
	reload = {
		keyboard = Enum.KeyCode.R,
		gamepad = Enum.KeyCode.ButtonX,
		touch = { label = "Reload", order = 6 },
	},
	swapWeapon = {
		keyboard = Enum.KeyCode.C,
		gamepad = Enum.KeyCode.ButtonY,
		touch = { label = "Swap", order = 7 },
	},
})
Input.mount()

-- ============================== character ===================================

--[[
	Build the animator for a character.

	The waits are bounded and the result is checked. The server spawns the
	player twice in the ordinary case — once explicitly once the arena exists,
	then again through CharacterAutoLoads — so this can be handed a model that
	is replaced while it is still waiting on its parts. An unbounded
	`WaitForChild` on that dead model yields forever, and the player ends up
	with no animator at all: stiff, sliding, and silent about why.
]]
local function onCharacter(character: Model)
	print("[anim] onCharacter entered for " .. character.Name)
	if not character:WaitForChild("Humanoid", 10) or not character:WaitForChild("HumanoidRootPart", 10) then
		warn("[anim] gave up waiting for the rig's parts")
		return
	end
	if player.Character ~= character then
		warn("[anim] character was superseded while waiting; skipping")
		return
	end
	Rig.stripDefaultAnimate(character)

	if animator then
		animator:destroy()
	end
	animator = Anim.new(character)
	Anim.bind(animator)
	Feel.registerAnimator(animator)

	-- Says out loud what the animator found. A rig whose joints do not resolve
	-- animates nothing and reports nothing, which is exactly how a stiff,
	-- sliding character went unexplained for as long as it did.
	local shape = animator:describe()
	local kinds = shape.jointKinds or {}
	print(string.format(
		"[anim] rig=%s joints=%d motor6d=%d constraint=%d locomotion=%s",
		tostring(shape.rig), #shape.joints,
		kinds.Motor6D or -1, kinds.AnimationConstraint or -1,
		tostring(shape.locomotion)
	))

	animator:onMarker(function(_clip, marker)
		if marker == "trail_on" then
			Anim.setTrail(character, true)
		elseif marker == "trail_off" then
			Anim.setTrail(character, false)
		end
	end)
end

if player.Character then
	task.spawn(onCharacter, player.Character)
end
player.CharacterAdded:Connect(onCharacter)

-- ================================ input =====================================
local COOLDOWN, COMBO_WINDOW, DODGE_COOLDOWN = 0.52, 1.1, 1.0

local function aim(): Vector3
	local look = camera.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.05 then
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		return root and (root :: BasePart).CFrame.LookVector or Vector3.new(0, 0, -1)
	end
	return flat.Unit
end

local function attack()
	local now = os.clock()
	if now - lastAttack < COOLDOWN or blocking then
		return
	end
	if now - lastAttack > COMBO_WINDOW then
		combo = 0
	end
	combo = (combo % 3) + 1
	lastAttack = now

	local direction = aim()
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		root.CFrame = CFrame.lookAt(root.Position, root.Position + direction)
	end

	if animator then
		animator:play("attack_" .. combo)
	end
	-- Predicted: the swing, the shake and the sound happen now, not after a
	-- round trip. The server may still refuse, and `rollback` undoes it.
	Netcode.perform("attack", { dir = direction })
end

local function dodge()
	local now = os.clock()
	if now - lastDodge < DODGE_COOLDOWN or (Hud.state.stamina or 0) < 24 then
		return
	end
	lastDodge = now

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not (humanoid and root) then
		return
	end

	local move = humanoid.MoveDirection
	local direction = move.Magnitude > 0.1 and move.Unit or -root.CFrame.LookVector

	if animator then
		animator:play("dodge")
	end
	Net.send("Dodge", { dir = direction })

	-- Local impulse so the roll starts on the keypress, not on the round trip.
	-- The server still owns the i-frames; this only moves the body.
	root:ApplyImpulse(direction * 62 * root.AssemblyMass)
end

local function setBlocking(on: boolean)
	if blocking == on then
		return
	end
	blocking = on
	Net.send("SetBlock", { on = on })
	if animator then
		if on then
			animator:play("block")
		else
			animator:stop("block")
		end
	end
end

Input.bind("strike", function(phase)
	if phase == "begin" then
		attack()
	end
end)

Input.bind("dodge", function(phase)
	if phase == "begin" then
		dodge()
	end
end)

Input.bind("block", function(phase)
	setBlocking(phase == "begin")
end)

--[[
	Sprint sends intent only.

	The client never touches WalkSpeed: the server owns it, because a client
	that sets its own speed sets it to whatever it likes. Holding the key while
	exhausted is allowed and simply does nothing, which is better than the input
	going dead — the player learns the rule by feeling it.
]]
Input.bind("sprint", function(phase)
	Net.send("SetSprint", { on = phase == "begin" })
end)

-- =============================== shooting ===================================
--[[
	The ranged half.

	Three things happen on the trigger and only one of them is authoritative:

	  1. the animation and the sound play now, locally;
	  2. a tracer flies now, locally, and decides nothing;
	  3. a direction goes to the server, which owns everything that matters.

	If the server disagrees, the tracer was wrong by a few centimetres and no
	one can tell. If step 3 were skipped, the game would be a client-side
	shooting gallery with a server watching.
]]
local ranged = {
	id = "longbow",
	ammo = 1,
	reserve = -1,
	reloading = false,
	drawing = false,
	drawStart = 0,
}

-- Recoil lives entirely on the client: the camera belongs to the player, and a
-- server that moves it is a server fighting the mouse. A spring rather than a
-- tween because the kick is interrupted constantly -- by the next shot.
local recoilPitch = Spring.new(0, { frequency = 5.5, damping = 0.55 })
local recoilYaw = Spring.new(0, { frequency = 5.5, damping = 0.55 })

local function rangedDef(): any
	return Weapon.definition(ranged.id) or Weapon.definition("longbow")
end

-- Melee aims flat; a shot does not. This one keeps the camera's pitch, which
-- is the whole point of being able to shoot a target on a rise.
local function aimFull(): Vector3
	local look = camera.CFrame.LookVector
	return look.Magnitude > 0.01 and look.Unit or Vector3.new(0, 0, -1)
end

local function muzzle(direction: Vector3): Vector3
	local character = player.Character
	local head = character and character:FindFirstChild("Head") :: BasePart?
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local anchor = head or root
	-- Same formula the server uses. If these two drift apart, the tracer
	-- leaves from somewhere the bullet did not.
	return anchor and (anchor :: BasePart).Position + direction * 2.2 or camera.CFrame.Position
end

--[[
	Draw the shot the player just took, before the server has confirmed it.

	Deterministic spread means the pellet direction here is the same one the
	server computes from the same seed -- except the client does not know the
	seed yet, so it draws the centre of the cone. At a degree or two of spread
	that is invisible; a shotgun would need the seed predicted too.
]]
local function drawLocalShot(direction: Vector3, charge: number)
	local def = rangedDef()
	local origin = muzzle(direction)

	if def.mode == "hitscan" then
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { player.Character }
		local result = Workspace:Raycast(origin, direction * def.range, params)
		Combat.beam(origin, result and result.Position or (origin + direction * def.range), {
			color = def.color,
			width = 0.1,
			life = 0.05,
		})
	else
		local pv = def.projectile or {}
		Combat.tracer({
			origin = origin,
			direction = direction,
			speed = (pv.speed or 160) * (0.5 + 0.5 * charge),
			gravity = pv.gravity or 0,
			life = pv.life or 4,
			visual = pv.visual,
		})
	end
end

local function shotSound(def: any, position: Vector3?)
	local cue = def.mode == "hitscan" and "shot.cannon" or "shot.bow"
	if position then
		Audio.playAt(cue, position)
	else
		Audio.play(cue)
	end
end

local function fireNow()
	local def = rangedDef()
	if ranged.reloading or ranged.ammo <= 0 then
		if ranged.ammo <= 0 and not ranged.reloading then
			Net.send("Reload", {})
		end
		return
	end

	local direction = aimFull()
	local charge = 1
	if def.charge then
		local held = os.clock() - ranged.drawStart
		charge = math.clamp(held / def.charge.time, 0, 1)
		-- The same gate the server applies. Checked here as well so a tap on
		-- the key does not play a loose animation for an arrow that the server
		-- is about to refuse.
		if charge < (def.charge.minRatio or 0) then
			Net.send("DrawCancel", {})
			if animator then
				animator:stop(def.aimClip, false)
			end
			ranged.drawing = false
			return
		end
	end

	Net.send("Shoot", { dir = direction })

	if animator then
		animator:stop(def.aimClip, true)
		animator:play(def.clip)
	end
	drawLocalShot(direction, charge)
	shotSound(def)

	local kick = (def.recoil and def.recoil.pitch or 1) * (def.charge and charge or 1)
	recoilPitch:impulse(kick * 22)
	recoilYaw:impulse((math.random() * 2 - 1) * (def.recoil and def.recoil.yaw or 0.3) * 22)
	Feel.shake(0.1 * kick)

	ranged.drawing = false
end

Input.bind("shoot", function(phase)
	local def = rangedDef()
	if phase == "begin" then
		if def.charge then
			-- Charged: the press starts the draw, the release looses it.
			ranged.drawing = true
			ranged.drawStart = os.clock()
			Net.send("DrawStart", {})
			if animator then
				animator:play(def.aimClip)
			end
		else
			fireNow()
		end
	elseif phase == "end" then
		if def.charge and ranged.drawing then
			fireNow()
			if animator then
				animator:stop(def.aimClip, false)
			end
		end
	end
end)

Input.bind("reload", function(phase)
	if phase ~= "begin" then
		return
	end
	local def = rangedDef()
	Net.send("Reload", {})
	if animator and def.reloadClip then
		animator:play(def.reloadClip)
	end
	Audio.play("reload")
end)

Input.bind("swapWeapon", function(phase)
	if phase == "begin" then
		Net.send("SwapWeapon", {})
	end
end)

-- Runs after the default camera has written its CFrame, so the kick survives
-- the frame instead of being overwritten by it.
RunService:BindToRenderStep("recoil", Enum.RenderPriority.Camera.Value + 1, function(dt)
	local pitch = recoilPitch:step(dt)
	local yaw = recoilYaw:step(dt)
	if math.abs(pitch) < 0.01 and math.abs(yaw) < 0.01 then
		return
	end
	camera.CFrame = camera.CFrame * CFrame.Angles(math.rad(pitch), math.rad(yaw), 0)
end)

-- The server is the only source of ammo. The client displays it and never
-- decrements it locally, so a refused shot cannot leave the HUD lying.
Net.on("Weapon", function(payload)
	ranged.id = payload.id or ranged.id
	ranged.ammo = payload.ammo or 0
	ranged.reserve = payload.reserve or -1
	ranged.reloading = payload.reloading == true
	Hud.setWeapon(rangedDef().label or ranged.id, ranged.ammo, ranged.reloading)

	-- The resting pose for "carrying a weapon". Priority 1, so every other
	-- clip in the game plays straight over the top of it and it simply
	-- reappears underneath when they finish.
	if animator then
		animator:play("hold")
	end
end)

--[[
	Somebody else's shot.

	The shooter skips this: it already drew its own tracer at the moment of the
	trigger, and drawing a second one on the confirmation would put two arrows
	in the air for every one fired.
]]
Net.on("Shot", function(payload)
	if payload.shooter == player then
		return
	end
	local def = Weapon.definition(payload.id)
	if not def then
		return
	end
	if payload.mode == "hitscan" then
		Combat.beam(payload.origin, payload.hitPos or (payload.origin + payload.dir * def.range), {
			color = def.color,
			width = 0.1,
			life = 0.05,
		})
	else
		local pv = def.projectile or {}
		Combat.tracer({
			origin = payload.origin,
			direction = payload.dir,
			speed = (pv.speed or 160) * (0.5 + 0.5 * (payload.charge or 1)),
			gravity = pv.gravity or 0,
			life = pv.life or 4,
			visual = pv.visual,
		})
	end
	shotSound(def, payload.origin)
end)

-- Where a shot landed on something that is not a body: chips, dust, a tick.
Net.on("Impact", function(payload)
	if payload.onFlesh then
		return -- the Hit handler already covers that case, and better
	end
	Feel.hit(payload.pos, {
		power = 0.5,
		color = Color3.fromRGB(214, 200, 176),
		direction = payload.normal,
		kind = "spray",
	})
	Audio.playAt("impact.world", payload.pos)
end)

-- ============================== feedback ====================================
Net.on("Hit", function(payload)
	local text = payload.blocked and "blocked" or tostring(payload.amount)
	Feel.number(payload.pos, text, {
		crit = payload.crit,
		color = payload.blocked and Color3.fromRGB(160, 190, 220)
			or (payload.kind == "enemy" and Color3.fromRGB(255, 130, 130) or nil),
	})
	Feel.hit(payload.pos, {
		power = payload.crit and 1.6 or 1,
		color = payload.crit and Color3.fromRGB(255, 210, 120) or Color3.fromRGB(255, 190, 150),
		direction = payload.dir,
		crit = payload.crit,
		kind = payload.dir and "spray" or "burst",
	})
	if payload.blocked then
		Audio.playAt("hit.blocked", payload.pos)
	elseif payload.crit then
		Audio.playAt("hit.crit", payload.pos)
		Audio.duck(0.5, 0.6)
	else
		Audio.playAt("hit.flesh", payload.pos)
	end

	if payload.kind == "enemy" then
		Feel.screenTint(Color3.fromRGB(180, 40, 40), 0.22, 0.3)
		Audio.play("hurt")
	end
end)

--[[
	Out of breath.

	Fired near the runner rather than only to them: seeing another player
	panting tells you they cannot dodge, which is worth more than the bar in
	your own corner.
]]
Net.on("Breath", function(payload)
	local character = payload.character
	if typeof(character) ~= "Instance" or not character:IsA("Model") then
		return
	end
	Feel.breathing(character, payload.on == true, { interval = 0.8, count = 6 })

	if character == player.Character and payload.on then
		Feel.screenTint(Color3.fromRGB(140, 160, 190), 0.12, 0.5)
		UI.toast("out of breath", { color = UI.theme.color.textDim, duration = 1.5 })
	end
end)

Net.on("Notify", function(payload)
	UI.toast(payload.text, { color = payload.color })
end)

print(string.format("[%s] client ready", Config.name))
