--!strict
--- Screens described as data, and kept in step with the game that owns them.
---
--- `Ui` has everything needed to build a screen -- panels, stacks, meters,
--- chips, buttons, a whole design system reading from tokens. What it had no
--- way to express was *a screen*: every generated game got its interface from a
--- template, so a caller could ask for "the shop screen" and could not ask for
--- "a sanity bar in the top-left bound to this attribute". That is the
--- difference between choosing from a menu and writing.
---
--- Two things make this more than a thin wrapper.
---
--- **Layout is not optional.** `Ui.panel` at its defaults is 100x100 with no
--- layout, so children pile at the origin and spill outside the background.
--- Every generated game had this and nobody saw it, because nobody opened a
--- screen. A composed panel always gets a stack and padding; there is no way to
--- ask for the broken arrangement.
---
--- **Bindings are live.** A meter bound to `Sanity` follows the attribute for
--- as long as the screen exists, and stops when it is destroyed. A number
--- painted once at build time is the most common way a HUD lies.

local Players = game:GetService("Players")

local Compose = {}

export type Binding = {
	--- The attribute to follow, read from the player unless `on` says otherwise.
	attribute: string,
	--- "player" (default), "workspace", or a full instance path.
	on: string?,
	--- Meters only: what counts as full.
	max: number?,
	--- Text only: a format string taking one value, e.g. "Sanity: %d%%".
	format: string?,
}

export type Element = {
	kind: string,
	body: string?,
	step: string?,
	caption: string?,
	icon: string?,
	bind: Binding?,
	children: { Element }?,
	options: { [string]: any }?,
}

export type Spec = {
	name: string,
	--- topLeft, topRight, bottomLeft, bottomRight, top, bottom, centre.
	anchor: string?,
	enabled: boolean?,
	children: { Element },
}

local KINDS = {
	panel = true, stack = true, text = true, value = true, meter = true,
	button = true, chip = true, icon = true, spacer = true, shelf = true,
	scroller = true,
}

local ANCHORS: { [string]: { any } } = {
	topLeft = { Vector2.new(0, 0), UDim2.fromScale(0.02, 0.03) },
	topRight = { Vector2.new(1, 0), UDim2.fromScale(0.98, 0.03) },
	bottomLeft = { Vector2.new(0, 1), UDim2.fromScale(0.02, 0.97) },
	bottomRight = { Vector2.new(1, 1), UDim2.fromScale(0.98, 0.97) },
	top = { Vector2.new(0.5, 0), UDim2.fromScale(0.5, 0.03) },
	bottom = { Vector2.new(0.5, 1), UDim2.fromScale(0.5, 0.97) },
	centre = { Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.5) },
}

--- `Ui.stack` speaks CSS: "row" and "column". A caller describing a screen
--- thinks in "vertical" and "horizontal", and gets an error naming neither if
--- the two vocabularies are left to collide. Both are accepted here.
local function direction(options: { [string]: any }): string
	local named = tostring(options.direction or "column")
	if named == "vertical" then
		return "column"
	end
	if named == "horizontal" then
		return "row"
	end
	return named
end

--- Say everything wrong with a spec before building any of it.
---
--- Returned as a list rather than raised: a caller fixing a screen wants all
--- five mistakes, not the first one five times.
function Compose.validate(spec: Spec): { string }
	local problems = {}
	if type(spec) ~= "table" then
		return { "screen spec must be a table" }
	end
	if type(spec.name) ~= "string" or spec.name == "" then
		table.insert(problems, "screen needs a name")
	end
	if spec.anchor ~= nil and ANCHORS[spec.anchor] == nil then
		local names = {}
		for key in pairs(ANCHORS) do table.insert(names, key) end
		table.sort(names)
		table.insert(problems, ("anchor %q is not one of %s"):format(
			tostring(spec.anchor), table.concat(names, ", ")))
	end
	if type(spec.children) ~= "table" or #spec.children == 0 then
		table.insert(problems, "screen has no children, so it would open blank")
	end

	local function walk(element: Element, path: string)
		if type(element) ~= "table" or type(element.kind) ~= "string" then
			table.insert(problems, path .. ": element needs a kind")
			return
		end
		if not KINDS[element.kind] then
			local names = {}
			for key in pairs(KINDS) do table.insert(names, key) end
			table.sort(names)
			table.insert(problems, ("%s: no element kind %q; have %s"):format(
				path, element.kind, table.concat(names, ", ")))
			return
		end
		if element.kind == "meter" and element.bind == nil then
			table.insert(problems, path .. ": a meter with no binding never moves")
		end
		if element.bind ~= nil and type(element.bind.attribute) ~= "string" then
			table.insert(problems, path .. ": binding needs an attribute name")
		end
		if (element.kind == "text" or element.kind == "button")
			and element.body == nil and element.bind == nil then
			table.insert(problems, path .. ": " .. element.kind .. " needs body or a binding")
		end
		for index, child in ipairs(element.children or {}) do
			walk(child, path .. "." .. element.kind .. "[" .. index .. "]")
		end
	end

	for index, child in ipairs(spec.children or {}) do
		walk(child, "child[" .. index .. "]")
	end
	return problems
end

