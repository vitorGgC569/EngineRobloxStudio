--!strict
--- A world you can touch and read.
---
--- The engine could build a place, light it, populate it and animate it, and
--- there was no way to click anything, no way to put readable text on a wall,
--- and no way to attach two parts together. `ClickDetector`, `SurfaceGui`,
--- `WeldConstraint` and `HingeConstraint` were all at zero -- `ProximityPrompt`
--- appeared twice, both times buried inside a setpiece.
---
--- That is the difference between a diorama and a game. A door you cannot open,
--- a sign you cannot read and a lever welded to nothing are all scenery.
---
--- **Four things that are not obvious and cost an afternoon each.**
---
--- A `SurfaceGui` at default settings is unreadable. `PixelsPerStud` defaults to
--- 50, so a 20-stud wall is a 1000px canvas and text sized for a screen is
--- microscopic on it. Sizing is done here in studs and converted.
---
--- A `ClickDetector` with the default `MaxActivationDistance` of 32 feels broken
--- at any real scale, and with no `CursorIcon` gives the player no signal that
--- the thing is clickable at all.
---
--- `WeldConstraint` needs `Part0` and `Part1` set *before* it is parented, and
--- welding two anchored parts does nothing at all -- silently. That last one is
--- the single most common "my machine doesn't move" bug in Roblox.
---
--- A `BillboardGui` without `MaxDistance` renders from across the map, which is
--- how a scene ends up with forty overlapping labels in the skyline.

local Players = game:GetService("Players")

local Interact = {}

export type ClickSpec = {
	--- How far away it can be clicked, in studs. The default of 32 is short.
	range: number?,
	cursor: string?,
	--- Runs on the server with the player who clicked.
	onClick: ((Player, BasePart) -> ())?,
}

export type PromptSpec = {
	label: string?,
	action: string?,
	range: number?,
	holdTime: number?,
	onTrigger: ((Player, BasePart) -> ())?,
}

export type SignSpec = {
	text: string,
	--- Which face carries it. Front is +Z in the part's own space.
	face: Enum.NormalId?,
	--- Cap height in studs. Sized in world units because a sign is a physical
	--- object, and "24 point" means nothing on a wall.
	size: number?,
	colour: Color3?,
	background: Color3?,
	transparency: number?,
	alignment: Enum.TextXAlignment?,
}

export type LabelSpec = {
	text: string,
	--- Studs above the part's top face.
	rise: number?,
	size: number?,
	colour: Color3?,
	--- Past this, the label stops drawing. Without it a scene fills its skyline.
	maxDistance: number?,
}

local function clear(host: Instance, className: string, name: string)
	for _, item in ipairs(host:GetChildren()) do
		if item:IsA(className) and item.Name == name then
			item:Destroy()
		end
	end
end

--- Make a part clickable.
function Interact.click(part: BasePart, spec: ClickSpec): ClickDetector
	if typeof(part) ~= "Instance" or not part:IsA("BasePart") then
		error("click needs a BasePart", 2)
	end
	clear(part, "ClickDetector", "RQEClick")

	local detector = Instance.new("ClickDetector")
	detector.Name = "RQEClick"
	-- 32 studs is the default and feels broken at any real scale: a player
	-- standing in front of a building cannot click its door.
	detector.MaxActivationDistance = spec.range or 24
	if spec.cursor ~= nil then
		detector.CursorIcon = spec.cursor
	end
	detector.Parent = part

	if spec.onClick ~= nil then
		local handler = spec.onClick
		detector.MouseClick:Connect(function(player)
			-- One player's bad click must not take the handler down for
			-- everyone else.
			local ok, err = pcall(handler, player, part)
			if not ok then
				warn("[Interact] click on " .. part.Name .. ": " .. tostring(err))
			end
		end)
	end
	return detector
end

