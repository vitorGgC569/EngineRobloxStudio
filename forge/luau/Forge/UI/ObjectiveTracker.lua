--!strict
--[[
	ObjectiveTracker — current objective text plus 3D marker plan.

	Quest/HUD guidance needs two things in sync: the objective text and a
	marker that follows the target (by tag or name). The marker is a
	rendering PLAN (screen-independent), so the client binds it and the
	probes can verify the chosen target.
]]

local ObjectiveTracker = {}

-- `table.clone` copied the array and left each marker table shared, and
-- `activeMarker` handed that same table back. Editing `text` on the caller's
-- marker, or on the one just returned, rewrote the plan later reads used.
local function deepCopy(value: any, seen: { [any]: any }): any
	if type(value) ~= "table" then
		return value
	end
	if seen[value] then
		return seen[value]
	end
	local copy = {}
	seen[value] = copy
	for key, item in value :: { [any]: any } do
		copy[key] = deepCopy(item, seen)
	end
	return copy
end

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
	self.markers = deepCopy(markers, {}) :: { Marker }
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
	local marker = self.markers[self.activeMarkerIndex]
	if marker == nil then
		return nil
	end
	return deepCopy(marker, {}) :: Marker
end

return ObjectiveTracker
