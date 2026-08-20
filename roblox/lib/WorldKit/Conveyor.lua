--!strict
-- Conveyor belts: the moving-object pipeline.
--
-- Generic on purpose. A tycoon's card belt, a factory's part line and a
-- baggage carousel are the same thing: items enter at one end, travel a fixed
-- path at a known speed, and are collected at the other. The primitive owns the
-- geometry, the motion and the collection contract, so a game supplies only
-- what an item *is*.
--
-- Motion uses part velocity on an anchored surface rather than tweening each
-- item: it is what Roblox's physics already does well, it replicates for free,
-- and items behave correctly when a player stands on the belt.

local Build = require(script.Parent.Build)
local Palette = require(script.Parent.Palette)
local Semantics = require(script.Parent.Semantics)

local Conveyor = {}
Conveyor.__index = Conveyor

local function finitePositive(value: number): boolean
	return value == value and value > 0 and value < math.huge
end

export type Spec = {
	origin: Vector3,
	--- Unit direction the belt carries items along.
	direction: Vector3,
	length: number,
	width: number,
	speed: number,
	theme: Palette.Theme,
	beltSwatch: string?,
	frameSwatch: string?,
	accentSwatch: string?,
}

export type Conveyor = typeof(setmetatable({} :: {
	model: Model,
	surface: BasePart,
	spawnPoint: Vector3,
	collectPoint: Vector3,
	direction: Vector3,
	speed: number,
	spec: Spec,
}, Conveyor))

--- Build the belt. Returns a handle used to place and collect items.
function Conveyor.build(parent: Instance, name: string, spec: Spec): Conveyor
	if name == "" then
		error("conveyor name must not be empty", 2)
	end
	if not finitePositive(spec.length) or not finitePositive(spec.width) or not finitePositive(spec.speed) then
		error("conveyor length, width and speed must be finite and positive", 2)
	end
	if spec.direction.Magnitude <= 1e-6 then
		error("conveyor direction must not be zero", 2)
	end
	if math.abs(spec.direction.Y) > 1e-4 then
		error("conveyor direction must be horizontal", 2)
	end
	local theme = spec.theme
	local belt = Palette.get(theme, spec.beltSwatch or "metalDark")
	local frame = Palette.get(theme, spec.frameSwatch or "metal")
	local accent = Palette.get(theme, spec.accentSwatch or "teal")

	local direction = spec.direction.Unit
	local model = Instance.new("Model")
	model.Name = name
	model.Parent = parent
	Semantics.root(model, "interactive", "conveyor", "worldkit.conveyor")

	local centre = spec.origin + direction * (spec.length / 2)
	local angle = math.atan2(direction.X, direction.Z)
	local orientation = CFrame.new(centre) * CFrame.Angles(0, angle, 0)

	local surface = Build.part(model, "Surface", Vector3.new(spec.width, 1.2, spec.length), centre, belt, { castShadow = false })
	surface.CFrame = orientation
	surface.TopSurface = Enum.SurfaceType.Smooth
	-- AssemblyLinearVelocity on an anchored part is what actually carries
	-- anything resting on it; the part itself does not move.
	surface.AssemblyLinearVelocity = direction * spec.speed
	surface:SetAttribute("ConveyorSpeed", spec.speed)

	local legOffset = spec.width / 2 + 1.2
	for side = -1, 1, 2 do
		local rail = Build.part(model, "Rail", Vector3.new(1.4, 2.4, spec.length), centre, frame, { castShadow = false })
		rail.CFrame = orientation * CFrame.new(side * legOffset, 0.6, 0)
	end

	local supports = math.max(2, math.floor(spec.length / 14))
	for index = 0, supports do
		local along = -spec.length / 2 + (spec.length / supports) * index
		for side = -1, 1, 2 do
			local leg = Build.part(model, "Leg", Vector3.new(1.4, 6, 1.4), centre, frame)
			leg.CFrame = orientation * CFrame.new(side * legOffset, -3.4, along)
		end
	end

	-- Tread stripes read as motion even in a still screenshot, and give the
	-- eye something to track when the belt is running.
	local stripes = math.max(4, math.floor(spec.length / 6))
	for index = 0, stripes do
		local along = -spec.length / 2 + (spec.length / stripes) * index
		local stripe = Build.part(model, "Tread", Vector3.new(spec.width * 0.86, 0.16, 1.2), centre, accent, { canCollide = false, castShadow = false })
		stripe.CFrame = orientation * CFrame.new(0, 0.68, along)
		stripe.Transparency = 0.25
	end

	local intake = Build.part(model, "Intake", Vector3.new(spec.width + 4, 7, 3), centre, frame)
	intake.CFrame = orientation * CFrame.new(0, 3, -spec.length / 2 - 1.5)

	local outfall = Build.part(model, "Outfall", Vector3.new(spec.width + 4, 7, 3), centre, frame)
	outfall.CFrame = orientation * CFrame.new(0, 3, spec.length / 2 + 1.5)
	local glow = Build.part(model, "OutfallGlow", Vector3.new(spec.width, 0.4, 0.6), centre, accent, { canCollide = false, castShadow = false })
	glow.CFrame = orientation * CFrame.new(0, 1.1, spec.length / 2 - 1)

	model.PrimaryPart = surface

	local self = setmetatable({
		model = model,
		surface = surface,
		spawnPoint = spec.origin + direction * 3 + Vector3.new(0, 2.6, 0),
		collectPoint = spec.origin + direction * (spec.length - 2) + Vector3.new(0, 2.6, 0),
		direction = direction,
		speed = spec.speed,
		spec = spec,
	}, Conveyor)

	return self :: any
