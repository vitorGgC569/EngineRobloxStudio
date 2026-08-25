--!strict
--[[
	Editor — the authoring surface over a Scene.

	Two callers, one API. A person clicking in the overlay and an agent calling
	`Editor.place("Prop.Barrel", cf)` go through exactly the same operations,
	which is the only way the UI and the automation can stay in agreement.

		Editor.open(scene)
		Editor.place("Prop.Barrel", CFrame.new(10, 3, 0))
		Editor.select(placement)
		Editor.nudge(Vector3.new(4, 0, 0))
		Editor.rotate(45)
		Editor.undo()
		local json = Editor.save()

	The server is the only mutator. Editor operations arrive as one rate-limited
	event and are refused unless the sender is authorised — an editor reachable
	by any client is a griefing tool, and "we will remember to gate it later" is
	how that ships.

	Undo is real: every operation records its inverse before applying. A place
	undoes to a delete, a move undoes to the previous CFrame.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")

local Assets = require(script.Parent.Assets)
local Scene = require(script.Parent.Scene)
local Net = require(script.Parent.Net)
local Signal = require(script.Parent.Core.Signal)

local Editor = {}

Editor.changed = Signal.new() -- (scene)
Editor.selectionChanged = Signal.new() -- (placement)

local IS_SERVER = RunService:IsServer()

local current: any = nil
local selected: { any } = {}
local clipboard: { any } = {}
local undoStack: { any } = {}
local redoStack: { any } = {}
local editors: { [Player]: boolean } = {}
local streamer: any = nil

Editor.config = {
	gridSize = 4,
	rotationStep = 15,
	maxUndo = 120,
	-- Who may edit. Studio is always allowed because a local test session has
	-- no real authority anyway; a live game must name its people.
	allowInStudio = true,
	allowedUserIds = {} :: { number },
	allowAllInPlaytest = false,
}

-- ============================== authorisation ===============================
function Editor.authorised(player: Player): boolean
	if Editor.config.allowInStudio and RunService:IsStudio() then
		return true
	end
	if Editor.config.allowAllInPlaytest then
		return true
	end
	for _, userId in Editor.config.allowedUserIds do
		if player.UserId == userId then
			return true
		end
	end
	return false
end

-- ============================== the document ================================
function Editor.open(scene: any): any
	current = scene
	table.clear(selected)
	table.clear(undoStack)
	table.clear(redoStack)
	if not scene:isLoaded() then
		scene:load()
	end
	Editor.changed:Fire(scene)
	return scene
end

function Editor.scene(): any
	return current
end

function Editor.attachStreamer(value: any)
	streamer = value
end

local function touched()
	-- A placement that moved may have crossed a chunk boundary; the streamer's
	-- index has to follow or the piece stops loading where it now is.
	if streamer then
		streamer:reindex()
	end
	Editor.changed:Fire(current)
end

local function pushUndo(entry: any)
	table.insert(undoStack, entry)
	if #undoStack > Editor.config.maxUndo then
		table.remove(undoStack, 1)
	end
	table.clear(redoStack)
end

-- ================================ operations ================================
--[[
	Coerce a position that arrived from anywhere.

	The overlay sends a real Vector3 from a raycast. An agent driving the bridge
	sends JSON, so the same field arrives as `{30, 34, 24}` or
	`{x = 30, y = 34, z = 24}`. Without this, "the UI and automation go through
	the same operations" is a claim that only holds for callers already inside
	Luau — which was true of this file until a bridge test proved it was not.
]]
function Editor.toVector(value: any): Vector3
	if typeof(value) == "Vector3" then
		return value
	end
	if type(value) == "table" then
		local x = value.x or value.X or value[1]
		local y = value.y or value.Y or value[2]
		local z = value.z or value.Z or value[3]
		if type(x) == "number" and type(y) == "number" and type(z) == "number" then
			return Vector3.new(x, y, z)
		end
	end
	return Vector3.zero
end

function Editor.snapVector(position: Vector3, grid: number?): Vector3
	local size = grid or Editor.config.gridSize
	if size <= 0 then
		return position
	end
	return Vector3.new(
		math.round(position.X / size) * size,
		position.Y,
		math.round(position.Z / size) * size
	)
end

function Editor.place(assetId: string, cframe: CFrame, options: any?): any
	if not current then
		return nil
	end
	if not Assets.exists(assetId) then
		warn(string.format("[Editor] no asset '%s'", assetId))
		return nil
	end

	local placement = current:add(assetId, cframe, options)
	pushUndo({ kind = "place", placement = placement })
	Editor.selectPlacement(placement)
	touched()
	return placement
end

local function targets(placement: any?): { any }
	if placement then
		return { placement }
	end
	return selected
end

function Editor.delete(placement: any?)
	if not current then
		return false
	end
	local list = targets(placement)
	local removed = 0

	for _, target in table.clone(list) do
		local index = table.find(current.placements, target)
		if not index then
			continue
		end
		if target.options and target.options.locked then
			continue
		end
		current:dematerialise(target)
		table.remove(current.placements, index)
		pushUndo({ kind = "delete", placement = target, index = index })
		removed += 1
	end

	if removed > 0 then
		Editor.selectPlacement(nil)
		touched()
	end
	return removed > 0
end

-- ============================ lock and visibility ===========================
--[[
	Locked things cannot be selected by clicking, which is what makes editing a
	dense scene possible: terrain dressing stops fighting you for every click.
	Hidden things stay in the scene data and leave the world.
]]
function Editor.setLocked(locked: boolean, placement: any?)
	for _, target in targets(placement) do
		target.options = target.options or {}
		target.options.locked = locked or nil
	end
	Editor.changed:Fire(current)
end

function Editor.setHidden(hidden: boolean, placement: any?)
	if not current then
		return
	end
	for _, target in targets(placement) do
		target.options = target.options or {}
		target.options.hidden = hidden or nil
		if hidden then
			current:dematerialise(target)
		elseif current:isLoaded() and not target._instance then
			current:materialise(target)
		end
	end
	touched()
end

-- ================================ clipboard =================================
function Editor.copy(placement: any?): number
	clipboard = {}
	local centre = Editor.selectionCentre()
	for _, target in targets(placement) do
		table.insert(clipboard, {
			asset = target.asset,
			offset = centre and (target.cframe.Position - centre.Position) or Vector3.zero,
			rotation = target.cframe - target.cframe.Position,
			options = table.clone(target.options or {}),
		})
	end
	return #clipboard
end

--[[
	Paste keeps the relative arrangement of what was copied.

	Pasting each piece at the cursor collapses a copied camp into one point,
	which is the version of paste nobody wants twice.
]]
function Editor.paste(at: Vector3?): { any }
	if not current or #clipboard == 0 then
		return {}
	end
	local centre = Editor.selectionCentre()
	local origin = at or (centre and centre.Position) or Vector3.zero
	local created = {}
	for _, entry in clipboard do
		local options = table.clone(entry.options)
		options.group = nil -- a pasted copy is its own thing
		local placement = Editor.place(entry.asset, entry.rotation + origin + entry.offset, options)
		if placement then
			table.insert(created, placement)
		end
	end
	Editor.selectMany(created)
	return created
end

function Editor.setCFrame(placement: any, cframe: CFrame)
	if not placement then
		return
	end
	pushUndo({ kind = "transform", placement = placement, from = placement.cframe })
	placement.cframe = cframe
	if placement._instance then
		if placement._instance:IsA("Model") then
			placement._instance:PivotTo(cframe)
		elseif placement._instance:IsA("BasePart") then
			placement._instance.CFrame = cframe
		end
	end
	touched()
end

function Editor.nudge(delta: Vector3, placement: any?)
	for _, target in targets(placement) do
		Editor.setCFrame(target, target.cframe + delta)
	end
end

--[[
	Rotation about the selection's own centre, not about each piece's origin.

	Rotating each piece independently spins them in place and leaves the
	arrangement untouched, which is never what "rotate this camp" means.
]]
function Editor.rotate(degrees: number, axis: string?, placement: any?)
	local list = targets(placement)
	if #list == 0 then
		return
	end

	local turn
	if axis == "x" then
		turn = CFrame.Angles(math.rad(degrees), 0, 0)
	elseif axis == "z" then
		turn = CFrame.Angles(0, 0, math.rad(degrees))
	else
		turn = CFrame.Angles(0, math.rad(degrees), 0)
	end

	if #list == 1 then
		Editor.setCFrame(list[1], list[1].cframe * turn)
		return
	end

	local centre = Editor.selectionCentre()
	if not centre then
		return
	end
	for _, target in list do
		local relative = centre:ToObjectSpace(target.cframe)
		Editor.setCFrame(target, centre * turn * relative)
	end
end

--[[
	Scale. `Model:ScaleTo` is the only uniform scale Roblox offers and not every
	model accepts it, so the factor is recorded in the placement as well: a scene
	reloaded from JSON reproduces the size even where the live call failed.
]]
function Editor.scale(factor: number, placement: any?)
	for _, target in targets(placement) do
		target.options = target.options or {}
		local previous = target.options.scale or 1
		local next_ = math.clamp(previous * factor, 0.1, 20)
		pushUndo({ kind = "scale", placement = target, from = previous })
		target.options.scale = next_

		local instance = target._instance
		if instance and instance:IsA("Model") then
			local ok = pcall(function()
				(instance :: any):ScaleTo(next_)
			end)
			if not ok then
				warn("[Editor] this model cannot be scaled")
			end
		elseif instance and instance:IsA("BasePart") then
			instance.Size = instance.Size * factor
		end
	end
	touched()
end

function Editor.duplicate(placement: any?): any
	local list = targets(placement)
	if not current or #list == 0 then
		return nil
	end
	local offset = Vector3.new(Editor.config.gridSize, 0, Editor.config.gridSize)
	local created = {}
	for _, target in list do
		local copy = Editor.place(target.asset, target.cframe + offset, table.clone(target.options or {}))
		if copy then
			table.insert(created, copy)
		end
	end
	Editor.selectMany(created)
	return created[1]
end

-- Drop a placement onto whatever is under it. The single most used editor
-- action, and the one people otherwise do by eye and get wrong by half a stud.
function Editor.groundPlacement(placement: any?)
	for _, target in targets(placement) do
		Editor.groundOne(target)
	end
end

function Editor.groundOne(target: any)
	if not target then
		return
	end
	local origin = target.cframe.Position + Vector3.new(0, 60, 0)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { target._instance }

	local result = Workspace:Raycast(origin, Vector3.new(0, -300, 0), params)
	if result then
		local height = 0
		if target._instance and target._instance:IsA("Model") then
			local _, size = target._instance:GetBoundingBox()
			height = size.Y / 2
		elseif target._instance and target._instance:IsA("BasePart") then
			height = target._instance.Size.Y / 2
		end
		local rotation = target.cframe - target.cframe.Position
		Editor.setCFrame(target, rotation + result.Position + Vector3.new(0, height, 0))
	end
end

-- ================================ selection =================================
--[[
	Selection is a list, not a slot.

	Single selection is the special case of a list with one entry, and building
	it the other way round means multi-select arrives as a rewrite of every
	operation rather than as a loop. Every op below applies to the whole
	selection; `Editor.primary()` is the one the inspector shows.
]]
function Editor.selectPlacement(placement: any?, additive: boolean?)
	if not placement then
		table.clear(selected)
	elseif additive then
		local index = table.find(selected, placement)
		if index then
			table.remove(selected, index)
		else
			table.insert(selected, placement)
		end
	else
		selected = { placement }
	end
	Editor.selectionChanged:Fire(Editor.primary())
end

function Editor.selectMany(placements: { any })
	selected = table.clone(placements)
	Editor.selectionChanged:Fire(Editor.primary())
end

-- Everything in a placed prefab, from any one of its pieces. Selecting a tent
-- and getting the camp is what makes group editing usable.
function Editor.selectGroupOf(placement: any?)
	local target = placement or Editor.primary()
	if not current or not target or not target.options or not target.options.group then
		return
	end
	Editor.selectMany(current:group(target.options.group))
end

function Editor.selectInstance(instance: Instance?, additive: boolean?): any
	if not current or not instance then
		Editor.selectPlacement(nil)
		return nil
	end
	local model = instance:IsA("Model") and instance or instance:FindFirstAncestorOfClass("Model")
	for _, placement in current.placements do
		if placement._instance == instance or placement._instance == model then
			if placement.options and placement.options.locked then
				return nil -- locked things are scenery, not targets
			end
			Editor.selectPlacement(placement, additive)
			return placement
		end
	end
	return nil
end

function Editor.selection(): { any }
	return selected
end

function Editor.primary(): any?
	return selected[1]
end

function Editor.selectionCount(): number
	return #selected
end

-- The centre of the selection, which is what a gizmo anchors to.
function Editor.selectionCentre(): CFrame?
	if #selected == 0 then
		return nil
	end
	local sum = Vector3.zero
	for _, placement in selected do
		sum += placement.cframe.Position
	end
	return CFrame.new(sum / #selected)
end

-- Everything matching a substring of its asset id or name. The only practical
-- way to find one placement among four hundred.
function Editor.search(query: string): { any }
	if not current then
		return {}
	end
	local needle = string.lower(query)
	local out = {}
	for index, placement in current.placements do
		local name = string.lower(placement.asset .. " " .. tostring(placement.options and placement.options.name or ""))
		if string.find(name, needle, 1, true) then
			table.insert(out, { index = index, placement = placement })
		end
	end
	return out
end

-- ================================ undo/redo =================================
local function applyInverse(entry: any, into: { any })
	if entry.kind == "place" then
		local index = table.find(current.placements, entry.placement)
		if index then
			current:dematerialise(entry.placement)
			table.remove(current.placements, index)
		end
		table.insert(into, { kind = "delete", placement = entry.placement, index = index or #current.placements + 1 })
	elseif entry.kind == "delete" then
		table.insert(current.placements, math.min(entry.index, #current.placements + 1), entry.placement)
		if current:isLoaded() then
			current:materialise(entry.placement)
		end
		table.insert(into, { kind = "place", placement = entry.placement })
	elseif entry.kind == "scale" then
		local previous = (entry.placement.options and entry.placement.options.scale) or 1
		entry.placement.options = entry.placement.options or {}
		entry.placement.options.scale = entry.from
		if entry.placement._instance and entry.placement._instance:IsA("Model") then
			pcall(function()
				(entry.placement._instance :: any):ScaleTo(entry.from)
			end)
		end
		table.insert(into, { kind = "scale", placement = entry.placement, from = previous })
	elseif entry.kind == "transform" then
		local previous = entry.placement.cframe
		entry.placement.cframe = entry.from
		if entry.placement._instance then
			if entry.placement._instance:IsA("Model") then
				entry.placement._instance:PivotTo(entry.from)
			elseif entry.placement._instance:IsA("BasePart") then
				entry.placement._instance.CFrame = entry.from
			end
		end
		table.insert(into, { kind = "transform", placement = entry.placement, from = previous })
	end
end

function Editor.undo(): boolean
	if not current or #undoStack == 0 then
		return false
	end
	local entry = table.remove(undoStack)
	applyInverse(entry, redoStack)
	touched()
	return true
end

function Editor.redo(): boolean
	if not current or #redoStack == 0 then
		return false
	end
	local entry = table.remove(redoStack)
	applyInverse(entry, undoStack)
	touched()
	return true
end

-- ============================== persistence =================================
function Editor.save(): string?
	if not current then
		return nil
	end
	local json = current:toJson()
	-- Published where `dm.properties` can read it, the same channel Debug uses.
	-- That is what lets `forge scene pull` get a world out of a live session.
	local holder = Workspace:FindFirstChild("ForgeScenes")
	if not holder then
		holder = Instance.new("Folder")
		holder.Name = "ForgeScenes"
		holder.Parent = Workspace
	end
	local value = holder:FindFirstChild(current.name)
	if not value then
		value = Instance.new("StringValue")
		value.Name = current.name
		value.Parent = holder
	end
	;(value :: StringValue).Value = json
	return json
end

function Editor.loadJson(text: string): any
	local scene = Scene.fromJson(text)
	return Editor.open(scene)
end

-- ================================= palette ==================================
function Editor.palette(): { [string]: { string } }
	local out: { [string]: { string } } = {}
	for _, namespace in Assets.namespaces() do
		out[namespace] = Assets.ids(namespace)
	end
	return out
end

-- ================================ networking ================================
--[[
	One event, one switch. A separate remote per operation is a wider surface
	to authorise and an easier one to forget.
]]
function Editor.serve()
	if not IS_SERVER then
		return
	end

	Net.define({
		EditorOp = { dir = "c2s", rate = 30, shape = { op = "string", data = "table" } },
		EditorSync = { dir = "s2c" },
	})

	local function syncTo(player: Player)
		if not current then
			return
		end
		local list = {}
		for index, placement in current.placements do
			table.insert(list, {
				index = index,
				asset = placement.asset,
				position = placement.cframe.Position,
				selected = table.find(selected, placement) ~= nil,
			})
		end
		local centre = Editor.selectionCentre()
		Net.fire(player, "EditorSync", {
			scene = current.name,
			placements = list,
			palette = Editor.palette(),
			-- The gizmo lives at the centre of the selection, so the client needs
			-- it every sync rather than recomputing from a placement list it only
			-- has positions for.
			centre = centre and centre.Position or nil,
			selectedIndex = Editor.primary() and table.find(current.placements, Editor.primary()) or nil,
			selectedCount = #selected,
			gridSize = Editor.config.gridSize,
			undo = #undoStack,
			redo = #redoStack,
		})
	end

	Editor.syncTo = syncTo

	local function syncAll()
		for player in editors do
			syncTo(player)
		end
	end
	Editor.changed:Connect(syncAll)
	Editor.selectionChanged:Connect(syncAll)

	Net.on("EditorOp", function(player, payload)
		if not Editor.authorised(player) then
			warn(string.format("[Editor] %s is not authorised to edit", player.Name))
			return
		end
		editors[player] = true

		local op, data = payload.op, payload.data
		if op == "open" then
			syncTo(player)
			-- Let the server tell the overlay to show itself. An agent driving
			-- the bridge has no keyboard, so without this the editor is only
			-- reachable by a person pressing F4 — which would make it exactly
			-- the kind of GUI-only surface Forge exists to avoid.
			Net.fire(player, "EditorSync", { openUi = true, placements = {}, palette = {} })
		elseif op == "closeUi" then
			Net.fire(player, "EditorSync", { openUi = false, placements = {}, palette = {} })
		elseif op == "place" then
			local position = Editor.toVector(data.position)
			Editor.place(data.asset, CFrame.new(Editor.snapVector(position)))
		elseif op == "select" then
			local placement = current and current.placements[data.index or 0]
			Editor.selectPlacement(placement)
		elseif op == "selectInstance" then
			Editor.selectInstance(data.instance, data.additive == true)
		elseif op == "selectGroup" then
			Editor.selectGroupOf()
		elseif op == "clearSelection" then
			Editor.selectPlacement(nil)
		elseif op == "nudge" then
			Editor.nudge(Editor.toVector(data.delta))
		elseif op == "rotate" then
			Editor.rotate(data.degrees or Editor.config.rotationStep, data.axis)
		elseif op == "scale" then
			Editor.scale(tonumber(data.factor) or 1.1)
		elseif op == "ground" then
			Editor.groundPlacement()
		elseif op == "ground_if_snapped" then
			-- Fired when a move drag ends. Only drops the selection when the grid
			-- is on: with snapping off the user is placing by eye, and yanking the
			-- piece to the floor under them is not help.
			if Editor.config.gridSize > 0 then
				Editor.groundPlacement()
			end
		elseif op == "delete" then
			Editor.delete()
		elseif op == "duplicate" then
			Editor.duplicate()
		elseif op == "copy" then
			Editor.copy()
		elseif op == "paste" then
			Editor.paste(data.position and Editor.toVector(data.position) or nil)
		elseif op == "lock" then
			Editor.setLocked(data.on == true)
		elseif op == "hide" then
			Editor.setHidden(data.on == true)
		elseif op == "undo" then
			Editor.undo()
		elseif op == "redo" then
			Editor.redo()
		elseif op == "grid" then
			Editor.config.gridSize = math.clamp(tonumber(data.size) or 4, 0, 32)
			syncTo(player)
		elseif op == "save" then
			local json = Editor.save()
			Net.fire(player, "EditorSync", {
				scene = current and current.name,
				saved = true,
				bytes = json and #json or 0,
				placements = {},
				palette = {},
			})
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		editors[player] = nil
	end)
end

function Editor.describe(): { [string]: any }
	local editorCount = 0
	for _ in editors do
		editorCount += 1
	end
	return {
		open = current ~= nil,
		scene = current and current.name or nil,
		placements = current and #current.placements or 0,
		selected = #selected,
		undo = #undoStack,
		redo = #redoStack,
		activeEditors = editorCount,
		gridSize = Editor.config.gridSize,
	}
end


--[[
	Siblings, resolved on the first thing that asks for one.

	This family holds modules beside this file, and until now the only way to
	reach them was to require the instance directly — so `Forge.Editor.Gizmo`
	was nil while `require(ReplicatedStorage.Forge.Editor.Gizmo)` worked. Two
	conventions in one engine, and the inconsistency is the defect: the first
	game written against `Forge.Core.Boot` died on `attempt to index nil`.

	Lazy rather than eager, matching `Forge` itself. Touching one family must
	not drag in every module it contains — several of them build tables and
	open connections at load, and paying for all of that to read one constant
	is how a require graph becomes a frame budget.
]]
return setmetatable(Editor, {
	__index = function(self, key: string): any
		local child = script:FindFirstChild(key)
		if not child or not child:IsA("ModuleScript") then
			return nil
		end
		local module = require(child) :: any
		rawset(self, key, module)
		return module
	end,
})