--- A hold-to-use prompt: the interaction Roblox players expect by default.
function Interact.prompt(part: BasePart, spec: PromptSpec): ProximityPrompt
	if typeof(part) ~= "Instance" or not part:IsA("BasePart") then
		error("prompt needs a BasePart", 2)
	end
	clear(part, "ProximityPrompt", "RQEPrompt")

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "RQEPrompt"
	prompt.ObjectText = spec.label or part.Name
	prompt.ActionText = spec.action or "Use"
	prompt.MaxActivationDistance = spec.range or 12
	prompt.HoldDuration = spec.holdTime or 0
	prompt.RequiresLineOfSight = false
	prompt.Parent = part

	if spec.onTrigger ~= nil then
		local handler = spec.onTrigger
		prompt.Triggered:Connect(function(player)
			local ok, err = pcall(handler, player, part)
			if not ok then
				warn("[Interact] prompt on " .. part.Name .. ": " .. tostring(err))
			end
		end)
	end
	return prompt
end

--- Readable text on a face of a part.
---
--- Sized in studs, because a sign is a physical object. The conversion is the
--- whole reason this exists: `PixelsPerStud` defaults to 50, so a 20-stud wall
--- is a 1000-pixel canvas, and `TextSize = 24` on it is four millimetres tall
--- in world terms -- invisible, and the reason every first attempt at a sign
--- looks blank.
function Interact.sign(part: BasePart, spec: SignSpec): SurfaceGui
	if typeof(part) ~= "Instance" or not part:IsA("BasePart") then
		error("sign needs a BasePart", 2)
	end
	if type(spec.text) ~= "string" or spec.text == "" then
		error("a sign with no text is a blank panel", 2)
	end
	clear(part, "SurfaceGui", "RQESign")

	local pixelsPerStud = 40
	local surface = Instance.new("SurfaceGui")
	surface.Name = "RQESign"
	surface.Face = spec.face or Enum.NormalId.Front
	surface.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	surface.PixelsPerStud = pixelsPerStud
	surface.AlwaysOnTop = false
	surface.Parent = part

	if spec.background ~= nil then
		local plate = Instance.new("Frame")
		plate.Size = UDim2.fromScale(1, 1)
		plate.BackgroundColor3 = spec.background
		plate.BackgroundTransparency = spec.transparency or 0
		plate.BorderSizePixel = 0
		plate.ZIndex = 0
		plate.Parent = surface
	end

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(0.92, 0.86)
	label.Position = UDim2.fromScale(0.04, 0.07)
	label.BackgroundTransparency = 1
	label.Text = spec.text
	label.TextColor3 = spec.colour or Color3.fromRGB(240, 238, 232)
	label.TextXAlignment = spec.alignment or Enum.TextXAlignment.Center
	label.TextWrapped = true
	label.Font = Enum.Font.GothamMedium
	-- Studs to pixels, which is the conversion nobody remembers.
	label.TextSize = math.max((spec.size or 1.2) * pixelsPerStud, 8)
	label.ZIndex = 1
	label.Parent = surface

	return surface
end

