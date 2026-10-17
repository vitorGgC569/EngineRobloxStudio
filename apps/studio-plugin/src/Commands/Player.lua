--!strict
-- The rest of the player family: teleport, equip, activate, inventory.
--
-- `actor.*` already spawns a rig, attaches to a real player, walks, navigates,
-- jumps and interacts. These four close the gap between "the agent can move"
-- and "the agent can play the product", which is the whole point of the family.
--
-- Everything here works on a character rather than on our synthetic rig
-- specifically, so an agent driving a real attached player gets the same
-- surface as one driving a spawned actor.

local Players = game:GetService("Players")

local Errors = require(script.Parent.Parent.Errors)
local Refs = require(script.Parent.Parent.Refs)
local Resolve = require(script.Parent.Parent.Resolve)
local Serialize = require(script.Parent.Parent.Serialize)

local PlayerCommands = {}

local function resolveCharacter(params: { [string]: any }): Model
	if params.character ~= nil then
		local instance = Resolve.instance(params.character)
		if not instance:IsA("Model") then
			Errors.raise("E_BAD_PARAMS", "character must resolve to a Model")
		end
		return instance
	end
	if params.player ~= nil then
		local player = Players:FindFirstChild(tostring(params.player))
		if player == nil or not player:IsA("Player") then
			Errors.raise("E_NOT_FOUND", "no player named " .. tostring(params.player))
		end
		local character = (player :: Player).Character
		if character == nil then
			Errors.raise("E_NOT_FOUND", "that player has no character right now")
		end
		return character
	end

	-- Fall back to the only character present. Guessing between several would
	-- make a scenario act on whichever one happened to load first.
	local found: { Model } = {}
	for _, descendant in ipairs(workspace:GetChildren()) do
		if descendant:IsA("Model") and descendant:FindFirstChildOfClass("Humanoid") ~= nil then
			table.insert(found, descendant)
		end
	end
	if #found == 0 then
		Errors.raise("E_NOT_FOUND", "no character is present in the workspace")
	end
	if #found > 1 then
		local names = {}
		for _, model in ipairs(found) do
			table.insert(names, model.Name)
		end
		Errors.raise("E_BAD_PARAMS", string.format(
			"%d characters are present (%s); name one with `character` or `player`",
			#found, table.concat(names, ", ")
		))
	end
	return found[1]
end

local function humanoidOf(character: Model): Humanoid
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		Errors.raise("E_BAD_PARAMS", character.Name .. " has no Humanoid")
	end
	return humanoid
end

local function describeTool(tool: Tool): { [string]: any }
	return {
		ref = Refs.of(tool),
		name = tool.Name,
		path = tool:GetFullName(),
		canBeDropped = tool.CanBeDropped,
		requiresHandle = tool.RequiresHandle,
		hasHandle = tool:FindFirstChild("Handle") ~= nil,
	}
end

--- player.teleport: move a character instantly, without walking.
---
--- Distinct from `walk_to` on purpose. Walking proves the world is navigable;
--- teleporting deliberately skips that proof to set up a scenario, and a test
--- that used one when it meant the other proves nothing.
function PlayerCommands.teleport(params: { [string]: any }): any
	local character = resolveCharacter(params)
	local humanoid = humanoidOf(character)
	local root = character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		Errors.raise("E_BAD_PARAMS", character.Name .. " has no HumanoidRootPart")
	end

	local target
	if params.position ~= nil then
		local position = params.position
		if type(position) ~= "table" or #position ~= 3 then
			Errors.raise("E_BAD_PARAMS", "position must be three numbers")
		end
		target = Vector3.new(position[1], position[2], position[3])
	elseif params.path ~= nil then
		local instance = Resolve.instance(params.path)
		if instance:IsA("BasePart") then
			target = instance.Position + Vector3.new(0, (instance.Size.Y / 2) + 3, 0)
		elseif instance:IsA("Model") then
			local cframe = instance:GetPivot()
			target = cframe.Position + Vector3.new(0, 5, 0)
		else
			Errors.raise("E_BAD_PARAMS", "path must resolve to a BasePart or Model")
		end
	else
		Errors.raise("E_BAD_PARAMS", "teleport needs a position or a path")
	end

	local before = root.Position
	character:PivotTo(CFrame.new(target))
	-- Zeroed so the character does not carry its previous momentum into the
	-- destination, which is what makes a teleported actor slide off a platform.
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero

	return {
		conclusive = true,
		character = character.Name,
		from = Serialize.roundVector(before, 3),
		to = Serialize.roundVector(root.Position, 3),
		requested = Serialize.roundVector(target, 3),
		drift = Serialize.round((root.Position - target).Magnitude, 3),
		humanoidState = tostring(humanoid:GetState()),
	}
