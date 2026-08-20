--!strict
--- Everything that can happen, as functions you call from your own code.
---
--- This is deliberately **not** a rule vocabulary. There is no table to fill in
--- and no schema to satisfy: each of these is a function that takes your
--- handler and returns a connection you own. Compose them however you like,
--- inside whatever structure you are writing.
---
--- What they buy you is the part that is fiddly rather than the part that is
--- interesting: debouncing a `Touched` that fires forty times a second,
--- resolving a part to the player who owns it, noticing that a character
--- respawned, or catching a threshold crossing rather than every change.
---
--- Every one returns something with `disconnect`, so a `Trove` can own it.
---
--- **If it is not here, write it.** These wrap Roblox signals; Roblox signals
--- are still right there.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local MarketplaceService = game:GetService("MarketplaceService")

local Signal = require(script.Parent.Signal)
local Timer = require(script.Parent.Timer)
local Zone = require(script.Parent.Zone)
local Spatial = require(script.Parent.Spatial)

local Events = {}

local function connection(disconnect: () -> ()): any
	local live = true
	local handle
	handle = {
		connected = true,
		disconnect = function()
			if live then
				live = false
				handle.connected = false
				disconnect()
			end
		end,
	}
	handle.Disconnect = handle.disconnect
	return handle
end

local function characterOf(part: BasePart): (Model?, Player?)
	local model = part:FindFirstAncestorOfClass("Model")
	if model == nil then
		return nil, nil
	end
	if model:FindFirstChildOfClass("Humanoid") == nil then
		return nil, nil
	end
	return model, Players:GetPlayerFromCharacter(model)
end

-- -- contact -------------------------------------------------------------------

--- Something touched this part.
---
--- Debounced per toucher, because raw `Touched` fires continuously while
--- anything rests against a part -- which turns a damage brick into an instant
--- kill and a pickup into a hundred pickups.
function Events.onTouch(part: BasePart, handler: (Model?, Player?, BasePart) -> (),
	options: { [string]: any }?): any

	local opts = options or {}
	local gap = tonumber(opts.debounce) or 0.5
	local last: { [Instance]: number } = {}

	local link = part.Touched:Connect(function(other: BasePart)
		local character, player = characterOf(other)
		if opts.playersOnly ~= false and character == nil then
			return
		end
		local key: Instance = character or other
		local now = os.clock()
		if now - (last[key] or -math.huge) < gap then
			return
		end
		last[key] = now
		handler(character, player, other)
	end)
	return connection(function()
		link:Disconnect()
		table.clear(last)
	end)
end

--- Something stopped touching this part.
function Events.onTouchEnded(part: BasePart, handler: (Model?, Player?, BasePart) -> ()): any
	local link = part.TouchEnded:Connect(function(other: BasePart)
		local character, player = characterOf(other)
		handler(character, player, other)
	end)
	return connection(function()
		link:Disconnect()
	end)
end

--- Somebody clicked it.
function Events.onClick(part: BasePart, handler: (Player, BasePart) -> (),
	options: { [string]: any }?): any

	local opts = options or {}
	local detector = part:FindFirstChildOfClass("ClickDetector")
	local made = false
	if detector == nil then
		detector = Instance.new("ClickDetector")
		-- 32 studs is the Roblox default and is short enough that a player
		-- standing in front of a door cannot click it.
		detector.MaxActivationDistance = tonumber(opts.range) or 24
		detector.Parent = part
		made = true
	end
	local link = detector.MouseClick:Connect(function(player)
		handler(player, part)
	end)
	return connection(function()
		link:Disconnect()
		if made then
			detector:Destroy()
		end
	end)
end

--- Somebody held the prompt.
function Events.onPrompt(part: BasePart, handler: (Player, ProximityPrompt) -> (),
	options: { [string]: any }?): any

	local opts = options or {}
	local prompt = part:FindFirstChildOfClass("ProximityPrompt")
	local made = false
	if prompt == nil then
		prompt = Instance.new("ProximityPrompt")
		prompt.ObjectText = opts.label or part.Name
		prompt.ActionText = opts.action or "Use"
		prompt.MaxActivationDistance = tonumber(opts.range) or 12
		prompt.HoldDuration = tonumber(opts.holdTime) or 0
		prompt.RequiresLineOfSight = opts.lineOfSight == true
		prompt.Parent = part
		made = true
	end
	local link = prompt.Triggered:Connect(function(player)
		handler(player, prompt)
	end)
	return connection(function()
		link:Disconnect()
		if made then
			prompt:Destroy()
		end
	end)
end

-- -- space ----------------------------------------------------------------------

