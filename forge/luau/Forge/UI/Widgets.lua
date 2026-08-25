--!strict
--[[
	Widgets — toast, tooltip and hotkey models.

	Small UI primitives as data plans: toasts stack with lifetimes,
	tooltips anchor with placement rules that avoid screen edges, hotkeys
	bind action->keycode tokens with chord support. Rendering is the
	client's; state lives here so tests cover behavior.
]]

local Widgets = {}

-- Toast: transient banner; queue drains oldest when full.
export type Toast = { id: number, text: string, duration: number }

local Toasts = { nextId = 1 }
Toasts.__index = Toasts

function Widgets.newToastQueue(maxVisible: number?): any
	return setmetatable({ items = {}, maxVisible = maxVisible or 3 }, Toasts)
end

function Toasts.push(self: any, text: string, duration: number?): Toast
	local toast = { id = self.nextId, text = text, duration = duration or 2.5 }
	self.nextId += 1
	table.insert(self.items, toast)
	while #self.items > self.maxVisible do
		table.remove(self.items, 1)
	end
	return toast
end

function Toasts.expire(self: Self, id: number): ()
	for index, toast in self.items :: { Toast } do
		if (toast :: Toast).id == id then
			table.remove(self.items :: { any }, index)
			break
		end
	end
end

-- Tooltip: placement that flips at screen edges.
local function placeTooltip(anchorX: number, anchorY: number, sizeW: number, sizeH: number, screenW: number, screenH: number): { x: number, y: number }
	local margin = 8
	local x = if anchorX + sizeW + margin > screenW then anchorX - sizeW - margin else anchorX + margin
	local y = if anchorY + sizeH + margin > screenH then anchorY - sizeH - margin else anchorY + margin
	return { x = math.max(margin, x), y = math.max(margin, y) }
end
Widgets.placeTooltip = placeTooltip

-- Hotkey registry: action -> key token ("Q", "LeftControl+R").
local Hotkeys = {}
Hotkeys.__index = Hotkeys

function Widgets.newHotkeys(): any
	return setmetatable({ bindings = {} }, Hotkeys)
end

function Hotkeys.bind(self: any, action: string, keyToken: string): ()
	self.bindings[action] = keyToken
end

function Hotkeys.unbind(self: any, action: string): ()
	self.bindings[action] = nil
end

-- Matches an input token against bindings ("LeftControl+R" exact order).
function Hotkeys.match(self: any, inputToken: string): string?
	for action, bound in self.bindings do
		if bound == inputToken then
			return action
		end
	end
	return nil
end

return Widgets
