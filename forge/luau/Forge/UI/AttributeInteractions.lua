--!strict
--[[
	AttributeInteractions — Pretty-style hover/press driven by attributes.

	A button wired through attributes needs zero event code in its
	creator: the model reads an attribute snapshot and answers with the
	interaction state plus which attributes to write back. The runtime
	binder is a thin loop (GetAttributeChangedSignal); this module owns
	the rules so they are testable without Instances.
]]

local AttributeInteractions = {}

export type AttributeSnapshot = { [string]: any }

export type InteractionState = {
	hovered: boolean,
	pressed: boolean,
	disabled: boolean,
}

export type WritePlan = {
	attribute: string,
	value: any,
}

type Self = {
	hoverAttribute: string,
	pressAttribute: string,
	enabledAttribute: string,
	stateAttribute: string,
}

AttributeInteractions.__index = AttributeInteractions

function AttributeInteractions.new(config: {
	hoverAttribute: string?,
	pressAttribute: string?,
	enabledAttribute: string?,
	stateAttribute: string?,
}): Self
	return setmetatable({
		hoverAttribute = config.hoverAttribute or "UIHovered",
		pressAttribute = config.pressAttribute or "UIPressed",
		enabledAttribute = config.enabledAttribute or "UIEnabled",
		stateAttribute = config.stateAttribute or "UIState",
	}, AttributeInteractions)
end

-- Evaluates one attribute snapshot into interaction state. Missing
-- attributes default to enabled/idle — fail-open for rendering, but the
-- write-back plan below always materializes them so state is observable.
function AttributeInteractions.evaluate(self: Self, snapshot: AttributeSnapshot): InteractionState
	local hovered = snapshot[self.hoverAttribute] == true
	local pressed = snapshot[self.pressAttribute] == true and hovered
	local disabled = snapshot[self.enabledAttribute] == false
	return { hovered = hovered, pressed = pressed, disabled = disabled }
end

-- The attributes a bound instance should carry so tools/probes can read
-- interaction state from outside without touching events.
function AttributeInteractions.writePlan(self: Self, state: InteractionState): { WritePlan }
	local label = if state.disabled then "disabled"
		elseif state.pressed then "pressed"
		elseif state.hovered then "hovered"
		else "idle"
	return {
		{ attribute = self.stateAttribute, value = label },
	}
end

return AttributeInteractions
