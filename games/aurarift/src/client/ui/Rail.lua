--!strict
--[[
	Rail — the interface shell.

	One place owns the layers, so nothing else has to reason about depth, and
	one place routes the wire, so a channel with no renderer is impossible
	rather than merely unlikely:

	    PanelsLayer (1)   hidden holders, one per panel, toggled by the rail
	    HudLayer    (10)  readouts, always visible
	    Rail        (15)  the column of panel buttons
	    RollerLayer (20)  summons and the reveal overlay at ZIndex 100
	    OfflineLayer(30)  the welcome-back claim, above everything but toasts

	The panel modules know nothing about each other. Rail is the only file
	that has seen them all, and it sees only their four-field contract:
	id, icon, label, mount(parent, scope).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local UI = Forge.UI
local Net = Forge.Net

local Icons = require(ReplicatedStorage
	:WaitForChild("Forge")
	:WaitForChild("UI")
	:WaitForChild("ItchIcons"))

local Theme = require(script.Parent:WaitForChild("Theme"))
local Hud = require(script.Parent:WaitForChild("Hud"))
local Roller = require(script.Parent:WaitForChild("Roller"))

local PANEL_MODULES: { any } = {
	require(script.Parent:WaitForChild("IndexPanel")),
	require(script.Parent:WaitForChild("EnchantPanel")),
	require(script.Parent:WaitForChild("TowerPanel")),
	require(script.Parent:WaitForChild("AscendPanel")),
	require(script.Parent:WaitForChild("RanksPanel")),
}

local Rail = {}

--: "3h 20m", because "12000 seconds" is a number nobody converts.
local function durationText(seconds: number): string
	local hours = math.floor(seconds / 3600)
	local minutes = math.floor((seconds % 3600) / 60)
	if hours > 0 then
		return string.format("%dh %dm", hours, minutes)
	end
	return string.format("%dm", math.max(minutes, 1))
end

function Rail.mount(screen: Instance): any
	local rail: any = {}
	local state: any = nil
	local openId: string? = nil
	local offlineDone = false
	local cells: { [string]: any } = {}
	local mounted: { [string]: any } = {}

	--[[
		The same scope object is handed to every module. `close` closes
		whatever is open, which is correct because Rail only ever opens one
		panel at a time — the playtest photographs each one in isolation and a
		player comparing two panels against each other is reading, not
		playing.
	]]
	local scope = {
		getState = function(): any
			return state
		end,
		send = function(channel: string, payload: any)
			Net.send(channel, payload)
		end,
		open = function(id: string)
			rail.open(id)
		end,
		close = function()
			rail.close()
		end,
	}

	local function layer(name: string, z: number): Frame
		local frame = Instance.new("Frame")
		frame.Name = name
		frame.BackgroundTransparency = 1
		frame.BorderSizePixel = 0
		frame.Size = UDim2.fromScale(1, 1)
		frame.ZIndex = z
		frame.Parent = screen
		return frame
	end

	-- ================================ panels =================================

	local panelsLayer = layer("PanelsLayer", 1)

	for _, def in PANEL_MODULES do
		local holder = Instance.new("Frame")
		holder.Name = def.id .. "Layer"
		holder.BackgroundTransparency = 1
		holder.BorderSizePixel = 0
		holder.Size = UDim2.fromScale(1, 1)
		holder.Visible = false
		holder.Parent = panelsLayer

		local panelScope = {
			getState = scope.getState,
			send = scope.send,
			open = scope.open,
			close = function()
				if openId == def.id then
					rail.close()
				end
			end,
		}

		local instance = def.mount(holder, panelScope)
		mounted[def.id] = { def = def, holder = holder, instance = instance }
	end

	-- =============================== hud + roller ============================

	local hudLayer = layer("HudLayer", 10)
	local hud = Hud.mount(hudLayer, scope)

	local rollerLayer = layer("RollerLayer", 20)
	local roller = Roller.mount(rollerLayer, scope)

	-- ============================== rail column ==============================

	local railBar = Instance.new("Frame")
	railBar.Name = "Rail"
	railBar.Size = UDim2.fromOffset(64, #PANEL_MODULES * 72)
	railBar.Position = UDim2.new(0, 10, 0.5, 0)
	railBar.AnchorPoint = Vector2.new(0, 0.5)
	railBar.BackgroundTransparency = 1
	railBar.ZIndex = 15
	railBar.Parent = screen
	UI.list(railBar, { gap = UI.theme.space.sm })

	local function styleCell(id: string)
		local cell = cells[id]
		if cell == nil then
			return
		end
		local active = openId == id
		cell.button.BackgroundColor3 = if active then Theme.color.accent else Theme.color.panelAlt
		cell.caption.TextColor3 = if active then Theme.color.text else Theme.color.textDim
		cell.caption.Text = if active then "• " .. cell.label .. " •" else cell.label
	end

	for _, def in PANEL_MODULES do
		local cell = Instance.new("Frame")
		cell.Name = def.id .. "Cell"
		cell.Size = UDim2.fromOffset(60, 64)
		cell.BackgroundTransparency = 1
		cell.Parent = railBar

		local button = Instance.new("ImageButton")
		button.Name = def.id .. "Button"
		button.Size = UDim2.fromOffset(56, 52)
		button.Position = UDim2.fromOffset(2, 0)
		button.BackgroundColor3 = Theme.color.panelAlt
		button.BorderSizePixel = 0
		button.AutoButtonColor = false
		button.Parent = cell
		UI.corner(button, UI.theme.radius.sm)
		UI.stroke(button, Theme.color.stroke, 1, 0.4)
		Icons.apply(button, def.icon)

		local caption = UI.label(cell, def.label, {
			name = def.id .. "Caption",
			size = UI.theme.text.xs,
			color = Theme.color.textDim,
			align = Enum.TextXAlignment.Center,
			frameSize = UDim2.fromOffset(60, 14),
			pos = UDim2.fromOffset(0, 50),
		})

		local base = button.BackgroundColor3
		button.MouseEnter:Connect(function()
			if openId ~= def.id then
				TweenService:Create(button, TweenInfo.new(0.12), {
					BackgroundColor3 = base:Lerp(Color3.new(1, 1, 1), 0.12),
				}):Play()
			end
		end)
		button.MouseLeave:Connect(function()
			if openId ~= def.id then
				TweenService:Create(button, TweenInfo.new(0.16), {
					BackgroundColor3 = base,
				}):Play()
			end
		end)
		button.MouseButton1Click:Connect(function()
			if openId == def.id then
				rail.close()
			else
				rail.open(def.id)
			end
		end)

		cells[def.id] = { button = button, caption = caption, label = def.label }
	end

	-- ============================ welcome back ===============================

	local modalLayer = layer("OfflineLayer", 30)
	modalLayer.Visible = false

	local modalDim = Instance.new("Frame")
	modalDim.Name = "Dim"
	modalDim.Size = UDim2.fromScale(1, 1)
	modalDim.BackgroundColor3 = Color3.new(0, 0, 0)
	modalDim.BackgroundTransparency = 0.45
	modalDim.BorderSizePixel = 0
	modalDim.Parent = modalLayer

	local modal = UI.panel(modalLayer, {
		name = "OfflinePanel",
		size = UDim2.fromOffset(400, 196),
		pos = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
	})

	UI.label(modal, "WELCOME BACK", {
		size = UI.theme.text.lg,
		font = UI.theme.font.title,
		color = Theme.color.gold,
		align = Enum.TextXAlignment.Center,
		frameSize = UDim2.new(1, -24, 0, 30),
		pos = UDim2.fromOffset(12, 18),
	})

	local modalBody = UI.label(modal, "", {
		size = UI.theme.text.sm,
		color = Theme.color.textDim,
		align = Enum.TextXAlignment.Center,
		wrap = true,
		frameSize = UDim2.new(1, -40, 0, 44),
		pos = UDim2.fromOffset(20, 54),
	})

	UI.label(modal, "Rift kept flowing while you were away.", {
		size = UI.theme.text.xs,
		color = Theme.color.textDim,
		align = Enum.TextXAlignment.Center,
		frameSize = UDim2.new(1, -40, 0, 16),
		pos = UDim2.fromOffset(20, 100),
	})

	UI.button(modal, "COLLECT", {
		name = "CollectOffline",
		size = UDim2.fromOffset(180, 48),
		pos = UDim2.new(0.5, 0, 1, -62),
		anchor = Vector2.new(0.5, 0),
		color = Theme.color.accent,
		textColor = Theme.color.bg,
		textSize = UI.theme.text.md,
		onClick = function()
			scope.send("ClaimOffline", {})
			modalLayer.Visible = false
		end,
	})

	-- ================================ routing ================================

	function rail.update(snapshot: any)
		state = snapshot
		if snapshot == nil then
			return
		end
		hud.update(snapshot)
		roller.update(snapshot)
		for _, entry in mounted do
			entry.instance.update(snapshot)
		end

		local offline = snapshot.offline
		if offline ~= nil and not offlineDone then
			offlineDone = true
			modalBody.Text = string.format("%s Rift (%s)",
				tostring(offline.amount or "0"), durationText(offline.seconds or 0))
			modalLayer.Visible = true
		end
	end

	function rail.rolled(payload: any)
		roller.rolled(payload)
	end

	function rail.announce(payload: any)
		roller.announce(payload)
	end

	function rail.battle(payload: any)
		local entry = mounted.tower
		if entry ~= nil and type(entry.instance.event) == "function" then
			entry.instance.event("battle", payload)
		end
	end

	function rail.board(payload: any)
		local entry = mounted.ranks
		if entry ~= nil and type(entry.instance.event) == "function" then
			entry.instance.event("board", payload)
		end
	end

	-- ================================ panels UI ==============================

	function rail.open(id: string): boolean
		local entry = mounted[id]
		if entry == nil then
			return false
		end
		if openId ~= nil and openId ~= id then
			mounted[openId].holder.Visible = false
			styleCell(openId)
		end
		openId = id
		--: The welcome-back claim would sit over the panel in every
		--: photograph; a player who opened a panel has chosen to move on.
		modalLayer.Visible = false
		entry.holder.Visible = true
		entry.instance.update(state)
		styleCell(id)
		return true
	end

	function rail.close()
		if openId == nil then
			return
		end
		mounted[openId].holder.Visible = false
		styleCell(openId)
		openId = nil
	end

	function rail.describe(): { [string]: any }
		local ids = {}
		for _, def in PANEL_MODULES do
			table.insert(ids, def.id)
		end
		return {
			title = "AURA RIFT",
			openPanel = openId,
			panels = ids,
		}
	end

	--: What `forge playtest` and any outside look drive. Same verbs a button
	--: does, so what gets photographed is what a player would see.
	function rail.invoke(command: any): any
		local text = tostring(command or "")
		local verb, rest = text:match("^(%a+):?(.*)$")
		if verb == "open" and rest ~= "" then
			return rail.open(rest)
		elseif verb == "close" then
			rail.close()
			return true
		elseif verb == "describe" then
			return rail.describe()
		end
		return nil
	end

	return rail
end

return Rail
