--!strict
-- Playable: the loop, standing in the world.
--
-- Systems that exist and a world nobody can act on is not a game. This is the
-- shortest honest path between them: something to press, a cost to pay, a thing
-- that appears, and a number that changes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local WorldKit = require(ReplicatedStorage.WorldKit)
local TokenData = require(ReplicatedStorage.Shared.TokenData)
local Catalogue = require(ReplicatedStorage.Shared.Catalogue)
local tokens = WorldKit.Tokens.define(TokenData)

local Playable = {}

--- Build the loop into the world, driven by the systems already constructed.
function Playable.build(Gameplay)
local systems = Gameplay.systems()

-- Waited for, not assumed. Server Scripts have no guaranteed order, and this
-- one lost the race to the world builder every time -- refusing correctly, for
-- a world that appeared a frame later. Bounded, because waiting forever for
-- something that will never arrive is the same bug with no error message.
local world = nil
local deadline = os.clock() + 10
repeat
	world = workspace:FindFirstChild("Blockout_probe-roles-world")
		or workspace:FindFirstChild("World")
	if world == nil then
		task.wait(0.1)
	end
until world ~= nil or os.clock() > deadline

if world == nil then
	-- Refused rather than guessed. Building the loop into a world that is not
	-- there produces prompts floating at the origin, which reads as broken
	-- rather than as absent.
	error("[Playable] no world to build the loop into", 0)
end

local stage = Instance.new("Folder")
stage.Name = "Playable"
stage.Parent = world

--- Where a region actually is, so props stand on the layout rather than beside
--- it. Regions are Models when the blockout built them and Parts otherwise.
local function regionPivot(name: string): CFrame?
	for _, child in ipairs(world:GetChildren()) do
		if child.Name == "Region_" .. name or child.Name == name then
			if child:IsA("Model") then
				return child:GetPivot()
			elseif child:IsA("BasePart") then
				return child.CFrame
			end
		end
	end
	return nil
end

-- The buildable slots, drawn from the layout rather than from coordinates
-- chosen here: a plot the grammar moved takes its slots with it.
local slots: { CFrame } = {}
for _, regionName in ipairs({ "build_west", "build_east", "arena", "staging" }) do
	local pivot = regionPivot(regionName)
	if pivot ~= nil then
		for index = -1, 1 do
			table.insert(slots, pivot * CFrame.new(index * 14, 0, 0))
		end
	end
end
if #slots == 0 then
	table.insert(slots, CFrame.new(0, 0, 0))
end

--- One buildable pad: a plinth, a prompt, and the cost the catalogue set.
local function pad(index: number, at: CFrame, entry: { [string]: any })
	local price = math.max(math.floor((entry.power or 10) * 5), 1)

	local plinth = Instance.new("Part")
	plinth.Name = "Pad_" .. index
	plinth.Anchored = true
	plinth.Size = Vector3.new(8, 1, 8)
	plinth.CFrame = at * CFrame.new(0, 0.5, 0)
	plinth.Color = tokens:color("stonePrimary")
	plinth.Material = Enum.Material.Slate
	plinth.Parent = stage

	local marker = Instance.new("Part")
	marker.Name = "Marker"
	marker.Anchored = true
	marker.CanCollide = false
	marker.Size = Vector3.new(3, 0.6, 3)
	marker.CFrame = plinth.CFrame * CFrame.new(0, 0.8, 0)
	marker.Color = tokens:color("accentGold")
	marker.Material = Enum.Material.Neon
	marker.Transparency = 0.35
	marker.Parent = plinth

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Build " .. tostring(entry.name)
	prompt.ObjectText = tostring(price) .. " cash"
	prompt.HoldDuration = 0.4
	prompt.MaxActivationDistance = 14
	prompt.RequiresLineOfSight = false
	prompt.Parent = plinth

	prompt.Triggered:Connect(function(player: Player)
		if systems.economy == nil then
			return
		end
		-- Spent through the economy, never by editing a number here. Two paths
		-- that move currency is how a ledger stops reconciling.
		local paid = systems.economy:spend(player, "cash", price, "build:" .. tostring(entry.id))
		if not paid then
			prompt.ObjectText = "Need " .. tostring(price) .. " cash"
			task.delay(1.5, function()
				prompt.ObjectText = tostring(price) .. " cash"
			end)
			return
		end

		local stats = entry.stats or {}
		local tower = Instance.new("Part")
		tower.Name = tostring(entry.id)
		tower.Anchored = true
		tower.Size = Vector3.new(4, 6 + math.min(stats.attack or 1, 6), 4)
		tower.CFrame = plinth.CFrame * CFrame.new(0, tower.Size.Y / 2 + 0.5, 0)
		tower.Color = tokens:color("structurePrimary")
		tower.Material = Enum.Material.Wood
		tower.Parent = stage

		local cap = Instance.new("Part")
		cap.Name = "Cap"
		cap.Anchored = true
		cap.Size = Vector3.new(5, 1.2, 5)
		cap.CFrame = tower.CFrame * CFrame.new(0, tower.Size.Y / 2, 0)
		cap.Color = tokens:color("metal")
		cap.Material = Enum.Material.Metal
		cap.Parent = tower

		WorldKit.Vfx.burst(tokens, cap, {
			fromRole = "accentGold", toRole = "neutralLight",
			rate = 0, lifetime = NumberRange.new(0.4, 0.9),
			speed = NumberRange.new(6, 10), size = 1.2,
		}, 18)

		if systems.tower ~= nil then
			systems.tower.place(player, tostring(entry.id),
				{ tower.Position.X, tower.Position.Y, tower.Position.Z })
		end

		plinth:SetAttribute("built", true)
		marker:Destroy()
		prompt:Destroy()
	end)
end

for index, at in ipairs(slots) do
	local entry = Catalogue[((index - 1) % math.max(#Catalogue, 1)) + 1]
	if entry ~= nil then
		pad(index, at, entry)
	end
end

-- Something to earn, so the cost above is payable. The objective pays out on a
-- cadence: a loop whose first step is unaffordable is a loop nobody enters.
local objective = regionPivot("objective") or CFrame.new(0, 0, -60)
local core = Instance.new("Part")
core.Name = "Core"
core.Anchored = true
core.Size = Vector3.new(6, 8, 6)
core.CFrame = objective * CFrame.new(0, 5, 0)
core.Color = tokens:color("accentRare")
core.Material = Enum.Material.Neon
core.Parent = stage

local collect = Instance.new("ProximityPrompt")
collect.ActionText = "Collect"
collect.ObjectText = "probe-roles"
collect.HoldDuration = 0.2
collect.MaxActivationDistance = 16
collect.RequiresLineOfSight = false
collect.Parent = core

collect.Triggered:Connect(function(player: Player)
	Gameplay.reward(player, 25, "objective")
	WorldKit.Vfx.burst(tokens, core, {
		fromRole = "accentRare", toRole = "neutralLight",
		rate = 0, lifetime = NumberRange.new(0.5, 1.0),
		speed = NumberRange.new(8, 14), size = 1.6,
	}, 24)
end)

-- A starting balance, so the first prompt is reachable. A tutorial that opens
-- with an unaffordable purchase teaches the player that the game is broken.
Players.PlayerAdded:Connect(function(player: Player)
	task.wait(1)
	Gameplay.reward(player, 120, "onboarding")
end)

print(string.format("[probe-roles] playable: %d pads, 1 objective", #slots))
	return stage
end

return Playable
