--!strict
--[[
	BoatController — the helm.

	Only the driver's machine runs this, and only while they sit at their
	boat's helm, because the driver is the network owner the server handed
	the physics to. The model obeys two lines of intent: a forward velocity
	at the hull's cruise speed, and a yaw rate from the steer input. Buoyancy
	is a spring toward the waterline, which is a lie a boat-shaped game can
	afford and a physics engine cannot be asked for twice.

	The intent can arrive from three devices and `BoatInput` is the only
	place that disagreement is resolved: keys (the original feel, unchanged),
	the gamepad's left thumbstick, and -- on touch devices, only while at the
	helm -- an on-screen two-axis stick worked by one thumb while the other
	steers the camera. The stick is `Active`, so its touches are consumed and
	never begin a cast: fishing from the helm stays one tap away on all three
	devices, exactly as casting from shore does.

	Nothing here is authoritative. The server built the boat and can take it
	away -- including by holding it on its anchor, which this file must obey.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local UI = Forge.UI

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BoatInput = require(Shared.BoatInput)
local Config = require(Shared.Config)
local Items = require(Shared.Items)

local BoatController = {}

local T = UI.theme

local player = Players.LocalPlayer
local SEA = Config.waterLevel

local function boatIdOf(model: Model): string
	local id = string.match(model.Name, "^(.+)_%d+$")
	if id and Items.boatById[id] then
		return id
	end
	return "rowboat"
end

-- ================================= intent ===================================
--[[
	One helm intent per frame, whatever the device.

	Keyboard: W/S throttle and A/D steer, exactly the numbers the helm always
	had. Gamepad: the left thumbstick, pushed up = ahead. Touch: the stick
	built below, mounted on first use and only where the device has a screen
	to press.
]]
local JOYSTICK_RADIUS = 62
local JOYSTICK_CENTRE = UDim2.new(0, 130, 1, -150)

local touchAxes: { x: number, y: number }? = nil
local joystickGui: ScreenGui? = nil
local touchInput: InputObject? = nil

local function setJoystickVisible(visible: boolean)
	if not UserInputService.TouchEnabled then
		return
	end
	if not joystickGui then
		if not visible then
			return
		end
		local gui = UI.mount("TideboundHelm", { displayOrder = 14 })
		local base = UI.panel(gui, {
			name = "Stick",
			size = UDim2.fromOffset(JOYSTICK_RADIUS * 2, JOYSTICK_RADIUS * 2),
			pos = JOYSTICK_CENTRE,
			anchor = Vector2.new(0.5, 0.5),
			color = T.color.bg,
			transparency = 0.3,
			radius = T.radius.pill,
		})
		--: Active, so a touch on the helm stick is consumed here and reported
		--: as processed; CastController skips processed input, so working the
		--: throttle never starts a cast charge.
		base.Active = true
		local knob = UI.panel(base, {
			name = "Knob",
			size = UDim2.fromOffset(54, 54),
			pos = UDim2.fromScale(0.5, 0.5),
			anchor = Vector2.new(0.5, 0.5),
			color = T.color.accent,
			transparency = 0.15,
			radius = T.radius.pill,
		})
		UI.label(gui, "HELM", {
			size = T.text.xs,
			color = T.color.textDim,
			frameSize = UDim2.fromOffset(120, 14),
			pos = UDim2.new(0, 130, 1, -150 - JOYSTICK_RADIUS - 20),
			anchor = Vector2.new(0.5, 0.5),
			align = Enum.TextXAlignment.Center,
		})
		joystickGui = gui

		--[[
			The touch is tracked by its own InputObject, which is what the
			engine's own dynamic thumbstick does; comparing positions instead
			would let a second finger steering the camera hijack the helm.
		]]
		local function follow(position: Vector3)
			local centre = base.AbsolutePosition + base.AbsoluteSize * 0.5
			local dx, dy = position.X - centre.X, position.Y - centre.Y
			local x, y = BoatInput.stickFromDrag(dx, dy, JOYSTICK_RADIUS)
			touchAxes = { x = x, y = y }
			local reach = math.min(math.sqrt(dx * dx + dy * dy), JOYSTICK_RADIUS)
			local angle = math.atan2(dy, dx)
			knob.Position = UDim2.fromScale(0.5, 0.5)
				+ UDim2.fromOffset(math.cos(angle) * reach, math.sin(angle) * reach)
		end

		base.InputBegan:Connect(function(input: InputObject)
			if input.UserInputType ~= Enum.UserInputType.Touch or touchInput then
				return
			end
			touchInput = input
			follow(input.Position)
		end)
		UserInputService.InputChanged:Connect(function(input: InputObject)
			if input == touchInput then
				follow(input.Position)
			end
		end)
		UserInputService.InputEnded:Connect(function(input: InputObject)
			if input ~= touchInput then
				return
			end
			touchInput = nil
			touchAxes = nil
			knob.Position = UDim2.fromScale(0.5, 0.5)
		end)
	end
	local gui = joystickGui
	if gui then
		gui.Enabled = visible
	end
end

--: The left thumbstick, when a pad is actually connected. `GetGamepadState`
--: returns nothing for a disconnected pad rather than erroring.
local function stickState(): { x: number, y: number }?
	for _, input in UserInputService:GetGamepadState(Enum.UserInputType.Gamepad1) do
		if input.KeyCode == Enum.KeyCode.Thumbstick1 then
			return { x = input.Position.X, y = input.Position.Y }
		end
	end
	return nil
end

local function intent(): BoatInput.Axes
	local sources: BoatInput.Sources = {
		keys = {
			forward = UserInputService:IsKeyDown(Enum.KeyCode.W),
			back = UserInputService:IsKeyDown(Enum.KeyCode.S),
			left = UserInputService:IsKeyDown(Enum.KeyCode.A),
			right = UserInputService:IsKeyDown(Enum.KeyCode.D),
		},
	}
	local stick = stickState()
	if stick then
		sources.stick = stick
	end
	if touchAxes then
		sources.touch = touchAxes
	end
	return BoatInput.resolve(sources)
end

-- ================================== drive ===================================
local lastYaw = 0

--: The seat this client is helming, or nil. A named helm on a VehicleSeat is
--: the only seat that drives a boat; a passenger seat never does.
local function helm(): (Model?, BasePart?)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	if not seat or not seat:IsA("VehicleSeat") or seat.Name ~= "Helm" then
		return nil, nil
	end
	local model = seat:FindFirstAncestorOfClass("Model")
	local hull = model and model.PrimaryPart
	if not hull or not hull:IsA("BasePart") then
		return nil, nil
	end
	return model, hull
end

local function drive(dt: number)
	local model, hull = helm()
	if not model or not hull then
		setJoystickVisible(false)
		return
	end

	--: While the server holds the hull on its anchor the physics is frozen:
	--: this client neither thrusts nor steers, and the touch stick steps out
	--: of the way rather than sitting there dead.
	local anchored = hull:GetAttribute("Anchored") == true
	setJoystickVisible(not anchored)
	if anchored then
		lastYaw = 0
		return
	end

	local axes = intent()
	local throttle = axes.throttle
	local steer = axes.steer

	local speed = (Items.boatById[boatIdOf(model)] or { speed = 26 }).speed
	local forward = hull.CFrame.LookVector
	local velocity = hull.AssemblyLinearVelocity

	--: Forward thrust with a little inertia: the hull slides into its speed
	--: instead of snapping to it, which is most of what makes a boat feel
	--: heavy.
	local want = Vector3.new(forward.X, 0, forward.Z).Unit * speed * throttle
	local blend = throttle ~= 0 and 1.8 or 0.6
	local planar = Vector3.new(velocity.X, 0, velocity.Z)
	planar = planar:Lerp(want, math.clamp(blend * dt * 4, 0, 1))

	--: Buoyancy: spring the centre toward the waterline.
	local vertical = math.clamp((SEA + 0.2 - hull.Position.Y) * 5, -12, 12)

	hull.AssemblyLinearVelocity = Vector3.new(planar.X, vertical, planar.Z)

	--: Steering scales with a minimum so a stopped boat can still be turned.
	local yaw = steer * (0.9 + 0.4 * math.abs(throttle))
	lastYaw = lastYaw + (yaw - lastYaw) * math.clamp(dt * 6, 0, 1)
	local angular = hull.AssemblyAngularVelocity
	hull.AssemblyAngularVelocity = Vector3.new(0, lastYaw, 0)
	if math.abs(angular.X) > 0.05 or math.abs(angular.Z) > 0.05 then
		--: Pitching comes from waves hitting the bow; roll comes from the
		--: same thing being asymmetric. Neither is simulation, both are
		--: texture, and the spring pulls them level again.
		hull.AssemblyAngularVelocity = Vector3.new(-angular.X * 0.9, lastYaw, -angular.Z * 0.9)
	end
end

function BoatController.start()
	RunService.Heartbeat:Connect(function(dt)
		local ok = pcall(drive, dt)
		if not ok then
			--: The boat was destroyed under the seat; next frame will find no
			--: seat and do nothing. No need to log a drama per frame.
		end
	end)
end

return BoatController