--- A floating label above a part.
function Interact.label(part: BasePart, spec: LabelSpec): BillboardGui
	if typeof(part) ~= "Instance" or not part:IsA("BasePart") then
		error("label needs a BasePart", 2)
	end
	clear(part, "BillboardGui", "RQELabel")

	local size = spec.size or 2
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "RQELabel"
	billboard.Size = UDim2.fromScale(#spec.text * size * 0.5, size)
	billboard.SizeOffset = Vector2.new(0, 0)
	billboard.StudsOffsetWorldSpace =
		Vector3.new(0, part.Size.Y * 0.5 + (spec.rise or 1.5), 0)
	billboard.AlwaysOnTop = false
	-- Without this a label draws from across the map, and a scene ends up with
	-- forty of them stacked in the skyline.
	billboard.MaxDistance = spec.maxDistance or 120
	billboard.Parent = part

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = spec.text
	label.TextColor3 = spec.colour or Color3.fromRGB(240, 238, 232)
	label.TextScaled = true
	label.Font = Enum.Font.GothamMedium
	label.Parent = billboard

	return billboard
end

--- Weld parts to an anchor so they move as one.
---
--- **Welding two anchored parts does nothing, silently.** Anchored parts are not
--- simulated, so the constraint is created, parented, and has no effect -- and
--- that is the most common "my machine will not move" bug in Roblox. This
--- refuses it out loud instead.
function Interact.weld(anchor: BasePart, parts: { BasePart }): (number, { string })
	if typeof(anchor) ~= "Instance" or not anchor:IsA("BasePart") then
		error("weld needs a BasePart to weld to", 2)
	end
	local made, problems = 0, {}
	for _, part in ipairs(parts) do
		if part == anchor then
			continue
		end
		if not part:IsA("BasePart") then
			table.insert(problems, tostring(part) .. " is not a BasePart")
			continue
		end
		if anchor.Anchored and part.Anchored then
			table.insert(problems, ("%s and %s are both anchored, so a weld "
				.. "between them does nothing"):format(anchor.Name, part.Name))
			continue
		end
		local weld = Instance.new("WeldConstraint")
		-- Both ends set before parenting. A WeldConstraint parented with a nil
		-- end never takes, and never says so.
		weld.Part0 = anchor
		weld.Part1 = part
		weld.Parent = anchor
		made += 1
	end
	return made, problems
end

--- A hinge between two parts: doors, levers, lids.
function Interact.hinge(a: BasePart, b: BasePart, options: { [string]: any }?): HingeConstraint
	local opts = options or {}
	if a.Anchored and b.Anchored then
		error(("%s and %s are both anchored; a hinge between them cannot turn")
			:format(a.Name, b.Name), 2)
	end

	local axis = opts.axis or Vector3.new(0, 1, 0)
	local pivot = opts.pivot or ((a.Position + b.Position) * 0.5)

	local function attachment(host: BasePart): Attachment
		local point = Instance.new("Attachment")
		point.Name = "RQEHinge"
		point.WorldPosition = pivot
		point.Axis = axis
		point.Parent = host
		return point
	end

	local hinge = Instance.new("HingeConstraint")
	hinge.Name = "RQEHinge"
	hinge.Attachment0 = attachment(a)
	hinge.Attachment1 = attachment(b)
	hinge.LimitsEnabled = opts.limits ~= false
	hinge.LowerAngle = opts.lower or -90
	hinge.UpperAngle = opts.upper or 90
	if opts.motor then
		hinge.ActuatorType = Enum.ActuatorType.Motor
		hinge.MotorMaxTorque = opts.torque or 10000
		hinge.AngularVelocity = opts.speed or 1
	end
	hinge.Parent = a
	return hinge
end

--- What in this world can be touched or read.
function Interact.report(root: Instance?): { [string]: any }
	local host = root or workspace
	local counts = {
		clickable = 0, prompts = 0, signs = 0, labels = 0,
		welds = 0, hinges = 0,
	}
	local unreachable = {}
	for _, item in ipairs(host:GetDescendants()) do
		if item:IsA("ClickDetector") then
			counts.clickable += 1
		elseif item:IsA("ProximityPrompt") then
			counts.prompts += 1
		elseif item:IsA("SurfaceGui") then
			counts.signs += 1
		elseif item:IsA("BillboardGui") then
			counts.labels += 1
		elseif item:IsA("WeldConstraint") then
			counts.welds += 1
			if item.Part0 == nil or item.Part1 == nil then
				table.insert(unreachable, item:GetFullName() .. " has a nil end")
			end
		elseif item:IsA("HingeConstraint") then
			counts.hinges += 1
		end
	end
	counts.interactive = counts.clickable + counts.prompts
	counts.problems = unreachable
	return counts
end

return Interact
