--!strict
-- World-space survivor pings (endgame radar + Screamer pulses): a billboard
-- marker over each pinged survivor for a few seconds.

local Debris = game:GetService("Debris")

local Theme = require(script.Parent.Theme)

local Pings = {}

function Pings.start(remotes: any)
	remotes.on("SurvivorPing", function(payload)
		for _, survivor in payload.survivors or {} do
			local anchor = Instance.new("Part")
			anchor.Anchored = true
			anchor.CanCollide = false
			anchor.CanQuery = false
			anchor.Transparency = 1
			anchor.Size = Vector3.new(1, 1, 1)
			anchor.Position = Vector3.new(survivor.x, survivor.y + 6, survivor.z)
			anchor.Parent = workspace

			local billboard = Instance.new("BillboardGui")
			billboard.Size = UDim2.new(0, 120, 0, 30)
			billboard.AlwaysOnTop = true
			billboard.MaxDistance = 1000
			billboard.Parent = anchor

			local label = Instance.new("TextLabel")
			label.Size = UDim2.new(1, 0, 1, 0)
			label.BackgroundTransparency = 1
			label.Font = Theme.Font
			label.TextSize = 14
			label.TextStrokeTransparency = 0.4
			label.TextColor3 = if payload.scream then Theme.Colors.Infected else Theme.Colors.Danger
			label.Text = "▼ " .. (survivor.name or "?")
			label.Parent = billboard

			Debris:AddItem(anchor, 4)
		end
	end)
	return {}
end

return Pings
