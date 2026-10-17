--!strict
--[[
	NpcService — the harbor's living half: models, prompts, conversations.

	The server owns every word. It builds a fresh dialogue tree from the
	player's actual save when a conversation opens, offers only the choices
	whose conditions pass, re-indexes what the client taps against what was
	shown (Forge.Dialogue does that part -- a raw definition index cannot
	reach a hidden branch), and runs the consequence itself. The client
	renders payloads and sends an index; that is the entire contract.

	Proximity is enforced twice: the prompt only fires within reach, and
	every answer re-checks that the character is still standing near the
	NPC it claims to be talking to. A client that walks away mid-sentence
	is either lagging or lying, and both get the same answer.

	First meetings persist in `profile.tutorial.seen["npc.<id>"]` -- the
	generic flag bag the save already has. NPCs borrow it rather than
	widening the profile schema for chatter; the keys are namespaced so
	they cannot collide with tutorial steps.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Mark = Forge.Mark

local Dialogue = Forge.Dialogue
local Interaction = Forge.Interaction
local Net = Forge.Net
local Debug = Forge.Debug

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local NpcData = require(Shared.NpcData)

local DataService = require(script.Parent.DataService)
local WorldService = require(script.Parent.WorldService)
local BuildKit = require(script.Parent.Parent.Lib.BuildKit)

local NpcService = {}

local TALK_RANGE = 14
--: How far a player may drift between opening a conversation and answering
--: it. Wide enough for a lag spike, narrow enough that shouting across the
--: harbor does not work.
local TALK_SLACK = 6

local started = false
local byId: { [string]: any } = {}
local placed: { any } = {}

local function subjectOf(player: Player): string
	return "player:" .. tostring(player.UserId)
end

-- ================================ context ===================================
--: The numbers a line is allowed to read. Assembled once per conversation
--: from the profile -- the tree is built from this and conditions close
--: over it, so no dialogue code ever touches the save directly.
local function contextFor(profile: any): any
	local quests = profile.quests.list or {}
	local done, claimable = 0, 0
	for _, quest in quests do
		if (quest.progress or 0) >= math.max(quest.target or 1, 1) then
			done += 1
			if not quest.claimed then
				claimable += 1
			end
		end
	end
	return {
		level = Config.levelForXp(profile.xp or 0),
		coins = profile.coins or 0,
		streak = profile.quests.streak or 0,
		quests = #quests,
		questsDone = done,
		claimable = claimable,
		species = (profile.stats and profile.stats.species) or 0,
		zones = profile.zones or {},
		met = (profile.tutorial and profile.tutorial.seen) or {},
	}
end

-- ================================ conversations =============================
local function openDialogue(player: Player, entry: any)
	local profile = DataService.profile(player)
	if not profile then
		return
	end
	local context = contextFor(profile)
	local tree = NpcData.voice(entry.def.id, context)
	if not tree then
		return
	end

	--: Built per player, per talk: the words interpolate the live save
	--: (coins, streak, claims), so a tree defined once at boot would greet
	--: everyone as the person they were at sunrise.
	local treeId = string.format("npc.%s.%d", entry.def.id, player.UserId)
	Dialogue.define(treeId, tree)
	--: The same context is the session's, so a condition reads the numbers
	--: the greeting was written against.
	local payload = Dialogue.begin(subjectOf(player), treeId, context)
	if not payload then
		return
	end

	Net.fire(player, "DialogueOpen", {
		npc = entry.def.id,
		name = entry.def.name,
		title = entry.def.title,
		text = payload.text,
		choices = payload.choices,
	})

	local flag = "npc." .. entry.def.id
	local seen = profile.tutorial and profile.tutorial.seen
	if seen and not seen[flag] then
		seen[flag] = true
		DataService.push(player)
	end
end

--: Is the player where they say they are? The prompt enforces closeness at
--: open; this enforces it at every answer.
local function stillNear(player: Player, entry: any): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local anchor = entry.model and entry.model.PrimaryPart
	if not (root and root:IsA("BasePart") and anchor) then
		return false
	end
	return (root.Position - anchor.Position).Magnitude <= TALK_RANGE + TALK_SLACK
end

-- ================================= placement ================================
local function facingFor(def: any, at: Vector3): Vector3
	local zone = Config.zone(def.zone) or Config.zone("shallows")
	local seaward = if def.zone == "shallows"
		then Vector3.new(0, 0, 1)
		else Vector3.new(zone.center.X - at.X, 0, zone.center.Y - at.Z)
	if seaward.Magnitude < 0.5 then
		seaward = Vector3.new(0, 0, 1)
	end
	seaward = seaward.Unit
	return if def.facing == "sea" then seaward else -seaward
end

local function buildNpc(def: any, parent: Instance): Model?
	local base = WorldService.dock(def.zone)
	local desired = base + Vector3.new(def.offset.X, 0, def.offset.Y)
	local at = WorldService.groundSpot(desired, base)
	local model = BuildKit.npc(def, at, facingFor(def, at), parent)
	--: NPCs are gameplay, not scenery: out of the visual audit's denominator.
	if model then
		Mark.exclude(model)
	end
	Interaction.register(model, {
		id = def.id,
		label = def.label or "Talk",
		objectLabel = def.name,
		key = (Enum.KeyCode :: any)[def.key],
		range = TALK_RANGE,
		onTrigger = function(player: Player)
			openDialogue(player, { def = def, model = model })
		end,
	})
	return model
end

-- ================================ lifecycle =================================
local function registerActions()
	Dialogue.action("openShop", function(): string
		return "shop"
	end)
	Dialogue.action("openQuests", function(): string
		return "quests"
	end)
	Dialogue.action("openMap", function(): string
		return "map"
	end)
	Dialogue.action("openRanks", function(): string
		return "ranks"
	end)
	Dialogue.action("openBestiary", function(): string
		return "bestiary"
	end)
end

function NpcService.start()
	if started then
		return
	end
	started = true

	registerActions()

	local root = Workspace:FindFirstChild("Tidebound")
	if not root then
		root = Instance.new("Folder")
		root.Name = "Tidebound"
		root.Parent = Workspace
	end
	local folder = Instance.new("Folder")
	folder.Name = "Npcs"
	folder.Parent = root

	for _, def in NpcData.roster do
		local model = buildNpc(def, folder)
		if model then
			local entry = { def = def, model = model }
			byId[def.id] = entry
			table.insert(placed, entry)
		end
	end

	Net.on("DialogueChoose", function(player: Player, payload: any)
		local entry = byId[payload.npc]
		if not entry or not stillNear(player, entry) then
			return
		end
		local result = Dialogue.choose(subjectOf(player), payload.index)
		if result == nil then
			Net.fire(player, "DialogueClose", { npc = entry.def.id })
		elseif result.actionResult ~= nil then
			--: A door, not a reply: end the conversation before the panel
			--: opens, or a session would hang behind it forever.
			Dialogue.finish(subjectOf(player))
			Net.fire(player, "DialogueAction", {
				npc = entry.def.id,
				action = result.action,
				to = tostring(result.actionResult),
			})
		else
			Net.fire(player, "DialogueNode", {
				npc = entry.def.id,
				text = result.text,
				choices = result.choices,
			})
		end
	end)

	Net.on("DialogueLeave", function(player: Player, payload: any)
		if byId[payload.npc] then
			Dialogue.finish(subjectOf(player))
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		Dialogue.finish(subjectOf(player))
	end)

	--: The idle sway: each villager drifts around their rest pose on their
	--: own phase, so a row of them reads as eight people and not one clone.
	local clock = 0
	RunService.Heartbeat:Connect(function(delta: number)
		clock += delta
		for index, entry in placed do
			local rest = entry.model:GetAttribute("RestPivot")
			if rest then
				local bob = math.sin(clock * 1.6 + index * 1.7) * 0.08
				local sway = math.sin(clock * 0.55 + index * 2.3) * 0.06
				entry.model:PivotTo((rest :: CFrame) * CFrame.new(0, bob, 0) * CFrame.Angles(0, sway, 0))
			end
		end
	end)

	Debug.count("npcs.placed", #placed)
	Debug.info(string.format("npcs placed: %d", #placed))
end

return NpcService
