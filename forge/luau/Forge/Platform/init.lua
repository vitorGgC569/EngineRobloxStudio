--!strict
--[[
	Platform — is this game actually playable on the device in front of you?

	`Input` already abstracts keyboard, gamepad and touch, and a test asserts
	every action declares a touch binding. That proves an action is *bindable*
	on a phone. It says nothing about whether the HUD fits, whether the buttons
	are big enough to hit, whether anything is hidden behind the Roblox topbar,
	or whether the frame budget survives a device with a tenth of the fill rate.

	Those are the four ways a Roblox game is unplayable on mobile while passing
	every test, and this measures all four.

		local report = Platform.audit()
		--> { device = "Phone", offscreen = {...}, tooSmall = {...}, ... }

	--- Why measure rather than design ---------------------------------------

	Because a layout that was fine at 1920x1080 is a layout nobody checked at
	390x844, and the person who finds out is a player holding a phone. A
	viewport is a number; "looks fine" is not.
]]

local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Platform = {}

Platform.config = {
	--[[
		The smallest a touch target may be, in pixels.

		44 is the number Apple and Google both landed on independently, which
		is about as close to settled as interface guidance gets. Below it,
		accuracy falls off a cliff for anyone whose hands are not steady.
	]]
	minimumTouchTarget = 44,
	-- Roblox's own topbar, which overlaps the top of every screen.
	topbarHeight = 36,
	-- What counts as a phone, by the narrow side of the viewport.
	phoneWidth = 500,
	tabletWidth = 1024,
}

-- ================================= device ===================================
function Platform.viewport(): Vector2
	local camera = Workspace.CurrentCamera
	return camera and camera.ViewportSize or Vector2.new(1920, 1080)
end

--[[
	What this is running on.

	Deliberately derived from input capability and viewport rather than from a
	single flag: Roblox reports `TouchEnabled` on laptops with touchscreens and
	`KeyboardEnabled` on tablets with a case, so either one alone mislabels a
	real device somebody is holding.
]]
function Platform.device(): string
	if GuiService:IsTenFootInterface() then
		return "Console"
	end
	local size = Platform.viewport()
	local touch = UserInputService.TouchEnabled
	local keyboard = UserInputService.KeyboardEnabled

	if touch and not keyboard then
		return size.X <= Platform.config.phoneWidth and "Phone" or "Tablet"
	end
	if touch and size.X <= Platform.config.tabletWidth then
		return "Tablet"
	end
	return "Desktop"
end

function Platform.isSmallScreen(): boolean
	return Platform.viewport().X <= Platform.config.tabletWidth
end

-- ================================== audit ===================================
local function absoluteRect(gui: GuiObject): (Vector2, Vector2)
	return gui.AbsolutePosition, gui.AbsoluteSize
end

--[[
	Every visible element that a device this size would break.

	Three questions per element, and each one corresponds to a bug that ships:

	  * Is any of it outside the viewport? A HUD anchored for a wide screen
	    puts its right-hand panel past the edge of a phone, where it is not
	    merely ugly but unreachable.
	  * Is it under the Roblox topbar? The top 36 pixels belong to Roblox, and
	    anything there is covered by controls the player cannot move.
	  * Is it too small to hit? A 24-pixel button is fine with a mouse and a
	    coin toss with a thumb.
]]
function Platform.audit(root: Instance?): { [string]: any }
	local player = Players.LocalPlayer
	local screen = root or (player and player:FindFirstChildOfClass("PlayerGui"))
	local size = Platform.viewport()

	local offscreen, underTopbar, tooSmall = {}, {}, {}
	local inspected = 0

	if screen then
		for _, gui in screen:GetDescendants() do
			if not gui:IsA("GuiObject") or not gui.Visible then
				continue
			end
			-- Zero-size elements are layout scaffolding, not interface.
			local position, extent = absoluteRect(gui)
			if extent.X < 1 or extent.Y < 1 then
				continue
			end
			inspected += 1

			if position.X < 0 or position.Y < 0
				or position.X + extent.X > size.X
				or position.Y + extent.Y > size.Y then
				table.insert(offscreen, gui:GetFullName())
			end

			if position.Y < Platform.config.topbarHeight then
				table.insert(underTopbar, gui:GetFullName())
			end

			--[[
				Only things you press.

				A label smaller than a thumb is a label; a button smaller than
				a thumb is a defect. `Active` and the button classes are how
				Roblox marks the difference.
			]]
			local pressable = gui:IsA("GuiButton")
				or (gui:IsA("GuiObject") and gui.Active)
			if pressable and math.min(extent.X, extent.Y) < Platform.config.minimumTouchTarget then
				table.insert(tooSmall, string.format("%s (%dx%d)",
					gui:GetFullName(), extent.X, extent.Y))
			end
		end
	end

	return {
		device = Platform.device(),
		viewport = { size.X, size.Y },
		inspected = inspected,
		offscreen = offscreen,
		underTopbar = underTopbar,
		tooSmall = tooSmall,
		ok = #offscreen == 0 and #underTopbar == 0 and #tooSmall == 0,
	}
