--!strict
--[[
	Rivals — the other houses are playing too.

	Vellum, Harth and Kest sell salt on their own shores while you do.
	Passing one is the race. Leading the board is what opens Kest's flat.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Net = Forge.Net
local Debug = Forge.Debug

local Lands = require(script.Parent:WaitForChild("Lands"))
local Ledger = require(script.Parent:WaitForChild("Ledger"))

local Rivals = {}

type House = { id: string, name: string, score: number, rate: number }

local houses: { House } = {
	{ id = "vellum", name = "Vellum", score = 36, rate = 4 },
	{ id = "harth", name = "Harth", score = 90, rate = 6 },
	{ id = "kest", name = "Kest", score = 160, rate = 5 },
}

local scores: { [Player]: number } = {}
local ahead: { [Player]: { [string]: boolean } } = {}

local function yourScore(player: Player): number
	return scores[player] or 0
end

local function standings(): { { id: string, name: string, score: number } }
	local rows = {}
	for _, house in houses do
		table.insert(rows, { id = house.id, name = house.name, score = house.score })
	end
	local players = Players:GetPlayers()
	if #players == 0 then
		table.insert(rows, { id = "you", name = "You", score = 0 })
	else
		for _, player in players do
			table.insert(rows, { id = "you:" .. player.Name, name = player.DisplayName, score = yourScore(player) })
		end
	end
	table.sort(rows, function(a, b)
		if a.score == b.score then
			return a.name < b.name
		end
		return a.score > b.score
	end)
	return rows
end

local function paint()
	Lands.paint(standings())
	for _, house in houses do
		Lands.house(house.id, string.format("%s  %d", string.upper(house.name), math.floor(house.score)))
	end
end

function Rivals.leading(player: Player): boolean
	local mine = yourScore(player)
	for _, house in houses do
		if house.score >= mine then
			return false
		end
	end
	return mine > 0
end

function Rivals.noteSale(player: Player, cash: number): string?
	if cash <= 0 then
		return nil
	end
	scores[player] = yourScore(player) + cash
	local known = ahead[player]
	if not known then
		known = {}
		ahead[player] = known
	end
	local passed: string? = nil
	for _, house in houses do
		if not known[house.id] and scores[player] > house.score then
			known[house.id] = true
			passed = house.name
		end
	end
	paint()
	return passed
end

function Rivals.start()
	Lands.onTake(function(player: Player)
		local profile = Ledger.get(player)
		if type(profile) == "table" and profile.holdingFlat == true then
			Net.fire(player, "Notify", { text = "The crystal flat is already yours." })
			return
		end
		if not Rivals.leading(player) then
			Net.fire(player, "Notify", { text = "Kest still leads. Sell more salt." })
			return
		end
		Ledger.mutate(player, function(clone)
			clone.holdingFlat = true
			clone.cash += 80
			return clone, { ok = true, reason = "", toast = "The crystal flat is yours." }
		end)
	end)

	local wait = 0
	RunService.Heartbeat:Connect(function(dt)
		wait += dt
		if wait < 2 then
			return
		end
		wait = 0
		for _, house in houses do
			house.score += house.rate
		end
		for _, player in Players:GetPlayers() do
			local mine = yourScore(player)
			local known = ahead[player]
			if known then
				for _, house in houses do
					if known[house.id] and house.score >= mine then
						known[house.id] = nil
						Net.fire(player, "Notify", { text = house.name .. " passed you." })
					end
				end
			end
		end
		paint()
	end)

	Players.PlayerRemoving:Connect(function(player)
		scores[player] = nil
		ahead[player] = nil
		paint()
	end)

	paint()
	Debug.probe("rivals", function()
		return { houses = standings() }
	end)
end

return Rivals
