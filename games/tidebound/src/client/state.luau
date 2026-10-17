--!strict
--[[
	state — the client's copy of the save, and a signal for when it moves.

	There is exactly one writer: the ProfileSync handler. Everything else
	subscribes. That is deliberate -- a UI that keeps its own coins number
	drifts from the server within minutes, and the player sees a number that
	was true once.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Signal = Forge.Core.Signal

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Items = require(Shared.Items)

local state = {}

state.profile = nil
state.changed = Signal.new()

function state.apply(profile: any)
	--[[
		Restore the shape empty tables lose on the wire.

		A fresh save's `tutorial` is `{ seen = {} }`, and the replica decodes
		empty tables as nil -- so `profile.tutorial` arrived nil, and the
		first cast died on `profile.tutorial.seen.cast`.  A crash because
		nothing was learned yet.  The profile enters here once; every reader
		downstream keeps the plain chain.
	]]
	if profile then
		profile.tutorial = profile.tutorial or {}
		profile.tutorial.seen = profile.tutorial.seen or {}
	end
	state.profile = profile
	state.changed:Fire(profile)
end

function state.get(): any?
	return state.profile
end

--: Everything below reads the cached profile. Nil-safe by returning neutral
--: values, because "the UI drew while the save was loading" is not an error.

function state.coins(): number
	local profile = state.profile
	return profile and profile.coins or 0
end

function state.level(): number
	local profile = state.profile
	if not profile then
		return 1
	end
	return Config.levelForXp(profile.xp or 0)
end

function state.xpAlpha(): number
	local profile = state.profile
	if not profile then
		return 0
	end
	local level = state.level()
	local floor = Config.xpForLevel(level)
	local ceil = Config.xpForLevel(math.min(level + 1, Config.maxLevel))
	if ceil <= floor then
		return 1
	end
	return math.clamp(((profile.xp or 0) - floor) / (ceil - floor), 0, 1)
end

function state.rod(): any?
	local profile = state.profile
	return profile and Items.rodById[profile.rods.equipped] or nil
end

function state.bait(): any?
	local profile = state.profile
	return profile and profile.baits.equipped and Items.baitById[profile.baits.equipped] or nil
end

function state.baitCount(baitId: string?): number
	local profile = state.profile
	if not profile or not baitId then
		return 0
	end
	return profile.baits.owned[baitId] or 0
end

return state