end

--- player.inventory: what the character is carrying, held and stowed.
function PlayerCommands.inventory(params: { [string]: any }): any
	local character = resolveCharacter(params)
	local player = Players:GetPlayerFromCharacter(character)

	local equipped: { any } = {}
	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("Tool") then
			table.insert(equipped, describeTool(child))
		end
	end

	local backpack: { any } = {}
	local unavailable: { string } = {}
	if player ~= nil then
		local container = player:FindFirstChildOfClass("Backpack")
		if container ~= nil then
			for _, child in ipairs(container:GetChildren()) do
				if child:IsA("Tool") then
					table.insert(backpack, describeTool(child))
				end
			end
		else
			table.insert(unavailable, "backpack")
		end
	else
		-- A spawned rig is not a Player, so it has no Backpack at all. Saying so
		-- separates "carrying nothing" from "cannot carry anything".
		table.insert(unavailable, "backpack (this character is not a Player)")
	end

	return {
		conclusive = true,
		character = character.Name,
		isPlayer = player ~= nil,
		equipped = equipped,
		backpack = backpack,
		equippedCount = #equipped,
		backpackCount = #backpack,
		unavailable = unavailable,
	}
end

--- player.equip: hold a tool, or put it away.
function PlayerCommands.equip(params: { [string]: any }): any
	local character = resolveCharacter(params)
	local humanoid = humanoidOf(character)
	local player = Players:GetPlayerFromCharacter(character)

	if params.unequip == true then
		local held: { string } = {}
		for _, child in ipairs(character:GetChildren()) do
			if child:IsA("Tool") then
				table.insert(held, child.Name)
			end
		end
		humanoid:UnequipTools()
		return {
			conclusive = true,
			action = "unequip",
			character = character.Name,
			unequipped = held,
		}
	end

	local name = params.tool
	if type(name) ~= "string" or name == "" then
		Errors.raise("E_BAD_PARAMS", "equip needs a tool name, or unequip = true")
	end

	local tool: Tool? = nil
	local searched: { string } = {}
	local containers: { Instance } = { character }
	if player ~= nil then
		local backpack = player:FindFirstChildOfClass("Backpack")
		if backpack ~= nil then
			table.insert(containers, backpack)
		end
	end
	for _, container in ipairs(containers) do
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") then
				table.insert(searched, child.Name)
				if child.Name == name then
					tool = child
				end
			end
		end
	end

	if tool == nil then
		Errors.raise("E_NOT_FOUND", string.format(
			"no tool named %q; the character can reach: %s",
			name, if #searched > 0 then table.concat(searched, ", ") else "nothing"
		))
	end

	humanoid:EquipTool(tool :: Tool)

	return {
		conclusive = true,
		action = "equip",
		character = character.Name,
		tool = describeTool(tool :: Tool),
		-- Equipping is asynchronous in the sense that the tool has to reparent.
		-- Reporting the observed parent rather than assuming success is what
		-- distinguishes "equipped" from "asked to equip".
		held = (tool :: Tool).Parent == character,
	}
end

--- player.activate: use the held tool, the way a click would.
---
--- `Tool:Activate()` fires the tool's own `Activated` signal, which is what the
--- game's code listens to. It is not a synthesised click: no input is generated,
--- so anything reading `UserInputService` directly will not see it. That
--- limitation is reported rather than hidden.
function PlayerCommands.activate(params: { [string]: any }): any
	local character = resolveCharacter(params)

	local tool: Tool? = nil
	if params.tool ~= nil then
		for _, child in ipairs(character:GetChildren()) do
			if child:IsA("Tool") and child.Name == params.tool then
				tool = child
			end
		end
		if tool == nil then
			Errors.raise("E_NOT_FOUND", string.format(
				"the character is not holding a tool named %q", tostring(params.tool)
			))
		end
	else
		for _, child in ipairs(character:GetChildren()) do
			if child:IsA("Tool") then
				tool = child
				break
			end
		end
		if tool == nil then
			Errors.raise("E_BAD_PARAMS", "the character is holding no tool to activate")
		end
	end

	local ok, failure = pcall(function()
		(tool :: Tool):Activate()
	end)
	if not ok then
		Errors.raise(Errors.EXEC, "activation failed: " .. tostring(failure))
	end

	return {
		conclusive = true,
		character = character.Name,
		tool = (tool :: Tool).Name,
		activated = true,
		note = "Tool.Activated fired; no input event was synthesised, so listeners "
			.. "reading UserInputService directly will not observe this",
	}
end

return PlayerCommands
