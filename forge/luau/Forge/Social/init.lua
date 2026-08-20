--!strict
--[[
	Social — the player's relationship with everyone outside this server.

	Three Roblox services that Forge had never touched, grouped because they
	answer one question between them: what may this particular player see, do
	and say, and who can they bring.

	  `PolicyService` decides what a player is *allowed* to be shown. Paid
	  items, random rewards and links to other experiences are all gated by
	  region and age, and the gate is not optional — it is compliance. A game
	  that shows a loot box to a player whose policy forbids it is a game with
	  a real problem, and nothing in Roblox stops you doing it by accident.

	  `SocialService` is invites. Roughly half of a Roblox game's growth is one
	  player pulling in a friend, and the prompt to do that is three lines
	  nobody writes.

	  `TextChatService` is chat, and more usefully, the filter. **Any** text a
	  player authored that another player will see must be filtered — names,
	  signs, pet names, guild tags. Not filtering is the single most common way
	  a Roblox game gets moderated off the platform.

		if Social.may(player, "paidItems") then ... end
		Social.inviteFriend(player)
		local safe = Social.filter(text, player)

	--- Fail closed --------------------------------------------------------

	Every question here fails closed. If the policy service cannot be reached,
	`may` returns false; if the filter errors, `filter` returns a redacted
	string rather than the original. Failing open on either would mean the one
	time the service is down is the one time a game shows a minor a paid item
	or broadcasts unfiltered text.
]]