end

--- Put an item on the belt at the intake end.
---
--- The item must be unanchored to ride: an anchored part sits still on a moving
--- surface, which is the single most common way a belt looks broken.
function Conveyor:place(item: BasePart | Model): BasePart
	local primary: BasePart?
	if item:IsA("Model") then
		primary = item.PrimaryPart or item:FindFirstChildWhichIsA("BasePart")
	else
		primary = item
	end
	if primary == nil then
		error("conveyor item model must contain a BasePart", 2)
	end

	if item:IsA("Model") then
		item:PivotTo(CFrame.new(self.spawnPoint))
	else
		primary.Position = self.spawnPoint
	end

	for _, part in ipairs(if item:IsA("Model") then item:GetDescendants() else { primary }) do
		if part:IsA("BasePart") then
			part.Anchored = false
			part.CanCollide = part == primary
		end
	end

	primary.AssemblyLinearVelocity = self.direction * self.speed
	item.Parent = self.model
	return primary
end

--- How far along the belt an item has travelled, as 0..1.
function Conveyor:progress(primary: BasePart): number
	local travelled = (primary.Position - self.spawnPoint):Dot(self.direction)
	return math.clamp(travelled / math.max(self.spec.length - 5, 1), 0, 1)
end

--- Call `onCollect` when an item reaches the far end, and clean it up.
---
--- Belts leak: an item that misses the collector rides off the end and becomes
--- an orphan part accumulating forever. The timeout is not optional.
function Conveyor:collect(item: Model | BasePart, timeoutSeconds: number, onCollect: (boolean) -> ())
	if not finitePositive(timeoutSeconds) then
		error("timeoutSeconds must be finite and positive", 2)
	end
	local primary: BasePart? = if item:IsA("Model")
		then (item.PrimaryPart or item:FindFirstChildWhichIsA("BasePart"))
		else item
	if primary == nil then
		error("conveyor item model must contain a BasePart", 2)
	end

	local function finish(reachedEnd: boolean)
		local ok, message = pcall(onCollect, reachedEnd)
		item:Destroy()
		if not ok then
			warn(string.format("WorldKit conveyor collection callback failed: %s", tostring(message)))
		end
	end

	task.spawn(function()
		local deadline = os.clock() + timeoutSeconds
		while os.clock() < deadline do
			if primary.Parent == nil then
				return
			end
			if self:progress(primary) >= 0.95 then
				finish(true)
				return
			end
			task.wait(0.1)
		end
		-- Timed out: collect anyway so the player is never cheated by physics,
		-- but say so, because a belt that always times out is a real defect.
		if primary.Parent ~= nil then
			finish(false)
		end
	end)
end

--- Change belt speed at runtime, for upgrades.
function Conveyor:setSpeed(speed: number)
	if not finitePositive(speed) then
		error("conveyor speed must be finite and positive", 2)
	end
	self.speed = speed
	self.surface.AssemblyLinearVelocity = self.direction * speed
	self.surface:SetAttribute("ConveyorSpeed", speed)
end

return Conveyor
