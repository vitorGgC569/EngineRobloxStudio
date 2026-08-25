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

local player = Players.LocalPlayer

--[[
	The look, applied before anything is drawn.

	A daylight quarry: warm key, cool shadow, no fog to speak of. The whole
	reason `Visual` exists is that a generated game reads as generated when
	nobody changes the default lighting, and this is one call.
]]
Visual.autoQuality()

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
local top = UI.panel(screen, {
	anchor = Vector2.new(0.5, 0),
	pos = UDim2.fromScale(0.5, 0.02),
	size = UDim2.fromOffset(300, 76),
})
UI.list(top, { gap = 2 })

local coinLabel = UI.label(top, "0", {
	size = TEXT.xl,
	frameSize = UDim2.new(1, 0, 0, 34),
	align = Enum.TextXAlignment.Center,
})
local rateLabel = UI.label(top, "build a drill, a belt and a depot", {
	size = TEXT.sm,
	frameSize = UDim2.new(1, 0, 0, 20),
	align = Enum.TextXAlignment.Center,
	color = UI.theme.color.textDim,
})

-- ================================= the reason ===============================
--[[
	Where the breakdown goes.

	Off to the side and small, because it is a thing you read when you want to
	know rather than a thing that competes with the game. A tooltip nobody can
	find is a tooltip nobody reads, and a panel that shouts is one they close.
]]
local detail = UI.panel(screen, {
	anchor = Vector2.new(0, 0.5),
	pos = UDim2.fromScale(0.02, 0.5),
	size = UDim2.fromOffset(260, 112),
	-- Hidden until there is something to explain. An empty panel is a black
	-- rectangle taking up a third of the screen for no reason, which is what
	-- it was doing.
	visible = false,
})
UI.list(detail, { gap = 1 })

local detailLines = {}
for index = 1, 5 do
	detailLines[index] = UI.label(detail, "", {
		size = TEXT.sm,
		frameSize = UDim2.new(1, 0, 0, 18),
	})
end

-- ================================= the shop =================================
local shop = UI.panel(screen, {
	anchor = Vector2.new(1, 1),
	pos = UDim2.new(1, -16, 1, -16),
	size = UDim2.fromOffset(176, 196),
})
UI.list(shop, { gap = 4 })
UI.label(shop, "Build", {
	size = TEXT.md,
	frameSize = UDim2.new(1, 0, 0, 22),
})

--[[
	One button per machine, in chain order.

	Source, carry, refine, sell — the order the ore travels, not alphabetical
	and not by price. A shop sorted by cost teaches a player to buy the cheap
	thing twice; a shop sorted by the chain teaches them what a chain is.
]]
local ORDER = { "drill", "belt", "smelter", "depot" }
for _, machineId in ORDER do
	local machine = Content.machines[machineId]
	if not machine then
		continue
	end
	UI.button(shop, string.format("%s  %d", machine.label, machine.price), {
		size = UDim2.new(1, 0, 0, 30),
		onClick = function()
			--[[
				Where it lands is the server's problem.

				The client sends an intent, not a placement: it asks for a
				drill and the server decides whether there is room, whether
				this is their plot, and where the next free cell is. A client
				that chose the cell would be a client that could choose
				somebody else's cell.
			]]
			Net.fire("Build", { machine = machineId })
		end,
	})
end

-- ================================= listening ================================
Net.on("StateSync", function(profile)
	if typeof(profile) ~= "table" then
		return
	end
	coinLabel.Text = string.format("%d", profile.coins or 0)
end)

Net.on("LineSync", function(payload)
	if typeof(payload) ~= "table" then
		return
	end
	coinLabel.Text = string.format("%d", payload.coins or 0)
	rateLabel.Text = string.format("+%d every %ds", payload.perTick or 0, 2)

	local explain = payload.explain or {}
	detail.Visible = #explain > 0
	for index, label in detailLines do
		label.Text = explain[index] or ""
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
			Net.fire("ClaimDaily")
		elseif input.KeyCode == Enum.KeyCode.R then
			Net.fire("Rebirth")
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
