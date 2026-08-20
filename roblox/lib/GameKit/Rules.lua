--!strict
-- Behaviour installed from data, one rule at a time.
--
-- Every other layer of this SDK could be composed piecemeal -- a wall here, a
-- material there, a sound on that event. Behaviour could not. It arrived whole
-- from a genre recipe, which is why a horror brief came out as a tower defense
-- wearing a horror palette: the recipe chose the game, and the only way to
-- disagree was to edit the recipe.
--
-- A rule is `when` / `require` / `then`. The vocabulary lives in
-- `rqe/gameplay/rules.py` and is validated there, before anything reaches a
-- running game: a rule spending a currency the economy never declared is
-- refused at authoring time rather than erroring on the one path nobody tested.
--
-- **This module trusts that validation and checks anyway.** The Python side
-- knows what the game declares; this side knows what actually exists in the
-- DataModel a second before the rule fires. A pad that was deleted, a prompt
-- renamed, an economy that failed to construct -- none of those are visible to
-- a validator and all of them are visible here.
--
-- **A failing rule never takes the game with it.** Every effect runs in a pcall
-- and a failure is counted and warned, not raised. The alternative is one bad
-- rule killing the script that installs the rest, which is the failure mode
-- that made a whole world stop building over a cue named `denial`.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Rules = {}

export type Effect = { [string]: any }
export type Condition = { [string]: any }

export type Rule = {
	id: string,
	when: { [string]: any },
	require: { Condition }?,
	["then"]: { Effect },
	once: boolean?,
	note: string?,
}

export type Bindings = {
	economy: any?,
	audio: any?,
	tokens: any?,
	world: Instance?,
	announce: ((Player, string) -> ())?,
	spawn: ((string, CFrame) -> Instance?)?,
}

export type Installed = {
	rules: number,
	connections: { RBXScriptConnection },
	fired: { [string]: number },
	refused: { [string]: number },
	problems: { string },
	stop: () -> (),
}

local function fail(message: string): never
	error("[GameKit.Rules] " .. message, 2)
end

--- What a rule may name, mirrored from the Python vocabulary.
---
--- Duplicated deliberately. The authoring side must refuse a bad rule before it
--- travels, and the runtime must refuse one that arrives anyway -- data can
--- reach a place from a file somebody edited by hand.
local TRIGGERS = {
	prompt = true, touch = true, timer = true,
	wave = true, state = true, join = true,
}
local EFFECTS = {
	spend = true, grant = true, spawn = true, destroy = true, play = true,
	announce = true, setAttribute = true, damage = true, vfx = true,
}

function Rules.validate(rule: Rule): { string }
	local problems: { string } = {}
	if type(rule.id) ~= "string" or rule.id == "" then
		table.insert(problems, "a rule needs a non-empty id")
	end
	local when = rule.when
	if type(when) ~= "table" or not TRIGGERS[tostring(when.kind)] then
		table.insert(problems, string.format(
			"rule %s has an unknown trigger %q", tostring(rule.id), tostring(when and when.kind)))
	end
	local effects = rule["then"]
	if type(effects) ~= "table" or #effects == 0 then
		table.insert(problems, string.format(
			"rule %s does nothing", tostring(rule.id)))
	else
		for _, effect in ipairs(effects) do
			if not EFFECTS[tostring(effect.kind)] then
				table.insert(problems, string.format(
					"rule %s names an unknown effect %q",
					tostring(rule.id), tostring(effect.kind)))
			end
		end
	end
	return problems
end

local function subjectOf(context: { [string]: any }): Player?
	local player = context.player
	return if typeof(player) == "Instance" and player:IsA("Player") then player else nil
end

local function holds(condition: Condition, context: { [string]: any },
	bindings: Bindings): boolean
	local kind = tostring(condition.kind)
	if kind == "chance" then
		return math.random() * 100 <= (tonumber(condition.percent) or 0)
	end

	if kind == "count" then
		local root = bindings.world or workspace
		local wanted = tostring(condition.of)
		local seen = 0
		for _, item in ipairs(root:GetDescendants()) do
			if item.Name == wanted then
				seen += 1
			end
		end
		local atLeast = tonumber(condition.atLeast)
		local atMost = tonumber(condition.atMost)
		if atLeast ~= nil and seen < atLeast then return false end
		if atMost ~= nil and seen > atMost then return false end
		return true
	end

	local player = subjectOf(context)
	if player == nil then
		return false
	end

	local value: number? = nil
	if kind == "currency" then
		local economy = bindings.economy
		if economy == nil then
			return false
		end
		local ok, balance = pcall(function()
			return economy:balance(player, tostring(condition.name))
		end)
		value = if ok then tonumber(balance) else nil
	elseif kind == "attribute" then
		value = tonumber(player:GetAttribute(tostring(condition.name)))
		local equals = condition.equals
		if equals ~= nil then
			return player:GetAttribute(tostring(condition.name)) == equals
		end
	end

	if value == nil then
		return false
	end
	local atLeast = tonumber(condition.atLeast)
	local atMost = tonumber(condition.atMost)
	if atLeast ~= nil and value < atLeast then return false end
	if atMost ~= nil and value > atMost then return false end
	return true
