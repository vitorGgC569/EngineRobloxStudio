--!strict
--[[
	InputMode — device classification and gamepad menu navigation.

	The input mode decides raycast origin (mouse vs center-screen),
	control scheme and response timeouts; it changes at runtime and must
	be re-checked, never cached forever. Gamepad navigation picks the
	nearest selectable button in a container by screen distance.
]]

local InputMode = {}

export type Mode = "keyboard" | "gamepad" | "touch"

type Self = {
	mode: Mode,
	lastChangedAt: number,
	clock: () -> number,
}

InputMode.__index = InputMode

function InputMode.new(clock: (() -> number)?): Self
	return setmetatable({ mode = "keyboard" :: Mode, lastChangedAt = 0, clock = clock or os.clock }, InputMode)
end

-- Facts come from UserSettings/Service checks on the client.
function InputMode.detect(self: Self, keyboardEnabled: boolean, gamepadEnabled: boolean, touchEnabled: boolean): Mode
	local nextMode: Mode = "keyboard"
	if touchEnabled then
		nextMode = "touch"
	elseif gamepadEnabled then
		nextMode = "gamepad"
	elseif keyboardEnabled then
		nextMode = "keyboard"
	end
	if nextMode ~= self.mode then
		self.mode = nextMode
		self.lastChangedAt = self.clock()
	end
	return self.mode
end

function InputMode.current(self: Self): Mode
	return self.mode
end

-- Ray origin policy per mode: mouse points, touch aims from screen centre.
function InputMode.usesCenterScreenRay(self: Self): boolean
	return self.mode ~= "keyboard"
end

-- Nearest selectable among candidates to the focus point; wraps nothing —
-- callers decide edge behaviour.
function InputMode.nearestSelectable(candidates: { { key: string, x: number, y: number } }, focusX: number, focusY: number): string?
	local bestKey: string? = nil
	local bestDist = math.huge
	for _, candidate in candidates do
		local dx, dy = candidate.x - focusX, candidate.y - focusY
		local dist = dx * dx + dy * dy
		if dist < bestDist then
			bestDist = dist
			bestKey = candidate.key
		end
	end
	return bestKey
end

-- Directional step over an ordered list for arrow-key navigation.
function InputMode.stepFocus(orderedKeys: { string }, currentIndex: number, direction: number): number?
	if #orderedKeys == 0 then
		return nil
	end
	local nextIndex = ((currentIndex - 1 + direction) % #orderedKeys) + 1
	if nextIndex < 1 or nextIndex > #orderedKeys then
		return nil
	end
	return nextIndex
end

return InputMode
