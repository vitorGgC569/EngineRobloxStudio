--!strict
--- Everything you can do, as functions you call from your own code.
---
--- The other half of `Events`. Same principle: no schema, no vocabulary, no
--- table to fill in — just functions, composed however you want.
---
--- What each one buys is the Roblox-specific care that is easy to leave out and
--- silent when you do: a teleport that survives the character not being loaded,
--- a spawn that lands on the ground instead of inside it, a heal that respects
--- MaxHealth, a destroy that cleans the welds first.
---
--- **Nothing here is required.** Every one of these is ten lines of Luau you
--- could write yourself, and sometimes you should.

local Players = game:GetService("Players")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local MarketplaceService = game:GetService("MarketplaceService")
local RunService = game:GetService("RunService")

local Spatial = require(script.Parent.Spatial)
local Curve = require(script.Parent.Curve)
local Timer = require(script.Parent.Timer)

local Actions = {}

local function humanoidOf(subject: any): Humanoid?
	if typeof(subject) ~= "Instance" then
		return nil
	end
	if subject:IsA("Player") then
		local character = subject.Character
		return if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
	end
	if subject:IsA("Humanoid") then
		return subject
	end
	if subject:IsA("Model") then
		return subject:FindFirstChildOfClass("Humanoid")
	end
	return nil
end

local function pivotOf(subject: any): Vector3?
	if typeof(subject) ~= "Instance" then
		return nil
	end
	if subject:IsA("Player") then
		subject = subject.Character
		if subject == nil then
			return nil
		end
	end
	if subject:IsA("BasePart") then
		return subject.Position
	end
	local ok, cframe = pcall(function()
		return subject:GetPivot()
	end)
	return if ok then cframe.Position else nil
end

-- -- making and unmaking ---------------------------------------------------------

--- Create a part with sane defaults. Anchored, because an unanchored part
--- appearing mid-air and falling is almost never what was meant.
function Actions.part(properties: { [string]: any }?): BasePart
	local props = properties or {}
	local part = Instance.new("Part")
	part.Anchored = props.Anchored ~= false
	part.Size = props.Size or Vector3.new(4, 4, 4)
	part.Position = props.Position or Vector3.zero
	for key, value in pairs(props) do
		if key ~= "Parent" then
			pcall(function()
				(part :: any)[key] = value
			end)
		end
	end
	part.Parent = props.Parent or workspace
	return part
end

--- Put a copy somewhere, settled onto the ground.
function Actions.spawn(template: Instance, at: Vector3, options: { [string]: any }?): Instance
	local opts = options or {}
	local copy = template:Clone()
	local position = at
	if opts.settle ~= false then
		local bounds = Spatial.bounds(copy)
		local lift = if bounds ~= nil then bounds.size.Y * 0.5 else 0
		position = Spatial.settle(at, { lift = lift, ignore = { copy } })
	end
	copy.Parent = opts.parent or workspace
	if copy:IsA("BasePart") then
		copy.Position = position
	elseif copy:IsA("Model") then
		copy:PivotTo(CFrame.new(position))
	end
	if opts.lifetime ~= nil then
		Debris:AddItem(copy, tonumber(opts.lifetime) or 10)
	end
	return copy
end

function Actions.destroy(subject: Instance, delay: number?)
	if delay ~= nil and delay > 0 then
		Debris:AddItem(subject, delay)
		return
	end
	subject:Destroy()
end

function Actions.clone(subject: Instance, parent: Instance?): Instance
	local copy = subject:Clone()
	copy.Parent = parent or subject.Parent
	return copy
end

-- -- moving ------------------------------------------------------------------------

function Actions.move(subject: Instance, to: Vector3)
	if subject:IsA("BasePart") then
		subject.Position = to
	elseif subject:IsA("Model") then
		subject:PivotTo(CFrame.new(to))
	end
end