end

local function perform(effect: Effect, context: { [string]: any },
	bindings: Bindings): boolean
	local kind = tostring(effect.kind)
	local player = subjectOf(context)

	if kind == "spend" or kind == "grant" then
		local economy = bindings.economy
		if economy == nil or player == nil then
			return false
		end
		local amount = tonumber(effect.amount) or 0
		local currency = tostring(effect.currency)
		if kind == "spend" then
			-- Through the ledger, never by editing a number. Two paths that
			-- move currency is how a balance stops reconciling.
			return economy:spend(player, currency, amount, "rule") == true
		end
		economy:grant(player, currency, amount, "rule")
		return true
	end

	if kind == "play" then
		local audio = bindings.audio
		if audio == nil then
			return false
		end
		local at = context.at
		if typeof(at) == "Instance" then
			audio.playAt(tostring(effect.cue), at)
		else
			audio.play(tostring(effect.cue))
		end
		return true
	end

	if kind == "announce" then
		local announce = bindings.announce
		if announce == nil or player == nil then
			return false
		end
		announce(player, tostring(effect.message))
		return true
	end

	if kind == "setAttribute" then
		if player == nil then
			return false
		end
		player:SetAttribute(tostring(effect.name), effect.value)
		return true
	end

	if kind == "spawn" then
		local spawner = bindings.spawn
		if spawner == nil then
			return false
		end
		local at = context.at
		local cframe = if typeof(at) == "Instance" and at:IsA("BasePart")
			then at.CFrame
			else CFrame.new()
		return spawner(tostring(effect.what), cframe) ~= nil
	end

	if kind == "destroy" then
		local at = context.at
		if typeof(at) == "Instance" then
			at:Destroy()
			return true
		end
		return false
	end

	if kind == "damage" then
		local at = context.at
		if typeof(at) ~= "Instance" then
			return false
		end
		local model = at:IsA("Model") and at or at:FindFirstAncestorOfClass("Model")
		if model == nil then
			return false
		end
		local health = tonumber(model:GetAttribute("Health"))
		if health == nil then
			return false
		end
		model:SetAttribute("Health", math.max(health - (tonumber(effect.amount) or 0), 0))
		return true
	end

	if kind == "chase" or kind == "flee" or kind == "patrol" or kind == "halt" then
		local Pursuit = require(script.Parent.Pursuit)
		local world = bindings.world or workspace
		local wanted = tostring(effect.who)

		-- `who` names a model by name, and there may be several: a rule saying
		-- "chase" means every pilgrim, not the first one the search found.
		local subjects: { Model } = {}
		if wanted == "self" and typeof(context.at) == "Instance" then
			local model = context.at:IsA("Model") and context.at
				or context.at:FindFirstAncestorOfClass("Model")
			if model ~= nil then
				table.insert(subjects, model)
			end
		else
			for _, item in ipairs(world:GetDescendants()) do
				if item:IsA("Model") and item.Name == wanted then
					table.insert(subjects, item)
				end
			end
		end
		if #subjects == 0 then
			return false
		end

		if kind == "halt" then
			local Motion = require(script.Parent.Motion)
			for _, model in ipairs(subjects) do
				Pursuit.stop(model)
				pcall(Motion.stop, model)
			end
			return true
		end

		local points = nil
		if kind == "patrol" and type(effect.points) == "table" then
			points = {}
			for _, point in ipairs(effect.points) do
				if type(point) == "table" and #point >= 3 then
					table.insert(points, Vector3.new(point[1], point[2], point[3]))
				end
			end
		end

		-- Movement animates unless the rule says otherwise. A creature that
		-- pathfinds and slides is the defect Motion exists to fix, and leaving
		-- the two effects independent means every author has to remember.
		local Motion = require(script.Parent.Motion)
		local gait = tostring(effect.gait or "walk")

		local started = 0
		for _, model in ipairs(subjects) do
			local pursuer = Pursuit.start(model, {
				mode = kind,
				speed = tonumber(effect.speed),
				safe = tonumber(effect.safe),
				giveUp = tonumber(effect.giveUp),
				points = points,
			}, function()
				local root = model:FindFirstChild("HumanoidRootPart")
				local from = if root ~= nil and root:IsA("BasePart")
					then root.Position else Vector3.zero
				return Pursuit.nearestPlayer(from)
			end)
			if pursuer ~= nil then
				started += 1
				if gait ~= "none" then
					-- A single-part creature cannot be animated and can still
					-- walk, so this must never block the movement.
					pcall(Motion.play, model, { gait = gait, rate = 1.6 })
				end
			end
		end
		return started > 0
	end

	if kind == "vfx" then
		local tokens = bindings.tokens
		local at = context.at
		if tokens == nil or typeof(at) ~= "Instance" then
			return false
		end
		local WorldKit = require(game:GetService("ReplicatedStorage"):WaitForChild("WorldKit"))
		WorldKit.Vfx.burst(tokens, at, {
			fromRole = "accentGold", toRole = "accentDanger",
			rate = 0, lifetime = NumberRange.new(0.3, 0.7),
			speed = NumberRange.new(6, 14), size = 1.2,
		}, 16)
		return true
	end

	return false
