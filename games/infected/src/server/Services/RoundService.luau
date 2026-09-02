--!strict
-- Drives the pure RoundMachine against real time/players and executes its effects.
-- All round state lives here on the server; clients only ever receive projections.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)
local RoundMachine = require(Shared.RoundMachine)

local RoundService = {}
RoundService.__index = RoundService

export type Deps = {
	remotes: any, -- Remotes.ServerApi
	-- Filled by later phases; optional so the core loop runs standalone in Phase 2.
	onRoundStart: ((playersInRound: { Player }) -> ())?,
	onRoundEnd: ((winner: string) -> ())?,
	onIntermission: (() -> ())?,
	-- Extra virtual participants (bots) added to the human count so rounds can start
	-- and reach the min-players threshold with a single human.
	getExtraCount: (() -> number)?,
}

function RoundService.new(deps: Deps)
	local self = setmetatable({}, RoundService)
	self._deps = deps
	self._machine = RoundMachine.new(GameConfig.Round :: any)
	self._playersInRound = {} :: { Player }
	return self
end

function RoundService:getState(): string
	return self._machine.state
end

function RoundService:getDeadline(): number?
	return self._machine.deadline
end

function RoundService:recordConversion()
	self:_execute(self._machine:recordConversion(os.clock()))
end

function RoundService:forceEnd(winner: string)
	self:_execute(self._machine:forceEnd(winner :: any, os.clock()))
end

function RoundService:setSurvivorCount(n: number)
	self:_execute(self._machine:setSurvivorCount(n, os.clock()))
end

function RoundService:_broadcastState()
	self._deps.remotes.fireAllClients("RoundState", {
		state = self._machine.state,
		deadline = self._machine.deadline,
		serverNow = os.clock(),
		playerCount = self._machine.playerCount,
		survivorCount = self._machine.survivorCount,
		conversions = self._machine.conversions,
	})
end

function RoundService:_execute(effects)
	for _, effect in effects do
		if effect.type == "StartRound" then
			self._playersInRound = Players:GetPlayers()
			if self._deps.onRoundStart then
				self._deps.onRoundStart(self._playersInRound)
			end
		elseif effect.type == "EndRound" then
			if self._deps.onRoundEnd then
				self._deps.onRoundEnd(effect.winner)
			end
		elseif effect.type == "StartIntermission" then
			if self._deps.onIntermission then
				self._deps.onIntermission()
			end
		end
	end
	if #effects > 0 then
		self:_broadcastState()
	end
end

function RoundService:_totalCount(): number
	local extra = self._deps.getExtraCount and self._deps.getExtraCount() or 0
	return #Players:GetPlayers() + extra
end

function RoundService:start()
	local function syncPlayerCount()
		self:_execute(self._machine:setPlayerCount(self:_totalCount(), os.clock()))
		self:_broadcastState()
	end
	Players.PlayerAdded:Connect(syncPlayerCount)
	Players.PlayerRemoving:Connect(function(leaving)
		-- Run after the player is actually gone from GetPlayers()
		task.defer(function()
			self:_execute(self._machine:setPlayerCount(self:_totalCount(), os.clock()))
			self:_broadcastState()
		end)
		local _ = leaving
	end)
	syncPlayerCount()

	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator < 0.25 then -- 4 Hz is plenty for a seconds-resolution timer
			return
		end
		accumulator = 0
		self:_execute(self._machine:tick(os.clock()))
	end)
end

return RoundService
