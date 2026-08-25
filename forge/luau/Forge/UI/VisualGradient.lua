--!strict
--[[
	VisualGradient — UIGradient plans from token colors.

	Gradients take token-resolved colors (never hex), a rotation in
	degrees and optional transparency stops. The plan maps 1:1 onto a
	UIGradient at bind time.
]]

local VisualGradient = {}

export type Stop = {
	offset: number,
	color: { r: number, g: number, b: number },
	transparency: number?,
}

export type GradientPlan = {
	rotation: number,
	stops: { Stop },
}

function VisualGradient.linear(config: {
	from: { r: number, g: number, b: number },
	to: { r: number, g: number, b: number },
	rotation: number?,
	fromTransparency: number?,
	toTransparency: number?,
}): GradientPlan
	return {
		rotation = math.clamp(config.rotation or 90, -360, 360),
		stops = {
			{ offset = 0, color = config.from, transparency = config.fromTransparency or 0 },
			{ offset = 1, color = config.to, transparency = config.toTransparency or 0 },
		},
	}
end

-- Three-stop vertical wash commonly used on panels (top highlight).
function VisualGradient.panelWash(base: { r: number, g: number, b: number }, highlight: { r: number, g: number, b: number }): GradientPlan
	return {
		rotation = 90,
		stops = {
			{ offset = 0, color = highlight, transparency = 0.25 },
			{ offset = 0.35, color = base, transparency = 0 },
			{ offset = 1, color = base, transparency = 0.1 },
		},
	}
end

function VisualGradient.validate(plan: GradientPlan): (boolean, string?)
	if #plan.stops < 2 then
		return false, "needs_two_stops"
	end
	for index, stop in plan.stops do
		if stop.offset < 0 or stop.offset > 1 then
			return false, ("stop_%d_offset_out_of_range"):format(index)
		end
	end
	for index = 2, #plan.stops do
		if plan.stops[index].offset < plan.stops[index - 1].offset then
			return false, ("stop_%d_out_of_order"):format(index)
		end
	end
	return true, nil
end

return VisualGradient
