--!strict
--[[
	VisualControls — input controls as stateful plans.

	Slider/Switch/Checkbox/TextField/Search/ProgressBar: each holds the
	truth for its control and renders a plan the presentation binds.
	Disabled controls ignore input by construction, not by caller care.
]]

local Controls = {}

-- ============================== slider ===================================
export type SliderState = {
	value: number,
	min: number,
	max: number,
	step: number?,
	disabled: boolean,
}

function Controls.slider(config: { value: number, min: number?, max: number?, step: number?, disabled: boolean? }): SliderState
	local min = config.min or 0
	local max = config.max or 100
	assert(max > min, "slider max must exceed min")
	return { value = math.clamp(config.value, min, max), min = min, max = max, step = config.step, disabled = config.disabled == true }
end

function Controls.setValue(slider: SliderState, value: number): number
	if slider.disabled then
		return slider.value
	end
	value = math.clamp(value, slider.min, slider.max)
	if slider.step then
		value = math.clamp(math.floor((value - slider.min) / slider.step + 0.5) * slider.step + slider.min, slider.min, slider.max)
	end
	slider.value = value
	return value
end

-- ============================== switch / checkbox =========================
export type ToggleState = { on: boolean, disabled: boolean }

function Controls.toggle(initial: boolean, disabled: boolean?): ToggleState
	return { on = initial, disabled = disabled == true }
end

function Controls.flip(state: ToggleState): boolean
	if state.disabled then
		return state.on
	end
	state.on = not state.on
	return state.on
end

-- ============================== text field ================================
export type TextFieldState = {
	text: string,
	placeholder: string,
	maxLength: number,
	focused: boolean,
	errorText: string?,
}

function Controls.textField(config: { placeholder: string?, maxLength: number? }): TextFieldState
	return {
		text = "",
		placeholder = config.placeholder or "",
		maxLength = config.maxLength or 64,
		focused = false,
		errorText = nil,
	}
end

function Controls.typeInto(field: TextFieldState, appended: string): string
	if not field.focused then
		return field.text
	end
	field.text = string.sub(field.text .. appended, 1, field.maxLength)
	return field.text
end

function Controls.setError(field: TextFieldState, message: string?): ()
	field.errorText = message
end

-- ============================== progress ==================================
export type ProgressState = { value: number, target: number }

function Controls.progress(value: number, target: number): ProgressState
	assert(target > 0, "target must be positive")
	return { value = math.max(0, value), target = target }
end

function Controls.fraction(progress: ProgressState): number
	return math.clamp(progress.value / progress.target, 0, 1)
end

return Controls
