--!strict
--[[
	ObjectiveTracker — current objective text plus 3D marker plan.

	Quest/HUD guidance needs two things in sync: the objective text and a
	marker that follows the target (by tag or name). The marker is a
	rendering PLAN (screen-independent), so the client binds it and the
	probes can verify the chosen target.
]]

local ObjectiveTracker = {}

export type Marker = {
	targetName: string,
	targetTag: string?,
	offsetY: number,
	alwaysOnTop: boolean,
	text: string?,
}

type Self = {
	objectiveText: string,
	markers: { Marker },
	activeMarkerIndex: number,
}

ObjectiveTracker.__index = ObjectiveTracker

function ObjectiveTracker.new(): Self
	return setmetatable({ objectiveText = "", markers = {}, activeMarkerIndex = 0 }, ObjectiveTracker)
end

function ObjectiveTracker.setObjective(self: Self, text: string): ()
	self.objectiveText = text
end

function ObjectiveTracker.setMarkers(self: Self, markers: { Marker }): ()
	self.markers = table.clone(markers)
	self.activeMarkerIndex = if #markers > 0 then 1 else 0
end

-- Advances to the next marker when the current target was reached.
function ObjectiveTracker.advance(self: Self): boolean
	if self.activeMarkerIndex >= #self.markers then
		return false
	end
	self.activeMarkerIndex += 1
	return true
end

function ObjectiveTracker.activeMarker(self: Self): Marker?
	return self.markers[self.activeMarkerIndex]
end

return ObjectiveTracker
