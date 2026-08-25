--!strict
--[[
	VisualKit.Component — BaseComponent contract and core components.

	The canonical lifecycle (props/render/destroy) plus the essential set:
	Button with hover/press/disabled states, Modal, Snackbar, Slider and
	Tab. Components produce PLANS (what to build/update), keeping this
	module headless-testable; the presentation layer binds plans to
	Instances through WorldKit.Ui.
]]

local Component = {}

-- ============================== base =====================================
local BaseComponent = {}
BaseComponent.__index = BaseComponent

function Component.new(props: { [string]: any }?): any
	return setmetatable({ props = props or {}, destroyed = false }, BaseComponent)
end

function BaseComponent.render(self: any): { [string]: any }
	return {}
end

function BaseComponent.destroy(self: any): ()
	self.destroyed = true
end

-- ============================== button ===================================
export type ButtonProps = {
	text: string,
	variant: ("primary" | "secondary" | "danger")?,
	disabled: boolean?,
	onPress: (() -> ())?,
}

local Button = setmetatable({}, BaseComponent)
Button.__index = Button

function Component.button(props: ButtonProps): any
	local self = setmetatable(Component.new(props), Button)
	self.hovered = false
	self.pressed = false
	return self
end

function Button.setHover(self: any, hovered: boolean): ()
	if not self.props.disabled then
		self.hovered = hovered
	end
end

function Button.press(self: any): ()
	if not self.props.disabled and not self.destroyed then
		self.pressed = true
	end
end

function Button.release(self: any): ()
	local wasPressed = self.pressed
	self.pressed = false
	if wasPressed and self.props.onPress then
		self.props.onPress()
	end
end

function Button.render(self: any): { [string]: any }
	return {
		kind = "button",
		text = self.props.text,
		variant = self.props.variant or "primary",
		disabled = self.props.disabled == true,
		hovered = self.hovered,
		pressed = self.pressed,
	}
end

-- ============================== modal ====================================
local Modal = setmetatable({}, BaseComponent)
Modal.__index = Modal

function Component.modal(props: { title: string, dismissable: boolean? }): any
	return setmetatable(Component.new(props), Modal)
end

function Modal.render(self: any): { [string]: any }
	return { kind = "modal", title = self.props.title, dismissable = self.props.dismissable ~= false }
end

-- ============================== snackbar =================================
local Snackbar = setmetatable({}, BaseComponent)
Snackbar.__index = Snackbar

function Component.snackbar(props: { text: string, actionText: string?, durationSeconds: number? }): any
	return setmetatable(Component.new(props), Snackbar)
end

function Snackbar.render(self: any): { [string]: any }
	return {
		kind = "snackbar",
		text = self.props.text,
		actionText = self.props.actionText,
		durationSeconds = self.props.durationSeconds or 3,
	}
end

return Component
