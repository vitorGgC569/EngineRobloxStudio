--!strict
--- Shapes over time and over numbers: easing, curves, ramps, and randomness.
---
--- Two different needs that live together because they are the same maths.
---
--- **Easing** is how a value moves between two others. Linear motion is the
--- signature of something nobody tuned; almost every movement in a game that
--- feels good is a curve.
---
--- **Progression curves** are how a number grows across a game: the price of
--- the tenth upgrade, the health of wave twelve, the XP for level thirty. Get
--- this wrong and the game is either over in four minutes or unplayable at
--- hour two, and no amount of art fixes it.

local Curve = {}

-- -- easing -------------------------------------------------------------------

local function outIn(fn: (number) -> number): (number) -> number
	return function(t: number): number
		return 1 - fn(1 - t)
	end
end

local EASINGS: { [string]: (number) -> number } = {}

EASINGS.linear = function(t) return t end
EASINGS.quadIn = function(t) return t * t end
EASINGS.quadOut = outIn(EASINGS.quadIn)
EASINGS.cubicIn = function(t) return t * t * t end
EASINGS.cubicOut = outIn(EASINGS.cubicIn)
EASINGS.quartIn = function(t) return t ^ 4 end
EASINGS.quartOut = outIn(EASINGS.quartIn)
EASINGS.sineIn = function(t) return 1 - math.cos(t * math.pi * 0.5) end
EASINGS.sineOut = outIn(EASINGS.sineIn)
EASINGS.expoIn = function(t) return if t == 0 then 0 else 2 ^ (10 * (t - 1)) end
EASINGS.expoOut = outIn(EASINGS.expoIn)
EASINGS.circIn = function(t) return 1 - math.sqrt(math.max(1 - t * t, 0)) end
EASINGS.circOut = outIn(EASINGS.circIn)

--- Overshoots and comes back. Buttons, pickups, anything that should feel light.
EASINGS.backOut = function(t)
	local c = 1.70158
	local p = t - 1
	return p * p * ((c + 1) * p + c) + 1
end

--- Settles with a wobble. Use sparingly; it reads as playful, not as polish.
EASINGS.elasticOut = function(t)
	if t == 0 or t == 1 then
		return t
	end
	return 2 ^ (-10 * t) * math.sin((t * 10 - 0.75) * (2 * math.pi / 3)) + 1
end

--- Lands and settles. The one for anything that has weight.
EASINGS.bounceOut = function(t)
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

local function makeInOut(name: string)
	local into = EASINGS[name .. "In"]
	if into == nil then
		return
	end
	EASINGS[name .. "InOut"] = function(t: number): number
		if t < 0.5 then
			return into(t * 2) * 0.5
		end
		return 1 - into((1 - t) * 2) * 0.5
	end
end
for _, name in ipairs({ "quad", "cubic", "quart", "sine", "expo", "circ" }) do
	makeInOut(name)
end

function Curve.easings(): { string }
	local names = {}
	for name in pairs(EASINGS) do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

--- Apply an easing by name. Names the ones it has when given one it does not.
function Curve.ease(name: string, t: number): number
	local fn = EASINGS[name]
	if fn == nil then
		error(("no easing %q; have %s"):format(name, table.concat(Curve.easings(), ", ")), 2)
	end
	return fn(math.clamp(t, 0, 1))
end

--- Interpolate anything numeric, with a curve.
function Curve.lerp(from: number, to: number, t: number, easing: string?): number
	local shaped = if easing ~= nil then Curve.ease(easing, t) else math.clamp(t, 0, 1)
	return from + (to - from) * shaped
end

-- -- ranges --------------------------------------------------------------------

--- Move a value from one range to another. Health to bar width, distance to
--- volume, score to star rating.
function Curve.remap(value: number, fromLow: number, fromHigh: number,
	toLow: number, toHigh: number, clamp: boolean?): number

	local span = fromHigh - fromLow
	if span == 0 then
		return toLow
	end
	local t = (value - fromLow) / span
	if clamp ~= false then
		t = math.clamp(t, 0, 1)
	end
	return toLow + (toHigh - toLow) * t
end

