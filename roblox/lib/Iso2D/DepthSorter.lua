--!strict
--[[
	DepthSorter — painter's-order ZIndex assignment with focus fade.

	Iso depth is draw order: objects sorted by world Y get sequential
	ZIndex values. Objects behind the focused one fade to a configured
	transparency so the player can always see what they are touching.
]]

local DepthSorter = {}

export type IsoObject = {
	id: string,
	y: number,
	zindex: number?,
}

type Self = {
	fadeTransparency: number,
	focusedId: string?,
}

DepthSorter.__index = DepthSorter

function DepthSorter.new(config: { fadeTransparency: number? }): Self
	return setmetatable({
		fadeTransparency = math.clamp(config.fadeTransparency or 0.5, 0, 1),
		focusedId = nil,
	}, DepthSorter)
end

function DepthSorter.setFocus(self: Self, objectId: string?): ()
	self.focusedId = objectId
end

-- Assigns zindex (1..n back-to-front) and returns per-object transparency.
function DepthSorter.apply(self: Self, objects: { IsoObject }): { [string]: { zindex: number, transparency: number } }
	table.sort(objects, function(a, b)
		return a.y < b.y
	end)
	local result: { [string]: { zindex: number, transparency: number } } = {}
	local focusY: number? = nil
	if self.focusedId then
		for _, obj in objects do
			if obj.id == self.focusedId then
				focusY = obj.y
				break
			end
		end
	end
	for index, obj in objects do
		obj.zindex = index
		local transparency = 0
		if focusY and obj.y < focusY and obj.id ~= self.focusedId then
			transparency = self.fadeTransparency
		end
		result[obj.id] = { zindex = index, transparency = transparency }
	end
	return result
end

return DepthSorter
