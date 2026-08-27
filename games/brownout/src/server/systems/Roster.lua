--!strict
--[[
	Roster — the player list, and the first five minutes of a new player's life.

	Two things a game is not finished without, and both of them are about people
	who have never seen it before.

	**leaderstats.** Roblox's player list is the one piece of interface every
	player already knows how to read, and a game that leaves it empty is a game
	that looks unfinished in the first screenshot anybody takes of it. Watts and
	nights survived, nothing else: a leaderboard with eight columns is a
	spreadsheet.

	**Onboarding driven by what the player did, not by a timer.** A scripted
	sequence of tips fires while somebody is still reading the first one, or
	while they are dead, or while they are already doing the thing it is about
	to explain. Every step below waits for the event it is actually about — you
	are told what the dark does the first time you walk into it, and what to do
	with a cell the first time you are holding one.

	It runs once. `profile.taught` records which steps a player has seen, so a
	returning player is never explained their own game.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Debug = Forge.Debug
local Net = Forge.Net
local Save = Forge.Save

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Shift = require(script.Parent.Parent:WaitForChild("core"):WaitForChild("Shift"))
local Cells = require(script.Parent:WaitForChild("Cells"))

local Roster = {}

-- ============================== leaderstats =================================
local function buildStats(player: Player, profile: any)
	--: Rebuilt rather than reused. A player who rejoins the same server gets a
	--: fresh Player instance, and a leaderstats folder parented to the old one
	--: is a folder nobody can see.
	local existing = player:FindFirstChild("leaderstats")
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = "leaderstats"

	local watts = Instance.new("IntValue")
	watts.Name = "Watts"
	watts.Value = math.floor(profile.watts or 0)
	watts.Parent = folder

	local nights = Instance.new("IntValue")
	nights.Name = "Nights"
	nights.Value = math.floor(profile.nights or 0)
	nights.Parent = folder

	folder.Parent = player
	return folder
end

--[[
	Push the profile into the player list.

	Called after anything that changes a balance rather than on a timer. An
	IntValue write replicates on change, so a per-second refresh of an unchanged
	number is a packet a second per player for nothing.
]]
function Roster.refresh(player: Player)
	local profile = Save.get(player)
	if not profile then
		return
	end
	local folder = player:FindFirstChild("leaderstats")
	if not folder then
		folder = buildStats(player, profile)
	end
	local watts = folder:FindFirstChild("Watts") :: IntValue?
	local nights = folder:FindFirstChild("Nights") :: IntValue?
	if watts then
		watts.Value = math.floor(profile.watts or 0)
	end
	if nights then
		nights.Value = math.floor(profile.nights or 0)
	end
end

-- =============================== onboarding =================================
--[[
	The five things a new player has to be told, and the moment each is true.

	Order is the order they become relevant, not the order they were written.
	`when` is the event; `text` is what is said the first time it happens.
]]
local LESSONS: { { id: string, text: string, tone: string } } = {
	{ id = "arrive", tone = "warn",
	  text = "The generator is starving. Fuel is out past the lamps." },
	{ id = "dark", tone = "bad",
	  text = "You are outside the light. Exposure builds out here — the lantern only buys time." },
	{ id = "carry", tone = "good",
	  text = "Run it back to the generator. Carrying slows you, and bigger cells slow you more." },
	{ id = "delivered", tone = "good",
	  text = "That is the loop. Further rings pay more, and the run home is longer." },
	{ id = "spend", tone = "warn",
	  text = "Watts are yours to keep. Spend them at the outfitter — press B." },
}

local function lessonById(id: string): { id: string, text: string, tone: string }?
	for _, lesson in LESSONS do
		if lesson.id == id then
			return lesson
		end
	end
	return nil
end

--[[
	Teach one lesson, once ever, for this player.

	The record lives in the save profile rather than in memory, so a player who
	rejoins is not taught their own game again. A player whose profile has not
	loaded is not taught at all — better a missed tip than a tip that is
	repeated on every join because nothing could remember it.
]]
local function teach(player: Player, id: string)
	local profile = Save.get(player)
	if not profile then
		return
	end
	profile.taught = profile.taught or {}
	if profile.taught[id] then
		return
	end
	local lesson = lessonById(id)
	if not lesson then
		return
	end
	profile.taught[id] = true
	Net.fire(player, "Notify", { text = lesson.text, tone = lesson.tone })
	Debug.count("onboarding.taught")
end

Roster.teach = teach

--: Has this player been through a whole night before? Used to decide whether
--: they are new, rather than counting minutes played.
local function isVeteran(player: Player): boolean
	local profile = Save.get(player)
	return profile ~= nil and (tonumber(profile.delivered) or 0) > 0
end

-- ================================= wiring ===================================
function Roster.start()
	--: Every player gets a list entry the moment their profile exists, and the
	--: opening line if they have never delivered anything.
	Save.observe(function(player, profile)
		buildStats(player, profile)
		--: Deferred a beat: a Notify fired during the join handshake arrives
		--: before the client has built its toast queue and is simply lost.
		task.delay(2.5, function()
			if player.Parent and not isVeteran(player) then
				teach(player, "arrive")
			end
		end)
	end)

	--: A delivery moves watts, nights and two lessons at once.
	Shift.onDeposit:Connect(function(player)
		Roster.refresh(player)
		teach(player, "delivered")
		task.delay(6, function()
			if player.Parent then
				teach(player, "spend")
			end
		end)
	end)

	Shift.onPhase:Connect(function(phase)
		if phase ~= "dawn" then
			return
		end
		for _, player in Players:GetPlayers() do
			Roster.refresh(player)
		end
	end)

	--[[
		The two lessons that need watching rather than an event.

		Two seconds is deliberately slow. These fire once each per account and
		the cost of noticing a second late is nothing, where the cost of a
		per-frame scan of every player's position is paid for the whole session.
	]]
	task.spawn(function()
		while true do
			task.wait(2)
			for _, player in Players:GetPlayers() do
				if isVeteran(player) then
					continue
				end
				if Cells.heldBy(player) then
					teach(player, "carry")
				end
				local character = player.Character
				local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
				if root then
					local flat = (root.Position * Vector3.new(1, 0, 1)).Magnitude
					if flat > Shift.radius() then
						teach(player, "dark")
					end
				end
			end
		end
	end)

	Debug.probe("roster", function()
		local out = {}
		for _, player in Players:GetPlayers() do
			local profile = Save.get(player)
			out[player.Name] = profile and {
				watts = math.floor(profile.watts or 0),
				nights = profile.nights or 0,
				delivered = profile.delivered or 0,
			} or "loading"
		end
		return out
	end)
end

return Roster
