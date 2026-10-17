--!strict
--[[
	CastController — the rod, the line, and the fight.

	Client side of fishing, in one state machine:

	  idle -> charging (hold) -> casting (release) -> waiting -> biting -> idle

	The server owns the fish; this file owns the *feel*: the charge bar, the
	line drawn to the bobber, the fight minigame (ReelMath, the same module
	the server can audit) and the honest report of how it went. A cast is
	refused locally before it is refused by the server whenever the client
	already knows better -- aiming over a hill, or at your own feet.

	The pictures ride in two neighbours -- `HeldRod` for the rod in the hand,
	`FishVisual` for what happens under the water -- and this file is only
	the wire between the cast's beats and them: call each on its beat, and
	forget it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local Net = Forge.Net
local UI = Forge.UI

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Items = require(Shared.Items)
local ReelMath = require(Shared.ReelMath)

local state = require(script.Parent.Parent.state)
local audio = require(script.Parent.Parent.audio)
local Reel = require(script.Parent.Parent.ui.ReelUI)
local HeldRod = require(script.Parent.Parent.visuals.HeldRod)
local FishVisual = require(script.Parent.Parent.visuals.FishVisual)

local CastController = {}

local T = UI.theme

local player = Players.LocalPlayer
local SEA = Config.waterLevel

local phase = "idle" -- idle | charging | casting | waiting | biting
local chargeStart = 0
local chargeBar: any = nil
local sessionId: number? = nil
local reelState: any = nil
local reelParams: any = nil
local reelStart = 0
local reelHold = false
--: The pull is tracked from InputBegan/InputEnded rather than read back with
--: IsMouseButtonPressed, because a bridge-driven fight delivers real input
--: events but never writes the engine's mouse state. Event-tracking is also
--: what touch already required; this only makes the two agree.
local pointerDown = false
local reelConn: RBXScriptConnection? = nil
local beamParts: { any } = {}

-- ================================ visuals ===================================
local function chargeWidget()
	if chargeBar then
		return chargeBar
	end
	local gui = UI.mount("TideboundCast", { displayOrder = 12 })
	local holder = UI.panel(gui, {
		name = "Charge",
		size = UDim2.fromOffset(260, 30),
		pos = UDim2.new(0.5, 0, 1, -110),
		anchor = Vector2.new(0.5, 1),
		visible = false,
	})
	UI.label(holder, "CAST POWER", {
		size = T.text.xs,
		color = T.color.textDim,
		pos = UDim2.fromOffset(12, 4),
		frameSize = UDim2.new(0, 120, 0, 12),
	})
	chargeBar = UI.bar(holder, {
		color = T.color.accent,
		size = UDim2.new(1, -24, 0, 8),
		pos = UDim2.fromOffset(12, 17),
	})
	chargeBar.holder = holder
	return chargeBar
end

local function showCharge(visible: boolean)
	local bar = chargeWidget()
	if bar.holder then
		bar.holder.Visible = visible
	end
end

local function clearLine()
	for _, part in beamParts do
		if part and part.Parent then
			part:Destroy()
		end
	end
	beamParts = {}
end

--: This player's bobber, wherever the server put it, or nil between casts.
local function bobberPart(): BasePart?
	local folder = Workspace:FindFirstChild("Bobbers")
	local part = folder and folder:FindFirstChild("Bobber_" .. tostring(player.UserId), true)
	if part and part:IsA("BasePart") then
		return part
	end
	return nil
end

--[[
	Draw the line from the rod tip to the bobber. Two attachments and a
	beam -- the cheapest thing that reads unmistakably as fishing.

	The tip comes from HeldRod and belongs to it: it is attached to here,
	never destroyed here. Without a rod (no character yet) the line falls
	back to a point by the root's shoulder, which is where it hung before
	there was a rod at all.
]]
local function drawLine()
	clearLine()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local part = bobberPart()
	if not part then
		return
	end

	local held = HeldRod.tip()
	local owned: { Instance } = {}
	if not held then
		if not root then
			return
		end
		local anchor = Instance.new("Attachment")
		anchor.Name = "LineAnchor"
		anchor.Position = Vector3.new(0.6, -0.2, -1.2)
		anchor.Parent = root
		held = anchor
		table.insert(owned, anchor)
	end

	local target = Instance.new("Attachment")
	target.Name = "LineTarget"
	target.Parent = part

	local beam = Instance.new("Beam")
	beam.Attachment0 = held
	beam.Attachment1 = target
	beam.Width0 = 0.06
	beam.Width1 = 0.06
	beam.FaceCamera = true
	beam.Color = ColorSequence.new(Color3.fromRGB(236, 240, 244))
	beam.Transparency = NumberSequence.new(0.25)
	beam.Parent = part

	table.insert(owned, target)
	table.insert(owned, beam)
	beamParts = owned
end

-- ============================== the fight ====================================
local function stopReel()
	if reelConn then
		reelConn:Disconnect()
		reelConn = nil
	end
	reelState = nil
	reelParams = nil
end

local function finishReel(won: boolean)
	local state_ = reelState
	if not state_ then
		return
	end
	local elapsed = os.clock() - reelStart
	local integrity = math.clamp(state_.integrity, 0, 1)
	local id = sessionId
	stopReel()
	Reel.dismiss()
	--: The fight is over this instant, whatever the server later says: a
	--: won fight swings the rod overhead, a lost one gives it back to the
	--: sea. CastEnd arrives a round trip later and returns it to rest.
	HeldRod.finish(won)
	if id then
		Net.send("ReelResult", {
			sessionId = id,
			won = won,
			integrity = integrity,
			elapsed = elapsed,
		})
	end
	if state.get() and not state.get().tutorial.seen.bite then
		Net.send("TutorialDone", { step = "bite" })
	end
end

local function beginReel(payload: any)
	sessionId = payload.sessionId
	reelParams = {
		seed = payload.seed,
		difficulty = payload.difficulty,
		duration = payload.duration,
	}
	reelState = ReelMath.new(reelParams)
	reelStart = os.clock()
	phase = "biting"
	Reel.show()
	audio.sfx("ui.open")
end

--: One RenderStepped loop, owned by the fight and torn down with it.
local function startReelLoop()
	if reelConn then
		reelConn:Disconnect()
	end
	reelConn = RunService.RenderStepped:Connect(function(dt)
		local current = reelState
		if not current then
			return
		end
		if current.done then
			finishReel(current.won)
			return
		end
		reelHold = pointerDown
		ReelMath.step(current, reelHold, dt)
		Reel.draw({
			centre = ReelMath.zoneCentre(reelParams, current.t),
			half = ReelMath.zoneHalf(reelParams),
			marker = current.marker,
			progress = current.progress,
			integrity = current.integrity,
			remaining = reelParams.duration - current.t,
			hold = reelHold,
		})
		if current.done then
			finishReel(current.won)
		end
	end)
end

-- ============================== casting =====================================
local function rodRange(): number
	local rod = state.rod()
	return rod and rod.range or 42
end

local function castTarget(): Vector3?
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end
	local mouse = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mouse.X, mouse.Y)
	local direction = ray.Direction
	if direction.Y >= -0.02 then
		return nil
	end
	local origin = ray.Origin
	local t = (SEA - origin.Y) / direction.Y
	if t <= 0 then
		return nil
	end
	--: Charge sets the distance: quick click drops the bait near your feet,
	--: a held cast reaches the rod's full range.
	local held = math.clamp((os.clock() - chargeStart) / Config.castChargeSeconds, 0, 1)
	local reach = rodRange() * (0.35 + 0.65 * held)
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil
	end
	local from = root.Position
	local hit = origin + direction * t
	local flat = Vector3.new(hit.X - from.X, 0, hit.Z - from.Z)
	if flat.Magnitude > reach then
		hit = from + Vector3.new(flat.Unit.X, 0, flat.Unit.Z) * reach
		hit = Vector3.new(hit.X, SEA, hit.Z)
	end
	return hit
end

local function doCast()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	local target = castTarget()
	if not target then
		audio.sfx("ui.error")
		return
	end
	local origin = root.Position
	phase = "casting"
	--: The rod answers the release before the server does.
	HeldRod.windup()
	Net.send("Cast", { origin = origin, target = target })
	audio.sfx("machine.clank")
	if state.get() and not state.get().tutorial.seen.cast then
		Net.send("TutorialDone", { step = "cast" })
	end
end

-- =============================== inputs =====================================
function CastController.start()
	HeldRod.start()
	local bar = chargeWidget()

	RunService.RenderStepped:Connect(function()
		if phase == "charging" then
			local held = math.clamp((os.clock() - chargeStart) / Config.castChargeSeconds, 0, 1)
			bar:set(held)
		end
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			pointerDown = true
		end
		if processed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			if phase == "idle" then
				phase = "charging"
				chargeStart = os.clock()
				showCharge(true)
			end
		elseif input.KeyCode == Enum.KeyCode.Q then
			if phase == "waiting" then
				Net.send("CancelCast", {})
			end
		end
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			pointerDown = false
			if phase == "charging" then
				showCharge(false)
				doCast()
			end
		end
	end)

	-- ============================== server events =============================
	Net.on("CastState", function(payload: any)
		sessionId = payload.sessionId
		phase = "waiting"
		--: The rod leans toward the bobber while the line settles; the fish
		--: shadow under the water is FishVisual's own resolve of the part.
		local bobber = bobberPart()
		if bobber then
			HeldRod.aimAt(bobber.Position)
		end
		FishVisual.shadow()
		task.delay(0.1, drawLine)
	end)

	Net.on("Bite", function(payload: any)
		beginReel(payload)
		startReelLoop()
		HeldRod.fight()
		FishVisual.bite()
	end)

	--: The catch card is the bootstrap's; this handler only hands the
	--: payload to the visuals layer. One channel, two listeners, no coupling.
	Net.on("CatchResult", function(payload: any)
		FishVisual.land(payload)
	end)

	Net.on("CastEnd", function(payload: any)
		if sessionId and payload.sessionId and payload.sessionId ~= sessionId then
			return
		end
		phase = "idle"
		sessionId = nil
		stopReel()
		Reel.dismiss()
		showCharge(false)
		clearLine()
		HeldRod.idle()
		FishVisual.clear()
	end)
end

return CastController
