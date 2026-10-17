--!strict
--[[
	Hud — what the last StateSync said.

	Carried coal, beacon seconds, elapsed and the outcome are drawn from that
	packet. Nothing here counts down. A local burn would disagree with Sim
	the moment a frame was dropped, and the buttons only name an intent.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local UI = Forge.UI

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Hud = {}

type Sync = {
	carried: number?,
	beacons: { [string]: number }?,
	elapsed: number?,
	outcome: string?,
}

local function shown(seconds: number): string
	return tostring(math.max(0, math.floor(seconds)))
end

function Hud.start(Net: any)
	local T = UI.theme
	local screen = UI.mount("BeaconmileHud")

	local panel = UI.panel(screen, {
		name = "Shift",
		size = UDim2.fromOffset(280, 0),
		pos = UDim2.fromOffset(T.space.lg, T.space.lg),
		padding = T.space.md,
	})
	panel.AutomaticSize = Enum.AutomaticSize.Y

	local body = Instance.new("Frame")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.Size = UDim2.new(1, 0, 0, 0)
	body.AutomaticSize = Enum.AutomaticSize.Y
	body.Parent = panel
	UI.list(body, { gap = T.space.sm })

	local carried = UI.label(body, "Carvão 0", {
		name = "Carried",
		size = T.text.md,
		font = T.font.bold,
		frameSize = UDim2.new(1, 0, 0, 20),
	})
	carried.LayoutOrder = 1

	local clock = UI.label(body, string.format("0 / %d", Config.shiftSeconds), {
		name = "Clock",
		size = T.text.sm,
		color = T.color.textDim,
		frameSize = UDim2.new(1, 0, 0, 16),
	})
	clock.LayoutOrder = 2

	local shiftBar = UI.bar(body, {
		name = "Shift",
		size = UDim2.new(1, 0, 0, 8),
		color = T.color.accent,
	})
	shiftBar.holder.LayoutOrder = 3
	shiftBar:setInstant(0)

	local outcome = UI.label(body, "", {
		name = "Outcome",
		size = T.text.sm,
		font = T.font.bold,
		frameSize = UDim2.new(1, 0, 0, 16),
	})
	outcome.LayoutOrder = 4

	local remaining: { [string]: TextLabel } = {}

	for index, beacon in Config.beacons do
		local id = beacon.id :: string
		local row = Instance.new("Frame")
		row.Name = id
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, 30)
		row.LayoutOrder = 10 + index
		row.Parent = body

		local title = if type(beacon.label) == "string" then beacon.label else id
		local label = UI.label(row, title .. "  —", {
			name = "Remaining",
			size = T.text.sm,
			frameSize = UDim2.new(1, -78, 1, 0),
		})
		remaining[id] = label

		UI.button(row, "Alimentar", {
			name = "Feed",
			size = UDim2.fromOffset(70, 28),
			pos = UDim2.new(1, 0, 0.5, 0),
			anchor = Vector2.new(1, 0.5),
			onClick = function()
				Net.send("FeedBeacon", { beaconId = id })
			end,
		})
	end

	local take = UI.button(body, "Pegar carvão", {
		name = "Take",
		size = UDim2.new(1, 0, 0, 32),
		onClick = function()
			Net.send("TakeCoal", { confirm = true })
		end,
	})
	take.LayoutOrder = 100

	local again = UI.button(body, "De novo", {
		name = "Again",
		size = UDim2.new(1, 0, 0, 32),
		onClick = function()
			Net.send("PlayAgain", { confirm = true })
		end,
	})
	again.LayoutOrder = 101
	again.Visible = false

	Net.on("StateSync", function(payload: any)
		if type(payload) ~= "table" then
			return
		end
		local sync = payload :: Sync
		local coal = if type(sync.carried) == "number" then sync.carried else 0
		carried.Text = string.format("Carvão %d", coal)

		local elapsed = if type(sync.elapsed) == "number" then sync.elapsed else 0
		local span = Config.shiftSeconds
		clock.Text = string.format("%s / %d", shown(elapsed), span)
		shiftBar:set(if span > 0 then math.clamp(elapsed / span, 0, 1) else 0)

		local result = if type(sync.outcome) == "string" then sync.outcome else "running"
		outcome.Text = if result == "won" then "Os faróis aguentaram" elseif result == "lost" then "Um farol apagou" else ""
		outcome.TextColor3 = if result == "won"
			then T.color.good
			elseif result == "lost" then T.color.danger
			else T.color.text
		again.Visible = result == "won" or result == "lost"

		local beacons = if type(sync.beacons) == "table" then sync.beacons else {}
		for _, beacon in Config.beacons do
			local id = beacon.id :: string
			local title = if type(beacon.label) == "string" then beacon.label else id
			local seconds = beacons[id]
			local label = remaining[id]
			if type(seconds) == "number" then
				label.Text = string.format("%s  %ss", title, shown(seconds))
			else
				label.Text = title .. "  —"
			end
		end
	end)
end

return Hud
