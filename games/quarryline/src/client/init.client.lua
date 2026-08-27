--!strict
--[[
	The client — a HUD that explains the number.

	A tycoon lives or dies on one thing: whether the player understands why
	their income is what it is. A bar that says "412 coins" is a score. A bar
	that says "412 coins, your belts are the bottleneck" is a game, because it
	names the next decision.

	So this deliberately shows the *breakdown* the server already computed
	rather than recomputing anything. The payout pipeline on the server keeps
	its own audit trail; the client renders it. Two computations of the same
	number is two numbers, and they disagree in front of the player at exactly
	the wrong moment.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Net = Forge.Net
local Audio = Forge.Audio
local Feel = Forge.Feel
local UI = Forge.UI
local Visual = Forge.Visual
local Platform = Forge.Platform
local Clock = Forge.Core.Clock

--: The theme's own type scale. Reading the token rather than passing a
--: name, because `UI.label` takes a pixel size and a string silently
--: becomes the TextSize — which is an error at the moment it is drawn.
local TEXT = UI.theme.text

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Content = require(Shared:WaitForChild("Content"))
local Channels = require(Shared:WaitForChild("Channels"))
local Icons = require(Shared:WaitForChild("Icons"))
local SoundBank = require(Shared:WaitForChild("Sound"))
local Machines = require(script:WaitForChild("Machines"))

local player = Players.LocalPlayer

--[[
	The look, applied before anything is drawn.

	A daylight quarry: warm key, cool shadow, no fog to speak of. The whole
	reason `Visual` exists is that a generated game reads as generated when
	nobody changes the default lighting, and this is one call.
]]
Visual.autoQuality()

--[[
	Sound and motion, before anything is drawn.

	`Feel.mount` is what binds the camera hooks -- shake, hitstop, punch -- and
	without it `Feel.shake` is a function that records trauma nobody reads. It
	was never called, which is why placing a machine had no weight even after
	the shake was written.

	`Machines.start` adopts every tagged machine already in the world and every
	one placed afterwards, and starts the one Heartbeat loop that animates all
	of them.
]]
--[[
	The channels, before anything tries to listen on one.

	`Net.on` errors on a name this VM has never defined, and the client had
	defined none: the first handler below threw and took every handler after it
	with it. The HUD is built above them, which is why it rendered perfectly and
	then never changed a single value again.
]]
Channels.define(Net)

SoundBank.register(Audio)
Feel.mount()
Machines.start()

--[[
	The house style, set before a single widget is built.

	`UI.theme` is explicitly documented as override-first-then-build, and this
	game never overrode anything -- so every panel came out in the engine's
	default SourceSans at default weights, which is why the HUD read as
	"functional, not designed". Three lines change the whole interface.

	GothamSSm for everything the player reads at a glance, and the mono face for
	the money. A balance that changes every two seconds in a proportional font
	makes the digits jump sideways as they change width; a monospaced one holds
	still, which is the difference between a counter and a flicker.
]]
UI.theme.font.body = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Medium)
UI.theme.font.bold = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold)

local COLOR = UI.theme.color

local screen = UI.mount("QuarryHud")

-- =================================== the bar ================================
--[[
	Every panel gets a layout, and every label gets a height.

	`UI.label` fills its parent by default, so three labels in one panel are
	three full-size labels stacked on top of each other — which is exactly what
	the first screenshot showed: a black rectangle with one line of text
	crammed into the corner and everything else underneath it. A `UIListLayout`
	and an explicit `frameSize` is the whole fix, and it is the difference
	between a HUD and a smear.
]]
--[[
	Every widget gets a name, because an unnamed interface cannot be addressed.

	`UI.panel` and `UI.button` both take one and this HUD passed none, so every
	panel was called `Panel` and every button `Button`. Four Build buttons at
	the identical path, and `QuarryHud.Panel` resolving to whichever panel came
	first -- which is the balance bar, and has no button in it.

	Found by trying to click Build from outside the game during a two-player
	test: the click could not name its target. A tool could not press it, a
	scenario could not assert on it, and a person reading the Explorer sees six
	things called Panel.
]]
local top = UI.panel(screen, {
	name = "Balance",
	anchor = Vector2.new(0.5, 0),
	pos = UDim2.fromScale(0.5, 0.025),
	size = UDim2.fromOffset(232, 66),
})
UI.list(top, { gap = 0 })

--[[
	The balance, in the mono face and the gold.

	Gold because it is money and every player already reads gold as money
	without being told; mono because it changes every two seconds and
	proportional digits shift the whole number sideways when a 1 becomes an 8.
]]
local coinLabel = UI.label(top, "0", {
	name = "Coins",
	size = TEXT.xl,
	frameSize = UDim2.new(1, 0, 0, 36),
	align = Enum.TextXAlignment.Center,
	color = COLOR.gold,
	font = UI.theme.font.mono,
})

