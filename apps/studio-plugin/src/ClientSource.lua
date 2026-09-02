--!strict
-- Source for the client-side instrumentation script.
--
-- Why this exists: a Studio plugin only ever lives in the edit and server
-- DataModels, but ProximityPrompt activation and GUI input are client-only.
-- Measured directly: `InputHoldBegin()` called from the server is accepted and
-- `Triggered` never fires.
--
-- Why it does not speak HTTP: `HttpService` is server-only, so a LocalScript
-- cannot reach the hub. Instead the plugin, which runs in the server DataModel,
-- calls into this script with `RemoteFunction:InvokeClient`. The hub therefore
-- still has exactly one endpoint, and the client half is reached through the
-- server half.
--
-- This module is a string on purpose: `bridge.install_client` writes it into
-- StarterPlayerScripts, so the plugin stays the single artefact to install.

return [==[
-- RQE Client Bridge (installed by the RQE Studio Bridge plugin).
-- Remove with: rqe studio call bridge.remove_client

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CHANNEL_NAME = "RQEClientChannel"
local player = Players.LocalPlayer

local function round(value, places)
	local factor = 10 ^ (places or 3)
	return math.round(value * factor) / factor
end

local function resolve(path)
	if path == nil or path == "" then
		error({ code = "E_BAD_PARAMS", message = "path is required" })
	end
	local current = game
	local walked = {}
	for segment in string.gmatch(path, "[^%.]+") do
		if segment ~= "game" and segment ~= "Game" then
			local nextInstance = nil
			if current == game then
				local ok, service = pcall(function()
					return game:GetService(segment)
				end)
				if ok and service then
					nextInstance = service
				end
			end
			if nextInstance == nil then
				nextInstance = current:FindFirstChild(segment)
			end
			if nextInstance == nil then
				error({ code = "E_NOT_FOUND", message = "no instance at " .. table.concat(walked, ".") .. "." .. segment })
			end
			current = nextInstance
			table.insert(walked, segment)
		end
	end
	return current
end

--- Effective visibility, not the element's own flag: a Frame inside a hidden
--- parent still reports Visible = true, and clicking it would do nothing.
local function effectivelyVisible(item)
	local node = item
	while node and node:IsA("GuiObject") do
		if not node.Visible then
			return false
		end
		node = node.Parent
	end
	return true
end

local COMMANDS = {}

function COMMANDS.info()
	return {
		isClient = RunService:IsClient(),
		isServer = RunService:IsServer(),
		player = player and player.Name or nil,
		userId = player and player.UserId or nil,
		hasCharacter = player and player.Character ~= nil or false,
		attributes = player and player:GetAttributes() or {},
	}
end

-- The reason this script exists: prompt activation only works client-side.
function COMMANDS.prompt_trigger(params)
	local prompt = resolve(params.path)
	if not prompt:IsA("ProximityPrompt") then
		error({ code = "E_BAD_PARAMS", message = prompt:GetFullName() .. " is not a ProximityPrompt" })
	end

	local character = player and player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local anchor = prompt.Parent
	local distance = nil
	if root and anchor and anchor:IsA("BasePart") then
		distance = round((anchor.Position - root.Position).Magnitude, 2)
	end

	if not prompt.Enabled then
		return { success = false, reason = "prompt_disabled", distance = distance }
	end
	if distance ~= nil and distance > prompt.MaxActivationDistance then
		return {
			success = false,
			reason = "out_of_range",
			distance = distance,
			maxActivationDistance = prompt.MaxActivationDistance,
		}
	end

	local fired, firedFor = false, nil
	local connection = prompt.Triggered:Connect(function(triggeredBy)
		fired = true
		firedFor = triggeredBy and triggeredBy.Name or nil
	end)

	local hold = math.max(prompt.HoldDuration, tonumber(params.holdSeconds) or 0) + 0.25
	local ok, err = pcall(function()
		prompt:InputHoldBegin()
		task.wait(hold)
		prompt:InputHoldEnd()
	end)
	task.wait(0.5)
	connection:Disconnect()

	return {
		success = ok and fired,
		triggered = fired,
		triggeredFor = firedFor,
		prompt = prompt:GetFullName(),
		actionText = prompt.ActionText,
		distance = distance,
		maxActivationDistance = prompt.MaxActivationDistance,
		holdSeconds = round(hold, 2),
		-- `x and nil or y` always yields y in Lua, because nil is falsy. Use an
		-- if-expression so a success genuinely reports no reason.
		inputError = if ok then nil else tostring(err),
		reason = if ok and fired then nil elseif ok then "prompt_did_not_fire" else "input_rejected",
	}
end

--[[
	The client's own DataModel, which nothing could see before.

	`gui_tree` answered one question -- what interface exists -- and every other
	question about the client had no answer at all. Debugging a first-person
	weapon meant writing state into a TextLabel and reading it back through the
	GUI tree, because that was the only channel out of a running client.

	A viewmodel parented to the camera, a part hidden by
	`LocalTransparencyModifier`, an effect that only exists on one machine: all
	of it lives here and none of it replicates, so the server cannot be asked.

	Same shape as the server's `dm.tree` and `dm.properties`, deliberately, so a
	caller can point the same code at either side.
]]
function COMMANDS.tree(params)
	local root = resolve(params.path or "Workspace")
	local maxDepth = tonumber(params.depth) or 2
	local limit = tonumber(params.limit) or 400
	local seen = 0

	local function walk(instance, depth)
		seen += 1
		local node = {
			path = instance:GetFullName(),
			name = instance.Name,
			className = instance.ClassName,
		}
		local children = instance:GetChildren()
		node.childCount = #children
		if depth >= maxDepth or seen >= limit then
			return node
		end
		local kids = {}
		for _, child in ipairs(children) do
			if seen >= limit then
				node.childrenOmitted = #children - #kids
				break
			end
			table.insert(kids, walk(child, depth + 1))
		end
		if #kids > 0 then
			node.children = kids
		end
		return node
	end

	return { root = params.path or "Workspace", tree = walk(root, 0),
		truncated = seen >= limit }
end

function COMMANDS.properties(params)
	local instance = resolve(params.path)
	local wanted = params.properties
	if type(wanted) ~= "table" then
		error({ code = "E_BAD_PARAMS",
			message = "properties must be a list of names" })
	end
	local out = {}
	for _, name in ipairs(wanted) do
		--: A property that does not exist on this class is not an error worth
		--: failing the whole call for; the caller asked a reasonable question
		--: about a mixed list of instances.
		local ok, value = pcall(function()
			return (instance :: any)[name]
		end)
		if ok then
			local kind = typeof(value)
			if kind == "Vector3" then
				out[name] = { value.X, value.Y, value.Z }
			elseif kind == "CFrame" then
				out[name] = { value.Position.X, value.Position.Y, value.Position.Z }
			elseif kind == "Color3" then
				out[name] = { value.R, value.G, value.B }
			elseif kind == "EnumItem" then
				out[name] = tostring(value)
			elseif kind == "Instance" then
				out[name] = value:GetFullName()
			elseif kind == "number" or kind == "string" or kind == "boolean" then
				out[name] = value
			else
				out[name] = tostring(value)
			end
		end
	end
	return { path = instance:GetFullName(), className = instance.ClassName,
		properties = out }
end

function COMMANDS.gui_tree(params)
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if playerGui == nil then
		error({ code = "E_NOT_FOUND", message = "PlayerGui is not available yet" })
	end
	local camera = workspace.CurrentCamera
	local viewport = camera and camera.ViewportSize or Vector2.new(0, 0)
	local includeHidden = params.includeHidden == true

	local nodes = {}
	for _, item in ipairs(playerGui:GetDescendants()) do
		local shown = effectivelyVisible(item)
		if item:IsA("GuiObject") and (shown or includeHidden) then
			local absPos, absSize = item.AbsolutePosition, item.AbsoluteSize
			local offScreen = absPos.X + absSize.X < 0
				or absPos.Y + absSize.Y < 0
				or absPos.X > viewport.X
				or absPos.Y > viewport.Y
			table.insert(nodes, {
				path = item:GetFullName(),
				name = item.Name,
				className = item.ClassName,
				visible = shown,
				selfVisible = item.Visible,
				text = (item:IsA("TextLabel") or item:IsA("TextButton") or item:IsA("TextBox")) and item.Text or nil,
				absolutePosition = { round(absPos.X, 1), round(absPos.Y, 1) },
				absoluteSize = { round(absSize.X, 1), round(absSize.Y, 1) },
				offScreen = offScreen,
				interactable = item:IsA("GuiButton") and item.Active or false,
			})
		end
	end

	return { viewport = { viewport.X, viewport.Y }, count = #nodes, elements = nodes }
end

--- Where a button sits on screen, and whether it can be pressed.
function COMMANDS.gui_locate(params)
	local item = resolve(params.path)
	if not item:IsA("GuiObject") then
		return { found = false, reason = "not_a_gui_object" }
	end
	local inset = game:GetService("GuiService"):GetGuiInset()
	local centre = item.AbsolutePosition + item.AbsoluteSize / 2
	return {
		found = true,
		clickable = item:IsA("GuiButton") and item.Active and effectivelyVisible(item),
		visible = effectivelyVisible(item),
		x = round(centre.X, 1),
		y = round(centre.Y + inset.Y, 1),
		size = { round(item.AbsoluteSize.X, 1), round(item.AbsoluteSize.Y, 1) },
		path = item:GetFullName(),
	}
end

local watched = {}

--- Start listening for a button's Activated before the press is delivered.
function COMMANDS.gui_watch(params)
	local button = resolve(params.path)
	if not button:IsA("GuiButton") then
		error({ code = "E_BAD_PARAMS", message = button:GetFullName() .. " is not a GuiButton" })
	end
	local key = button:GetFullName()
	if watched[key] then
		watched[key].connection:Disconnect()
	end
	local record = { fired = false }
	record.connection = button.Activated:Connect(function()
		record.fired = true
	end)
	watched[key] = record
	return { watching = true, path = key }
end

function COMMANDS.gui_watch_result(params)
	local button = resolve(params.path)
	local key = button:GetFullName()
	local record = watched[key]
	if record == nil then
		return { activated = false, reason = "not_watching" }
	end
	record.connection:Disconnect()
	watched[key] = nil
	return {
		activated = record.fired,
		path = key,
		text = button:IsA("TextButton") and button.Text or nil,
	}
end

function COMMANDS.gui_click(params)
	local button = resolve(params.path)
	if not button:IsA("GuiButton") then
		error({ code = "E_BAD_PARAMS", message = button:GetFullName() .. " is not a GuiButton" })
	end
	if not button.Visible then
		return { success = false, reason = "not_visible", path = button:GetFullName() }
	end

	-- A GuiButton's Activated signal cannot be raised from a script, so the
	-- click is delivered as real pointer input at the button's own on-screen
	-- rectangle. VirtualInputManager is Studio-only, which is where tests run.
	local fired = false
	local connection = button.Activated:Connect(function()
		fired = true
	end)

	local guiService = game:GetService("GuiService")
	local centre = button.AbsolutePosition + button.AbsoluteSize / 2
	local inset = guiService:GetGuiInset()

	local pressOk, pressErr = pcall(function()
		local vim = game:GetService("VirtualInputManager")
		vim:SendMouseButtonEvent(centre.X, centre.Y + inset.Y, 0, true, game, 1)
		task.wait(0.08)
		vim:SendMouseButtonEvent(centre.X, centre.Y + inset.Y, 0, false, game, 1)
	end)
	task.wait(0.4)
	connection:Disconnect()

	return {
		success = fired,
		activated = fired,
		path = button:GetFullName(),
		text = button:IsA("TextButton") and button.Text or nil,
		clickedAt = { round(centre.X, 1), round(centre.Y + inset.Y, 1) },
		inputError = if pressOk then nil else tostring(pressErr),
		reason = if fired then nil elseif pressOk then "button_did_not_activate" else "virtual_input_unavailable",
	}
end

--- The client's own Output. A LocalScript that errors is invisible to the
--- server's LogService, so without this a broken HUD looks like a working one
--- that simply drew nothing.
function COMMANDS.logs(params)
	local LogService = game:GetService("LogService")
	local ok, history = pcall(function()
		return LogService:GetLogHistory()
	end)
	if not ok then
		return { available = false, reason = tostring(history), entries = {} }
	end

	local severityOf = {
		[Enum.MessageType.MessageOutput] = "info",
		[Enum.MessageType.MessageInfo] = "info",
		[Enum.MessageType.MessageWarning] = "warning",
		[Enum.MessageType.MessageError] = "error",
	}

	local limit = math.clamp(tonumber(params.limit) or 80, 1, 400)
	local wanted = params.severity
	local entries, counts = {}, { info = 0, warning = 0, error = 0 }
	for _, entry in ipairs(history) do
		local severity = severityOf[entry.messageType] or "info"
		counts[severity] = (counts[severity] or 0) + 1
		if wanted == nil or severity == wanted then
			table.insert(entries, { severity = severity, message = entry.message, timestamp = entry.timestamp })
		end
	end
	while #entries > limit do
		table.remove(entries, 1)
	end
	return { available = true, counts = counts, returned = #entries, entries = entries }
end

--- Invoke a BindableFunction the game exposes for testing.
---
--- Needed because Roblox refuses synthetic GUI input: measured,
--- `VirtualInputManager:SendMouseButtonEvent` is rejected with "lacking
--- capability RobloxScript" from a LocalScript *and* from a plugin. A game
--- that wants its screens testable therefore publishes an entry point, and
--- this calls it. It exercises the same code the button runs; it does not
--- prove the button is wired, which stays a visual check.
function COMMANDS.invoke_bindable(params)
	local target = resolve(params.path)
	if not target:IsA("BindableFunction") then
		error({ code = "E_BAD_PARAMS", message = target:GetFullName() .. " is not a BindableFunction" })
	end
	local ok, result = pcall(function()
		return target:Invoke(params.argument)
	end)
	if not ok then
		error({ code = "E_EXEC", message = tostring(result) })
	end
	return { invoked = true, path = target:GetFullName(), returned = result }
end

--- Fire a RemoteEvent from the client, exactly as a UI button would.
---
--- This is the honest substitute for a synthetic click: Roblox refuses
--- synthetic pointer input, but the thing a button *does* is send this remote,
--- and firing it from the client exercises the server handler under the same
--- identity and the same validation.
function COMMANDS.fire_remote(params)
	local remote = resolve(params.path)
	if not remote:IsA("RemoteEvent") then
		error({ code = "E_BAD_PARAMS", message = remote:GetFullName() .. " is not a RemoteEvent" })
	end
	--[[
		An array is a list of arguments; a map is one payload.

		This unpacked every table, and `table.unpack` on a dictionary yields
		nothing at all -- so `{ machine = "drill" }` arrived at the server as
		`FireServer()` with no argument, the handler's first guard saw a nil
		payload, and it returned silently. The bridge reported `fired = true`
		and the game did nothing.

		That is the shape almost every Roblox game uses: one table of named
		fields per event. Driving a game's network layer from outside was
		therefore broken for exactly the common case, and broken without a
		message.

		A sequence still unpacks, because a caller who writes `args = {a, b, c}`
		means three arguments. The empty table goes through whole: a handler
		expecting a payload is better served by an empty one than by nil.
	]]
	local args = params.args
	if type(args) == "table" then
		local isSequence = next(args) ~= nil
		if isSequence then
			for key in pairs(args) do
				if type(key) ~= "number" then
					isSequence = false
					break
				end
			end
		end

		if isSequence then
			remote:FireServer(table.unpack(args))
		else
			remote:FireServer(args)
		end
	elseif args ~= nil then
		remote:FireServer(args)
	else
		remote:FireServer()
	end
	return { fired = true, path = remote:GetFullName() }
end

--- Do these asset ids actually render for a player?
---
--- Asked on the client because that is where images are fetched and drawn. A
--- moderated or deleted decal assigns to an ImageLabel without complaint and
--- simply shows nothing, so `IsLoaded` is the only honest answer -- and it has
--- to be read after giving the engine time to fetch.
function COMMANDS.probe_images(params)
	local ids = params.ids
	if type(ids) ~= "table" or #ids == 0 then
		error({ code = "E_BAD_PARAMS", message = "ids must be a non-empty array" })
	end

	local holder = Instance.new("ScreenGui")
	holder.Name = "RQEImageProbe"
	holder.Enabled = false
	holder.Parent = player:WaitForChild("PlayerGui")

	local labels = {}
	for _, id in ipairs(ids) do
		local label = Instance.new("ImageLabel")
		label.Size = UDim2.fromOffset(64, 64)
		label.Image = "rbxassetid://" .. tostring(id)
		label.Parent = holder
		table.insert(labels, { id = id, label = label })
	end

	-- Poll rather than PreloadAsync: preloading yields until every asset
	-- resolves, and a dead id makes that wait unbounded.
	local deadline = os.clock() + math.clamp(tonumber(params.waitSeconds) or 8, 1, 25)
	while os.clock() < deadline do
		local allDone = true
		for _, entry in ipairs(labels) do
			if not entry.label.IsLoaded then
				allDone = false
				break
			end
		end
		if allDone then
			break
		end
		task.wait(0.25)
	end

	local results, loaded = {}, 0
	for _, entry in ipairs(labels) do
		local ok = entry.label.IsLoaded
		if ok then
			loaded += 1
		end
		table.insert(results, { id = entry.id, loaded = ok })
	end

	holder:Destroy()
	return { probed = #results, loaded = loaded, results = results }
end

function COMMANDS.player_state()
	local character = player and player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local leaderstats = player and player:FindFirstChild("leaderstats")
	local stats = {}
	if leaderstats then
		for _, stat in ipairs(leaderstats:GetChildren()) do
			local ok, value = pcall(function()
				return stat.Value
			end)
			if ok then
				stats[stat.Name] = value
			end
		end
	end
	return {
		player = player and player.Name or nil,
		userId = player and player.UserId or nil,
		position = root and { round(root.Position.X, 2), round(root.Position.Y, 2), round(root.Position.Z, 2) } or nil,
		health = humanoid and humanoid.Health or nil,
		grounded = humanoid and humanoid.FloorMaterial ~= Enum.Material.Air or nil,
		attributes = player and player:GetAttributes() or {},
		leaderstats = stats,
	}
end


-- ------------------------------------------------------------------ UI family
--
-- The measurements a UI requirement needs, all of them client-side because a
-- GUI's effective state does not exist anywhere else. Reading text from the
-- server returns whatever the server thinks is there, which on a client-driven
-- HUD is nothing at all.

--- client.gui_text: read text, or type into a TextBox.
---
--- Writing goes through the Text property rather than synthesised keystrokes,
--- because VirtualInputManager is refused to us. That means a listener on
--- `FocusLost` fires but one reading raw input does not, and the response says
--- so rather than letting a scenario assume otherwise.
function COMMANDS.gui_text(params)
	local element = resolve(params.path)
	if not (element:IsA("TextLabel") or element:IsA("TextButton") or element:IsA("TextBox")) then
		error({ code = "E_BAD_PARAMS", message = element:GetFullName() .. " has no Text property" })
	end

	local before = element.Text
	local wrote = false
	if params.text ~= nil then
		if not element:IsA("TextBox") then
			error({ code = "E_BAD_PARAMS", message = "only a TextBox accepts input" })
		end
		element.Text = tostring(params.text)
		wrote = true
		if params.commit ~= false then
			-- What a player pressing Enter produces. Without it, code listening on
			-- FocusLost never runs and the typed value is never consumed.
			pcall(function()
				element:ReleaseFocus(true)
			end)
		end
	end

	return {
		path = element:GetFullName(),
		className = element.ClassName,
		text = element.Text,
		previous = before,
		wrote = wrote,
		visible = effectivelyVisible(element),
		textBounds = { element.TextBounds.X, element.TextBounds.Y },
		textFits = element.TextFits,
		truncated = not element.TextFits,
		note = if wrote then "Text was set directly; no keystroke was synthesised" else nil,
	}
end

--- client.gui_scroll: move a ScrollingFrame's canvas.
function COMMANDS.gui_scroll(params)
	local element = resolve(params.path)
	if not element:IsA("ScrollingFrame") then
		error({ code = "E_BAD_PARAMS", message = element:GetFullName() .. " is not a ScrollingFrame" })
	end

	local before = element.CanvasPosition
	local target = before
	if params.to ~= nil then
		target = Vector2.new(params.to[1] or before.X, params.to[2] or before.Y)
	elseif params.by ~= nil then
		target = before + Vector2.new(params.by[1] or 0, params.by[2] or 0)
	elseif params.edge == "bottom" then
		target = Vector2.new(before.X, element.AbsoluteCanvasSize.Y)
	elseif params.edge == "top" then
		target = Vector2.new(before.X, 0)
	else
		error({ code = "E_BAD_PARAMS", message = "gui_scroll needs to, by, or edge" })
	end

	element.CanvasPosition = target
	local after = element.CanvasPosition

	return {
		path = element:GetFullName(),
		from = { before.X, before.Y },
		to = { after.X, after.Y },
		requested = { target.X, target.Y },
		-- Roblox clamps to the canvas. Reporting the clamp is what stops a caller
		-- believing it scrolled somewhere it could not reach.
		clamped = (after - target).Magnitude > 0.5,
		canvasSize = { element.AbsoluteCanvasSize.X, element.AbsoluteCanvasSize.Y },
		windowSize = { element.AbsoluteWindowSize.X, element.AbsoluteWindowSize.Y },
		atBottom = after.Y >= element.AbsoluteCanvasSize.Y - element.AbsoluteWindowSize.Y - 1,
	}
end

--- client.camera_set: move the camera the running game is actually rendering.
---
--- `camera.set` runs in the plugin, which lives in the *edit* DataModel. During
--- Play the viewport shows a different one, so the plugin command reports
--- applied, changes an off-screen camera, and every capture comes back from
--- wherever the player camera happened to be. Two captures at different
--- requested positions came back byte-identical, and only the capture's own
--- pose check noticed.
---
--- Restores the previous camera type on release, because a camera left
--- Scriptable after a capture looks to a player like the game has frozen.
local savedCameraType: Enum.CameraType? = nil

function COMMANDS.camera_set(params)
	local camera = workspace.CurrentCamera
	if camera == nil then
		error("there is no CurrentCamera on this client", 0)
	end

	local position = params.position
	if type(position) ~= "table" or #position ~= 3 then
		error("position must be three numbers", 0)
	end

	if savedCameraType == nil then
		savedCameraType = camera.CameraType
	end
	camera.CameraType = Enum.CameraType.Scriptable

	local at = Vector3.new(position[1], position[2], position[3])
	local lookAt = params.lookAt
	if type(lookAt) == "table" and #lookAt == 3 then
		camera.CFrame = CFrame.lookAt(at, Vector3.new(lookAt[1], lookAt[2], lookAt[3]))
	else
		camera.CFrame = CFrame.new(at)
	end
	if type(params.fieldOfView) == "number" then
		camera.FieldOfView = params.fieldOfView
	end

	-- Reported back so a caller can compare what it asked for against what the
	-- engine settled on, rather than trusting that setting it worked.
	local pos = camera.CFrame.Position
	local look = camera.CFrame.LookVector
	return {
		applied = true,
		position = { round(pos.X, 3), round(pos.Y, 3), round(pos.Z, 3) },
		lookVector = { round(look.X, 4), round(look.Y, 4), round(look.Z, 4) },
		fieldOfView = camera.FieldOfView,
		cameraType = camera.CameraType.Name,
	}
end

--- client.camera_release: hand the camera back to the player.
function COMMANDS.camera_release(params)
	local camera = workspace.CurrentCamera
	if camera == nil then
		error("there is no CurrentCamera on this client", 0)
	end
	camera.CameraType = savedCameraType or Enum.CameraType.Custom
	savedCameraType = nil
	local player = game:GetService("Players").LocalPlayer
	local character = player and player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid ~= nil then
		camera.CameraSubject = humanoid
	end
	return { released = true, cameraType = camera.CameraType.Name }
end

--- client.viewport: the screen a requirement is actually being judged on.
function COMMANDS.viewport(params)
	local camera = workspace.CurrentCamera
	local size = camera and camera.ViewportSize or Vector2.new(0, 0)
	local inset = game:GetService("GuiService"):GetGuiInset()
	local input = game:GetService("UserInputService")

	-- Device class from the viewport rather than from a platform enum: what
	-- matters to a layout is how much room it has, and a small window on a
		-- desktop has the same problem a phone does.
	local class = "desktop"
	if size.X < 768 then
		class = "phone"
	elseif size.X < 1024 then
		class = "tablet"
	end

	return {
		viewport = { size.X, size.Y },
		aspectRatio = if size.Y > 0 then round(size.X / size.Y, 4) else 0,
		deviceClass = class,
		guiInset = { inset.X, inset.Y },
		touchEnabled = input.TouchEnabled,
		keyboardEnabled = input.KeyboardEnabled,
		gamepadEnabled = input.GamepadEnabled,
		mouseEnabled = input.MouseEnabled,
	}
end

--- client.gui_snapshot: every visible element with a measured rectangle.
---
--- The structured counterpart to a screenshot: a capture shows what it looks
--- like, this says what is there, where, and whether it overflows the screen.
function COMMANDS.gui_snapshot(params)
	local camera = workspace.CurrentCamera
	local viewport = camera and camera.ViewportSize or Vector2.new(0, 0)
	local limit = math.clamp(tonumber(params.limit) or 300, 1, 2000)

	local roots = {}
	if params.path ~= nil then
		table.insert(roots, resolve(params.path))
	else
		local gui = player and player:FindFirstChildOfClass("PlayerGui")
		if gui ~= nil then
			table.insert(roots, gui)
		end
	end

	local elements = {}
	local offscreen = 0
	local overlapping = 0
	local total = 0
	local rectangles = {}

	for _, root in ipairs(roots) do
		for _, descendant in ipairs(root:GetDescendants()) do
			if descendant:IsA("GuiObject") and effectivelyVisible(descendant) then
				total += 1
				local position = descendant.AbsolutePosition
				local size = descendant.AbsoluteSize
				local outside = position.X + size.X < 0 or position.Y + size.Y < 0
					or position.X > viewport.X or position.Y > viewport.Y
				if outside then
					offscreen += 1
				end
				if #elements < limit then
					table.insert(elements, {
						path = descendant:GetFullName(),
						className = descendant.ClassName,
						name = descendant.Name,
						position = { position.X, position.Y },
						size = { size.X, size.Y },
						offscreen = outside,
						text = if descendant:IsA("TextLabel") or descendant:IsA("TextButton")
							then descendant.Text else nil,
						truncated = if descendant:IsA("TextLabel") or descendant:IsA("TextButton")
							then not descendant.TextFits else nil,
						zIndex = descendant.ZIndex,
					})
					table.insert(rectangles, { position, size, descendant:GetFullName() })
				end
			end
		end
	end

	return {
		viewport = { viewport.X, viewport.Y },
		elements = elements,
		returned = #elements,
		total = total,
		truncated = total > #elements,
		offscreen = offscreen,
	}
end

local channel = ReplicatedStorage:WaitForChild(CHANNEL_NAME, 30)
if channel == nil then
	warn("[RQE Client] no " .. CHANNEL_NAME .. "; the plugin creates it when a play session starts")
	return
end

channel.OnClientInvoke = function(request)
	if type(request) ~= "table" or type(request.method) ~= "string" then
		return { ok = false, error = { code = "E_BAD_PARAMS", message = "request must carry a method" } }
	end
	local handler = COMMANDS[request.method]
	if handler == nil then
		local names = {}
		for name in pairs(COMMANDS) do
			table.insert(names, "client." .. name)
		end
		return { ok = false, error = { code = "E_UNKNOWN_METHOD", message = "client." .. request.method, details = { available = names } } }
	end
	local started = os.clock()
	local ok, result = pcall(handler, request.params or {})
	if ok then
		return { ok = true, result = result, elapsedMs = (os.clock() - started) * 1000 }
	end
	if type(result) == "table" and result.code then
		return { ok = false, error = result }
	end
	return { ok = false, error = { code = "E_EXEC", message = tostring(result) } }
end

print("[RQE Client] instrumentation ready for " .. tostring(player and player.Name))
]==]