--- Something entered a volume. Correct enter and exit, unlike `Touched`.
function Events.onEnter(centre: Vector3, size: Vector3,
	handler: (Instance, Player?) -> (), options: { [string]: any }?): any

	local zone = Zone.new(centre, size, options)
	zone.entered:connect(handler)
	return connection(function()
		zone:destroy()
	end)
end

function Events.onExit(centre: Vector3, size: Vector3,
	handler: (Instance, Player?) -> (), options: { [string]: any }?): any

	local zone = Zone.new(centre, size, options)
	zone.left:connect(handler)
	return connection(function()
		zone:destroy()
	end)
end

--- Both halves and the zone itself, when you want to ask who is inside.
function Events.zone(centre: Vector3, size: Vector3, options: { [string]: any }?)
	return Zone.new(centre, size, options)
end

--- Something got within range of a point.
function Events.onApproach(point: Vector3, radius: number,
	handler: (Model, Player?) -> (), options: { [string]: any }?): any

	local opts = options or {}
	local inside: { [Instance]: boolean } = {}
	local handle = Timer.every(tonumber(opts.beat) or 0.2, function()
		local found: { [Instance]: boolean } = {}
		for _, player in ipairs(Players:GetPlayers()) do
			local character = player.Character
			if character ~= nil then
				local ok, pivot = pcall(function()
					return character:GetPivot().Position
				end)
				if ok and (pivot - point).Magnitude <= radius then
					found[character] = true
					if not inside[character] then
						inside[character] = true
						handler(character, player)
					end
				end
			end
		end
		for character in pairs(inside) do
			if not found[character] then
				inside[character] = nil
			end
		end
	end, "onApproach")
	return connection(function()
		handle:cancel()
	end)
end

--- Something can see something else. Guards, turrets, jump scares.
function Events.onSighted(watcher: Instance, handler: (Model, Player?) -> (),
	options: { [string]: any }?): any

	local opts = options or {}
	local range = tonumber(opts.range) or 90
	local seen: { [Instance]: boolean } = {}
	local handle = Timer.every(tonumber(opts.beat) or 0.3, function()
		if watcher.Parent == nil then
			return
		end
		local ok, from = pcall(function()
			return watcher:GetPivot().Position
		end)
		if not ok then
			return
		end
		for _, player in ipairs(Players:GetPlayers()) do
			local character = player.Character
			if character ~= nil then
				local ok2, at = pcall(function()
					return character:GetPivot().Position
				end)
				if ok2 and (at - from).Magnitude <= range
					and Spatial.sees(from, at, { caster = watcher, target = character }) then
					if not seen[character] then
						seen[character] = true
						handler(character, player)
					end
				else
					seen[character] = nil
				end
			end
		end
	end, "onSighted")
	return connection(function()
		handle:cancel()
	end)
end

-- -- time ------------------------------------------------------------------------

function Events.after(seconds: number, handler: () -> ()): any
	local handle = Timer.after(seconds, handler)
	return connection(function() handle:cancel() end)
end

function Events.every(seconds: number, handler: (number) -> ()): any
	local handle = Timer.every(seconds, handler)
	return connection(function() handle:cancel() end)
end

function Events.eachFrame(handler: (number) -> ()): any
	local link = RunService.Heartbeat:Connect(handler)
	return connection(function() link:Disconnect() end)
end

--- Count down out loud. Rounds, waves, escape sequences.
function Events.countdown(seconds: number, onTick: (number) -> (), onDone: () -> ()): any
	local left = math.floor(seconds)
	onTick(left)
	local handle
	handle = Timer.every(1, function()
		left -= 1
		if left <= 0 then
			handle:cancel()
			onTick(0)
			onDone()
		else
			onTick(left)
		end
	end, "countdown")
	return connection(function() handle:cancel() end)
end

-- -- state -------------------------------------------------------------------------

--- An attribute changed anywhere.
function Events.onAttribute(subject: Instance, name: string,
	handler: (any, any) -> ()): any

	local previous = subject:GetAttribute(name)
	local link = subject:GetAttributeChangedSignal(name):Connect(function()
		local value = subject:GetAttribute(name)
		local was = previous
		previous = value
		handler(value, was)
	end)
	return connection(function() link:Disconnect() end)
end

--- An attribute crossed a line, in a direction. Low health, full meter, broke.
---
--- The difference from `onAttribute` matters: a health bar changing from 40 to
--- 39 is not an event, and a handler that fires on every change has to
--- rediscover the threshold itself every time.
function Events.onThreshold(subject: Instance, name: string, threshold: number,
	direction: string, handler: (number) -> ()): any

	local previous = tonumber(subject:GetAttribute(name)) or 0
	local link = subject:GetAttributeChangedSignal(name):Connect(function()
		local value = tonumber(subject:GetAttribute(name)) or 0
		local crossed =
			if direction == "below" then previous >= threshold and value < threshold
			elseif direction == "above" then previous <= threshold and value > threshold
			else previous ~= value and value == threshold
		previous = value
		if crossed then
			handler(value)
		end
	end)
	return connection(function() link:Disconnect() end)