local PolicyService = game:GetService("PolicyService")
local SocialService = game:GetService("SocialService")
local TextService = game:GetService("TextService")
local TextChatService = game:GetService("TextChatService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Signal = require(script.Parent.Core).Signal

local Social = {}

Social.config = {
	--: What an unfilterable string becomes. Visible, so it is noticed.
	redaction = "[unavailable]",
	policyCacheSeconds = 600,
}

Social.policyLoaded = Signal.new() -- (player, policy)
Social.invited = Signal.new() -- (player)

local policies: { [Player]: { at: number, value: any } } = {}
local stats = { policyReads = 0, policyFailures = 0, filtered = 0, filterFailures = 0, invites = 0 }

-- ================================== policy ==================================
--[[
	What this player's region and age permit.

	Cached per player, because `GetPolicyInfoForPlayerAsync` is a web call and
	the answer does not change during a session. A game that asks on every
	shop render makes a web call per frame.
]]
function Social.policy(player: Player): any?
	local cached = policies[player]
	if cached and os.clock() - cached.at < Social.config.policyCacheSeconds then
		return cached.value
	end

	local ok, info = pcall(function()
		return PolicyService:GetPolicyInfoForPlayerAsync(player)
	end)
	stats.policyReads += 1
	if not ok then
		stats.policyFailures += 1
		warn(string.format("[Social] policy lookup failed for %s: %s",
			player.Name, tostring(info)))
		return nil
	end

	policies[player] = { at = os.clock(), value = info }
	Social.policyLoaded:Fire(player, info)
	return info
end

--[[
	May this player be shown a thing?

	  `paidItems`      anything bought with real money or Robux
	  `randomItems`    loot boxes, crates, gacha — restricted in several regions
	  `leaveExperience` links out to other experiences
	  `trading`        player-to-player trade

	Returns **false** when the policy cannot be read. That is the whole design:
	a permission question that answers "yes" on failure is a permission
	question that eventually answers yes to the wrong person, and the cost of
	being wrong here is regulatory rather than cosmetic.
]]
function Social.may(player: Player, what: string): boolean
	local policy = Social.policy(player)
	if not policy then
		return false
	end

	if what == "paidItems" then
		return policy.ArePaidRandomItemsRestricted ~= true
			and policy.IsPaidItemTradingAllowed ~= false
	elseif what == "randomItems" then
		return policy.ArePaidRandomItemsRestricted ~= true
	elseif what == "trading" then
		return policy.IsPaidItemTradingAllowed == true
	elseif what == "leaveExperience" then
		local allowed = policy.AllowedExternalLinkReferences
		return typeof(allowed) == "table" and #allowed > 0
	elseif what == "subscriptions" then
		return policy.IsSubjectToChinaPolicies ~= true
	end

	warn(string.format("[Social] '%s' is not a policy this module knows", tostring(what)))
	return false
end

-- ================================== filter ==================================
--[[
	Make player-authored text safe to show another player.

	Every string a player wrote and another will read goes through here. Not
	filtering is the most common way a Roblox game gets taken down, and the
	surface is wider than chat: a pet's name, a sign, a guild tag, a custom
	message on a gift.

	`fromUserId` matters. Roblox filters differently depending on who wrote the
	text and who is about to see it, and passing the wrong author produces a
	filter that is legal but wrong.
]]
function Social.filter(text: string, from: Player, to: Player?): string
	if typeof(text) ~= "string" or text == "" then
		return ""
	end
	if not RunService:IsServer() then
		warn("[Social] filtering must happen on the server; a client filter is decoration")
		return Social.config.redaction
	end

	local ok, result = pcall(function()
		return TextService:FilterStringAsync(text, from.UserId)
	end)
	if not ok or not result then
		stats.filterFailures += 1
		--[[
			Redact rather than return the original.

			A filter that falls back to the raw string on error is not a filter
			— it is a filter that stops working exactly when Roblox is having a
			bad day, which is when the most text is flowing.
		]]
		return Social.config.redaction
	end

	local rendered
	local renderOk = pcall(function()
		if to then
			rendered = result:GetChatForUserAsync(to.UserId)
		else
			rendered = result:GetNonChatStringForBroadcastAsync()
		end
	end)
	if not renderOk or typeof(rendered) ~= "string" then
		stats.filterFailures += 1
		return Social.config.redaction
	end

	stats.filtered += 1
	return rendered
end

--[[
	Filter one string for every player who will see it.

	Roblox's filter is per viewer, so one broadcast string is genuinely several
	strings. Returning a map rather than one value is the honest shape of that,
	and a caller that ignores it and sends one string to everybody is a caller
	filtering for the wrong audience.
]]
function Social.filterForAll(text: string, from: Player): { [Player]: string }
	local out: { [Player]: string } = {}
	for _, viewer in Players:GetPlayers() do
		out[viewer] = Social.filter(text, from, viewer)
	end
	return out
end

-- ================================= invites ==================================
--[[
	Ask a player to bring a friend.

	Roughly half of a Roblox game's growth is one player inviting another, and
	the prompt is three lines that almost nobody writes. `CanSendGameInvite` is
	checked first because the prompt errors rather than no-ops when the player
	cannot send one.
]]
function Social.canInvite(player: Player): boolean
	local ok, allowed = pcall(function()
		return SocialService:CanSendGameInviteAsync(player)
	end)
	return ok and allowed == true
end

function Social.inviteFriend(player: Player, options: any?): boolean
	if not Social.canInvite(player) then
		return false
	end

	local prompt = nil
	if options then
		local ok, made = pcall(function()
			local invite = Instance.new("ExperienceInviteOptions")
			if options.message then
				invite.PromptMessage = options.message
			end
			if options.launchData then
				invite.LaunchData = options.launchData
			end
			return invite
		end)
		prompt = ok and made or nil
	end

	local ok = pcall(function()
		if prompt then
			SocialService:PromptGameInvite(player, prompt)
		else
			SocialService:PromptGameInvite(player)
		end
	end)
	if ok then
		stats.invites += 1
		Social.invited:Fire(player)
	end
	return ok
end

-- =================================== chat ===================================
--[[
	Say something as the game, in a player's own chat.

	Uses `TextChatService` when the experience is on it and falls back
	silently otherwise, because which chat version an experience uses is a
	place setting rather than a code decision and a module that assumes one
	breaks in half the projects that adopt it.
]]
function Social.system(player: Player, message: string, colour: Color3?)
	local channels = TextChatService:FindFirstChild("TextChannels")
	local general = channels and channels:FindFirstChild("RBXGeneral")
	if not general then
		return false
	end

	local body = message
	if colour then
		body = string.format('<font color="#%02X%02X%02X">%s</font>',
			math.floor(colour.R * 255), math.floor(colour.G * 255),
			math.floor(colour.B * 255), message)
	end

	local ok = pcall(function()
		(general :: any):DisplaySystemMessage(body)
	end)
	return ok
end

function Social.start()
	if not RunService:IsServer() then
		return
	end
	--[[
		Read policy on join rather than at the first shop render.

		The web call takes a moment, and the moment it takes is exactly when a
		player is looking at their first menu. Warming it on join means `may`
		is a table lookup by the time anything asks.
	]]
	Players.PlayerAdded:Connect(function(player)
		task.spawn(Social.policy, player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		policies[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(Social.policy, player)
	end
end

function Social.describe(): { [string]: any }
	local cached = 0
	for _ in policies do
		cached += 1
	end
	return {
		context = RunService:IsServer() and "server" or "client",
		policiesCached = cached,
		stats = table.clone(stats),
		failsClosed = true,
	}
end

return Social