--[[
	The income line carries the alarm.

	It is the only place in the interface that can tell a player their factory
	has stopped, so it changes colour rather than only wording: green while the
	line pays, amber the moment it does not. Colour is read before text is.
]]
--[[
	The coin, beside the number.

	Parented to the balance label rather than laid out beside it, because the
	panel's list layout would otherwise give the icon a row of its own and push
	the number down. An icon that belongs to a number should travel with it.

	`ScaleType = Fit` and a square frame: these are 128px sources drawn at 22,
	and anything else stretches line art.
]]
do
	local coinIcon = Instance.new("ImageLabel")
	coinIcon.Name = "CoinIcon"
	coinIcon.BackgroundTransparency = 1
	coinIcon.Size = UDim2.fromOffset(22, 22)
	coinIcon.AnchorPoint = Vector2.new(1, 0.5)
	coinIcon.Position = UDim2.new(0.5, -46, 0.5, 0)
	coinIcon.ScaleType = Enum.ScaleType.Fit
	coinIcon.Image = Icons.hudIcon("coin") or ""
	coinIcon.ImageColor3 = COLOR.gold
	coinIcon.Parent = coinLabel
end

local rateLabel = UI.label(top, "starting up", {
	name = "Rate",
	size = TEXT.sm,
	frameSize = UDim2.new(1, 0, 0, 18),
	align = Enum.TextXAlignment.Center,
	color = COLOR.textDim,
})

-- ================================= the reason ===============================
--[[
	Where the breakdown goes.

	Off to the side and small, because it is a thing you read when you want to
	know rather than a thing that competes with the game. A tooltip nobody can
	find is a tooltip nobody reads, and a panel that shouts is one they close.
]]
local detail = UI.panel(screen, {
	name = "Why",
	anchor = Vector2.new(0, 1),
	pos = UDim2.new(0, 16, 1, -16),
	size = UDim2.fromOffset(268, 116),
	-- Hidden until there is something to explain. An empty panel is a dark
	-- rectangle taking up a corner of the screen for no reason.
	visible = false,
})
UI.list(detail, { gap = 2 })

--[[
	Moved from the middle of the left edge to the bottom corner.

	It used to sit at 50% height, directly over the plots, so the one panel
	explaining the factory was drawn on top of the factory. The bottom corner is
	where a player expects a readout and where nothing important is rendered.
]]
UI.label(detail, "WHY", {
	name = "WhyTitle",
	size = TEXT.xs,
	frameSize = UDim2.new(1, 0, 0, 14),
	color = COLOR.accent,
	font = UI.theme.font.bold,
})

local detailLines = {}
for index = 1, 4 do
	detailLines[index] = UI.label(detail, "", {
		name = string.format("Reason%d", index),
		size = TEXT.sm,
		frameSize = UDim2.new(1, 0, 0, 18),
		color = index == 1 and COLOR.text or COLOR.textDim,
	})
end

-- ================================= the shop =================================
local shop = UI.panel(screen, {
	name = "Shop",
	anchor = Vector2.new(1, 1),
	pos = UDim2.new(1, -16, 1, -16),
	size = UDim2.fromOffset(196, 216),
})
UI.list(shop, { gap = 5 })
UI.label(shop, "BUILD", {
	name = "ShopTitle",
	size = TEXT.xs,
	frameSize = UDim2.new(1, 0, 0, 16),
	color = COLOR.accent,
	font = UI.theme.font.bold,
})

--[[
	One button per machine, in chain order.

	Source, carry, refine, sell -- the order the ore travels, not alphabetical
	and not by price. A shop sorted by cost teaches a player to buy the cheap
	thing twice; a shop sorted by the chain teaches them what a chain is.
]]
local ORDER = {
	"drill", "belt", "smelter", "depot",
	--: Tiers after the base row rather than interleaved: a player reads the
	--: chain first and the ladder second, and a shop that opens on twelve
	--: buttons teaches neither.
	"drill_mk2", "belt_mk2", "smelter_mk2", "depot_mk2",
	"drill_mk3", "belt_mk3", "smelter_mk3", "depot_mk3",
}

--: Kept so the affordability pass can dim what the player cannot buy.
local shopRows: { { button: TextButton, price: number, machine: any } } = {}