end

function Events.onProperty(subject: Instance, property: string, handler: (any) -> ()): any
	local link = subject:GetPropertyChangedSignal(property):Connect(function()
		handler((subject :: any)[property])
	end)
	return connection(function() link:Disconnect() end)
end

--- Anything tagged this way, now and as more appear.
function Events.onTagged(tag: string, handler: (Instance) -> (),
	removed: ((Instance) -> ())?): any

	for _, item in ipairs(CollectionService:GetTagged(tag)) do
		task.spawn(handler, item)
	end
	local added = CollectionService:GetInstanceAddedSignal(tag):Connect(handler)
	local gone = if removed ~= nil
		then CollectionService:GetInstanceRemovedSignal(tag):Connect(removed)
		else nil
	return connection(function()
		added:Disconnect()
		if gone ~= nil then
			gone:Disconnect()
		end
	end)
end

-- -- people ---------------------------------------------------------------------------

--- A player joined. Fires for everybody already here, which is what you meant.
function Events.onPlayer(handler: (Player) -> ()): any
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(handler, player)
	end
	local link = Players.PlayerAdded:Connect(handler)
	return connection(function() link:Disconnect() end)
end

function Events.onPlayerLeft(handler: (Player) -> ()): any
	local link = Players.PlayerRemoving:Connect(handler)
	return connection(function() link:Disconnect() end)
end

--- A character spawned. Fires for existing characters and every respawn.
function Events.onCharacter(handler: (Model, Player, Humanoid) -> ()): any
	local troves = {}
	local function watch(player: Player)
		local function arrived(character: Model)
			local humanoid = character:WaitForChild("Humanoid", 5)
			if humanoid ~= nil and humanoid:IsA("Humanoid") then
				handler(character, player, humanoid)
			end
		end
		if player.Character ~= nil then
			task.spawn(arrived, player.Character)
		end
		troves[player] = player.CharacterAdded:Connect(arrived)
	end

	local outer = Events.onPlayer(watch)
	return connection(function()
		outer:disconnect()
		for _, link in pairs(troves) do
			link:Disconnect()
		end
		table.clear(troves)
	end)
end

function Events.onDeath(handler: (Model, Player) -> ()): any
	return Events.onCharacter(function(character, player, humanoid)
		humanoid.Died:Connect(function()
			handler(character, player)
		end)
	end)
end

--- Health dropped. Damage, in the only form the engine actually reports.
function Events.onDamaged(handler: (Model, Player, number, number) -> ()): any
	return Events.onCharacter(function(character, player, humanoid)
		local previous = humanoid.Health
		humanoid.HealthChanged:Connect(function(health)
			local delta = health - previous
			previous = health
			if delta < 0 then
				handler(character, player, -delta, health)
			end
		end)
	end)
end

-- -- input -------------------------------------------------------------------------------

--- A key or button. Client only -- the server has no keyboard, and asking for
--- one there is a mistake worth naming rather than ignoring.
function Events.onInput(key: Enum.KeyCode, handler: (InputObject) -> ()): any
	if not RunService:IsClient() then
		warn("[Events] onInput only means anything on the client")
		return connection(function() end)
	end
	local link = UserInputService.InputBegan:Connect(function(input, typing)
		if typing then
			return
		end
		if input.KeyCode == key then
			handler(input)
		end
	end)
	return connection(function() link:Disconnect() end)
end

-- -- commerce ------------------------------------------------------------------------------

function Events.onPurchase(handler: (Player, number, boolean) -> ()): any
	local link = MarketplaceService.PromptGamePassPurchaseFinished:Connect(handler)
	return connection(function() link:Disconnect() end)
end

-- -- your own --------------------------------------------------------------------------------

local custom: { [string]: any } = {}

--- Name your own event. Nothing here is privileged over it.
function Events.custom(name: string)
	local existing = custom[name]
	if existing == nil then
		existing = Signal.new(name)
		custom[name] = existing
	end
	return existing
end

function Events.on(name: string, handler: (...any) -> ()): any
	return Events.custom(name):connect(handler)
end

function Events.emit(name: string, ...)
	Events.custom(name):fire(...)
end

function Events.list(): { string }
	local names = {}
	for name in pairs(custom) do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

return Events