local function sourceFor(binding: Binding, player: Player?): Instance?
	local on = binding.on or "player"
	if on == "player" then
		return player
	end
	if on == "workspace" then
		return workspace
	end
	local node: Instance = game
	for piece in string.gmatch(on, "[^%.]+") do
		if piece ~= "game" then
			local found = node:FindFirstChild(piece)
			if found == nil then
				return nil
			end
			node = found
		end
	end
	return node
end

--- Wire one element to an attribute and keep it there.
---
--- The connection is parented to the element, so destroying the screen stops
--- the updates. A HUD that keeps recomputing after it is gone is a leak that
--- only shows up under a long session, which is exactly when nobody is looking.
local function bindElement(tokens: any, instance: Instance, kind: string,
	binding: Binding, player: Player?, live: { RBXScriptConnection })

	local source = sourceFor(binding, player)
	if source == nil then
		warn("[Compose] nothing at " .. tostring(binding.on) .. " to bind " .. binding.attribute)
		return
	end

	local function paint()
		local value = source:GetAttribute(binding.attribute)
		if kind == "meter" then
			local Ui = require(script.Parent.Ui)
			local maximum = binding.max or 100
			local fraction = math.clamp((tonumber(value) or 0) / math.max(maximum, 1), 0, 1)
			-- Tokens first: the fill colour carries the urgency, so the meter
			-- has to be able to reach the palette.
			Ui.meterSet(tokens, instance :: Frame, fraction)
			return
		end
		local text = if binding.format ~= nil
			then string.format(binding.format, tonumber(value) or 0)
			else tostring(value == nil and "" or value)
		if instance:IsA("TextLabel") or instance:IsA("TextButton") then
			instance.Text = text
		else
			local label = instance:FindFirstChildWhichIsA("TextLabel", true)
			if label ~= nil then
				label.Text = text
			end
		end
	end

	paint()
	table.insert(live, source:GetAttributeChangedSignal(binding.attribute):Connect(paint))
end

--- Build a screen. Refuses the whole spec on any problem.
function Compose.build(parent: Instance, tokens: any, spec: Spec, player: Player?): (ScreenGui?, { string })
	local problems = Compose.validate(spec)
	if #problems > 0 then
		return nil, problems
	end

	local Ui = require(script.Parent.Ui)
	local screen = Ui.screen(parent, spec.name, {})
	-- Generated games all built `Enabled = false` and nothing ever set it true,
	-- so no game the factory made could open a screen. The default here is on.
	screen.Enabled = spec.enabled ~= false

	local anchor = ANCHORS[spec.anchor or "topLeft"]
	local live: { RBXScriptConnection } = {}

	local function place(element: Element, into: Instance): Instance?
		local kind = element.kind
		local options = element.options or {}
		local made: Instance? = nil

		if kind == "panel" then
			local panel = Ui.panel(tokens, into, options)
			-- Always a layout. `Ui.panel` alone piles children at the origin.
			made = Ui.stack(tokens, panel, direction(options), options)
		elseif kind == "stack" then
			made = Ui.stack(tokens, into, direction(options), options)
		elseif kind == "text" then
			made = Ui.text(tokens, into, element.step or "body", element.body or "", options)
		elseif kind == "value" then
			made = Ui.value(tokens, into, element.caption or "", element.body or "", options)
		elseif kind == "meter" then
			made = Ui.meter(tokens, into, options)
		elseif kind == "button" then
			made = Ui.button(tokens, into, element.body or "", options)
		elseif kind == "chip" then
			made = Ui.chip(tokens, into, options)
		elseif kind == "icon" then
			made = Ui.icon(tokens, into, element.icon or "star", options)
		elseif kind == "spacer" then
			made = Ui.spacer(tokens, into, element.step or "md", options)
		elseif kind == "shelf" then
			made = Ui.shelf(tokens, into, options)
		elseif kind == "scroller" then
			made = Ui.scroller(tokens, into, options)
		end

		if made == nil then
			return nil
		end
		if element.bind ~= nil then
			bindElement(tokens, made, kind, element.bind, player, live)
		end
		-- A panel's children go inside the panel; a stack's inside the stack.
		local host = if made:IsA("GuiObject") then made else into
		for _, child in ipairs(element.children or {}) do
			place(child, host)
		end
		return made
	end

	local root = Ui.stack(tokens, screen, "column", {})
	root.AnchorPoint = anchor[1]
	root.Position = anchor[2]
	root.Size = UDim2.fromOffset(0, 0)
	root.AutomaticSize = Enum.AutomaticSize.XY
	root.BackgroundTransparency = 1

	for _, child in ipairs(spec.children) do
		place(child, root)
	end

	screen.Destroying:Connect(function()
		for _, connection in ipairs(live) do
			connection:Disconnect()
		end
	end)

	-- `Ui.audit` is the same check the emit gate runs. Reporting it here means a
	-- composed screen is held to the standard a generated one is.
	local audit = Ui.audit(screen)
	return screen, audit
end

--- Build the screen for every player, now and as they arrive.
function Compose.publish(tokens: any, spec: Spec): { string }
	local problems = Compose.validate(spec)
	if #problems > 0 then
		return problems
	end
	local function give(player: Player)
		local gui = player:FindFirstChildOfClass("PlayerGui")
		if gui == nil then
			return
		end
		local existing = gui:FindFirstChild(spec.name)
		if existing ~= nil then
			existing:Destroy()
		end
		Compose.build(gui, tokens, spec, player)
	end
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(give, player)
	end
	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Wait()
		give(player)
	end)
	return {}
end

return Compose
