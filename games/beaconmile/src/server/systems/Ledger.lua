--!strict
--[[
	Ledger — the live save table and the only writer of StateSync.

	Sim edits a copy. On success those fields are copied onto the table Save
	is already holding, which is what a later autosave persists. A load that
	does not come back is not a new profile: Save has no way to adopt a table
	it did not load, and a second table would play a shift that never flushes.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Net = Forge.Net
local Save = Forge.Save

local Sim = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sim"))

local Ledger = {}

local profiles: { [Player]: any } = {}

-- The draft is a different table. Save is watching `live`, so the fields have
-- to move onto it. Replacing the table would leave Save flushing the old one.
local function writeBack(live: any, draft: any)
	live.version = draft.version
	live.carried = draft.carried
	live.elapsed = draft.elapsed
	live.outcome = draft.outcome
	live.beacons = draft.beacons
end

function Ledger.get(player: Player): any?
	return profiles[player]
end

function Ledger.each(): any
	return pairs(profiles)
end

function Ledger.sync(player: Player)
	local profile = profiles[player]
	if not profile then
		return
	end
	local snap = Sim.clone(profile)
	Net.fire(player, "StateSync", {
		carried = snap.carried,
		beacons = snap.beacons,
		elapsed = snap.elapsed,
		outcome = snap.outcome,
	})
end

function Ledger.mutate(player: Player, reducer: (any) -> (boolean, string?)): (boolean, string?)
	local profile = profiles[player]
	if not profile then
		return false, "bad_id"
	end
	local draft = Sim.clone(profile)
	local ok, reason = reducer(draft)
	if ok ~= true then
		return false, reason
	end
	writeBack(profile, draft)
	Ledger.sync(player)
	return true, nil
end

function Ledger.start()
	-- observe replays a profile Save already loaded and hears the ones that
	-- finish after this connects. Await-plus-a-fresh-table used to split the
	-- game from the record the autosave flushes when the wait timed out.
	Save.observe(function(player, profile)
		if profiles[player] or type(profile) ~= "table" then
			return
		end
		profiles[player] = profile
		if profile.outcome ~= "running" then
			Sim.restart(profile)
		end
		Ledger.sync(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		profiles[player] = nil
	end)
end

return Ledger
