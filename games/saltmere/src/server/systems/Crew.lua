--!strict
--[[
	Crew — hire a raker, grader or watch, and point a raker at a pan.

	The flood wage and the harvest rake are Sim.onPhase. This file only
	accepts Hire and AssignCrew and lets Sim accept or refuse them.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Net = Forge.Net
local Debug = Forge.Debug

local Sim = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sim"))
local Ledger = require(script.Parent:WaitForChild("Ledger"))

local Crew = {}

local function crewCounts(): { [string]: any }
	if type(Ledger.each) ~= "function" then
		return { listening = true }
	end

	local hired = 0
	local players = 0
	local byRole: { [string]: number } = {}
	local seen: { [Player]: boolean } = {}

	local ok = pcall(function()
		for player, profile in Ledger.each() do
			if typeof(player) ~= "Instance" or not player:IsA("Player") or seen[player] then
				error("iterator")
			end
			seen[player] = true
			players += 1
			if players > 32 then
				error("iterator")
			end

			local crew = if type(profile) == "table" then profile.crew else nil
			if type(crew) ~= "table" then
				continue
			end
			for _, member in ipairs(crew) do
				hired += 1
				if type(member) == "table" and type(member.role) == "string" then
					byRole[member.role] = (byRole[member.role] or 0) + 1
				end
			end
		end
	end)

	if not ok then
		return { listening = true }
	end
	return {
		players = players,
		hired = hired,
		byRole = byRole,
	}
end

function Crew.start()
	Net.on("Hire", function(player: Player, payload: { roleId: string })
		Ledger.mutate(player, function(clone)
			return Sim.hire(clone, payload.roleId)
		end)
	end)

	Net.on("AssignCrew", function(player: Player, payload: { crewId: string, panId: string })
		Ledger.mutate(player, function(clone)
			return Sim.assign(clone, payload.crewId, payload.panId)
		end)
	end)

	Debug.probe("crew", crewCounts)
end

return Crew
