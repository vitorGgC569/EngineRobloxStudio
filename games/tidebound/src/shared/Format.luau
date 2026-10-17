--!strict
--[[
	Format — how numbers read.

	Money, weight and time appear in four places each and were never going to
	agree if every place was allowed its own `math.floor`. One module, one
	voice: `$1.2K`, `14.35 kg`, `07:40`.
]]

local Format = {}

local SUFFIXES = { "", "K", "M", "B" }

--: Compact money. The dock is a busy screen; "$12,450" does not fit a row
--: three times.
function Format.money(amount: number): string
	local negative = amount < 0
	amount = math.abs(amount)
	local suffix = 1
	while amount >= 1000 and suffix < #SUFFIXES do
		amount /= 1000
		suffix += 1
	end
	local text: string
	if suffix == 1 then
		text = tostring(math.floor(amount))
	else
		text = string.format("%.1f", amount):gsub("%.0$", "")
	end
	return (negative and "-$" or "$") .. text .. SUFFIXES[suffix]
end

--: Full money for tooltips, where precision is the point.
function Format.moneyFull(amount: number): string
	local text = tostring(math.floor(math.abs(amount)))
	local out = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	out = out:gsub("^,", "")
	return (amount < 0 and "-$" or "$") .. out
end

function Format.weight(kg: number): string
	if kg < 10 then
		return string.format("%.2f kg", kg)
	elseif kg < 100 then
		return string.format("%.1f kg", kg)
	end
	return string.format("%d kg", math.floor(kg + 0.5))
end

--: Clock time for the weather chip. The world's clock, not the player's.
function Format.hour(hour: number): string
	local h = math.floor(hour) % 24
	local m = math.floor((hour - math.floor(hour)) * 60)
	return string.format("%02d:%02d", h, m)
end

function Format.percent(alpha: number): string
	return string.format("%d%%", math.floor(alpha * 100 + 0.5))
end

function Format.duration(seconds: number): string
	if seconds < 60 then
		return string.format("%ds", math.floor(seconds + 0.5))
	end
	return string.format("%dm", math.floor(seconds / 60))
end

--: UTC date key applied by every server without agreeing first, the same
--: trick Leaderboard rounds use.
function Format.dayKey(offsetDays: number?): string
	local t = os.time() + (offsetDays or 0) * 86400
	return os.date("!%Y-%m-%d", t)
end

--: Days since the epoch for a date key, or for today when no key is given.
--:
--: A key is a calendar date, not an instant, so it is converted with
--: civil-date arithmetic rather than `os.time`, which would read the date
--: through the host timezone and can move it across midnight.
function Format.dayNumber(key: string?): number
	local captures = { string.match(key or "", "^(%d%d%d%d)%-(%d%d)%-(%d%d)$") }
	if #captures == 3 then
		local year = tonumber(captures[1]) :: number
		local month = tonumber(captures[2]) :: number
		local day = tonumber(captures[3]) :: number
		if month <= 2 then
			year -= 1
		end
		local era = math.floor(year / 400)
		local yearOfEra = year - era * 400
		local dayOfYear = math.floor((153 * (month + (if month > 2 then -3 else 9)) + 2) / 5) + day - 1
		local dayOfEra = yearOfEra * 365 + math.floor(yearOfEra / 4) - math.floor(yearOfEra / 100) + dayOfYear
		return era * 146097 + dayOfEra - 719468
	end
	return math.floor(os.time() / 86400)
end

return Format
