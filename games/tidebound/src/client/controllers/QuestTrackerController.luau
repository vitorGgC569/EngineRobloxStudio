--!strict
--[[
	QuestTrackerController — one focus, one line, one light.

	The HUD line and the beam answer the same question -- "where do I go
	next?" -- from the same reading of the save, so they can never disagree.
	`QuestFocus` does the choosing; this controller only draws.

	The beam is a client-only part: not replicated, not physical, not
	queryable, invisible to everyone but this player. A light you can walk
	toward should not be a world object other players can stand on.

	When a quest is finished the beam walks home to the harbor and turns
	gold, because the last step of an errand is the claiming, and the
	claiming lives at the Quests board.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local Debug = Forge.Debug

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local QuestFocus = require(Shared.QuestFocus)
local SeaPlan = require(Shared.SeaPlan)

local state = require(script.Parent.Parent.state)

local QuestTrackerController = {}

local ACCENT = Color3.fromRGB(94, 198, 214)
local GOLD = Color3.fromRGB(236, 196, 108)

export type HudApi = { setQuest: (string?) -> () }

function QuestTrackerController.start(hud: HudApi)
	local beacon = Instance.new("Part")
	beacon.Name = "QuestBeacon"
	beacon.Anchored = true
	beacon.CanCollide = false
	beacon.CanQuery = false
	beacon.CanTouch = false
	beacon.CastShadow = false
	beacon.Material = Enum.Material.Neon
	beacon.Transparency = 1
	beacon.Size = Vector3.new(2.4, 88, 2.4)
	beacon.Color = ACCENT
	beacon.Parent = Workspace

	local tag = Instance.new("BillboardGui")
	tag.Name = "Focus"
	tag.Size = UDim2.fromOffset(280, 44)
	tag.StudsOffsetWorldSpace = Vector3.new(0, 46, 0)
	tag.LightInfluence = 0
	tag.MaxDistance = 1200
	tag.Enabled = false
	tag.Parent = beacon

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.SourceSansBold
	label.Text = ""
	label.TextColor3 = Color3.fromRGB(226, 238, 240)
	label.TextScaled = true
	label.TextStrokeTransparency = 0.35
	label.Parent = tag

	local function paint(focus: any)
		if not focus then
			--: Parts have no `Visible` (measured: the tracker died on it and
			--: the beam stayed up). Hidden means fully transparent, and the
			--: billboard rides the same state so the label never outlives
			--: its light.
			beacon.Transparency = 1
			tag.Enabled = false
			return
		end
		--: A finished quest points at the harbor, because the last leg of
		--: an errand is the claiming and the board is at the harbor.
		local zoneId = if focus.done then "shallows" else focus.zoneId
		local zone = Config.zone(zoneId)
		if not zone then
			zone = Config.zone("shallows")
		end
		local point = SeaPlan.dockPoint(zone)
		beacon.CFrame = CFrame.new(point.X, Config.waterLevel + 44, point.Y)
		beacon.Color = if focus.done then GOLD else ACCENT
		label.Text = if focus.done then "Claim: " .. focus.label else focus.label
		beacon.Transparency = 0.86
		tag.Enabled = true
	end

	local function apply()
		local profile = state.get()
		if not profile then
			return
		end
		--: Config order is shallow-to-deep, so the last entry is the deepest
		--: water this player owns -- the honest fallback for a quest that
		--: names no water of its own.
		local zones = {}
		for _, zone in Config.zones do
			if profile.zones and profile.zones[zone.id] then
				table.insert(zones, zone.id)
			end
		end
		local focus = QuestFocus.pick(profile.quests and profile.quests.list or {}, nil, zones)
		hud.setQuest(QuestFocus.line(focus))
		paint(focus)
	end

	state.changed:Connect(apply)
	apply()
	Debug.info("quest tracker armed")
end

return QuestTrackerController
