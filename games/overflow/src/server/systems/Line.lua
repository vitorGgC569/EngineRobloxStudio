--!strict
--[[
	Line — the crates: where they come from, how they move, where they end.

	Crates are **anchored and moved by the server**, not thrown onto a physical
	belt. Physics was the obvious choice and is the wrong one here for three
	reasons that all showed up the moment the design was written down: a
	physical crate can be pushed off the belt by a player standing in the wrong
	place, its speed is whatever friction decides rather than the number the
	difficulty curve is built on, and nothing about it is reproducible, so a
	scenario asserting "this crate reached that chute" would be asserting about
	the weather.

	Anchored and stepped, the belt is a clock the game can be balanced against.

	The queue is generated ahead
	----------------------------

	`upcoming` holds the kinds the player is shown on the HUD. The crates are
	decided before they exist, because the whole skill of the game is planning
	the next four seconds, and a plan is only possible against a future that has
	already been fixed. Generating a kind at spawn time would make the preview a
	lie.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Debug = Forge.Debug
local Mark = Forge.Mark
local Boot = Forge.Core.Boot

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Mill = require(script.Parent:WaitForChild("Mill"))

local Line = {}

--: One part of a crate and where it sits relative to the body, kept so the
--: whole model can be slid into a chute as one object.
type Carried = { part: BasePart, offset: Vector3 }

export type Crate = {
	kind: string,
	model: Model,
	body: BasePart,
	x: number,
	--: Set when a chute takes it, so the tick stops moving it while it falls.
	claimed: boolean,
}

Line.crates = {} :: { Crate }
--: The kinds already decided, in the order they will arrive.
Line.upcoming = {} :: { string }

local rand = Random.new(Config.seed)

local function kinds(): { string }
	local out = {}
	for _, spec in Config.chutes do
		if type(spec) == "table" and spec.id then
			table.insert(out, spec.id)
		end
	end
	return out
end

Line.kinds = kinds()

local function colourFor(kind: string): Color3
	for _, spec in Config.chutes do
		if type(spec) == "table" and spec.id == kind then
			return Color3.fromRGB(spec.color[1], spec.color[2], spec.color[3])
		end
	end
	return Color3.fromRGB(200, 200, 200)
end

Line.colourFor = colourFor

--[[
	Top up the decided queue.

	Deliberately not uniform: a run of four identical crates is a gift and a
	perfect alternation is a metronome, and both are less interesting than a
	distribution that occasionally repeats. So a kind is drawn at random but the
	one just drawn is half as likely again.
]]
function Line.fill(target: number)
	local pool = Line.kinds
	while #Line.upcoming < target do
		local pick = pool[rand:NextInteger(1, #pool)]
		local last = Line.upcoming[#Line.upcoming]
		if pick == last and rand:NextNumber() < 0.5 then
			pick = pool[rand:NextInteger(1, #pool)]
		end
		table.insert(Line.upcoming, pick)
	end
end

--: What the HUD is allowed to show, oldest first.
function Line.preview(): { string }
	local out = {}
	for i = 1, math.min(Config.line.previewCount, #Line.upcoming) do
		table.insert(out, Line.upcoming[i])
	end
	return out
end

-- ================================ building ==================================
--[[
	One crate: a baked store crate, tinted to its kind, with a glowing band.

	The band is the readable part. A baked prop's own colour is whatever its
	author chose and cannot be relied on to carry meaning, so the kind is
	painted on as a neon ring the player can read at forty studs — and the prop
	underneath is there so the thing on the belt is an object rather than a
	coloured box.
]]
local function buildCrate(kind: string, x: number, container: Instance): Crate
	local B = Config.belt
	local colour = colourFor(kind)
	local at = Vector3.new(x, B.y, B.z)

	local model = Instance.new("Model")
	model.Name = "Crate_" .. kind
	model:SetAttribute("Kind", kind)

	--: The body is this code's own part, and the prop hangs off it. A baked
	--: model's parts are whatever its author left; a part placed here is a part
	--: this system can move and measure.
	local body = Instance.new("Part")
	body.Name = "Body"
	body.Size = Vector3.new(3.4, 3.4, 3.4)
	body.CFrame = CFrame.new(at + Vector3.new(0, 1.7, 0))
	body.Anchored = true
	body.CanCollide = false
	body.Transparency = 1
	body.Parent = model
	model.PrimaryPart = body

	local shell = Instance.new("Part")
	shell.Name = "Shell"
	shell.Size = Vector3.new(3, 3, 3)
	shell.CFrame = body.CFrame
	shell.Anchored = true
	shell.CanCollide = false
	shell.Color = colour:Lerp(Color3.fromRGB(30, 28, 32), 0.55)
	shell.Material = Enum.Material.WoodPlanks
	shell.Parent = model

	local band = Instance.new("Part")
	band.Name = "Band"
	band.Size = Vector3.new(3.2, 0.7, 3.2)
	band.CFrame = body.CFrame
	band.Anchored = true
	band.CanCollide = false
	band.CastShadow = false
	band.Color = colour
	band.Material = Enum.Material.Neon
	band.Parent = model

	local light = Instance.new("PointLight")
	light.Brightness = 1.1
	light.Range = 12
	light.Color = colour
	light.Shadows = false
	light.Parent = band

	model.Parent = container
	--: Set explicitly. `PivotTo` and `GetExtentsSize` both answer relative to
	--: the pivot, and an inherited one is rotated often enough that trusting
	--: the default is how a crate ends up travelling sideways.
	model.WorldPivot = body.CFrame

	Mark.exclude(body)
	Mark.exclude(shell)
	Mark.exclude(band)

	return { kind = kind, model = model, body = body, x = x, claimed = false }
end

--: Take the next decided kind and put a crate on the head of the belt.
function Line.spawn(): Crate?
	Line.fill(Config.line.previewCount + 4)
	local kind = table.remove(Line.upcoming, 1)
	if not kind then
		return nil
	end
	local container = Workspace:FindFirstChild("Line") or Workspace
	local crate = buildCrate(kind, Config.belt.headX, container)
	table.insert(Line.crates, crate)
	return crate
end

--[[
	Move every crate downstream, and say which ones left the belt.

	Returns the crates that reached the tail. The caller decides what that
	means — this module knows about a belt and not about strikes.
]]
function Line.step(dt: number, speed: number): { Crate }
	local B = Config.belt
	local fell: { Crate } = {}

	for index = #Line.crates, 1, -1 do
		local crate = Line.crates[index]
		if crate.claimed then
			continue
		end
		crate.x += speed * dt
		crate.model:PivotTo(CFrame.new(crate.x, B.y + 1.7, B.z))
		if crate.x >= B.tailX then
			table.remove(Line.crates, index)
			table.insert(fell, crate)
		end
	end

	return fell
end

--[[
	The crate a chute would take right now, or nil.

	The furthest-along crate inside the span, because a gate that opens with two
	crates over it should take the one about to leave rather than the one that
	still has time. That is the choice a person would make and the one that
	makes a late pull feel like a save rather than a mistake.
]]
function Line.crateAt(centreX: number, span: number): Crate?
	local half = span * 0.5
	local best: Crate? = nil
	for _, crate in Line.crates do
		if crate.claimed then
			continue
		end
		if math.abs(crate.x - centreX) <= half then
			if not best or crate.x > best.x then
				best = crate
			end
		end
	end
	return best
end

--[[
	Send a crate into a chute and destroy it.

	Tweened sideways rather than deleted where it stands: a crate that vanishes
	mid-belt reads as a bug, and the half second of it sliding into the mouth is
	the only feedback the player gets that the pull worked.
]]
function Line.consume(crate: Crate, chute: any, correct: boolean)
	crate.claimed = true
	for index, held in Line.crates do
		if held == crate then
			table.remove(Line.crates, index)
			break
		end
	end

	local target = chute.mouth.Position + Vector3.new(0, -2, 0)
	local TweenService = game:GetService("TweenService")
	local info = TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

	--: Tweening a Model needs a part to tween; the body is anchored and the
	--: rest is welded to nothing, so every part moves with an offset kept from
	--: the moment the tween starts.
	--: A named pair rather than `{ BasePart, Vector3 }`, which is not Luau type
	--: syntax at all: `{T}` is an array of T, and a two-element tuple written
	--: that way is a parse error rather than a type error — so the module never
	--: loads and the game is simply absent.
	local origin = crate.body.Position
	local parts: { Carried } = {}
	for _, d in crate.model:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, { part = d, offset = d.Position - origin })
		end
	end

	local driver = Instance.new("Vector3Value")
	driver.Value = origin
	driver:GetPropertyChangedSignal("Value"):Connect(function()
		for _, row in parts do
			row.part.Position = driver.Value + row.offset
		end
	end)
	local tween = TweenService:Create(driver, info, { Value = target })
	tween:Play()

	--: Wrong chute still takes the crate. Bouncing it back would be a second
	--: rule to learn for no gain, and the punishment is the strike.
	if not correct then
		for _, row in parts do
			row.part.Color = Color3.fromRGB(206, 68, 72)
		end
	end

	tween.Completed:Connect(function()
		driver:Destroy()
		crate.model:Destroy()
	end)
end

--: Clear the belt. Used between shifts, so a new shift never starts with the
--: last one's mistakes still riding towards the drop.
function Line.clear()
	for _, crate in Line.crates do
		crate.model:Destroy()
	end
	table.clear(Line.crates)
	table.clear(Line.upcoming)
end

function Line.start()
	task.spawn(function()
		if not Boot.await("mill_ready", 120) then
			Debug.error("line gave up waiting for the mill; nothing will run")
			return
		end
		Line.fill(Config.line.previewCount + 4)
		Boot.signal("line_ready")
		Debug.info(string.format("line ready (%d kinds)", #Line.kinds))
	end)
end

return Line
