--!strict
--[[
	Editor.Ui — the overlay.

		local EditorUi = require(ReplicatedStorage.Forge.Editor.Ui)
		EditorUi.mount()          -- F4 toggles it

	Deliberately thin. Every button sends the same operation an agent would
	send, so there is no behaviour here that automation cannot reach — the UI
	is a view, never a second implementation.

	    ┌──────────────────────────────────────────────────┐
	    │ File  World  Actor  Grid  Play                   │
	    ├────────────┬────────────────────────┬────────────┤
	    │ Assets     │                        │ Inspector  │
	    │ Prop.…     │      the game          │ asset      │
	    │ Enemy.…    │                        │ position   │
	    │            │                        │ actions    │
	    ├────────────┴────────────────────────┴────────────┤
	    │ console                                          │
	    └──────────────────────────────────────────────────┘

	Click an asset to arm it, click the world to place. Click a placed thing to
	select it. Arrows nudge, R rotates, G drops it on the ground, Delete removes.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Forge = require(script.Parent.Parent)
local UI = Forge.UI
local Net = Forge.Net
local Gizmo = require(script.Parent.Gizmo)

local Ui = {}

local player = Players.LocalPlayer
local mounted = false
local visible = false
local armed: string? = nil
local state = { placements = {}, palette = {}, selectedIndex = nil, gridSize = 4 }
local widgets: { [string]: any } = {}
local log: { string } = {}

local T = UI.theme

local function send(op: string, data: any?)
	Net.send("EditorOp", { op = op, data = data or {} })
end

local function note(text: string)
	table.insert(log, text)
	if #log > 7 then
		table.remove(log, 1)
	end
	if widgets.console then
		widgets.console.Text = table.concat(log, "\n")
	end
end

-- ================================== build ===================================
local function buildMenu(root: Instance)
	-- Roblox's own topbar owns the top-left corner, and this overlay draws under
	-- it because IgnoreGuiInset is on. Starting at x=12 put Save and Undo behind
	-- the chat and menu buttons: visible in a screenshot, unclickable in a game.
	local TOPBAR_CLEARANCE = 236
	local bar = UI.panel(root, {
		size = UDim2.new(1, -TOPBAR_CLEARANCE - 24, 0, 34),
		pos = UDim2.fromOffset(TOPBAR_CLEARANCE, 10),
		transparency = 0.05,
		radius = T.radius.sm,
	})

	local layout = UI.list(bar, { horizontal = true, gap = 4 })
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 8)
	padding.Parent = bar

	local function menuButton(label: string, order: number, onClick: () -> ())
		-- 66px, not 84. Adding Copy/Paste/Lock/mode pushed the last two buttons
		-- off the right edge — visible in a screenshot, unclickable in the game,
		-- which is the same defect the topbar clearance already fixed once.
		local button = UI.button(bar, label, {
			size = UDim2.fromOffset(66, 24),
			textSize = T.text.xs,
			onClick = onClick,
		})
		button.LayoutOrder = order
		return button
	end

	menuButton("Save", 1, function()
		send("save")
		note("saving scene…")
	end)
	menuButton("Undo", 2, function()
		send("undo")
	end)
	menuButton("Redo", 3, function()
		send("redo")
	end)
	menuButton("Dupe", 4, function()
		send("duplicate")
	end)
	menuButton("Drop", 5, function()
		send("ground")
	end)
	menuButton("Copy", 6, function()
		send("copy")
		note("copied " .. tostring(state.selectedCount or 0) .. " item(s)")
	end)
	menuButton("Paste", 7, function()
		send("paste")
	end)
	menuButton("Lock", 8, function()
		send("lock", { on = true })
		note("selection locked; click-select will skip it")
	end)

	-- Mode switch. The label shows the active mode rather than the next one,
	-- because a button that says what it will do reads as a verb and a button
	-- that says what is true reads as state — and this is state.
	widgets.modeButton = menuButton("Move", 9, function()
		local order = { move = "rotate", rotate = "scale", scale = "move" }
		Ui.setMode(order[Gizmo.mode()] or "move")
	end)

	widgets.gridButton = menuButton("Grid 4", 6, function()
		local sizes = { 0, 1, 2, 4, 8, 16 }
		local index = table.find(sizes, state.gridSize) or 4
		local next_ = sizes[(index % #sizes) + 1]
		send("grid", { size = next_ })
	end)

	menuButton("Play", 7, function()
		Ui.toggle()
		note("editor hidden — press F4 to return")
	end)
end

local function buildPalette(root: Instance)
	local panel = UI.panel(root, {
		size = UDim2.fromOffset(210, 380),
		pos = UDim2.fromOffset(12, 52),
		transparency = 0.1,
	})
	UI.label(panel, "Assets", {
		size = T.text.sm,
		color = T.color.textDim,
		font = T.font.bold,
		frameSize = UDim2.new(1, -20, 0, 20),
		pos = UDim2.fromOffset(12, 6),
	})

	local scroll = Instance.new("ScrollingFrame")
	scroll.Size = UDim2.new(1, -20, 1, -36)
	scroll.Position = UDim2.fromOffset(10, 28)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 4
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.Parent = panel
	UI.list(scroll, { gap = 3 })

	widgets.palette = scroll
end

local function buildInspector(root: Instance)
	local panel = UI.panel(root, {
		size = UDim2.fromOffset(230, 240),
		pos = UDim2.new(1, -242, 0, 56),
		transparency = 0.1,
	})
	UI.label(panel, "Inspector", {
		size = T.text.sm,
		color = T.color.textDim,
		font = T.font.bold,
		frameSize = UDim2.new(1, -20, 0, 20),
		pos = UDim2.fromOffset(12, 6),
	})

	widgets.inspectorCount = UI.label(panel, "", {
		size = T.text.xs,
		color = T.color.gold,
		frameSize = UDim2.new(1, -24, 0, 14),
		pos = UDim2.fromOffset(12, 68),
	})

	widgets.inspectorAsset = UI.label(panel, "nothing selected", {
		size = T.text.sm,
		frameSize = UDim2.new(1, -24, 0, 18),
		pos = UDim2.fromOffset(12, 30),
	})
	widgets.inspectorPos = UI.label(panel, "", {
		size = T.text.xs,
		color = T.color.textDim,
		font = T.font.mono,
		frameSize = UDim2.new(1, -24, 0, 16),
		pos = UDim2.fromOffset(12, 52),
	})

	local actions = Instance.new("Frame")
	actions.Size = UDim2.new(1, -24, 0, 120)
	actions.Position = UDim2.fromOffset(12, 76)
	actions.BackgroundTransparency = 1
	actions.Parent = panel
	UI.list(actions, { gap = 4 })

	local function action(label: string, order: number, onClick: () -> ())
		local button = UI.button(actions, label, {
			size = UDim2.new(1, 0, 0, 22),
			textSize = T.text.xs,
			onClick = onClick,
		})
		button.LayoutOrder = order
	end

	action("Rotate 15°", 1, function()
		send("rotate", { degrees = 15 })
	end)
	action("Rotate -15°", 2, function()
		send("rotate", { degrees = -15 })
	end)
	action("Drop to ground", 3, function()
		send("ground")
	end)
	action("Delete", 4, function()
		send("delete")
	end)

	UI.label(panel, "arrows nudge · R rotate · G ground · Del remove", {
		size = T.text.xs,
		color = T.color.textDim,
		wrap = true,
		frameSize = UDim2.new(1, -24, 0, 30),
		pos = UDim2.fromOffset(12, 200),
	})
end

local function buildConsole(root: Instance)
	local panel = UI.panel(root, {
		size = UDim2.new(1, -24, 0, 96),
		pos = UDim2.new(0, 12, 1, -108),
		transparency = 0.15,
	})
	widgets.console = UI.label(panel, "editor ready", {
		size = T.text.xs,
		color = T.color.textDim,
		font = T.font.mono,
		valign = Enum.TextYAlignment.Top,
		frameSize = UDim2.new(1, -24, 1, -16),
		pos = UDim2.fromOffset(12, 8),
	})
end

-- ================================= refresh ==================================
local function refreshPalette()
	local scroll = widgets.palette
	if not scroll then
		return
	end
	for _, child in scroll:GetChildren() do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end

	local order = 0
	local namespaces = {}
	for namespace in state.palette do
		table.insert(namespaces, namespace)
	end
	table.sort(namespaces)

	for _, namespace in namespaces do
		order += 1
		local header = UI.label(scroll, namespace, {
			size = T.text.xs,
			color = T.color.gold,
			font = T.font.bold,
			frameSize = UDim2.new(1, -6, 0, 16),
		})
		header.LayoutOrder = order

		for _, id in state.palette[namespace] do
			order += 1
			local short = string.gsub(id, "^" .. namespace .. "%.", "")
			local button = UI.button(scroll, short, {
				size = UDim2.new(1, -6, 0, 20),
				textSize = T.text.xs,
				onClick = function()
					armed = id
					note("armed " .. id .. " — click the world to place")
				end,
			})
			button.TextXAlignment = Enum.TextXAlignment.Left
			button.LayoutOrder = order
			local padding = Instance.new("UIPadding")
			padding.PaddingLeft = UDim.new(0, 8)
			padding.Parent = button
		end
	end
end

local function refreshInspector()
	if not widgets.inspectorAsset then
		return
	end
	local count = state.selectedCount or 0
	widgets.inspectorCount.Text = count > 1 and string.format("%d selected", count) or ""

	local selected = state.selectedIndex and state.placements[state.selectedIndex]
	if not selected then
		widgets.inspectorAsset.Text = "nothing selected"
		widgets.inspectorPos.Text = ""
		return
	end
	widgets.inspectorAsset.Text = selected.asset
	local p = selected.position
	widgets.inspectorPos.Text = string.format("%.1f, %.1f, %.1f", p.X, p.Y, p.Z)
end

-- ================================== input ===================================
local function worldPointUnderMouse(): (Vector3?, Instance?)
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil, nil
	end
	local location = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(location.X, location.Y)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character }

	local result = Workspace:Raycast(ray.Origin, ray.Direction * 2000, params)
	if result then
		return result.Position, result.Instance
	end
	return nil, nil
end

local function onClick()
	if not visible then
		return
	end
	local point, instance = worldPointUnderMouse()
	if not point then
		return
	end

	if armed then
		send("place", { asset = armed, position = point })
		note(string.format("placed %s at %.0f, %.0f, %.0f", armed, point.X, point.Y, point.Z))
		return
	end
	if instance then
		-- Ctrl adds to the selection, the convention every editor shares.
		send("selectInstance", {
			instance = instance,
			additive = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl),
		})
	else
		send("clearSelection")
	end
end

local function onKey(input: InputObject)
	if not visible then
		return
	end
	local key = input.KeyCode
	local step = state.gridSize > 0 and state.gridSize or 1

	if key == Enum.KeyCode.Up then
		send("nudge", { delta = Vector3.new(0, 0, -step) })
	elseif key == Enum.KeyCode.Down then
		send("nudge", { delta = Vector3.new(0, 0, step) })
	elseif key == Enum.KeyCode.Left then
		send("nudge", { delta = Vector3.new(-step, 0, 0) })
	elseif key == Enum.KeyCode.Right then
		send("nudge", { delta = Vector3.new(step, 0, 0) })
	elseif key == Enum.KeyCode.PageUp then
		send("nudge", { delta = Vector3.new(0, step, 0) })
	elseif key == Enum.KeyCode.PageDown then
		send("nudge", { delta = Vector3.new(0, -step, 0) })
	elseif key == Enum.KeyCode.W then
		Ui.setMode("move")
	elseif key == Enum.KeyCode.E then
		Ui.setMode("rotate")
	elseif key == Enum.KeyCode.R then
		if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then
			send("rotate", { degrees = 15 })
		else
			Ui.setMode("scale")
		end
	elseif key == Enum.KeyCode.C and UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
		send("copy")
	elseif key == Enum.KeyCode.V and UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
		send("paste")
	elseif key == Enum.KeyCode.L then
		send("lock", { on = true })
	elseif key == Enum.KeyCode.H then
		send("hide", { on = true })
	elseif key == Enum.KeyCode.F then
		send("selectGroup")
		note("selected the whole prefab")
	elseif key == Enum.KeyCode.G then
		send("ground")
	elseif key == Enum.KeyCode.Delete or key == Enum.KeyCode.X then
		send("delete")
	elseif key == Enum.KeyCode.Escape then
		armed = nil
		note("disarmed")
	elseif key == Enum.KeyCode.Z and UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
		send("undo")
	elseif key == Enum.KeyCode.Y and UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
		send("redo")
	end
end

-- ================================== mount ===================================
function Ui.mount()
	if mounted then
		return
	end
	mounted = true

	Net.define({
		EditorOp = { dir = "c2s", rate = 30, shape = { op = "string", data = "table" } },
		EditorSync = { dir = "s2c" },
	})

	local screen = UI.mount("ForgeEditor", { displayOrder = 400 })
	local root = Instance.new("Frame")
	root.Name = "EditorRoot"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.Visible = false
	root.Parent = screen
	widgets.root = root

	-- PlayerGui, not the overlay frame: see the note in Gizmo.mount.
	Gizmo.mount(player:WaitForChild("PlayerGui"))

	buildMenu(root)
	buildPalette(root)
	buildInspector(root)
	buildConsole(root)

	Net.on("EditorSync", function(payload)
		if payload.openUi ~= nil then
			Ui.toggle(payload.openUi)
			return
		end
		if payload.saved then
			note(string.format("saved %s (%d bytes)", tostring(payload.scene), payload.bytes or 0))
			return
		end
		state.placements = payload.placements or {}
		state.selectedIndex = payload.selectedIndex
		state.selectedCount = payload.selectedCount or 0
		state.gridSize = payload.gridSize or state.gridSize

		-- The gizmo follows the server's idea of the selection centre, never a
		-- locally guessed one: they would drift apart the moment a drag is
		-- partially rejected.
		Gizmo.setTarget(payload.centre)
		if payload.palette and next(payload.palette) then
			state.palette = payload.palette
			refreshPalette()
		end
		if widgets.gridButton then
			widgets.gridButton.Text = state.gridSize > 0 and ("Grid " .. state.gridSize) or "Grid off"
		end
		refreshInspector()
	end)

	UserInputService.InputBegan:Connect(function(input, processed)
		if input.KeyCode == Enum.KeyCode.F4 then
			Ui.toggle()
			return
		end
		if processed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			onClick()
		else
			onKey(input)
		end
	end)

	note("F4 toggles the editor")
end

function Ui.toggle(force: boolean?)
	if not mounted then
		Ui.mount()
	end
	-- Not `force ~= nil and force or not visible`: with force = false the
	-- and/or chain falls through to `not visible`, so "close it" becomes
	-- "toggle it". The oldest trap in Lua and still the easiest to write.
	local wanted
	if force == nil then
		wanted = not visible
	else
		wanted = force
	end
	if wanted == visible then
		return
	end
	visible = wanted
	widgets.root.Visible = visible
	if not visible then
		Gizmo.setTarget(nil)
	end
	if visible then
		send("open")
		note("editor open")
	else
		note("editor closed")
	end
end

--[[
	Switching mode is a client concern: the handles are client instances and the
	server has no opinion about which one is showing. Everything a mode *does*
	still goes through the same server ops.
]]
function Ui.setMode(next_: string)
	Gizmo.setMode(next_)
	if widgets.modeButton then
		local labels = { move = "Move", rotate = "Rotate [E]", scale = "Scale [R]" }
		widgets.modeButton.Text = labels[next_] or next_
	end
	note("mode: " .. next_)
end

function Ui.isOpen(): boolean
	return visible
end

return Ui