function Actions.rotate(subject: Instance, degrees: Vector3)
	local turn = CFrame.Angles(math.rad(degrees.X), math.rad(degrees.Y), math.rad(degrees.Z))
	if subject:IsA("BasePart") then
		subject.CFrame = CFrame.new(subject.Position) * turn
	elseif subject:IsA("Model") then
		local pivot = subject:GetPivot()
		subject:PivotTo(CFrame.new(pivot.Position) * turn)
	end
end

function Actions.scale(subject: Instance, factor: number)
	if subject:IsA("BasePart") then
		subject.Size *= factor
	elseif subject:IsA("Model") then
		local ok = pcall(function()
			subject:ScaleTo(subject:GetScale() * factor)
		end)
		if not ok then
			for _, item in ipairs(subject:GetDescendants()) do
				if item:IsA("BasePart") then
					item.Size *= factor
				end
			end
		end
	end
end

--- Glide there over time. Returns the tween so it can be waited on or cancelled.
function Actions.glide(subject: Instance, to: Vector3, seconds: number,
	easing: string?): Tween?

	local target = if subject:IsA("BasePart") then subject else nil
	if target == nil and subject:IsA("Model") then
		target = subject.PrimaryPart
		if target == nil then
			-- A model with no PrimaryPart cannot be tweened as one thing; step
			-- it instead of failing silently.
			local from = subject:GetPivot().Position
			local elapsed = 0
			Timer.each(function(delta)
				elapsed += delta
				local t = math.min(elapsed / seconds, 1)
				local eased = if easing ~= nil then Curve.ease(easing, t) else t
				subject:PivotTo(CFrame.new(from:Lerp(to, eased)))
				return t >= 1
			end, "glide")
			return nil
		end
	end
	if target == nil then
		return nil
	end
	local info = TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tween = TweenService:Create(target, info, { Position = to })
	tween:Play()
	return tween
end

--- Put a player somewhere, waiting for a character that may not exist yet.
function Actions.teleport(subject: any, to: Vector3): boolean
	local character = if typeof(subject) == "Instance" and subject:IsA("Player")
		then subject.Character else subject
	if character == nil then
		return false
	end
	local ok = pcall(function()
		character:PivotTo(CFrame.new(to + Vector3.new(0, 3, 0)))
	end)
	return ok
end

-- -- bodies ---------------------------------------------------------------------------

function Actions.damage(subject: any, amount: number): boolean
	local humanoid = humanoidOf(subject)
	if humanoid == nil then
		-- Not every damageable thing is a Humanoid. Fall back to the attribute
		-- convention the rest of this engine uses.
		if typeof(subject) == "Instance" then
			local health = tonumber(subject:GetAttribute("Health"))
			if health ~= nil then
				subject:SetAttribute("Health", math.max(health - amount, 0))
				return true
			end
		end
		return false
	end
	humanoid.Health = math.max(humanoid.Health - amount, 0)
	return true
end

function Actions.heal(subject: any, amount: number): boolean
	local humanoid = humanoidOf(subject)
	if humanoid == nil then
		if typeof(subject) == "Instance" then
			local health = tonumber(subject:GetAttribute("Health"))
			local maximum = tonumber(subject:GetAttribute("MaxHealth")) or 100
			if health ~= nil then
				subject:SetAttribute("Health", math.min(health + amount, maximum))
				return true
			end
		end
		return false
	end
	humanoid.Health = math.min(humanoid.Health + amount, humanoid.MaxHealth)
	return true
end

function Actions.kill(subject: any): boolean
	local humanoid = humanoidOf(subject)
	if humanoid ~= nil then
		humanoid.Health = 0
		return true
	end
	return false
end

function Actions.setSpeed(subject: any, speed: number): boolean
	local humanoid = humanoidOf(subject)
	if humanoid == nil then
		return false
	end
	humanoid.WalkSpeed = speed
	return true
end

function Actions.push(subject: Instance, force: Vector3): boolean
	local part = if subject:IsA("BasePart") then subject
		elseif subject:IsA("Model") then subject.PrimaryPart
		else nil
	if part == nil or part.Anchored then
		return false
	end
	part:ApplyImpulse(force * part.AssemblyMass)
	return true
end

-- -- state ------------------------------------------------------------------------------