end

--- Install a set of rules against a live game.
---
--- Returns a handle carrying what fired and what refused, because "the rule ran
--- and its condition was false" and "the rule never ran" look identical from
--- outside and mean completely different things.
function Rules.install(rules: { Rule }, bindings: Bindings): Installed
	if type(rules) ~= "table" then
		fail("rules must be a table")
	end

	local problems: { string } = {}
	local usable: { Rule } = {}
	for _, rule in ipairs(rules) do
		local found = Rules.validate(rule)
		if #found > 0 then
			for _, item in ipairs(found) do
				table.insert(problems, item)
			end
		else
			table.insert(usable, rule)
		end
	end

	local installed: Installed = {
		rules = #usable,
		connections = {},
		fired = {},
		refused = {},
		problems = problems,
		stop = function() end,
	}
	local spent: { [string]: boolean } = {}
	local running = true

	local function run(rule: Rule, context: { [string]: any })
		if not running then
			return
		end
		if rule.once and spent[rule.id] then
			return
		end
		for _, condition in ipairs(rule["require"] or {}) do
			local ok, held = pcall(holds, condition, context, bindings)
			if not ok or not held then
				installed.refused[rule.id] = (installed.refused[rule.id] or 0) + 1
				return
			end
		end
		if rule.once then
			spent[rule.id] = true
		end
		for _, effect in ipairs(rule["then"]) do
			-- Counted and warned, never raised. One bad rule must not take the
			-- script installing the others down with it.
			local ok, done = pcall(perform, effect, context, bindings)
			if not ok or not done then
				warn(string.format("[GameKit.Rules] %s: effect %q did not apply",
					rule.id, tostring(effect.kind)))
			end
		end
		installed.fired[rule.id] = (installed.fired[rule.id] or 0) + 1
	end

	local root = bindings.world or workspace

	for _, rule in ipairs(usable) do
		local when = rule.when
		local kind = tostring(when.kind)

		if kind == "prompt" or kind == "touch" then
			local wanted = tostring(when.target)
			for _, item in ipairs(root:GetDescendants()) do
				if kind == "prompt" and item:IsA("ProximityPrompt")
					and (item.Parent ~= nil and item.Parent.Name == wanted
						or item.Name == wanted) then
					table.insert(installed.connections, item.Triggered:Connect(function(player)
						run(rule, { player = player, at = item.Parent })
					end))
				elseif kind == "touch" and item:IsA("BasePart") and item.Name == wanted then
					table.insert(installed.connections, item.Touched:Connect(function(hit)
						local character = hit:FindFirstAncestorOfClass("Model")
						local player = character and Players:GetPlayerFromCharacter(character)
						if player ~= nil then
							run(rule, { player = player, at = item })
						end
					end))
				end
			end

		elseif kind == "timer" then
			local seconds = math.max(tonumber(when.seconds) or 1, 0.1)
			task.spawn(function()
				while running do
					task.wait(seconds)
					run(rule, {})
				end
			end)

		elseif kind == "join" then
			table.insert(installed.connections, Players.PlayerAdded:Connect(function(player)
				run(rule, { player = player })
			end))
			for _, player in ipairs(Players:GetPlayers()) do
				task.spawn(run, rule, { player = player })
			end

		elseif kind == "state" then
			local wanted = tostring(when.value)
			local function watch(player: Player)
				table.insert(installed.connections,
					player:GetAttributeChangedSignal("sessionState"):Connect(function()
						if tostring(player:GetAttribute("sessionState")) == wanted then
							run(rule, { player = player })
						end
					end))
			end
			for _, player in ipairs(Players:GetPlayers()) do
				watch(player)
			end
			table.insert(installed.connections, Players.PlayerAdded:Connect(watch))

		elseif kind == "wave" then
			local function watch(player: Player)
				table.insert(installed.connections,
					player:GetAttributeChangedSignal("wave"):Connect(function()
						run(rule, { player = player, index = player:GetAttribute("wave") })
					end))
			end
			for _, player in ipairs(Players:GetPlayers()) do
				watch(player)
			end
			table.insert(installed.connections, Players.PlayerAdded:Connect(watch))
		end
	end

	installed.stop = function()
		running = false
		for _, connection in ipairs(installed.connections) do
			connection:Disconnect()
		end
		table.clear(installed.connections)
	end

	return installed
end

return Rules