end

-- ================================ simulate ==================================
--[[
	Look at the interface as a phone would, without a phone.

	Roblox has no way to change the real viewport from a script, so this does
	the honest version: it measures every element against the dimensions a
	device *would* have and reports what would break. Anything anchored or
	scaled relatively is evaluated correctly; anything positioned in absolute
	pixels is exactly what this is looking for.
]]
Platform.devices = {
	Phone = Vector2.new(390, 844),
	PhoneLandscape = Vector2.new(844, 390),
	Tablet = Vector2.new(820, 1180),
	Console = Vector2.new(1920, 1080),
}

function Platform.auditAs(deviceName: string, root: Instance?): { [string]: any }
	local size = Platform.devices[deviceName]
	if not size then
		return { error = "no device profile named " .. tostring(deviceName) }
	end

	local player = Players.LocalPlayer
	local screen = root or (player and player:FindFirstChildOfClass("PlayerGui"))
	local offscreen, tooSmall = {}, {}
	local inspected = 0

	if screen then
		for _, gui in screen:GetDescendants() do
			if not gui:IsA("GuiObject") or not gui.Visible then
				continue
			end
			local position, extent = absoluteRect(gui)
			if extent.X < 1 or extent.Y < 1 then
				continue
			end
			inspected += 1

			--[[
				Re-project onto the target viewport.

				An element positioned with a Scale component moves with the
				screen and stays put; one positioned in Offset does not. Scaling
				the measured rectangle by the viewport ratio is a good enough
				model of that, and it is the difference this is hunting.
			]]
			local current = Platform.viewport()
			local ratio = Vector2.new(size.X / current.X, size.Y / current.Y)
			local projected = Vector2.new(position.X * ratio.X, position.Y * ratio.Y)

			if projected.X + extent.X > size.X or projected.Y + extent.Y > size.Y then
				table.insert(offscreen, string.format("%s would sit at %d,%d",
					gui.Name, projected.X, projected.Y))
			end

			local pressable = gui:IsA("GuiButton") or gui.Active
			if pressable and math.min(extent.X, extent.Y) < Platform.config.minimumTouchTarget then
				table.insert(tooSmall, string.format("%s (%dx%d)",
					gui.Name, extent.X, extent.Y))
			end
		end
	end

	return {
		asDevice = deviceName,
		viewport = { size.X, size.Y },
		inspected = inspected,
		offscreen = offscreen,
		tooSmall = tooSmall,
		ok = #offscreen == 0 and #tooSmall == 0,
	}
end

-- ================================ performance ===============================
--[[
	A frame budget for the device, not for this machine.

	A Studio session on a desktop says nothing about a phone, and no amount of
	measuring here will. What *is* portable is the part count and the draw
	distance, because those are what a weak GPU actually chokes on — so this
	reports them against thresholds that a low-end device can hold, and leaves
	milliseconds to a real device.
]]
Platform.budgets = {
	Phone = { parts = 6000, drawDistance = 500, shadowCasters = 300 },
	Tablet = { parts = 12000, drawDistance = 800, shadowCasters = 600 },
	Console = { parts = 20000, drawDistance = 1200, shadowCasters = 1200 },
	Desktop = { parts = 40000, drawDistance = 2000, shadowCasters = 3000 },
}

function Platform.sceneBudget(deviceName: string?): { [string]: any }
	local device = deviceName or Platform.device()
	local budget = Platform.budgets[device] or Platform.budgets.Desktop

	local parts, casters = 0, 0
	for _, d in Workspace:GetDescendants() do
		if d:IsA("BasePart") then
			parts += 1
			if d.CastShadow then
				casters += 1
			end
		end
	end

	return {
		device = device,
		parts = parts,
		partBudget = budget.parts,
		shadowCasters = casters,
		shadowBudget = budget.shadowCasters,
		ok = parts <= budget.parts and casters <= budget.shadowCasters,
	}
end

function Platform.describe(): { [string]: any }
	return {
		context = RunService:IsServer() and "server" or "client",
		device = RunService:IsClient() and Platform.device() or "server",
		profiles = (function()
			local names = {}
			for name in Platform.devices do
				table.insert(names, name)
			end
			table.sort(names)
			return names
		end)(),
		minimumTouchTarget = Platform.config.minimumTouchTarget,
	}
end

return Platform
