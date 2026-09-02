--!strict
-- Round-modifier banner + client-side lighting effects. The server rolls a modifier at
-- round start and broadcasts it; this announces it and, for Blackout, dims the lighting.
-- Original lighting is captured once and restored when the modifier clears.

local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent.Theme)

local Modifiers = {}

function Modifiers.start(remotes: any)
	local gui = Theme.screenGui("Modifiers", 9)

	local banner = Theme.frame(gui, {
		Size = UDim2.new(0, 420, 0, 64),
		Position = UDim2.new(0.5, -210, 0, -80),
		BackgroundColor3 = Theme.Colors.Panel,
		BackgroundTransparency = 0.1,
	})
	Theme.corner(banner, 12)
	local stroke = Instance.new("UIStroke")
	stroke.Color = Theme.Colors.Gold
	stroke.Thickness = 2
	stroke.Parent = banner
	local title = Theme.label(banner, {
		Size = UDim2.new(1, -16, 0, 26),
		Position = UDim2.new(0, 8, 0, 8),
		Text = "",
		TextSize = 20,
		TextColor3 = Theme.Colors.Gold,
	})
	local desc = Theme.label(banner, {
		Size = UDim2.new(1, -16, 0, 20),
		Position = UDim2.new(0, 8, 0, 34),
		Text = "",
		TextSize = 14,
		TextColor3 = Theme.Colors.TextDim,
	})

	-- Snapshot of the lighting to restore when Blackout ends. Captured when Blackout STARTS,
	-- not once at client start: the old version restored whatever lighting happened to be
	-- loaded when you joined, so after one Blackout round (about one in seven) every
	-- subsequent map was lit wrong until the next map load.
	local defaults: { [string]: any }? = nil
	local blackoutOn = false

	local function setBlackout(on: boolean)
		if on == blackoutOn then
			return
		end
		blackoutOn = on
		if on then
			defaults = {
				Ambient = Lighting.Ambient,
				OutdoorAmbient = Lighting.OutdoorAmbient,
				Brightness = Lighting.Brightness,
				ClockTime = Lighting.ClockTime,
				FogEnd = Lighting.FogEnd,
			}
		end
		local target = on
				and {
					Ambient = Color3.fromRGB(8, 8, 12),
					OutdoorAmbient = Color3.fromRGB(12, 12, 18),
					-- Blackout used to drop to 0.4 brightness with 120-stud fog on maps that
					-- were already near-black, which made the round unplayable rather than
					-- tense. The zombie outlines now carry the readability.
					Brightness = 0.8,
					ClockTime = 0,
					FogEnd = 200,
				}
			or defaults
		if target == nil then
			return
		end
		TweenService:Create(Lighting, TweenInfo.new(0.8), {
			Ambient = target.Ambient,
			OutdoorAmbient = target.OutdoorAmbient,
			Brightness = target.Brightness,
			ClockTime = target.ClockTime,
			FogEnd = target.FogEnd,
		}):Play()
	end

	local function showBanner(name: string, description: string)
		title.Text = name
		desc.Text = description
		TweenService:Create(banner, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Position = UDim2.new(0.5, -210, 0, 76),
		}):Play()
		task.delay(4.5, function()
			TweenService:Create(banner, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				Position = UDim2.new(0.5, -210, 0, -80),
			}):Play()
		end)
	end

	remotes.on("RoundModifier", function(payload)
		if not payload.active then
			setBlackout(false)
			return
		end
		setBlackout(payload.blackout == true)
		-- "Standard" rounds don't need a banner shout.
		if payload.id ~= "normal" then
			showBanner(payload.name, payload.desc)
		end
	end)

	return {}
end

return Modifiers
