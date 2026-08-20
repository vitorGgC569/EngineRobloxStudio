--!strict
--[[
	Camera — where the player is looking, and who decides.

	Forge had no camera at all. `Feel` shakes one and that was the entire
	surface, which means every game built on this engine had Roblox's default
	follow camera and no way to tell a story with it: no cutscene, no shoulder
	framing for a shot, no pull-back when something big arrives.

	The design is one idea: **modes stack, and the highest priority wins.**

		Camera.mode("shoulder", { priority = 10, ... })   -- while aiming
		Camera.mode("cutscene", { priority = 100, ... })  -- during a scene

	A cutscene does not have to know what the aim mode was doing, and the aim
	mode does not have to be cancelled — it is simply outranked, and returns
	the moment the cutscene releases. Anything else turns into a pile of
	booleans that eventually disagree.

	--- Why this fights Roblox's camera, and how -----------------------------

	The default camera script writes `Camera.CFrame` every frame during the
	`Camera` render step. Anything written before that is overwritten, which is
	a mistake this project has already made once with an animator. So this
	binds *after* that step, and when a mode takes over it sets
	`CameraType = Scriptable` so Roblox stops writing at all.

	Releasing every mode hands control back rather than leaving the camera
	frozen where the last one left it, which is the other classic bug: a
	cutscene that ends and never gives the player their view back.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Spring = require(script.Parent.Core).Spring
local Ease = require(script.Parent.Core).Ease

local Camera = {}

export type Mode = {
	priority: number?,
	--: Returns the CFrame this mode wants this frame.
	cframe: ((dt: number, current: CFrame) -> CFrame?)?,
	fieldOfView: number?,
	--: Seconds to blend in and out. Zero cuts, which is almost never right.
	blend: number?,
	--: Called when this mode starts and stops being the winner.
	onEnter: (() -> ())?,
	onExit: (() -> ())?,
}

Camera.config = {
	blend = 0.35,
	--: Roblox's default. Restored whenever no mode asks for anything else.
	fieldOfView = 70,
	bindName = "ForgeCamera",
}

local modes: { [string]: Mode } = {}
local active: string? = nil
local blendFrom: CFrame? = nil
local blendStart = 0
local blendFor = 0
local bound = false
local offsetSpring = Spring.new(Vector3.zero, { frequency = 4, damping = 0.7 })

local function camera(): Camera?
	return Workspace.CurrentCamera
end

local function highest(): (string?, Mode?)
	local bestName, bestMode, bestPriority = nil, nil, -math.huge
	for name, mode in modes do
		local priority = mode.priority or 0
		if priority > bestPriority then
			bestName, bestMode, bestPriority = name, mode, priority
		end
	end
	return bestName, bestMode
end

-- =================================== drive ==================================
local function step(dt: number)
	local cam = camera()
	if not cam then
		return
	end

	local name, mode = highest()
	if name ~= active then
		local previous = active and modes[active]
		if previous and previous.onExit then
			task.spawn(previous.onExit)
		end
		if mode and mode.onEnter then
			task.spawn(mode.onEnter)
		end
		--[[
			Blend from wherever the camera actually is.

			Not from where the outgoing mode thought it was: a mode that was
			itself mid-blend, or that had been shaken by `Feel`, is not where
			its own maths say. Reading the real CFrame makes every handover
			continuous regardless of what came before.
		]]
		blendFrom = cam.CFrame
		blendStart = os.clock()
		blendFor = (mode and mode.blend) or Camera.config.blend
		active = name

		if mode then
			cam.CameraType = Enum.CameraType.Scriptable
		else
			-- Nothing wants it: give it back rather than leaving it frozen.
			cam.CameraType = Enum.CameraType.Custom
			cam.FieldOfView = Camera.config.fieldOfView
		end
	end

	if not mode then
		return
	end

	local wanted = mode.cframe and mode.cframe(dt, cam.CFrame) or nil
	if not wanted then
		return
	end

	-- Additive offset, for recoil and impacts. Springs back to zero on its own.
	local offset = offsetSpring:step(dt)
	if offset.Magnitude > 1e-4 then
		wanted = wanted * CFrame.new(offset)
	end

	if blendFrom and blendFor > 0 then
		local t = (os.clock() - blendStart) / blendFor
		if t < 1 then
			cam.CFrame = blendFrom:Lerp(wanted, Ease.get("quadOut")(t))
		else
			blendFrom = nil
			cam.CFrame = wanted
		end
	else
		cam.CFrame = wanted
	end

	if mode.fieldOfView then
		cam.FieldOfView += (mode.fieldOfView - cam.FieldOfView) * math.min(1, dt * 6)
	end
end

local function bind()
	if bound or not RunService:IsClient() then
		return
	end
	--[[
		After the character step, on purpose.

		Roblox's own camera writes during `Enum.RenderPriority.Camera`. Binding
		before it means every frame is overwritten and the mode silently does
		nothing — the same ordering mistake that made an animator a no-op
		earlier in this project's life.
	]]
	RunService:BindToRenderStep(
		Camera.config.bindName,
		Enum.RenderPriority.Camera.Value + 1,
		step)
	bound = true
end

-- =================================== modes ==================================
--[[
	Add or replace a mode.

	Re-registering a name replaces it rather than stacking, so a system that
	updates its own mode every frame does not accumulate hundreds.
]]
function Camera.mode(name: string, mode: Mode)
	modes[name] = mode
	bind()
end

function Camera.release(name: string)
	modes[name] = nil
end

function Camera.releaseAll()
	table.clear(modes)
end

function Camera.activeMode(): string?
	return active
end

--[[
	A kick, in camera space.

	Recoil, a heavy landing, a hit taken. Additive on top of whatever mode is
	winning, so it works during a cutscene and during ordinary play without
	either knowing about it.
]]
function Camera.impulse(offset: Vector3)
	offsetSpring:impulse(offset)
end

-- ============================== ready-made modes =============================
--[[
	Over the shoulder.

	The framing every third-person shooter uses, and the one Roblox's default
	camera cannot do: the character sits off-centre so the crosshair is not
	behind their head.
]]
function Camera.shoulder(options: any?): Mode
	local o = options or {}
	local side = o.side or 1.8
	local height = o.height or 1.6
	local distance = o.distance or 8

	return {
		priority = o.priority or 10,
		blend = o.blend or 0.25,
		fieldOfView = o.fieldOfView,
		cframe = function()
			local player = Players.LocalPlayer
			local character = player and player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
			local cam = camera()
			if not (root and cam) then
				return nil
			end
			--[[
				Aim direction comes from the camera, not the character.

				The player aims with the mouse; the body follows. Deriving the
				view from the body instead produces a camera that chases its own
				tail whenever the character turns to face where it is looking.
			]]
			local look = cam.CFrame.LookVector
			local pivot = root.Position + Vector3.new(0, height, 0)
			local right = look:Cross(Vector3.yAxis)
			right = right.Magnitude > 0.01 and right.Unit or Vector3.xAxis
			return CFrame.lookAt(pivot - look * distance + right * side, pivot + look * 40)
		end,
	}
end

--[[
	Look at something, from somewhere.

	The building block of every cutscene: a fixed shot. `from` and `at` may be
	values or functions, and the function form is what makes a shot follow
	something that is moving.
]]
function Camera.shot(from: any, at: any, options: any?): Mode
	local o = options or {}
	local function resolve(value: any): Vector3?
		if typeof(value) == "Vector3" then
			return value
		end
		if typeof(value) == "function" then
			local result = value()
			return typeof(result) == "Vector3" and result or nil
		end
		if typeof(value) == "Instance" then
			if value:IsA("BasePart") then
				return value.Position
			end
			if value:IsA("Model") then
				return value:GetPivot().Position
			end
		end
		return nil
	end

	return {
		priority = o.priority or 100,
		blend = o.blend or 0.6,
		fieldOfView = o.fieldOfView,
		cframe = function()
			local eye = resolve(from)
			local target = resolve(at)
			if not (eye and target) then
				return nil
			end
			return CFrame.lookAt(eye, target)
		end,
	}
end

-- ================================= cutscene =================================
--[[
	Play a sequence of shots, then give the camera back.

	Returns a handle with `skip`, because a cutscene a player cannot skip is a
	cutscene they resent on the second viewing. The camera is released when the
	sequence ends *or* is skipped — releasing in only one of those paths is how
	a game leaves someone stuck staring at a wall.

		Camera.cutscene({
			{ from = doorway, at = boss, hold = 2.5 },
			{ from = overhead, at = arena, hold = 1.5, blend = 1 },
		}, { onFinish = function() ... end })
]]
function Camera.cutscene(shots: { any }, options: any?): any
	local o = options or {}
	local handle = { playing = true, index = 0 }

	task.spawn(function()
		for index, shot in shots do
			if not handle.playing then
				break
			end
			handle.index = index
			Camera.mode("cutscene", Camera.shot(shot.from, shot.at, {
				priority = o.priority or 100,
				blend = shot.blend or o.blend or 0.6,
				fieldOfView = shot.fieldOfView,
			}))
			local held = 0
			local hold = shot.hold or 3
			while held < hold and handle.playing do
				held += RunService.RenderStepped:Wait()
			end
		end

		handle.playing = false
		Camera.release("cutscene")
		if o.onFinish then
			task.spawn(o.onFinish)
		end
	end)

	function handle:skip()
		self.playing = false
	end

	return handle
end

function Camera.describe(): { [string]: any }
	local names = {}
	for name, mode in modes do
		table.insert(names, string.format("%s(%d)", name, mode.priority or 0))
	end
	table.sort(names)
	return {
		context = RunService:IsServer() and "server" or "client",
		modes = names,
		active = active,
		bound = bound,
	}
end

return Camera