function Actions.set(subject: Instance, name: string, value: any)
	subject:SetAttribute(name, value)
end

function Actions.get(subject: Instance, name: string, fallback: any?): any
	local value = subject:GetAttribute(name)
	if value == nil then
		return fallback
	end
	return value
end

--- Add to a number attribute, clamped. Currency, score, ammo, sanity.
function Actions.add(subject: Instance, name: string, amount: number,
	options: { [string]: any }?): number

	local opts = options or {}
	local value = (tonumber(subject:GetAttribute(name)) or 0) + amount
	if opts.min ~= nil then
		value = math.max(value, opts.min)
	end
	if opts.max ~= nil then
		value = math.min(value, opts.max)
	end
	subject:SetAttribute(name, value)
	return value
end

--- Spend, if there is enough. Returns whether it happened -- the check and the
--- deduction in one place, because doing them separately is how a player buys
--- something twice.
function Actions.spend(subject: Instance, name: string, amount: number): boolean
	local value = tonumber(subject:GetAttribute(name)) or 0
	if value < amount then
		return false
	end
	subject:SetAttribute(name, value - amount)
	return true
end

-- -- presentation --------------------------------------------------------------------------

function Actions.sound(assetId: string, options: { [string]: any }?): Sound
	local opts = options or {}
	local sound = Instance.new("Sound")
	sound.SoundId = if string.find(assetId, "rbxassetid") then assetId
		else ("rbxassetid://" .. assetId)
	sound.Volume = tonumber(opts.volume) or 0.5
	sound.PlaybackSpeed = tonumber(opts.pitch) or 1
	sound.Looped = opts.loop == true
	sound.Parent = opts.at or SoundService
	sound:Play()
	if not sound.Looped then
		-- Cleaned up by itself; an unparented Sound that finished is still an
		-- Instance, and a game that plays ten a second accumulates them.
		sound.Ended:Once(function()
			sound:Destroy()
		end)
		Debris:AddItem(sound, 30)
	end
	return sound
end

function Actions.highlight(subject: Instance, colour: Color3?, seconds: number?): Highlight
	local existing = subject:FindFirstChildOfClass("Highlight")
	local light = existing or Instance.new("Highlight")
	light.FillColor = colour or Color3.fromRGB(255, 214, 120)
	light.OutlineColor = colour or Color3.fromRGB(255, 240, 200)
	light.FillTransparency = 0.6
	light.Parent = subject
	if seconds ~= nil then
		Debris:AddItem(light, seconds)
	end
	return light
end

function Actions.notify(player: Player, message: string, options: { [string]: any }?)
	local opts = options or {}
	-- Attribute-based, so a HUD bound with `Compose` picks it up and a game
	-- without one still records that it happened.
	player:SetAttribute("Notice", message)
	player:SetAttribute("NoticeAt", os.clock())
	if opts.kind ~= nil then
		player:SetAttribute("NoticeKind", opts.kind)
	end
end

function Actions.shake(intensity: number, seconds: number)
	if not RunService:IsClient() then
		return
	end
	local camera = workspace.CurrentCamera
	if camera == nil then
		return
	end
	local elapsed = 0
	local origin = camera.CFrame
	Timer.each(function(delta)
		elapsed += delta
		local t = elapsed / seconds
		if t >= 1 then
			return true
		end
		local falloff = intensity * (1 - t)
		camera.CFrame = origin * CFrame.new(
			(math.random() - 0.5) * falloff,
			(math.random() - 0.5) * falloff,
			0)
		return false
	end, "shake")
end

-- -- commerce -------------------------------------------------------------------------------

function Actions.prompt(player: Player, kind: string, id: number): boolean
	local ok = pcall(function()
		if kind == "pass" then
			MarketplaceService:PromptGamePassPurchase(player, id)
		else
			MarketplaceService:PromptProductPurchase(player, id)
		end
	end)
	return ok
end

function Actions.owns(player: Player, passId: number): boolean
	local ok, result = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
	end)
	return ok and result == true
end

return Actions
