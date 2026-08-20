--!strict
-- Number formatting for an idle game.
--
-- Idle economies run past every scale a person can read. The reference shows
-- values like $1.63Dc and $862.27N, so the ladder has to reach decillions and
-- keep three significant figures the whole way: "$1.63Dc" is legible,
-- "1630000000000000000000000000000000" is not.

local Format = {}

--- Short-scale suffixes. Index 1 is thousands.
Format.Suffixes = {
	"K", "M", "B", "T",
	"Qa", "Qi", "Sx", "Sp", "Oc", "N",
	"Dc", "Ud", "Dd", "Td", "Qad", "Qid", "Sxd", "Spd", "Ocd", "Nd",
	"Vg",
}

--- 12345 -> "12.3K", 1.63e33 -> "1.63Dc".
function Format.short(value: number): string
	if value ~= value then
		return "0"
	end
	local sign = if value < 0 then "-" else ""
	local amount = math.abs(value)

	if amount < 1000 then
		-- Under a thousand, decimals are noise.
		return sign .. tostring(math.floor(amount + 0.5))
	end

	local tier = math.floor(math.log(amount, 1000))
	tier = math.clamp(tier, 1, #Format.Suffixes)
	local scaled = amount / (1000 ^ tier)

	-- Three significant figures, so the number stays the same width as it grows.
	local text
	if scaled >= 100 then
		text = string.format("%.0f", scaled)
	elseif scaled >= 10 then
		text = string.format("%.1f", scaled)
	else
		text = string.format("%.2f", scaled)
	end

	return sign .. text .. Format.Suffixes[tier]
end

function Format.money(value: number): string
	return "$" .. Format.short(value)
end

function Format.rate(value: number): string
	return "$" .. Format.short(value) .. "/s"
end

--- 3725 -> "1h 2m". Used by the offline-earnings screen.
function Format.duration(seconds: number): string
	local total = math.max(0, math.floor(seconds))
	local hours = math.floor(total / 3600)
	local minutes = math.floor((total % 3600) / 60)
	if hours > 0 then
		return string.format("%dh %dm", hours, minutes)
	end
	if minutes > 0 then
		return string.format("%dm", minutes)
	end
	return string.format("%ds", total % 60)
end

function Format.multiplier(value: number): string
	if value >= 100 then
		return string.format("%.0fx", value)
	elseif value >= 10 then
		return string.format("%.1fx", value)
	end
	return string.format("%.2fx", value)
end

return Format
