--!strict
-- Ease — curves by name, so a curve choice can live in a data table instead of
-- in code. `Ease.get("outBack")(t)` is what makes a designer-tunable UI possible.

local Ease = {}

local function outBounce(t: number): number
	local n, d = 7.5625, 2.75
	if t < 1 / d then
		return n * t * t
	elseif t < 2 / d then
		t -= 1.5 / d
		return n * t * t + 0.75
	elseif t < 2.5 / d then
		t -= 2.25 / d
		return n * t * t + 0.9375
	end
	t -= 2.625 / d
	return n * t * t + 0.984375
end

local curves: { [string]: (number) -> number } = {
	linear = function(t) return t end,

	inQuad = function(t) return t * t end,
	outQuad = function(t) return 1 - (1 - t) ^ 2 end,
	inOutQuad = function(t) return t < 0.5 and 2 * t * t or 1 - ((-2 * t + 2) ^ 2) / 2 end,

	inCubic = function(t) return t ^ 3 end,
	outCubic = function(t) return 1 - (1 - t) ^ 3 end,
	inOutCubic = function(t) return t < 0.5 and 4 * t ^ 3 or 1 - ((-2 * t + 2) ^ 3) / 2 end,

	inQuint = function(t) return t ^ 5 end,
	outQuint = function(t) return 1 - (1 - t) ^ 5 end,

	inExpo = function(t) return t == 0 and 0 or 2 ^ (10 * t - 10) end,
	outExpo = function(t) return t == 1 and 1 or 1 - 2 ^ (-10 * t) end,

	inSine = function(t) return 1 - math.cos((t * math.pi) / 2) end,
	outSine = function(t) return math.sin((t * math.pi) / 2) end,
	inOutSine = function(t) return -(math.cos(math.pi * t) - 1) / 2 end,

	-- smoothstep: the default for anything that must not look mechanical
	smooth = function(t) return t * t * (3 - 2 * t) end,
	smoother = function(t) return t * t * t * (t * (t * 6 - 15) + 10) end,

	-- overshoot: impact, pop-in, "juice"
	outBack = function(t)
		local c1, c3 = 1.70158, 2.70158
		return 1 + c3 * (t - 1) ^ 3 + c1 * (t - 1) ^ 2
	end,
	inBack = function(t)
		local c1, c3 = 1.70158, 2.70158
		return c3 * t ^ 3 - c1 * t ^ 2
	end,
	outElastic = function(t)
		if t == 0 or t == 1 then
			return t
		end
		local c4 = (2 * math.pi) / 3
		return 2 ^ (-10 * t) * math.sin((t * 10 - 0.75) * c4) + 1
	end,
	outBounce = outBounce,
	inBounce = function(t) return 1 - outBounce(1 - t) end,
}

Ease.curves = curves

function Ease.get(name: string?): (number) -> number
	if not name then
		return curves.smooth
	end
	local fn = curves[name]
	if not fn then
		warn(string.format("[Ease] unknown curve '%s', falling back to smooth", name))
		return curves.smooth
	end
	return fn
end

function Ease.apply(name: string?, t: number): number
	return Ease.get(name)(math.clamp(t, 0, 1))
end

-- Lerp that works on the types gameplay actually interpolates.
function Ease.lerp(a: any, b: any, t: number): any
	local kind = typeof(a)
	if kind == "number" then
		return a + (b - a) * t
	elseif kind == "Color3" then
		return (a :: Color3):Lerp(b, t)
	elseif kind == "Vector3" or kind == "Vector2" then
		return (a :: any):Lerp(b, t)
	elseif kind == "CFrame" then
		return (a :: CFrame):Lerp(b, t)
	elseif kind == "UDim2" then
		return (a :: UDim2):Lerp(b, t)
	end
	error("[Ease] cannot lerp a " .. kind, 2)
end

-- Frame-rate independent approach. `speed` is roughly "fraction closed per
-- second". Use instead of `x += (goal - x) * 0.1`, which is frame-rate bound.
function Ease.approach(current: any, goal: any, speed: number, dt: number): any
	return Ease.lerp(current, goal, 1 - math.exp(-speed * dt))
end

return Ease
