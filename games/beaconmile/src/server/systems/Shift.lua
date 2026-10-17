--!strict
-- Advance every shift Ledger is holding. Sim mutates that profile in place;
-- a copy would burn beacons the save and the other systems never see.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Sim = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sim"))
local Ledger = require(script.Parent.Ledger)

local Shift = {}

-- One stalled frame must not be applied whole. Sim burns every beacon by dt
-- and then decides the shift, so an uncapped hitch ends it in a single step.
-- Time past this ceiling is dropped, not replayed as further steps.
local MAX_STEP = 0.25

-- After the shift ends, one sync is enough for the HUD. Further heartbeats
-- would resend the same packet for the rest of the session.
local closed: { [Player]: boolean } = {}

function Shift.start()
	RunService.Heartbeat:Connect(function(dt: number)
		if dt > MAX_STEP then
			dt = MAX_STEP
		end
		local seen: { [Player]: boolean } = {}
		for player, profile in Ledger.each() do
			seen[player] = true
			if profile.outcome == "running" then
				closed[player] = nil
			elseif closed[player] then
				continue
			else
				Ledger.sync(player)
				closed[player] = true
				continue
			end
			Sim.tick(profile, dt)
			Ledger.sync(player)
			if profile.outcome ~= "running" then
				closed[player] = true
			end
		end
		for player in closed do
			if not seen[player] then
				closed[player] = nil
			end
		end
	end)
end

return Shift
