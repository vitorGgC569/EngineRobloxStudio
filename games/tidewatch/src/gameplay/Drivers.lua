--!strict
-- Drivers: what happens without the player asking.
--
-- One driver per system. The systems differ per game because the composer
-- resolves them from the IR, so this file differs per game without any
-- genre ever being named in it.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Drivers = {}

--- Session state, which every genre has and no genre owns.
---
--- start -> pressure -> resolution -> reward -> repeat. Win and loss are
--- states of this machine rather than rules of any one game.
local session = {
	state = "PREPARING",
	round = 0,
	elapsed = 0,
	integrity = 100,
}
Drivers.session = session

local listeners: { (string, { [string]: any }) -> () } = {}

--- Announce a state change once, in one place.
---
--- Every driver reports through here so the HUD, the VFX and the analytics
--- see the same event. Three subsystems each deciding when a wave started
--- is how they disagree about which wave it is.
function Drivers.emit(event: string, detail: { [string]: any }?)
	local payload = detail or {}
	-- Published as player attributes, which is what the HUD reads. An
	-- event nothing writes down is an event the interface cannot show,
	-- and a HUD polling the session would eventually disagree with it
	-- about which wave it is.
	for _, who in ipairs(Players:GetPlayers()) do
		who:SetAttribute("sessionState", session.state)
		who:SetAttribute("wave", session.round)
		who:SetAttribute("integrity", session.integrity)
	end
	for _, listener in ipairs(listeners) do
		task.spawn(listener, event, payload)
	end
end

function Drivers.on(listener: (string, { [string]: any }) -> ())
	table.insert(listeners, listener)
end

function Drivers.start(Gameplay)
	local systems = Gameplay.systems()

	-- Production. The clock that makes every cost reachable, and the reason
	-- a player has anything to decide between two prompts.
	local accrued = 0
	RunService.Heartbeat:Connect(function(delta: number)
		if session.state ~= "ACTIVE" then
			return
		end
		accrued += delta
		if accrued < 1 then
			return
		end
		accrued -= 1
		for _, player in ipairs(Players:GetPlayers()) do
			-- Scaled by the tier the player has reached, so progression is
			-- felt as speed rather than read as a number.
			local multiplier = 1
			if systems.progression ~= nil then
				local tierId = player:GetAttribute("tierId")
				multiplier = systems.progression:multiplierAt(tierId)
			end
			local balance = systems.economy:grant(player, "cash",
				Gameplay.incomePerSecond * multiplier, "production")
			player:SetAttribute("cash", balance)
		end
	end)

	-- Advancement. A ladder nothing climbs is a table of numbers; this is
	-- what turns a balance into a sense of getting somewhere.
	RunService.Heartbeat:Connect(function()
		if session.state ~= "ACTIVE" or systems.economy == nil then
			return
		end
		for _, player in ipairs(Players:GetPlayers()) do
			local current = player:GetAttribute("tierId")
			local next = systems.progression:nextAfter(current)
			if next ~= nil then
				player:SetAttribute("nextCost", next.cost)
				player:SetAttribute("nextTier", next.displayName)
				local balance = systems.economy:balance(player, "cash")
				if balance >= next.cost then
					local paid = systems.economy:spend(player, "cash",
						next.cost, "tier:" .. next.id)
					if paid then
						player:SetAttribute("tierId", next.id)
						player:SetAttribute("cash",
							systems.economy:balance(player, "cash"))
						Drivers.emit("tier", { player = player, tier = next.displayName })
					end
				end
			end
		end
	end)

	-- The session opens once somebody is here to play it. Starting on an
	-- empty server burns rounds nobody sees and greets the first arrival
	-- mid-defeat.
	Players.PlayerAdded:Connect(function(player: Player)
		player:SetAttribute("tierId", nil)
		if session.state == "PREPARING" then
			task.wait(Gameplay.prepareSeconds)
			session.state = "ACTIVE"
			Drivers.emit("session", { state = session.state })
		end
	end)

	RunService.Heartbeat:Connect(function(delta: number)
		if session.state == "ACTIVE" then
			session.elapsed += delta
		end
	end)

	return session
end

return Drivers
