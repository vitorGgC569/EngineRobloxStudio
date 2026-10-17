--!strict
--[[
	Works — brine in, salt out.

	Collect and claim are intents. Sim accepts or refuses them, and the only
	client field that reaches Sim is the pan id. Heartbeat carries the tide
	into Sim.integrate. Ledger copies a profile back only when that changes
	brine or ready, so a full pan or a quiet phase does not StateSync. Pan
	colour asks Sim.capacity, the same expression the fill uses.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Net = Forge.Net
local Debug = Forge.Debug

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Sim = require(Shared:WaitForChild("Sim"))

local Ledger = require(script.Parent.Ledger)
local Marsh = require(script.Parent.Marsh)

local Works = {}

-- One step, a few times a second. Fill spends the real dt; StateSync and the
-- pan colour do not run at the frame rate.
local STEP = 0.25

type PanSnap = { brine: number, ready: boolean }

local function capacityOf(profile: any, pan: any): number
	-- Same expression Sim uses. Prefer the export; otherwise read Config.
	local ask = (Sim :: any).capacity
	if type(ask) == "function" then
		local value = ask(profile, pan)
		if type(value) == "number" then
			return value
		end
	end
	local level = if type(pan) == "table" and type(pan.level) == "number" then pan.level else 1
	local upgrades = if type(profile) == "table" then profile.upgrades else nil
	local cistern = 0
	if type(upgrades) == "table" then
		local stored = (upgrades :: { [string]: any }).cistern
		if type(stored) == "number" then
			cistern = stored
		end
	end
	local production = Config.production
	return production.capacityBase
		+ (level - 1) * production.capacityPerLevel
		+ cistern * Config.effects.cisternCapacity
end

local function snapPans(profile: any): { [string]: PanSnap }
	local out: { [string]: PanSnap } = {}
	local pans = if type(profile) == "table" then profile.pans else nil
	if type(pans) ~= "table" then
		return out
	end
	for id, pan in pans :: { [string]: any } do
		if type(pan) == "table" then
			local brine = pan.brine
			out[id] = {
				brine = if type(brine) == "number" then brine else 0,
				ready = pan.ready == true,
			}
		end
	end
	return out
end

local function pansChanged(before: { [string]: PanSnap }, after: { [string]: PanSnap }): boolean
	for id, pan in before do
		local other = after[id]
		if other == nil or other.brine ~= pan.brine or other.ready ~= pan.ready then
			return true
		end
	end
	for id in after do
		if before[id] == nil then
			return true
		end
	end
	return false
end

-- Preview on a clone. The live save is written only by Ledger.mutate.
local function fillWouldChange(profile: any, dt: number, phase: string): boolean
	if type(profile) ~= "table" or dt <= 0 then
		return false
	end
	local before = snapPans(profile)
	local cloned = Sim.clone(profile)
	if type(cloned) ~= "table" or cloned == profile then
		return true
	end
	local preview = Sim.integrate(cloned, dt, phase)
	if type(preview) ~= "table" then
		return true
	end
	return pansChanged(before, snapPans(preview))
end

local function refreshPlayer(player: Player)
	local profile = Ledger.get(player)
	if type(profile) ~= "table" or type(profile.pans) ~= "table" then
		return
	end
	for panId, pan in profile.pans :: { [string]: any } do
		if type(pan) == "table" then
			local brine = pan.brine
			Marsh.setPanVisual(
				player,
				panId,
				if type(brine) == "number" then brine else 0,
				capacityOf(profile, pan),
				pan.ready == true
			)
		end
	end
end

local function refreshPan(player: Player, panId: string)
	local profile = Ledger.get(player)
	if type(profile) ~= "table" or type(profile.pans) ~= "table" then
		return
	end
	local pan = (profile.pans :: { [string]: any })[panId]
	if type(pan) ~= "table" then
		return
	end
	local brine = pan.brine
	Marsh.setPanVisual(
		player,
		panId,
		if type(brine) == "number" then brine else 0,
		capacityOf(profile, pan),
		pan.ready == true
	)
end

local function refreshAll()
	for player in Ledger.each() do
		if typeof(player) == "Instance" and player:IsA("Player") then
			refreshPlayer(player)
		end
	end
end

local function integratePlayer(player: Player, profile: any, dt: number, phase: string)
	if not fillWouldChange(profile, dt, phase) then
		return
	end
	Ledger.mutate(player, function(clone)
		return Sim.integrate(clone, dt, phase)
	end)
end

local function collect(player: Player, panId: string)
	Ledger.mutate(player, function(clone)
		return Sim.collect(clone, panId, Marsh.phase())
	end)
	refreshPan(player, panId)
end

local function claim(player: Player, panId: string)
	Ledger.mutate(player, function(clone)
		return Sim.claim(clone, panId)
	end)
	refreshPan(player, panId)
end

function Works.start()
	local pending = 0
	local accounted = Marsh.phase()

	local function pump(dt: number, phase: string)
		for player, profile in Ledger.each() do
			if typeof(player) == "Instance" and player:IsA("Player") then
				integratePlayer(player, profile, dt, phase)
			end
		end
	end

	local function flush(phase: string)
		if pending <= 0 then
			return
		end
		local step = pending
		pending = 0
		pump(step, phase)
	end

	Marsh.onCollect(function(player: Player, panId: string)
		collect(player, panId)
	end)

	Marsh.onClaim(function(player: Player, panId: string)
		claim(player, panId)
	end)

	Net.on("CollectPan", function(player: Player, payload: { panId: string })
		collect(player, payload.panId)
	end)

	Net.on("ClaimPan", function(player: Player, payload: { panId: string })
		claim(player, payload.panId)
	end)

	Marsh.onPhase(function(phase: string, _index: number)
		-- Seconds still in the previous phase have to fill as that phase.
		-- integrate adds brine only during flood.
		if accounted ~= phase then
			flush(accounted)
		end
		accounted = phase
		for player, _profile in Ledger.each() do
			if typeof(player) ~= "Instance" or not player:IsA("Player") then
				continue
			end
			Ledger.mutate(player, function(clone)
				return Sim.onPhase(clone, phase)
			end)
		end
		refreshAll()
	end)

	RunService.Heartbeat:Connect(function(dt: number)
		pending += dt
		local phase = Marsh.phase()
		if phase ~= accounted then
			flush(accounted)
			accounted = phase
			refreshAll()
			return
		end
		if pending < STEP then
			return
		end
		flush(phase)
		refreshAll()
	end)

	Debug.probe("works", function()
		return {
			phase = Marsh.phase(),
		}
	end)

	refreshAll()
end

return Works
