--!strict
--[[
	PlotPermissions — plot ownership with visitor capability toggles.

	The tycoon multiplayer contract: ownership by allocation, visitors
	invited with per-capability toggles (Build/Buy/Sell), and every
	mutation checked against the plot's permission state. Pure rules; the
	server maps capabilities to remotes.
]]

local PlotPermissions = {}

export type Capability = "Build" | "Buy" | "Sell"

type PlotState = {
	ownerUserId: number,
	visitors: { [number]: { [Capability]: boolean } },
	defaults: { [Capability]: boolean },
}

type Self = {
	capabilities: { Capability },
	plots: { [string]: PlotState },
}

PlotPermissions.__index = PlotPermissions

local function capabilitySet(toggles: { string }?): { [Capability]: boolean }
	local set: { [Capability]: boolean } = {}
	for _, name in { "Build", "Buy", "Sell" } do
		set[name :: Capability] = if toggles then table.find(toggles, name) ~= nil else false
	end
	return set
end

function PlotPermissions.new(): Self
	return setmetatable({ capabilities = { "Build", "Buy", "Sell" }, plots = {} }, PlotPermissions)
end

function PlotPermissions.createPlot(self: Self, plotId: string, ownerUserId: number): ()
	assert(not self.plots[plotId], ("duplicate plot %q"):format(plotId))
	self.plots[plotId] = {
		ownerUserId = ownerUserId,
		visitors = {},
		defaults = capabilitySet(),
	}
end

function PlotPermissions.transfer(self: Self, plotId: string, newOwner: number): boolean
	local plot = self.plots[plotId]
	if not plot then
		return false
	end
	plot.ownerUserId = newOwner
	plot.visitors = {}
	return true
end

function PlotPermissions.invite(self: Self, plotId: string, visitorUserId: number, toggles: { string }): boolean
	local plot = self.plots[plotId]
	if not plot or plot.visitors[visitorUserId] then
		return false
	end
	plot.visitors[visitorUserId] = capabilitySet(toggles)
	return true
end

function PlotPermissions.uninvite(self: Self, plotId: string, visitorUserId: number): boolean
	local plot = self.plots[plotId]
	if not plot or not plot.visitors[visitorUserId] then
		return false
	end
	plot.visitors[visitorUserId] = nil
	return true
end

function PlotPermissions.toggle(self: Self, plotId: string, visitorUserId: number, capability: Capability, enabled: boolean): boolean
	local plot = self.plots[plotId]
	local caps = plot and plot.visitors[visitorUserId]
	if not caps or not caps[capability] and not enabled then
		return false
	end
	if not caps then
		return false
	end
	caps[capability] = enabled
	return true
end

-- The gate every mutation remote calls first.
function PlotPermissions.check(self: Self, plotId: string, userId: number, capability: Capability): (boolean, string?)
	local plot = self.plots[plotId]
	if not plot then
		return false, "unknown_plot"
	end
	if plot.ownerUserId == userId then
		return true, nil
	end
	local caps = plot.visitors[userId]
	if not caps then
		return false, "not_invited"
	end
	if not caps[capability] then
		return false, "capability_off"
	end
	return true, nil
end

return PlotPermissions
