--[[
	Format — how a number becomes words, in one place.

	The server formats every big number it sends, so the client never has to
	own a formatter and two formatters can never disagree. The client still
	uses this module for values it receives raw (power) and for counters it
	animates locally.
]]

local Format = {}

local SUFFIXES = { "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }

local function fixed(value, decimals)
	local text = string.format("%." .. tostring(decimals) .. "f", value)
	text = text:gsub("%.0+$", "")
	return text
end

--: 1234 -> "1.2K"; 5_400_000 -> "5.4M"; beyond Dc -> "1.2e36".
function Format.abbrev(value)
	if value == nil or value ~= value then
		return "0"
	end
	if value < 0 then
		return "-" .. Format.abbrev(-value)
	end
	if value < 1000 then
		local shown = math.floor(value)
		if value < 10 and value ~= shown then
			return string.format("%.1f", value)
		end
		return tostring(shown)
	end

	local exponent = math.floor(math.log(value, 10))
	local tier = math.floor(exponent / 3)
	if tier <= #SUFFIXES and exponent < 33.1 then
		local scaled = value / (10 ^ (tier * 3))
		local decimals = scaled < 10 and 1 or (scaled < 100 and 1 or 0)
		return fixed(scaled, decimals) .. SUFFIXES[tier]
	end

	local mantissa = value / (10 ^ exponent)
	return string.format("%.1fe%d", mantissa, exponent)
end

--: A BigNumber-shaped table { mantissa, exponent } without requiring the
--: engine on the client. Exact for the tiers that have names, scientific
--: beyond them.
function Format.big(big)
	if type(big) == "number" then
		return Format.abbrev(big)
	end
	if type(big) ~= "table" or big.mantissa == nil or big.exponent == nil then
		return "0"
	end
	local mantissa = big.mantissa
	local exponent = big.exponent
	if mantissa ~= mantissa then
		return "0"
	end
	if exponent < 3 then
		return Format.abbrev(mantissa * (10 ^ exponent))
	end
	local tier = math.floor(exponent / 3)
	if tier <= #SUFFIXES then
		local scaled = mantissa * (10 ^ (exponent - tier * 3))
		local decimals = scaled < 10 and 2 or (scaled < 100 and 1 or 0)
		return fixed(scaled, decimals) .. SUFFIXES[tier]
	end
	return string.format("%.2fe%d", mantissa, exponent)
end

function Format.percent(fraction)
	return string.format("%d%%", math.floor(fraction * 100 + 0.5))
end

function Format.duration(seconds)
	seconds = math.max(0, math.floor(seconds))
	local hours = math.floor(seconds / 3600)
	local minutes = math.floor((seconds % 3600) / 60)
	local secs = seconds % 60
	if hours > 0 then
		return string.format("%dh %dm", hours, minutes)
	end
	if minutes > 0 then
		return string.format("%dm %ds", minutes, secs)
	end
	return string.format("%ds", secs)
end

return Format
