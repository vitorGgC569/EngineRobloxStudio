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

	local function feedback(event: string, detail: { [string]: any }?)
		if event == "tier" then
			local player = detail and detail.player
			if player ~= nil then systems.feedback:emit(player, "upgrade",
				{ itemName = tostring(detail.tier or "Tier") }) end
		elseif event == "wave" then
			systems.feedback:broadcast("wave", { round = session.round })
		elseif event == "wave_cleared" then
			systems.feedback:broadcast("reward", {})
		elseif event == "leak" then
			systems.feedback:broadcast("damage", { amount = 25 })
		elseif event == "victory" or event == "defeat" then
			systems.feedback:broadcast(event, { round = session.round })
		end
	end
	Drivers.on(feedback)

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
			-- Preserve the tutorial's earned currency until its promised
			-- purchase commits. Automatic tier spending used to consume the
			-- reward between the reliquary and the highlighted foundation.
			if systems.onboarding ~= nil
				and player:GetAttribute("RQEOnboardingComplete") ~= true then
				continue
			end
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

	-- Pressure. The waves the Tower module already validated, arriving.
	-- Simulated rather than re-implemented: `Tower.simulate` decides whether
	-- the defence holds, so the number a player sees is the number the
	-- balance check used.
	task.spawn(function()
		while true do
			if session.state == "ACTIVE" then
				session.round += 1
				Drivers.emit("wave", { round = session.round })
				task.wait(Gameplay.waveSeconds)

				local held = true
				for _, player in ipairs(Players:GetPlayers()) do
					local report = systems.tower.forecast(player, Gameplay.pathLength)
					local wave = report.waves[math.min(session.round, #report.waves)]
					if wave ~= nil and not wave.clearable then
						held = false
					elseif wave ~= nil and systems.economy ~= nil then
						local balance = systems.economy:grant(player, "cash",
							wave.bounty, "wave")
						player:SetAttribute("cash", balance)
					end
				end

				if held then
					Drivers.emit("wave_cleared", { round = session.round })
				else
					-- Damage to what the player is defending, which is the only
					-- thing that makes losing possible and therefore winning mean
					-- anything.
					session.integrity -= 25
					Drivers.emit("leak", { integrity = session.integrity })
					if session.integrity <= 0 then
						session.state = "DEFEAT"
						Drivers.emit("defeat", { round = session.round })
					end
				end

				if session.round >= Gameplay.roundsToWin and session.state == "ACTIVE" then
					session.state = "VICTORY"
					Drivers.emit("victory", { round = session.round })
				end
			else
				task.wait(0.5)
			end
		end
	end)

	-- The session opens once somebody is here to play it. Starting on an
	-- empty server burns rounds nobody sees and greets the first arrival
	-- mid-defeat.
	local joined: { [number]: boolean } = {}
	local function onPlayer(player: Player)
		if joined[player.UserId] then return end
		joined[player.UserId] = true
		player:SetAttribute("tierId", nil)
		if systems.onboarding ~= nil then systems.onboarding.start(player) end
		if session.state == "PREPARING" then
			task.spawn(function()
				task.wait(Gameplay.prepareSeconds)
				if session.state == "PREPARING" then
					session.state = "ACTIVE"
					Drivers.emit("session", { state = session.state })
				end
			end)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in ipairs(Players:GetPlayers()) do onPlayer(player) end

	RunService.Heartbeat:Connect(function(delta: number)
		if session.state == "ACTIVE" then
			session.elapsed += delta
		end
	end)

	return session
end

return Drivers
