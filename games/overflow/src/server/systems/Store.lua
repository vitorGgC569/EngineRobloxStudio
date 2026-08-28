--!strict
--[[
	Store — the four upgrades, the player list, and the only place a balance
	goes down.

	It is worth a module rather than four lines inside `Play` for exactly that
	reason: a balance that can be decremented from two files is a balance that
	will eventually go negative in production and nowhere else.

	The client sends an id. The server looks up what that id costs, checks the
	profile it holds, deducts, writes through, and answers. No quantity in the
	packet, no price in the packet, no confirm step a client could skip.
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

local Store = {}

local function specFor(id: string): any?
	for _, spec in Config.upgrades do
		if spec.id == id then
			return spec
		end
	end
	return nil
end

-- ============================== player list =================================
--[[
	Coins and best score in Roblox's own player list.

	It is the one piece of interface every player already knows how to read, and
	a game that leaves it empty looks unfinished in the first screenshot anybody
	takes of it. Two columns, not eight: a leaderboard with eight columns is a
	spreadsheet.
]]
local function buildStats(player: Player, profile: any)
	local existing = player:FindFirstChild("leaderstats")
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "leaderstats"

	local coins = Instance.new("IntValue")
	coins.Name = "Coins"
	coins.Value = math.floor(profile.coins or 0)
	coins.Parent = folder

	local best = Instance.new("IntValue")
	best.Name = "Best"
	best.Value = math.floor(profile.bestScore or 0)
	best.Parent = folder

	folder.Parent = player
	return folder
end

function Store.refresh(player: Player)
	local profile = Save.get(player)
	if not profile then
		return
	end
	local folder = player:FindFirstChild("leaderstats") or buildStats(player, profile)
	local coins = folder:FindFirstChild("Coins") :: IntValue?
	local best = folder:FindFirstChild("Best") :: IntValue?
	if coins then
		coins.Value = math.floor(profile.coins or 0)
	end
	if best then
		best.Value = math.floor(profile.bestScore or 0)
	end
end

-- ================================= buying ===================================
--[[
	Buy one level, or say why not.

	Exported so the live suite runs the same path the packet does. Returns
	`(ok, message)`; the message is what the player is told either way, so no
	caller has to compose one.
]]
function Store.buyFor(player: Player, id: any): (boolean, string)
	local spec = specFor(id)
	if not spec then
		Debug.warn(string.format("%s asked for unknown upgrade '%s'", player.Name, tostring(id)))
		return false, "No such upgrade."
	end

	local profile = Save.get(player)
	if not profile then
		return false, "Profile still loading."
	end

	profile.upgrades = profile.upgrades or {}
	local level = tonumber(profile.upgrades[spec.id]) or 0

	local cost = Shift.upgradeCost(spec, level)
	if not cost then
		return false, spec.label .. " is maxed."
	end

	local coins = tonumber(profile.coins) or 0
	if coins < cost then
		return false, string.format("Need %d more.", math.ceil(cost - coins))
	end

	profile.coins = coins - cost
	profile.upgrades[spec.id] = level + 1

	--[[
		Written through immediately rather than left to the autosave.

		An upgrade is the one thing here a player would be genuinely angry to
		lose, and the window between "spent the coins" and "the autosave ran" is
		a real two minutes in which a server can restart.
	]]
	Save.write(player)
	Store.refresh(player)

	Debug.info(string.format("%s bought %s L%d for %d", player.Name, spec.id, level + 1, cost))
	return true, string.format("%s → level %d", spec.label, level + 1)
end

function Store.start()
	Net.on("Buy", function(player, payload)
		local ok, message = Store.buyFor(player, payload.id)
		Net.fire(player, "Notify", { text = message, tone = if ok then "good" else "warn" })
		if ok then
			Net.fire(player, "You", Shift.crewSnapshot(player))
		end
	end)

	--: Every player gets a list entry and real numbers in the HUD the moment
	--: their profile exists, rather than after their first sort.
	Save.observe(function(player, profile)
		buildStats(player, profile)
		Net.fire(player, "You", Shift.crewSnapshot(player))

		--[[
			One line, once, for somebody who has never worked a shift.

			The prompt along the bottom already says which key to press. What it
			cannot say without becoming a paragraph is *why the strip at the top
			matters* — and the strip is the whole game, because being at the
			right lever is only possible if you read what is coming. A player who
			treats it as decoration is playing a reaction game with no reactions
			available.

			Recorded against `shifts`, so a returning operator is never told
			their own job. Delayed, because a toast fired during the join
			handshake arrives before the client has built its queue and is lost.
		]]
		if (tonumber(profile.shifts) or 0) > 0 then
			return
		end
		task.delay(3, function()
			if not player.Parent then
				return
			end
			Net.fire(player, "Notify", {
				text = "The strip up top is the next four crates. Be at that lever before it arrives.",
				tone = "warn",
			})
		end)
	end)

	--: The crew's coins move on every correct sort, and the list holds coins.
	Shift.onResolved:Connect(function(_kind, _chute, correct)
		if not correct then
			return
		end
		for _, player in Players:GetPlayers() do
			Store.refresh(player)
			Net.fire(player, "You", Shift.crewSnapshot(player))
		end
	end)

	Debug.probe("store", function()
		local out = {}
		for _, player in Players:GetPlayers() do
			local profile = Save.get(player)
			out[player.Name] = profile and {
				coins = math.floor(profile.coins or 0),
				best = profile.bestScore or 0,
				shifts = profile.shifts or 0,
			} or "loading"
		end
		return out
	end)
end

return Store