--- Smooth approach that does not depend on frame rate.
---
--- `value = value + (target - value) * 0.1` in a Heartbeat is the usual way and
--- it runs at different speeds on different machines, which is a real bug that
--- shows up as "the camera is jerky on my laptop".
function Curve.approach(current: number, target: number, smoothing: number, delta: number): number
	local alpha = 1 - math.exp(-smoothing * delta)
	return current + (target - current) * alpha
end

-- -- progression ----------------------------------------------------------------

--- Each step costs `ratio` times the last. Shops, upgrades, tycoon tiers.
---
--- Below about 1.15 the late game is free; above about 1.6 the third purchase
--- is out of reach. Most shipped Roblox economies live between them.
function Curve.geometric(base: number, ratio: number, step: number): number
	return base * ratio ^ math.max(step - 1, 0)
end

--- Each step costs a fixed amount more. Gentler, and it flattens late.
function Curve.linearStep(base: number, increment: number, step: number): number
	return base + increment * math.max(step - 1, 0)
end

--- Grows fast then slows to a ceiling. Good for anything that must not run away.
function Curve.diminishing(base: number, ceiling: number, rate: number, step: number): number
	return ceiling - (ceiling - base) * math.exp(-rate * math.max(step - 1, 0))
end

--- The whole ladder at once, for reading before shipping it.
function Curve.ladder(kind: string, steps: number, options: { [string]: any }?): { number }
	local opts = options or {}
	local base = tonumber(opts.base) or 100
	local out = {}
	for step = 1, steps do
		local value
		if kind == "geometric" then
			value = Curve.geometric(base, tonumber(opts.ratio) or 1.35, step)
		elseif kind == "linear" then
			value = Curve.linearStep(base, tonumber(opts.increment) or 50, step)
		elseif kind == "diminishing" then
			value = Curve.diminishing(base, tonumber(opts.ceiling) or base * 10,
				tonumber(opts.rate) or 0.3, step)
		else
			error(("no curve %q; have geometric, linear, diminishing"):format(kind), 2)
		end
		table.insert(out, math.floor(value + 0.5))
	end
	return out
end

-- -- randomness -------------------------------------------------------------------

--- A seeded stream. Same seed, same game -- which is what makes a bug
--- reproducible and a scatter re-creatable.
function Curve.stream(seed: number)
	local random = Random.new(seed)
	return {
		number = function(low: number?, high: number?): number
			if low == nil then
				return random:NextNumber()
			end
			return random:NextNumber(low, high or 1)
		end,
		integer = function(low: number, high: number): number
			return random:NextInteger(low, high)
		end,
		chance = function(probability: number): boolean
			return random:NextNumber() < probability
		end,
		pick = function<T>(items: { T }): T?
			if #items == 0 then
				return nil
			end
			return items[random:NextInteger(1, #items)]
		end,
		--- Pick by weight. Drop tables, loot, spawn mixes -- the one everybody
		--- writes by hand and gets subtly wrong at the boundaries.
		weighted = function<T>(entries: { { value: T, weight: number } }): T?
			local total = 0
			for _, entry in ipairs(entries) do
				total += math.max(entry.weight, 0)
			end
			if total <= 0 then
				return nil
			end
			local roll = random:NextNumber() * total
			for _, entry in ipairs(entries) do
				roll -= math.max(entry.weight, 0)
				if roll <= 0 then
					return entry.value
				end
			end
			return entries[#entries].value
		end,
		shuffle = function<T>(items: { T }): { T }
			local copy = table.clone(items)
			for index = #copy, 2, -1 do
				local swap = random:NextInteger(1, index)
				copy[index], copy[swap] = copy[swap], copy[index]
			end
			return copy
		end,
		point = function(centre: Vector3, radius: number): Vector3
			local angle = random:NextNumber() * math.pi * 2
			-- Square root, or every point clusters at the centre. The bug that
			-- makes a "random scatter" look like a bullseye.
			local distance = math.sqrt(random:NextNumber()) * radius
			return centre + Vector3.new(math.cos(angle) * distance, 0,
				math.sin(angle) * distance)
		end,
	}
end

return Curve
