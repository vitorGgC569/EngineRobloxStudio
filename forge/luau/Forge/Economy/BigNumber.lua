--!strict
--[[
	BigNumber — arbitrary-magnitude numbers in scientific notation, pure Luau.

	A value is a { mantissa, exponent } pair with the mantissa normalised into
	[-10, -1) ∪ [1, 10) (or exactly zero). Doubles saturate near 1e308; here the
	exponent keeps counting, which is what incremental-game economies need.

		local price = BigNumber.new(1e15)
		BigNumber.format(price)      --> "1.00Qd"
		BigNumber.parse("1.00Qd")    --> the same value back

	Underflow collapses to zero. Growth past a configurable exponent ceiling
	(default 1000) caps there instead of escaping to infinity.
]]

local BigNumber = {}

export type BigNumber = {
	mantissa: number,
	exponent: number,
}

local DEFAULT_MAX_EXPONENT = 1000

local maxExponent = DEFAULT_MAX_EXPONENT

local ALIGN_LIMIT = 17

local INTEGRAL_EXPONENT = 16

local PREFIXES = { "", "U", "D", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No" }

local GROUPS = { "Dc", "Vg", "Tg", "Qag", "Qig", "Sxg", "Spg", "Ocg", "Nog", "Ct" }

local function buildSuffixes(): { string }
	local list: { string } = { "K", "M", "B", "T", "Qd", "Qn", "Sx", "Sp", "Oc", "No" }
	for _, group in GROUPS do
		for _, prefix in PREFIXES do
			table.insert(list, prefix .. group)
		end
	end
	return list
end

local SUFFIXES = buildSuffixes()

-- =============================== construction ===============================

local function normalize(mantissa: number, exponent: number): BigNumber
	if mantissa == 0 or mantissa ~= mantissa then
		return { mantissa = 0, exponent = 0 }
	end
	local sign = if mantissa < 0 then -1 else 1
	mantissa = math.abs(mantissa)
	local shift = math.floor(math.log(mantissa, 10))
	mantissa /= 10 ^ shift
	exponent += shift
	if mantissa >= 10 then
		mantissa /= 10
		exponent += 1
	elseif mantissa < 1 then
		mantissa *= 10
		exponent -= 1
	end
	if exponent > maxExponent then
		exponent = maxExponent
	elseif exponent < -maxExponent then
		return { mantissa = 0, exponent = 0 }
	end
	return { mantissa = sign * mantissa, exponent = exponent }
end

function BigNumber.fromNumber(value: number): BigNumber
	return normalize(value, 0)
end

function BigNumber.new(value: any): BigNumber
	local kind = type(value)
	if kind == "number" then
		return normalize(value :: number, 0)
	elseif kind == "string" then
		return BigNumber.parse(value :: string)
	elseif kind == "table" then
		local other = value :: BigNumber
		return { mantissa = other.mantissa, exponent = other.exponent }
	end
	error("BigNumber.new expects a number, string or BigNumber")
end

function BigNumber.zero(): BigNumber
	return { mantissa = 0, exponent = 0 }
end

function BigNumber.one(): BigNumber
	return { mantissa = 1, exponent = 0 }
end

function BigNumber.setMaxExponent(limit: number)
	maxExponent = limit
end

function BigNumber.getMaxExponent(): number
	return maxExponent
end

-- ================================= queries ===================================

function BigNumber.isZero(a: BigNumber): boolean
	return a.mantissa == 0
end

function BigNumber.sign(a: BigNumber): number
	if a.mantissa > 0 then
		return 1
	elseif a.mantissa < 0 then
		return -1
	end
	return 0
end

function BigNumber.compare(a: BigNumber, b: BigNumber): number
	local signA = BigNumber.sign(a)
	local signB = BigNumber.sign(b)
	if signA ~= signB then
		return if signA > signB then 1 else -1
	end
	if signA == 0 then
		return 0
	end
	if a.exponent ~= b.exponent then
		return signA * (if a.exponent > b.exponent then 1 else -1)
	end
	local magA = math.abs(a.mantissa)
	local magB = math.abs(b.mantissa)
	if magA == magB then
		return 0
	end
	return signA * (if magA > magB then 1 else -1)
end

function BigNumber.toNumber(a: BigNumber): number
	return a.mantissa * 10 ^ a.exponent
end

function BigNumber.log10Floor(a: BigNumber): number
	if a.mantissa == 0 then
		return -math.huge
	end
	return math.floor(a.exponent + math.log(math.abs(a.mantissa), 10) + 1e-11)
end

function BigNumber.floor(a: BigNumber): BigNumber
	if a.mantissa == 0 or a.exponent >= INTEGRAL_EXPONENT then
		return BigNumber.new(a)
	end
	return BigNumber.fromNumber(math.floor(BigNumber.toNumber(a)))
end

-- ================================ arithmetic ==================================

function BigNumber.negate(a: BigNumber): BigNumber
	return { mantissa = -a.mantissa, exponent = a.exponent }
end

function BigNumber.add(a: BigNumber, b: BigNumber): BigNumber
	if a.mantissa == 0 then
		return BigNumber.new(b)
	end
	if b.mantissa == 0 then
		return BigNumber.new(a)
	end
	local larger, smaller = a, b
	if a.exponent < b.exponent then
		larger, smaller = b, a
	end
	local gap = larger.exponent - smaller.exponent
	if gap > ALIGN_LIMIT then
		return BigNumber.new(larger)
	end
	return normalize(larger.mantissa + smaller.mantissa / 10 ^ gap, larger.exponent)
end

function BigNumber.sub(a: BigNumber, b: BigNumber): BigNumber
	return BigNumber.add(a, BigNumber.negate(b))
end

function BigNumber.mul(a: BigNumber, b: BigNumber): BigNumber
	if a.mantissa == 0 or b.mantissa == 0 then
		return { mantissa = 0, exponent = 0 }
	end
	return normalize(a.mantissa * b.mantissa, a.exponent + b.exponent)
end

function BigNumber.div(a: BigNumber, b: BigNumber): BigNumber
	assert(b.mantissa ~= 0, "BigNumber.div by zero")
	if a.mantissa == 0 then
		return { mantissa = 0, exponent = 0 }
	end
	return normalize(a.mantissa / b.mantissa, a.exponent - b.exponent)
end

function BigNumber.powInt(base: BigNumber, power: number): BigNumber
	if power == 0 then
		return { mantissa = 1, exponent = 0 }
	end
	local negative = power < 0
	local remaining = if negative then -power else power
	local result = BigNumber.one()
	local factor = BigNumber.new(base)
	while remaining > 0 do
		if remaining % 2 >= 1 then
			result = BigNumber.mul(result, factor)
		end
		remaining = math.floor(remaining / 2)
		if remaining > 0 then
			factor = BigNumber.mul(factor, factor)
		end
	end
	if negative then
		result = BigNumber.div(BigNumber.one(), result)
	end
	return result
end

-- ================================ formatting ==================================

local function formatFixed(value: number, decimals: number): string
	return string.format("%." .. decimals .. "f", value)
end

function BigNumber.format(value: any, decimals: number?, suffixes: { string }?): string
	local places = decimals or 2
	local list = suffixes or SUFFIXES
	local num = BigNumber.new(value)
	if num.mantissa == 0 then
		return formatFixed(0, places)
	end
	if num.mantissa < 0 then
		return "-" .. BigNumber.format(BigNumber.negate(num), places, list)
	end
	if num.exponent < 0 then
		return string.format("%." .. places .. "fe%+d", num.mantissa, num.exponent)
	end
	if num.exponent < 3 then
		return formatFixed(num.mantissa * 10 ^ num.exponent, places)
	end
	local tier = math.floor(num.exponent / 3)
	local suffix = list[tier]
	if suffix == nil then
		return string.format("%." .. places .. "fe%+d", num.mantissa, num.exponent)
	end
	return formatFixed(num.mantissa * 10 ^ (num.exponent - tier * 3), places) .. suffix
end

function BigNumber.parse(text: string): BigNumber
	local cleaned = (string.gsub(text, "%s+", ""))
	if cleaned == "" then
		error("BigNumber.parse got an empty string")
	end
	local negative = false
	if string.sub(cleaned, 1, 1) == "-" then
		negative = true
		cleaned = string.sub(cleaned, 2)
	end
	local mantissaText, exponentText = string.match(cleaned, "^([%d%.]+)[eE]%+?(%-?%d+)$")
	if mantissaText and exponentText then
		local mantissa = tonumber(mantissaText) :: number
		local exponent = tonumber(exponentText) :: number
		return normalize(if negative then -mantissa else mantissa, exponent)
	end
	for tier = #SUFFIXES, 1, -1 do
		local suffix = SUFFIXES[tier]
		if string.sub(cleaned, -#suffix) == suffix then
			local head = tonumber(string.sub(cleaned, 1, -#suffix - 1))
			if head then
				return normalize(if negative then -head else head, tier * 3)
			end
		end
	end
	local plain = tonumber(cleaned)
	if plain == nil then
		error("BigNumber.parse cannot read '" .. text .. "'")
	end
	return normalize(if negative then -plain else plain, 0)
end

return BigNumber
