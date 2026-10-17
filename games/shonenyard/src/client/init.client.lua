--!strict
--[[
	The yard, as the player sees it.

	Three things this interface has to do, in the order a player needs them:

	**Say what changed.** Every readout is driven by a value the server owns.
	The client never keeps its own copy of ki: a client that does disagrees
	with the ledger the moment anything is spent, and it always disagrees in
	the player's favour on screen.

	**Give the loop one button.** The summon is the game. It is the largest
	thing on the screen, it is reachable with a thumb, and its first press
	costs nothing -- because 28% of the new players in the only real retention
	record here left before a first payout.

	**Make the reveal a moment.** A draw folded into a state broadcast arrives
	with everything else and reads as a number changing, and a number changing
	is not why anybody opens the next one. The reveal is its own remote, its
	own card, and it is coloured by rarity so a mythic is visibly not a common
	before a word is read.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Content = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Content"))

local UI = Forge.UI
local Net = Forge.Net

--[[
	The channels, defined in *this* VM.

	Without this line the client has no channel table: `Net.send` has nothing
	to send down and `Net.on` binds to nothing. It fails only when somebody
	presses a button, which is why it survived every automated gate here and
	was found by a person opening the game.
]]
require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Wire"))

local player = Players.LocalPlayer

--: Rarity, as a colour. Named here rather than in `Content` because `Content`
--: is server-shared data and a hex value is a client concern.
local RARITY_COLOUR = {
	[1] = Color3.fromRGB(148, 152, 162),
	[2] = Color3.fromRGB(104, 190, 126),
	[3] = Color3.fromRGB(88, 158, 232),
	[4] = Color3.fromRGB(206, 142, 62),
	[5] = Color3.fromRGB(226, 88, 108),
}

local gui = UI.mount("ShonenYard", { ignoreInset = false })

-- ================================================================== the bar

local top = UI.panel(gui, {
	size = UDim2.new(1, -24, 0, 62),
	pos = UDim2.new(0.5, 0, 0, 12),
	anchor = Vector2.new(0.5, 0),
})
UI.list(top, { horizontal = true, padding = 22, align = Enum.HorizontalAlignment.Center })

--[[
	One readout, bound to a player attribute the server writes.

	Attributes rather than a remote payload because the server publishes them
	anyway for a validator to read, and two channels for one number is how the
	HUD and the ledger come to disagree.
]]
local function readout(caption: string, attribute: string, format: (any) -> string)
	local holder = Instance.new("Frame")
	holder.Size = UDim2.fromOffset(150, 44)
	holder.BackgroundTransparency = 1
	holder.Parent = top

	local value = UI.label(holder, "-", {
		size = 26, align = Enum.TextXAlignment.Center,
		pos = UDim2.fromOffset(0, 0),
	})
	value.Size = UDim2.new(1, 0, 0, 26)

	local name = UI.label(holder, caption, {
		size = 13, align = Enum.TextXAlignment.Center,
		color = Color3.fromRGB(150, 152, 162),
		pos = UDim2.fromOffset(0, 26),
	})
	name.Size = UDim2.new(1, 0, 0, 16)

	local function refresh()
		local raw = player:GetAttribute(attribute)
		if raw ~= nil then
			value.Text = format(raw)
		end
	end
	player:GetAttributeChangedSignal(attribute):Connect(refresh)
	refresh()
	return value
end

local function short(value: number): string
	--: Compact, because a tycoon's numbers outgrow a readout fast and a HUD
	--: that wraps at ten thousand is a HUD that stops being read at ten
	--: thousand.
	local units = { { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }
	for _, unit in units do
		if value >= unit[1] then
			return string.format("%.1f%s", value / unit[1], unit[2])
		end
	end
	return string.format("%d", value)
end

readout("Ki", "ki", function(v) return short(v) end)
readout("per second", "perSecond", function(v) return string.format("%.1f", v) end)
readout("Shards", "shards", function(v) return short(v) end)
readout("Rank", "rank", function(v)
	local rank = Content.ranks[v]
	return rank and rank.name or tostring(v)
end)
readout("Roster", "collected", function(v)
	return string.format("%d/%d", v, #Content.fighters)
end)

-- ============================================================== the one button

--[[
	The loop, as the largest thing on the screen.

	Bottom centre and thumb-sized: this is pressed more than everything else in
	the game combined, and a control a phone player has to reach for is a
	control they stop pressing.
]]
local summon = UI.button(gui, "UNSEAL A SCROLL", {
	size = UDim2.fromOffset(300, 68),
	pos = UDim2.new(0.5, 0, 1, -40),
	anchor = Vector2.new(0.5, 1),
	color = Color3.fromRGB(198, 74, 92),
})
summon.TextSize = 22

local hint = UI.label(gui, "your first one is free", {
	size = 15, align = Enum.TextXAlignment.Center,
	color = Color3.fromRGB(180, 182, 190),
	pos = UDim2.new(0.5, 0, 1, -118),
})
hint.Size = UDim2.new(0, 320, 0, 20)
hint.AnchorPoint = Vector2.new(0.5, 1)

--[[
	One function, two callers: the button and the harness.

	`Net.define` being missing here meant this button did nothing for anybody,
	and it survived a clean compile, a clean `forge doctor`, eleven live
	scenarios and a dozen screenshots. The reason is narrow and worth naming:
	**every test in this project drove the RemoteEvent directly**, which
	exercises the server handler and skips the client's send path entirely. The
	half that was broken was the half nothing could reach.

	Studio refuses synthetic clicks (`virtual_input_refused`), so the way to
	reach a button from a test is a `BindableFunction` the client owns that
	calls the same function the button does. `client.invoke_bindable` reaches
	it, and it takes one `argument`, not a list.
]]
local function requestSummon(scroll: string?)
	Net.send("Summon", { scroll = scroll or "novice" })
	return true
end

summon.Activated:Connect(function()
	requestSummon("novice")
end)

do
	local press = Instance.new("BindableFunction")
	press.Name = "ShonenPressSummon"
	press.OnInvoke = requestSummon
	press.Parent = gui
end

-- ================================================================ the moment

--[[
	The reveal.

	A card that arrives, holds, and leaves. The hold is deliberate: a reveal
	that vanishes in under a second is one the player's eye never lands on,
	and the whole reason the summon is worth pressing again is that they saw
	what came out of the last one.
]]
local function reveal(payload: any)
	local colour = RARITY_COLOUR[payload.rarity] or RARITY_COLOUR[1]
	local rarity = Content.rarities[payload.rarity]

	local card = UI.panel(gui, {
		size = UDim2.fromOffset(360, 150),
		pos = UDim2.new(0.5, 0, 0.42, 0),
		anchor = Vector2.new(0.5, 0.5),
	})
	card.BackgroundColor3 = Color3.fromRGB(22, 22, 28)

	local stroke = Instance.new("UIStroke")
	stroke.Color = colour
	stroke.Thickness = 3
	stroke.Parent = card

	local band = UI.label(card, string.upper(rarity and rarity.name or "?"), {
		size = 14, color = colour, align = Enum.TextXAlignment.Center,
		pos = UDim2.fromOffset(0, 14),
	})
	band.Size = UDim2.new(1, 0, 0, 18)

	local name = UI.label(card, payload.name, {
		size = 28, align = Enum.TextXAlignment.Center,
		pos = UDim2.fromOffset(0, 38),
	})
	name.Size = UDim2.new(1, 0, 0, 34)

	local blurb = UI.label(card, payload.blurb or "", {
		size = 14, color = Color3.fromRGB(168, 170, 178),
		align = Enum.TextXAlignment.Center, pos = UDim2.fromOffset(16, 78),
	})
	blurb.Size = UDim2.new(1, -32, 0, 40)
	blurb.TextWrapped = true

	if payload.isNew then
		local tag = UI.label(card, "NEW", {
			size = 13, color = Color3.fromRGB(240, 240, 240),
			align = Enum.TextXAlignment.Center, pos = UDim2.fromOffset(0, 124),
		})
		tag.Size = UDim2.new(1, 0, 0, 16)
	end

	--: Arrives from slightly small, which reads as *appearing* rather than as
	--: being switched on. A rarer draw holds longer, because the thing worth
	--: looking at should be on screen long enough to look at.
	card.Size = UDim2.fromOffset(300, 120)
	TweenService:Create(card, TweenInfo.new(0.18, Enum.EasingStyle.Back,
		Enum.EasingDirection.Out), { Size = UDim2.fromOffset(360, 150) }):Play()

	local hold = 1.4 + (payload.rarity or 1) * 0.35
	task.delay(hold, function()
		local out = TweenService:Create(card, TweenInfo.new(0.22), {
			BackgroundTransparency = 1,
		})
		out:Play()
		out.Completed:Wait()
		card:Destroy()
	end)
end

Net.on("Summoned", reveal)

-- ================================================================== notices

Net.on("Notify", function(payload)
	UI.toast(tostring(payload.text))
end)

--[[
	The nudge.

	`Loop.Hatch` reports what is going wrong for this player *now* -- no first
	payout, dead time, a second rung out of reach. Showing it is the difference
	between finding the hole in a report next month and closing it in the
	session it opened.
]]
local nudge = UI.label(gui, "", {
	size = 16, align = Enum.TextXAlignment.Center,
	color = Color3.fromRGB(226, 188, 96),
	pos = UDim2.new(0.5, 0, 1, -150),
})
nudge.Size = UDim2.new(0, 460, 0, 22)
nudge.AnchorPoint = Vector2.new(0.5, 1)

local NUDGE = {
	first_payout_late = "Press the button. The first scroll costs nothing.",
	dead_time = "Put a fighter on the post -- an idle yard earns nothing.",
	tier_two_unreached = "You can afford a rank. Take it.",
}

Net.on("Findings", function(payload)
	local first = (payload.findings or {})[1]
	nudge.Text = first and (NUDGE[first.rule] or "") or ""
end)

Net.on("StateSync", function(state)
	--: The hint stops lying once the first scroll is spent.
	hint.Text = if state.summons and state.summons > 0
		then string.format("%d unsealed  ·  %s",
			state.summons, state.rankName or "")
		else "your first one is free"
end)

print("[shonenyard] interface up")
