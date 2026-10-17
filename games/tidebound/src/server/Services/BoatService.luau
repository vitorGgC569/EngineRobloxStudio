--!strict
--[[
	BoatService — the thing that makes the sea a place you cross.

	The server builds the boat, owns the seat, owns the luck and the crate.
	The *drive* is delegated to the client's network owner once somebody sits
	down, because a boat that stutters every time the driver's ping spikes is
	not a boat, it is a slideshow. The client writes velocity to a model the
	server created and can destroy at any time; nothing about the economy is
	decided by whoever is at the helm.

	One boat per player. Summoning the next one under your feet is the whole
	interaction -- no traffic, no berths, no parking.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Mark = Forge.Mark

local Net = Forge.Net
local Debug = Forge.Debug

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Items = require(Shared.Items)

local DataService = require(script.Parent.DataService)
local WorldService = require(script.Parent.WorldService)

local BoatService = {}

local SEA = Config.waterLevel

--: Hull dimensions and trim per hull type. Speed comes from Items; this is
--: the carpentry.
local HULLS: { [string]: any } = {
	rowboat = { length = 14, width = 5, height = 2.6, hull = Color3.fromRGB(146, 118, 84), trim = Color3.fromRGB(206, 176, 124), mast = false },
	sailboat = { length = 20, width = 6.2, height = 3.2, hull = Color3.fromRGB(120, 96, 70), trim = Color3.fromRGB(228, 226, 216), mast = true },
	trawler = { length = 26, width = 8, height = 3.6, hull = Color3.fromRGB(96, 104, 116), trim = Color3.fromRGB(196, 202, 208), mast = false, cabin = true },
	cutter = { length = 28, width = 8.6, height = 3.8, hull = Color3.fromRGB(70, 82, 96), trim = Color3.fromRGB(216, 190, 120), mast = true, cabin = true },
}

local boats: { [Player]: Model } = {}

--: Under this hull speed (studs/s) the anchor is offered. A prompt on a fast
--: unanchored part never fires -- measured, see ENGINE-FACTS -- so the helm
--: never shows one it cannot honour: dropping anchor is what a slowing boat
--: does, and anchoring at cruise was never the point.
local ANCHOR_SPEED_LIMIT = 7

--[[
	Toggle the physical anchor on a hull.

	Called from the helm's own ProximityPrompt, which fires on the server and
	names the player who pressed it -- so the toggle is server-authoritative
	with no channel to declare. Only the seat's occupant may drop or weigh the
	anchor; anyone else in range is refused rather than obeyed.

	The state lives in the hull's `Anchored` attribute, which replicates to
	everyone: the driver's BoatController reads the same attribute and stops
	thrusting, so client intent and server physics agree about whether the
	boat is held.
]]
local function toggleAnchor(player: Player, seat: VehicleSeat, prompt: ProximityPrompt)
	local model = seat:FindFirstAncestorOfClass("Model")
	local hull = model and model.PrimaryPart
	if not model or not hull then
		return
	end
	local occupant = seat.Occupant
	local driver = occupant and Players:GetPlayerFromCharacter(occupant.Parent)
	if driver ~= player then
		Debug.count("boats.anchor.refused")
		return
	end

	if hull:GetAttribute("Anchored") == true then
		hull:SetAttribute("Anchored", false)
		hull.Anchored = false
		--: Anchoring released the network ownership; hand the physics back to
		--: whoever is at the helm or the boat answers server ping instead of
		--: the driver's stick.
		BoatService.setOwnership(model, player)
		prompt.ActionText = "Drop anchor"
		Net.fire(player, "Notify", { text = "Anchor raised." })
	else
		hull.AssemblyLinearVelocity = Vector3.zero
		hull.AssemblyAngularVelocity = Vector3.zero
		hull:SetAttribute("Anchored", true)
		hull.Anchored = true
		prompt.ActionText = "Weigh anchor"
		Net.fire(player, "Notify", { text = "Anchor down." })
	end
	Debug.count("boats.anchor")
end

local function folder(): Instance
	local existing = Workspace:FindFirstChild("Boats")
	if existing then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = "Boats"
	created.Parent = Workspace
	return created
end

local function makePart(name: string, size: Vector3, color: Color3, anchor: CFrame, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.CFrame = anchor
	part.Anchored = false
	part.CanCollide = true
	part.Material = Enum.Material.WoodPlanks
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function flagsFor(player: Player): Color3
	local hue = (player.UserId * 47) % 360 / 360
	return Color3.fromHSV(hue, 0.62, 0.95)
end

-- ================================== build ===================================
local function build(player: Player, boatId: string): Model
	local spec = HULLS[boatId] or HULLS.rowboat
	local model = Instance.new("Model")
	model.Name = string.format("%s_%d", boatId, player.UserId)

	local hull = makePart("Hull", Vector3.new(spec.width, spec.height, spec.length),
		spec.hull, CFrame.new(0, 0, 0), model)
	hull:SetAttribute("Owner", player.UserId)
	model.PrimaryPart = hull

	--: Bow: a wedge is not available as a primitive, so it is earned with a
	--: smaller angled block instead of pretended at with a mesh.
	local bow = makePart("Bow", Vector3.new(spec.width * 0.72, spec.height, 3.4),
		spec.hull, CFrame.new(0, 0, spec.length / 2 + 1.2) * CFrame.Angles(0, math.pi, 0), model)

	local gunwaleL = makePart("GunwaleL", Vector3.new(0.5, spec.height * 0.55, spec.length),
		spec.trim, CFrame.new(-spec.width / 2 + 0.25, spec.height * 0.22, 0), model)
	local gunwaleR = makePart("GunwaleR", Vector3.new(0.5, spec.height * 0.55, spec.length),
		spec.trim, CFrame.new(spec.width / 2 - 0.25, spec.height * 0.22, 0), model)
	gunwaleL.CanCollide = false
	gunwaleR.CanCollide = false

	local deck = makePart("Deck", Vector3.new(spec.width - 0.4, 0.3, spec.length - 0.4),
		spec.trim, CFrame.new(0, spec.height * 0.34, 0), model)
	deck.CanCollide = false

	local seat = Instance.new("VehicleSeat")
	seat.Name = "Helm"
	seat.Size = Vector3.new(2.4, 0.4, 2.4)
	seat.CFrame = CFrame.new(0, spec.height * 0.4, spec.length * 0.28)
	seat.Color = spec.trim
	seat.Material = Enum.Material.Fabric
	seat:SetAttribute("Owner", player.UserId)
	seat.MaxSpeed = 0
	seat.Torque = 0
	seat.TurnSpeed = 0

	--[[
		The anchor rides a prompt, not the wire: `Triggered` runs on the server
		and names the pressing player, which is the whole authorisation. It is
		parented to the helm so only the seated driver is ever in range, takes
		a key no other control uses, and stays disabled until the boat is slow
		enough that a prompt on it can actually fire (see ANCHOR_SPEED_LIMIT).
	]]
	local anchor = Instance.new("ProximityPrompt")
	anchor.Name = "AnchorPrompt"
	anchor.ObjectText = "Anchor"
	anchor.ActionText = "Drop anchor"
	anchor.KeyboardKeyCode = Enum.KeyCode.F
	anchor.GamepadKeyCode = Enum.KeyCode.ButtonX
	anchor.HoldDuration = 0
	anchor.MaxActivationDistance = 12
	anchor.RequiresLineOfSight = false
	anchor.Exclusivity = Enum.ProximityPromptExclusivity.AlwaysShow
	anchor.Enabled = false
	anchor.Parent = seat
	anchor.Triggered:Connect(function(clicker: Player)
		toggleAnchor(clicker, seat, anchor)
	end)

	seat.Parent = model

	local flag = makePart("Flag", Vector3.new(0.16, 1.6, 0.9),
		flagsFor(player), CFrame.new(0, spec.height / 2 + 1.6, -spec.length / 2 + 0.4), model)
	flag.CanCollide = false
	flag.Material = Enum.Material.Fabric

	local mast, sail = nil, nil
	if spec.mast then
		mast = makePart("Mast", Vector3.new(0.4, 14, 0.4),
			spec.hull, CFrame.new(0, spec.height / 2 + 7, -spec.length * 0.08), model)
		mast.CanCollide = false
		sail = makePart("Sail", Vector3.new(0.2, 9, 6),
			Color3.fromRGB(238, 234, 222), CFrame.new(0, spec.height / 2 + 9, -spec.length * 0.08 + 3.2), model)
		sail.CanCollide = false
		sail.Material = Enum.Material.Fabric
	end
	if spec.cabin then
		local cabin = makePart("Cabin", Vector3.new(spec.width * 0.6, 3.4, spec.length * 0.3),
			spec.trim, CFrame.new(0, spec.height / 2 + 1.7, -spec.length * 0.22), model)
		cabin.CanCollide = false
	end

	local name = Instance.new("BillboardGui")
	name.Name = "NameTag"
	name.Size = UDim2.fromOffset(180, 26)
	name.StudsOffsetWorldSpace = Vector3.new(0, spec.height / 2 + 3.2, 0)
	name.AlwaysOnTop = false
	name.Parent = hull
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamMedium
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(240, 244, 248)
	label.TextStrokeTransparency = 0.4
	label.Text = string.format("%s -- %s", player.DisplayName, (Items.boatById[boatId] or {}).name or boatId)
	label.Parent = name

	--: Weld the sculpture to the one physical part. Everything else is set
	--: CanCollide=false above, so the boat is a single smooth hull colliding
	--: with the world instead of a pile of blocks catching on terrain.
	for _, child in model:GetChildren() do
		if child:IsA("BasePart") and child ~= hull then
			local constraint = Instance.new("WeldConstraint")
			constraint.Part0 = hull
			constraint.Part1 = child
			constraint.Parent = child
		end
	end

	model.Parent = folder()
	Mark.root(model, "structure", "boat-" .. boatId, "buildkit")
	BoatService.setOwnership(model, player)
	return model
end

--[[
	Hand the physics to the driver.

	Called from the server after building and whenever the helm changes
	hands. If the seat is empty the owner of record still gets the keys --
	an abandoned boat owned by the server is a boat nobody can rescue.
]]
function BoatService.setOwnership(model: Model, player: Player)
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and not part.Anchored then
			pcall(function()
				part:SetNetworkOwner(player)
			end)
		end
	end
end

local function seatOf(model: Model): VehicleSeat?
	for _, part in model:GetDescendants() do
		if part:IsA("VehicleSeat") then
			return part
		end
	end
	return nil
end

--: Somewhere wet near this player, or the zone's mooring if there is not.
local function findWater(player: Player): Vector3
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local zoneId = "shallows"
	if root then
		local zone = Config.zoneAt(root.Position)
		zoneId = zone and zone.id or "shallows"
		--: 12 directions, two rings. The first wet spot wins; the point is
		--: for the boat to appear at the water's edge, not for the search to
		--: be clever.
		for ring = 1, 2 do
			local radius = 18 + ring * 14
			for step = 0, 11 do
				local angle = (step / 12) * math.pi * 2
				local point = Vector3.new(
					root.Position.X + math.cos(angle) * radius,
					SEA + 1.2,
					root.Position.Z + math.sin(angle) * radius)
				if WorldService.isWater(point) then
					return point
				end
			end
		end
	end
	return WorldService.boatSpawn(zoneId)
end

local function orient(position: Vector3, zoneId: string): CFrame
	local dock = WorldService.dock(zoneId)
	local facing = Vector3.new(dock.X - position.X, 0, dock.Z - position.Z)
	if facing.Magnitude < 1 then
		facing = Vector3.new(0, 0, 1)
	end
	return CFrame.lookAt(position + Vector3.new(0, 0.4, 0), position + facing.Unit * 20)
end

--: The driver owns the physics; re-hand it over whenever anybody sits or
--: stands, so a borrowed helm is responsive too.
local function watchSeat(model: Model, owner: Player)
	local seat = seatOf(model)
	if not seat then
		return
	end
	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		task.defer(function()
			if not model.Parent then
				return
			end
			local occupant = seat.Occupant
			local driver = occupant and Players:GetPlayerFromCharacter(occupant.Parent)
			BoatService.setOwnership(model, driver or owner)
			--: Stepping aboard changes the displayed luck (the boat's bonus
			--: applies while seated), so the HUD hears about the seat change
			--: instead of waiting for the next unrelated sync.
			DataService.push(owner)
			if driver and driver ~= owner then
				DataService.push(driver)
			end
		end)
	end)
end

-- ================================== public ==================================
function BoatService.get(player: Player): Model?
	local model = boats[player]
	if model and model.Parent then
		return model
	end
	return nil
end

function BoatService.destroy(player: Player)
	local model = boats[player]
	boats[player] = nil
	if model then
		model:Destroy()
	end
end

function BoatService.summon(player: Player): Model?
	local profile = DataService.profile(player)
	if not profile then
		return nil
	end
	BoatService.destroy(player)

	local position = findWater(player)
	local zone = Config.zoneAt(position) or Config.zone("shallows")
	local model = build(player, profile.boats.equipped)
	model:PivotTo(orient(position, zone.id))
	boats[player] = model
	watchSeat(model, player)
	Debug.count("boats.summoned")
	return model
end

--: Put the player's boat at a zone's mooring, summoning it if it is not out.
function BoatService.placeAt(player: Player, zoneId: string): Model?
	local model = BoatService.get(player)
	local position = WorldService.boatSpawn(zoneId)
	if not model then
		local profile = DataService.profile(player)
		if not profile then
			return nil
		end
		model = build(player, profile.boats.equipped)
		boats[player] = model
		watchSeat(model, player)
	end
	model:PivotTo(orient(position, zoneId))
	BoatService.setOwnership(model, player)
	return model
end

function BoatService.store(player: Player): boolean
	local existed = BoatService.get(player) ~= nil
	BoatService.destroy(player)
	return existed
end

-- ================================== start ===================================
function BoatService.start()
	Net.on("SummonBoat", function(player: Player)
		local model = BoatService.summon(player)
		if model then
			Net.fire(player, "Notify", { text = "Your boat is in the water." })
		end
	end)

	Net.on("StoreBoat", function(player: Player)
		if BoatService.store(player) then
			Net.fire(player, "Notify", { text = "Boat stowed." })
		end
	end)

	--: Summoning also covers the "boat is out but I am across the map"
	--: case by just building a new one where the player is.
	local Save = Forge.Save
	Save.observe(function(player: Player)
		task.delay(2, function()
			if player.Parent and not boats[player] then
				BoatService.summon(player)
			end
		end)
	end)

	--[[
		Drift guard: a boat flung under the terrain by a physics spike is a
		player stranded without their crate and their luck. The fix is not to
		investigate -- it is to put the boat back on the surface it left.
	]]
	task.spawn(function()
		while true do
			task.wait(3)
			for player, model in boats do
				local hull = model.PrimaryPart
				if not model.Parent then
					boats[player] = nil
				elseif hull and hull.Position.Y < SEA - 25 then
					hull.AssemblyLinearVelocity = Vector3.zero
					hull.AssemblyAngularVelocity = Vector3.zero
					model:PivotTo(CFrame.new(hull.Position.X, SEA + 1.2, hull.Position.Z))
					Debug.count("boats.recovered")
				end
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		BoatService.destroy(player)
	end)

	--[[
		Anchor prompt visibility, at 4Hz: enabled exactly when the prompt can
		fire and the person who could press it is sitting there. A helm at
		cruise shows nothing; the offer appears as the hull comes to rest, and
		an anchored helm keeps showing it so the anchor can be weighed again.
	]]
	task.spawn(function()
		while true do
			task.wait(0.25)
			for _, model in boats do
				local hull = model.PrimaryPart
				local seat = seatOf(model)
				local prompt = seat and seat:FindFirstChild("AnchorPrompt")
				if hull and seat and prompt and prompt:IsA("ProximityPrompt") then
					local anchored = hull:GetAttribute("Anchored") == true
					prompt.Enabled = seat.Occupant ~= nil
						and (anchored or hull.AssemblyLinearVelocity.Magnitude < ANCHOR_SPEED_LIMIT)
				end
			end
		end
	end)

	Debug.info("boats armed")
end

return BoatService
