--!strict
-- Hud — health, stamina, score. Reads tokens from UI.theme so nothing here
-- invents a colour.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local UI = Forge.UI
local Net = Forge.Net

local Hud = {}
Hud.state = { stamina = 100, score = 0, kills = 0, best = 0 }

-- Replaced by the real one inside `init`, which closes over the labels. This
-- placeholder exists so a weapon packet arriving before the HUD is built is a
-- no-op rather than a nil call.
function Hud.setWeapon(_label: string, _ammo: number, _reloading: boolean) end

local player = Players.LocalPlayer

function Hud.init()
	local T = UI.theme
	local screen = UI.mount("ProvingGroundHud")

	local vitals = UI.panel(screen, {
		size = UDim2.fromOffset(320, 74),
		pos = UDim2.new(0, 18, 1, -92),
		transparency = 0.2,
	})

	local health = UI.bar(vitals, {
		color = T.color.danger,
		size = UDim2.fromOffset(288, 20),
		pos = UDim2.fromOffset(16, 14),
	})
	local healthText = UI.label(health.holder, "", {
		size = T.text.xs,
		align = Enum.TextXAlignment.Center,
		font = T.font.bold,
		z = 5,
	})

	local stamina = UI.bar(vitals, {
		color = T.color.warning,
		size = UDim2.fromOffset(288, 8),
		pos = UDim2.fromOffset(16, 40),
		speed = 10,
	})

	--[[
		The weapon readout.

		Bottom right rather than under the bars: ammo is read between shots and
		health is read during them, so they want different corners of the eye.
	]]
	local weaponPanel = UI.panel(screen, {
		size = UDim2.fromOffset(184, 54),
		pos = UDim2.new(1, -202, 1, -72),
		transparency = 0.25,
	})
	local weaponName = UI.label(weaponPanel, "Longbow", {
		size = T.text.xs,
		color = T.color.textDim,
		align = Enum.TextXAlignment.Right,
		frameSize = UDim2.new(1, -14, 0, 15),
		pos = UDim2.fromOffset(0, 6),
	})
	local ammoLabel = UI.label(weaponPanel, "1", {
		size = T.text.lg,
		color = T.color.text,
		font = T.font.title,
		align = Enum.TextXAlignment.Right,
		frameSize = UDim2.new(1, -14, 0, 28),
		pos = UDim2.fromOffset(0, 21),
	})

	--[[
		Called by the client whenever the server says the weapon changed.

		The HUD never counts rounds itself. If it did, a shot the server refused
		would still tick the counter down and the player would be looking at a
		number that is not true.
	]]
	function Hud.setWeapon(label: string, ammo: number, reloading: boolean)
		weaponName.Text = label
		if reloading then
			ammoLabel.Text = "--"
			ammoLabel.TextColor3 = T.color.warning
		else
			ammoLabel.Text = tostring(ammo)
			ammoLabel.TextColor3 = ammo > 0 and T.color.text or T.color.danger
		end
	end

	local scorePanel = UI.panel(screen, {
		size = UDim2.fromOffset(190, 62),
		pos = UDim2.new(1, -208, 0, 18),
		transparency = 0.25,
	})
	local scoreLabel = UI.label(scorePanel, "0", {
		size = T.text.xl,
		color = T.color.gold,
		font = T.font.title,
		align = Enum.TextXAlignment.Right,
		frameSize = UDim2.new(1, -14, 0, 34),
		pos = UDim2.fromOffset(0, 6),
	})
	local subLabel = UI.label(scorePanel, "0 kills   best 0", {
		size = T.text.xs,
		color = T.color.textDim,
		align = Enum.TextXAlignment.Right,
		frameSize = UDim2.new(1, -14, 0, 16),
		pos = UDim2.fromOffset(0, 38),
	})

	UI.label(screen, "<b>LMB</b> strike  <b>Q</b> dodge  <b>RMB</b> block  <b>Shift</b> run  <b>F</b> shoot  <b>R</b> reload  <b>C</b> swap", {
		size = T.text.xs,
		color = T.color.textDim,
		frameSize = UDim2.fromOffset(620, 18),
		pos = UDim2.new(0, 20, 1, -20),
	})

	--[[
		Stamina arrives on its own channel, several times a second.

		When it hits zero the bar turns red and pulses. A player who is out of
		breath should not have to read a number to know it — the bar and the
		character's breath say the same thing in two places.
	]]
	local exhausted = false
	Net.on("Stamina", function(payload)
		Hud.state.stamina = payload.value or 0
		exhausted = payload.exhausted == true
		stamina.fill.BackgroundColor3 = exhausted and T.color.danger or T.color.warning
	end)

	Net.on("StateSync", function(payload)
		for key, value in payload do
			Hud.state[key] = value
		end
		scoreLabel.Text = tostring(Hud.state.score or 0)
		subLabel.Text = string.format("%d kills   best %d", Hud.state.kills or 0, Hud.state.best or 0)
	end)

	RunService.RenderStepped:Connect(function()
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.MaxHealth > 0 then
			health:set(humanoid.Health / humanoid.MaxHealth)
			healthText.Text = string.format("%d / %d", math.floor(humanoid.Health), math.floor(humanoid.MaxHealth))
		end
		stamina:set((Hud.state.stamina or 100) / 100)
		if exhausted then
			-- 3 Hz: fast enough to read as alarm, slow enough not to strobe.
			local pulse = 0.5 + 0.5 * math.sin(os.clock() * 19)
			stamina.fill.BackgroundTransparency = 0.15 + pulse * 0.35
		elseif stamina.fill.BackgroundTransparency ~= 0 then
			stamina.fill.BackgroundTransparency = 0
		end
	end)
end

return Hud
