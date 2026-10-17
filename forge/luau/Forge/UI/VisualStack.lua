--!strict
--[[
	VisualKit.Stack — ordered screen stack with focus and input routing.

	Only the top of the stack receives input; screens beneath render but
	ignore presses. Push/pop/settle are explicit so transitions (slide
	out old, slide in new) have a deterministic order, mirroring
	Pretty's stack discipline.
]]

local ScreenStack = {}

export type Layer = {
	id: string,
	modal: boolean,
	visible: boolean,
}

type Self = {
	layers: { Layer },
	nextId: number,
}

ScreenStack.__index = ScreenStack

function ScreenStack.new(): Self
	return setmetatable({ layers = {}, nextId = 1 }, ScreenStack)
end

function ScreenStack.push(self: Self, modal: boolean?): string
	local layer: Layer = { id = ("layer_%d"):format(self.nextId), modal = modal ~= false, visible = true }
	self.nextId += 1
	table.insert(self.layers, layer)
	return layer.id
end
-- Pop returns the closed id plus which id is now focused (top).
function ScreenStack.pop(self: Self): (string?, string?)
	local removed = table.remove(self.layers)
	if not removed then
		return nil, nil
	end
	local top = self.layers[#self.layers]
	return removed.id, if top then top.id else nil
end

function ScreenStack.top(self: Self): Layer?
	local layer = self.layers[#self.layers]
	if not layer then
		return nil
	end
	-- The stored layer used to come back live. Clearing modal on that table
	-- let a layer underneath receive input.
	return table.clone(layer)
end

-- Only the focused layer may handle input; background layers cannot.
function ScreenStack.canHandleInput(self: Self, layerId: string): boolean
	for index = #self.layers, 1, -1 do
		local layer = self.layers[index]
		if layer.id == layerId then
			return true -- it is the top-most
		end
		if layer.modal then
			return false -- a modal above blocks everything below
		end
	end
	return false
end

function ScreenStack.count(self: Self): number
	return #self.layers
end

-- ============================ transitions =================================
-- Push/pop return a transition plan: what leaves, what enters, and how.
-- Presentation runs the plan; tests assert its shape and duration.

export type TransitionPlan = {
	kind: ("slide" | "fade"),
	direction: ("inFromRight" | "inFromBottom"),
	durationSeconds: number,
	outgoingId: string?,
	incomingId: string,
}

local DEFAULT_TRANSITION = { kind = "slide" :: any, durationSeconds = 0.24 }

function ScreenStack.transitionConfig(self: Self, config: { kind: ("slide" | "fade")?, durationSeconds: number? }): ()
	self.transitionKind = config.kind or "slide"
	self.transitionDuration = config.durationSeconds or 0.24
end

function ScreenStack.planPush(self: Self): { layerId: string, plan: TransitionPlan }
	local incoming = self:push(true)
	return {
		layerId = incoming,
		plan = {
			kind = self.transitionKind or (DEFAULT_TRANSITION.kind :: any),
			direction = "inFromRight",
			durationSeconds = self.transitionDuration or DEFAULT_TRANSITION.durationSeconds,
			outgoingId = if #self.layers > 1 then self.layers[#self.layers - 1].id else nil,
			incomingId = incoming,
		},
	}
end

function ScreenStack.planPop(self: Self): { closedId: string?, focusedId: string?, plan: TransitionPlan? }
	local closed, focused = self:pop()
	if not closed then
		return { closedId = nil, focusedId = nil, plan = nil }
	end
	return {
		closedId = closed,
		focusedId = focused,
		plan = {
			kind = self.transitionKind or (DEFAULT_TRANSITION.kind :: any),
			direction = "inFromRight", -- background slides back from the same side
			durationSeconds = self.transitionDuration or DEFAULT_TRANSITION.durationSeconds,
			outgoingId = closed,
			incomingId = focused or "",
		},
	}
end

return ScreenStack
