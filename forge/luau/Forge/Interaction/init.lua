--!strict
--[[
	Interaction — things a player can do to the world, in one registry.

		Interaction.register(chestModel, {
			id = "chest",
			label = "Open",
			holdDuration = 0.4,
			range = 12,
			onTrigger = function(player, instance) ... end,
		})

	This wraps ProximityPrompt, and the wrapping earns its place entirely
	because of two measured Roblox behaviours that silently break interaction
	and are invisible in the code that causes them:

	  * `ProximityPromptExclusivity` defaults to `OnePerButton`, so the nearest
	    prompt sharing a key **suppresses every other one**. A prompt can be
	    visible, in range, enabled and impossible to trigger. Forge sets
	    `AlwaysShow` and hands out distinct keys.

	  * `InputHoldBegin()` from the server is accepted and `Triggered` never
	    fires. Activation is client-side, so a headless test that "triggers" a
	    prompt server-side proves nothing. `Interaction.trigger` exists for
	    tests and calls the handler directly, honestly, without pretending a
	    prompt fired.

	A prompt on a fast unanchored part also never fires; the registry warns
	rather than leaving you to find out.
]]

local Players = game:GetService("Players")
local Events = require(script.Parent.Events)

local Interaction = {}

type Options = {
	id: string?,
	label: string?,
	objectLabel: string?,
	holdDuration: number?,
	range: number?,
	key: Enum.KeyCode?,
	enabled: boolean?,
	requiresLineOfSight: boolean?,
	onTrigger: ((player: Player, instance: Instance, entry: any) -> ())?,
	condition: ((player: Player, instance: Instance) -> boolean)?,
	[string]: any,
}

local registry: { [Instance]: any } = {}
local byId: { [string]: { any } } = {}
local keyCursor = 1

-- Distinct keys so two nearby prompts never suppress one another.
local KEY_POOL = {
	Enum.KeyCode.E,
	Enum.KeyCode.F,
	Enum.KeyCode.Q,
	Enum.KeyCode.R,
	Enum.KeyCode.T,
	Enum.KeyCode.G,
}

local function nextKey(): Enum.KeyCode
	local key = KEY_POOL[keyCursor]
	keyCursor = (keyCursor % #KEY_POOL) + 1
	return key
end

local function anchorPart(instance: Instance): BasePart?
	if instance:IsA("BasePart") then
		return instance
	end
	if instance:IsA("Model") then
		local primary = instance.PrimaryPart
		if primary then
			return primary
		end
		return instance:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

function Interaction.register(instance: Instance, options: Options): any
	local opts = options or {}
	local part = anchorPart(instance)
	if not part then
		warn(string.format("[Interaction] %s has no BasePart to attach a prompt to", instance:GetFullName()))
		return nil
	end

	if not part.Anchored and not part:IsDescendantOf(Players) then
		warn(string.format(
			"[Interaction] %s is unanchored; a prompt on a moving part frequently never fires",
			instance:GetFullName()
		))
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "ForgeInteraction"
	prompt.ActionText = opts.label or "Interact"
	prompt.ObjectText = opts.objectLabel or instance.Name
	prompt.HoldDuration = opts.holdDuration or 0
	prompt.MaxActivationDistance = opts.range or 10
	prompt.KeyboardKeyCode = opts.key or nextKey()
	prompt.RequiresLineOfSight = opts.requiresLineOfSight == true
	prompt.Enabled = opts.enabled ~= false
	-- the fix for the silent-suppression trap
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.AlwaysShow
	prompt.Parent = part

	local entry = {
		id = opts.id or instance.Name,
		instance = instance,
		prompt = prompt,
		options = opts,
	}

	registry[instance] = entry
	byId[entry.id] = byId[entry.id] or {}
	table.insert(byId[entry.id], entry)

	entry.connection = prompt.Triggered:Connect(function(player)
		Interaction.trigger(instance, player)
	end)

	entry.destroying = instance.Destroying:Connect(function()
		Interaction.unregister(instance)
	end)

	return entry
end

function Interaction.unregister(instance: Instance)
	local entry = registry[instance]
	if not entry then
		return
	end
	if entry.connection then
		entry.connection:Disconnect()
	end
	if entry.destroying then
		entry.destroying:Disconnect()
	end
	if entry.prompt and entry.prompt.Parent then
		entry.prompt:Destroy()
	end
	registry[instance] = nil

	local list = byId[entry.id]
	if list then
		for i = #list, 1, -1 do
			if list[i] == entry then
				table.remove(list, i)
			end
		end
	end
end

function Interaction.setEnabled(instance: Instance, enabled: boolean)
	local entry = registry[instance]
	if entry and entry.prompt then
		entry.prompt.Enabled = enabled
	end
end

function Interaction.setLabel(instance: Instance, label: string)
	local entry = registry[instance]
	if entry and entry.prompt then
		entry.prompt.ActionText = label
	end
end

--[[
	Run the interaction. Called by the prompt, and callable directly by a test
	or a scripted actor.

	This is the honest path a headless run should use: it does not pretend a
	ProximityPrompt fired, it does what the prompt would have done.
]]
function Interaction.trigger(instance: Instance, player: Player): boolean
	local entry = registry[instance]
	if not entry then
		return false
	end
	local opts = entry.options

	if entry.prompt and not entry.prompt.Enabled then
		return false
	end
	if opts.condition and not opts.condition(player, instance) then
		Events.emit("interaction.refused", { id = entry.id, player = player.Name })
		return false
	end

	Events.emit("interaction.triggered", {
		id = entry.id,
		player = player.Name,
		subject = "player:" .. player.UserId,
		instance = instance.Name,
	})

	if opts.onTrigger then
		local ok, err = pcall(opts.onTrigger, player, instance, entry)
		if not ok then
			warn(string.format("[Interaction] handler for '%s' errored: %s", entry.id, tostring(err)))
			return false
		end
	end
	return true
end

function Interaction.get(instance: Instance): any
	return registry[instance]
end

function Interaction.withId(id: string): { any }
	return byId[id] or {}
end

-- Nearest registered interactable to a point, for games that drive their own
-- input instead of using prompts.
function Interaction.nearest(position: Vector3, maxDistance: number?): (Instance?, number)
	local limit = maxDistance or 12
	local best, bestDistance = nil, limit
	for instance, entry in registry do
		local part = anchorPart(instance)
		if part then
			local distance = (part.Position - position).Magnitude
			if distance < bestDistance then
				best, bestDistance = instance, distance
			end
		end
	end
	return best, bestDistance
end

function Interaction.describe(): { [string]: any }
	local count, ids = 0, {}
	for _, entry in registry do
		count += 1
		ids[entry.id] = (ids[entry.id] or 0) + 1
	end
	return { registered = count, byId = ids }
end

return Interaction
