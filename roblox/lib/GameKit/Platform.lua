--!strict
--- Badges, teams, teleports and language: the platform a game sits on.
---
--- All four were at zero. Each is a thin wrapper over a Roblox service, and each
--- has one trap that turns "it works in Studio" into "it is broken in
--- production" -- which is why they are here together rather than left to a
--- caller who would meet each trap once.
---
---   badges       awarding needs the server and costs a call every time
---   teams        two teams sharing a colour merge, silently
---   teleport     a failed teleport strands a player with no error on screen
---   language     a translator that falls back to the key is worse than none
---
--- **Nothing here creates a badge or a place.** Those are made on the website
--- and their ids arrive at these functions, the same as game passes.

local BadgeService = game:GetService("BadgeService")
local TeleportService = game:GetService("TeleportService")
local Teams = game:GetService("Teams")
local LocalizationService = game:GetService("LocalizationService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Platform = {}

-- -- badges ------------------------------------------------------------------

--- Who already has what, so the same badge is not looked up twice a second.
---
--- `UserHasBadgeAsync` is a web call. Awarding a badge on every kill without
--- caching is how a game hits the request budget and starts failing the awards
--- it actually needs.
local badgeCache: { [string]: boolean } = {}

local function badgeKey(userId: number, badgeId: number): string
	return tostring(userId) .. ":" .. tostring(badgeId)
end

function Platform.hasBadge(player: Player, badgeId: number): boolean
	local key = badgeKey(player.UserId, badgeId)
	local cached = badgeCache[key]
	if cached ~= nil then
		return cached
	end
	local ok, owned = pcall(function()
		return BadgeService:UserHasBadgeAsync(player.UserId, badgeId)
	end)
	if not ok then
		-- Unknown is not the same as "does not have it". Returning false on a
		-- failed lookup makes the caller award again, which is a wasted call at
		-- best and a duplicate notification at worst.
		return false
	end
	badgeCache[key] = owned
	return owned
end

--- Award a badge, once.
---
--- Server only: `AwardBadge` from a LocalScript silently does nothing, and the
--- player never finds out. This says so instead.
function Platform.award(player: Player, badgeId: number): (boolean, string?)
	if not RunService:IsServer() then
		return false, "badges can only be awarded from the server"
	end
	if type(badgeId) ~= "number" or badgeId <= 0 then
		return false, "badgeId must be a positive integer from the website"
	end
	if Platform.hasBadge(player, badgeId) then
		return false, "already awarded"
	end
	local ok, err = pcall(function()
		BadgeService:AwardBadge(player.UserId, badgeId)
	end)
	if not ok then
		return false, tostring(err)
	end
	badgeCache[badgeKey(player.UserId, badgeId)] = true
	return true, nil
end

-- -- teams --------------------------------------------------------------------

--- Build the teams a game declares.
---
--- **Two teams cannot share a `TeamColor`.** Roblox keys teams by BrickColor,
--- so assigning the same colour twice merges them and every player on the
--- second ends up on the first -- with no error anywhere. The collision is
--- caught here.
function Platform.teams(declared: { { name: string, colour: string, autoAssign: boolean? } })
	: (boolean, { string })

	local problems, seen = {}, {}
	for index, entry in ipairs(declared) do
		local label = tostring(entry.name or ("team " .. index))
		if type(entry.name) ~= "string" or entry.name == "" then
			table.insert(problems, ("team %d has no name"):format(index))
		end
		local colour = BrickColor.new(entry.colour or "Medium stone grey")
		if seen[colour.Name] ~= nil then
			table.insert(problems, ("%s and %s both use %s; Roblox keys teams by "
				.. "colour, so they would merge"):format(
				seen[colour.Name], label, colour.Name))
		else
			seen[colour.Name] = label
		end
	end
	if #problems > 0 then
		return false, problems
	end

	for _, existing in ipairs(Teams:GetTeams()) do
		existing:Destroy()
	end
	for _, entry in ipairs(declared) do
		local team = Instance.new("Team")
		team.Name = entry.name
		team.TeamColor = BrickColor.new(entry.colour or "Medium stone grey")
		team.AutoAssignable = entry.autoAssign ~= false
		team.Parent = Teams
	end
	return true, {}
end

function Platform.teamReport(): { [string]: any }
	local out = {}
	for _, team in ipairs(Teams:GetTeams()) do
		table.insert(out, {
			name = team.Name,
			colour = team.TeamColor.Name,
			autoAssignable = team.AutoAssignable,
			players = #team:GetPlayers(),
		})
	end
	return { teams = out, count = #out }
end

-- -- teleport -----------------------------------------------------------------

--- Send players to another place, and notice when it fails.
---
--- **A failed teleport strands the player.** `TeleportAsync` can fail for
--- flooding, an unpublished target or a place in a different universe, and
--- without a `TeleportInitFailed` handler the player simply stands there with no
--- message. Installing that handler is the whole reason not to call the service
--- directly.
function Platform.teleport(players: { Player }, placeId: number,
	data: { [string]: any }?): (boolean, string?)

	if not RunService:IsServer() then
		return false, "teleports are started from the server"
	end
	if type(placeId) ~= "number" or placeId <= 0 then
		return false, "placeId must be a positive integer; places are made on the website"
	end

	local options = Instance.new("TeleportOptions")
	if data ~= nil then
		options:SetTeleportData(data)
	end

	local ok, err = pcall(function()
		TeleportService:TeleportAsync(placeId, players, options)
	end)
	if not ok then
		return false, tostring(err)
	end
	return true, nil
end

--- Install the failure handler once, so a stranded player is told.
function Platform.watchTeleports(notify: ((Player, string) -> ())?): RBXScriptConnection?
	if not RunService:IsServer() then
		return nil
	end
	return TeleportService.TeleportInitFailed:Connect(function(player, result, message)
		warn(("[Platform] teleport failed for %s: %s (%s)")
			:format(player.Name, tostring(message), result.Name))
		if notify ~= nil then
			pcall(notify, player, tostring(message))
		end
		player:SetAttribute("TeleportFailed", tostring(message))
	end)
end

-- -- language ------------------------------------------------------------------

local phrases: { [string]: { [string]: string } } = {}
local sourceLocale = "en"

--- Declare the game's text, keyed by phrase then locale.
---
--- **A translator that falls back to the key is worse than no translation.**
--- A player seeing `shop.buy.confirm` on a button knows something is broken; a
--- player seeing English in a Portuguese game just thinks it was not translated.
--- So `text()` falls back to the source locale, and `Platform.missing()` names
--- every phrase that has no entry for a locale -- which is the list somebody
--- can actually act on.
function Platform.declareText(table_: { [string]: { [string]: string } }, source: string?)
	phrases = table_
	sourceLocale = source or "en"
end

function Platform.localeFor(player: Player): string
	local ok, locale = pcall(function()
		return player.LocaleId
	end)
	if not ok or type(locale) ~= "string" or locale == "" then
		return sourceLocale
	end
	-- `pt-br` and `pt` should find the same phrase; match the language first.
	return string.lower(string.sub(locale, 1, 2))
end

function Platform.text(key: string, locale: string?): string
	local entry = phrases[key]
	if entry == nil then
		return key
	end
	local wanted = locale or sourceLocale
	return entry[wanted] or entry[string.sub(wanted, 1, 2)]
		or entry[sourceLocale] or key
end

--- Every phrase with no entry for a locale. The actionable half of localisation.
function Platform.missing(locale: string): { string }
	local gaps = {}
	for key, entry in pairs(phrases) do
		if entry[locale] == nil and entry[string.sub(locale, 1, 2)] == nil then
			table.insert(gaps, key)
		end
	end
	table.sort(gaps)
	return gaps
end

function Platform.locales(): { string }
	local seen: { [string]: boolean } = {}
	for _, entry in pairs(phrases) do
		for locale in pairs(entry) do
			seen[locale] = true
		end
	end
	local out = {}
	for locale in pairs(seen) do
		table.insert(out, locale)
	end
	table.sort(out)
	return out
end

function Platform.report(): { [string]: any }
	local count = 0
	for _ in pairs(phrases) do
		count += 1
	end
	local coverage: { [string]: number } = {}
	for _, locale in ipairs(Platform.locales()) do
		coverage[locale] = count - #Platform.missing(locale)
	end
	return {
		teams = Platform.teamReport(),
		phrases = count,
		locales = Platform.locales(),
		coverage = coverage,
		sourceLocale = sourceLocale,
		badgeLookupsCached = (function()
			local n = 0
			for _ in pairs(badgeCache) do n += 1 end
			return n
		end)(),
	}
end

return Platform
