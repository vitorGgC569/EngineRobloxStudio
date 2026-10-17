--!strict
--[[
	Carry — coal off the road and into a beacon.

	A prompt and a remote are the same intent. Sim accepts or refuses it
	on the profile Ledger passes in. This module does not keep a copy.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Net = Forge.Net

local Sim = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sim"))
local Ledger = require(script.Parent.Ledger)

local Carry = {}

local bound: { [ProximityPrompt]: boolean } = {}

local function apply(player: Player, step: (any) -> (boolean, string?))
	-- Sim edits the profile it is given and reports success separately.
	-- The boolean is how Ledger knows whether to persist; it is not a new table.
	Ledger.mutate(player, function(profile)
		if type(profile) ~= "table" then
			return false, "bad_id"
		end
		return step(profile)
	end)
end

local function take(player: Player)
	apply(player, function(profile)
		return Sim.takeCoal(profile)
	end)
end

local function feed(player: Player, beaconId: string)
	apply(player, function(profile)
		return Sim.feed(profile, beaconId)
	end)
end

local function onPrompt(prompt: ProximityPrompt, player: Player)
	local action = prompt:GetAttribute("Action")
	if action == "take" then
		take(player)
	elseif action == "feed" then
		local beaconId = prompt:GetAttribute("BeaconId")
		if type(beaconId) == "string" then
			feed(player, beaconId)
		end
	end
end

local function bindPrompt(inst: Instance)
	if not inst:IsA("ProximityPrompt") or bound[inst] then
		return
	end
	bound[inst] = true
	-- Read Action at trigger time. Road may set it after the prompt is parented.
	inst.Triggered:Connect(function(player: Player)
		onPrompt(inst, player)
	end)
end

local function watch(road: Instance)
	for _, inst in road:GetDescendants() do
		bindPrompt(inst)
	end
	road.DescendantAdded:Connect(bindPrompt)
end

function Carry.start()
	local road = Workspace:FindFirstChild("Road")
	if road then
		watch(road)
	else
		local conn: RBXScriptConnection? = nil
		conn = Workspace.ChildAdded:Connect(function(child)
			if child.Name ~= "Road" then
				return
			end
			if conn then
				conn:Disconnect()
			end
			watch(child)
		end)
	end

	-- The fire is the intent. The confirm field is not a second rule.
	Net.on("TakeCoal", function(player: Player, _payload: any)
		take(player)
	end)
	Net.on("FeedBeacon", function(player: Player, payload: any)
		local beaconId = if type(payload) == "table" then payload.beaconId else nil
		if type(beaconId) ~= "string" then
			return
		end
		feed(player, beaconId)
	end)
	Net.on("PlayAgain", function(player: Player, _payload: any)
		Ledger.mutate(player, function(profile)
			return Sim.reopen(profile)
		end)
	end)
end

return Carry