for _, machineId in ORDER do
	local machine = Content.machines[machineId]
	if not machine then
		continue
	end

	local button = UI.button(shop, string.format("   %s   %d", machine.label, machine.price), {
		--: Named after the machine, so `Shop.Buy_drill` is a path a tool, a
		--: scenario or a person can reach without counting children.
		name = "Buy_" .. machineId,
		size = UDim2.new(1, 0, 0, 34),
		onClick = function()
			if Audio.defined("cue.click") then
				Audio.play("cue.click")
			end
			--[[
				Where it lands is the server's problem.

				The client sends an intent, not a placement: it asks for a
				drill and the server decides whether there is room, whether
				this is their plot, and where the next free cell is. A client
				that chose the cell would be a client that could choose
				somebody else's cell.
			]]
			Net.send("Build", { machine = machineId })
		end,
	})

	--[[
		A stripe in the machine's own colour, down the left edge.

		The machines on the plot are told apart by colour and silhouette, and
		until now the shop shared neither -- four identical grey rows of text.
		Carrying the colour across means the button and the thing it builds are
		recognisably the same object, which is the cheapest legibility there is.
	]]
	local stripe = Instance.new("Frame")
	stripe.Name = "Stripe"
	stripe.Size = UDim2.new(0, 3, 1, -8)
	stripe.Position = UDim2.new(0, 4, 0, 4)
	stripe.BorderSizePixel = 0
	stripe.BackgroundColor3 = machine.colour
	stripe.ZIndex = (button.ZIndex or 1) + 1
	stripe.Parent = button

	--[[
		The machine's own icon, tinted to the machine's own colour.

		The stripe stays. It is the thing that still reads when the icon has not
		finished moderation, or is missing because nobody uploaded one for a
		machine added later -- and a row with a colour and no picture is a row,
		while a row with neither is a mystery.
	]]
	local glyph = Icons.hudIcon(machineId)
	if glyph then
		local icon = Instance.new("ImageLabel")
		icon.Name = "Glyph"
		icon.BackgroundTransparency = 1
		icon.Size = UDim2.fromOffset(20, 20)
		icon.AnchorPoint = Vector2.new(0, 0.5)
		icon.Position = UDim2.new(0, 12, 0.5, 0)
		icon.ScaleType = Enum.ScaleType.Fit
		icon.Image = glyph
		icon.ImageColor3 = machine.colour
		icon.ZIndex = (button.ZIndex or 1) + 1
		icon.Parent = button
	end

	table.insert(shopRows, { button = button, price = machine.price, machine = machine })
end

--[[
	Dim what the player cannot afford yet.

	A shop that looks identical whether you have 10 coins or 10,000 makes the
	player do the arithmetic themselves every time. Greying the unaffordable
	rows answers "what can I do right now" without a single word.
]]
local function refreshAffordability(coins: number)
	for _, row in shopRows do
		local affordable = coins >= row.price
		row.button.TextColor3 = affordable and COLOR.text or COLOR.textDim
		row.button.BackgroundTransparency = affordable and 0 or 0.45
		local stripe = row.button:FindFirstChild("Stripe")
		if stripe and stripe:IsA("Frame") then
			stripe.BackgroundTransparency = affordable and 0 or 0.55
		end
	end
end

-- ================================= listening ================================
Net.on("StateSync", function(profile)
	if typeof(profile) ~= "table" then
		return
	end
	local coins = tonumber(profile.coins) or 0
	coinLabel.Text = string.format("%d", coins)
	refreshAffordability(coins)
end)

Net.on("LineSync", function(payload)
	if typeof(payload) ~= "table" then
		return
	end
	local coins = tonumber(payload.coins) or 0
	local perTick = tonumber(payload.perTick) or 0
	coinLabel.Text = string.format("%d", coins)
	refreshAffordability(coins)

	--: Green while it pays, amber when it does not. The wording alone was the
	--: only signal a line had stalled, and nobody reads a subtitle.
	if perTick > 0 then
		rateLabel.Text = string.format("+%d every 2s", perTick)
		rateLabel.TextColor3 = COLOR.good
	else
		rateLabel.Text = "line stalled"
		rateLabel.TextColor3 = COLOR.warning
	end

	local explain = payload.explain or {}
	detail.Visible = #explain > 0
	for index, label in detailLines do
		label.Text = explain[index] or ""
	end
end)

--[[
	Somebody's line just paid out; show it where it happened.

	Every client hears every sale, and `Machines.sold` filters to the depot on
	that plot -- so the payout appears on the crate that earned it rather than
	only as a number changing in the corner.
]]
Net.on("Sold", function(payload)
	if typeof(payload) == "table" and payload.plot then
		Machines.sold(tostring(payload.plot), tonumber(payload.amount) or 0)
	end
end)

Net.on("Built", function(payload)
	if typeof(payload) == "table" and typeof(payload.at) == "Vector3" then
		Machines.built(payload.at)
	end
end)

Net.on("Notify", function(payload)
	if typeof(payload) == "table" and payload.text then
		UI.toast(tostring(payload.text))
	end
end)

-- ================================== hotkeys =================================
--[[
	Keys for the things a player does every few seconds.

	Only on a device that has keys. `Platform` answers that from the viewport
	rather than from a platform enum, which is right: a small window on a
	desktop has the same problem a phone does.
]]
if UserInputService.KeyboardEnabled then
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.E then
			Net.send("ClaimDaily")
		elseif input.KeyCode == Enum.KeyCode.R then
			Net.send("Rebirth")
		end
	end)
end

--[[
	Tell the server what this screen is.

	`Platform.audit` measures the layout on the device it is actually on —
	touch targets under the minimum, anything off-screen — and the server
	records it. That is how a phone problem becomes a number in a dashboard
	rather than a complaint in a review.
]]
task.delay(5, function()
	local report = Platform.audit()
	if report and report.tooSmall and report.tooSmall > 0 then
		warn(string.format("[quarryline] %d touch targets under the minimum",
			report.tooSmall))
	end
end)

print(string.format("[quarryline] client ready at %s", Clock.format(0)))
