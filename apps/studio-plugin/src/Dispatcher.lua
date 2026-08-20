--!strict
-- Command registry and execution.
--
-- Adding a capability to the platform means adding one entry here. Dispatch is
-- table-driven so `bridge.capabilities` can report the live surface rather than
-- a hand-maintained list that drifts from the code.

local Errors = require(script.Parent.Errors)

local ActorCommands = require(script.Parent.Commands.Actor)
local AssetCommands = require(script.Parent.Commands.Assets)
local BridgeCommands = require(script.Parent.Commands.Bridge)
local CameraCommands = require(script.Parent.Commands.Camera)
local ClientCommands = require(script.Parent.Commands.Client)
local CodeCommands = require(script.Parent.Commands.Code)
local InspectCommands = require(script.Parent.Commands.Inspect)
local TransformCommands = require(script.Parent.Commands.Transform)
local DataModelCommands = require(script.Parent.Commands.DataModel)
local InstanceCommands = require(script.Parent.Commands.Instance)
local PlayerCommands = require(script.Parent.Commands.Player)
local ProductCommands = require(script.Parent.Commands.Product)
local QualityCommands = require(script.Parent.Commands.Quality)
local RuntimeCommands = require(script.Parent.Commands.Runtime)
local SessionCommands = require(script.Parent.Commands.Session)
local TelemetryCommands = require(script.Parent.Commands.Telemetry)
local TerrainCommands = require(script.Parent.Commands.Terrain)
local WorldCommands = require(script.Parent.Commands.World)

local Dispatcher = {}

type Handler = (params: { [string]: any }) -> any

local REGISTRY: { [string]: Handler } = {
	-- bridge
	["bridge.ping"] = BridgeCommands.ping,
	["bridge.capabilities"] = BridgeCommands.capabilities,
	["studio.info"] = BridgeCommands.info,
	["product.identity"] = ProductCommands.identity,

	-- asset authoring. Local plugins are the only Studio surface where
	-- CreateAssetAsync is permitted, so this cannot move to the Creator Store.
	["assets.capabilities"] = AssetCommands.capabilities,
	["assets.create_image"] = AssetCommands.createImage,

	-- hierarchy
	["dm.tree"] = DataModelCommands.tree,
	["dm.properties"] = DataModelCommands.properties,
	["dm.find"] = DataModelCommands.find,

	-- DataModel mutation as typed primitives, so building a world never has to
	-- go through bridge.exec. Arbitrary Luau has no schema: nothing can validate
	-- it before it runs and nothing can describe what it changed after.
	["instance.create"] = InstanceCommands.create,
	["instance.update"] = InstanceCommands.update,
	["instance.delete"] = InstanceCommands.delete,
	["instance.clone"] = InstanceCommands.clone,
	["instance.children"] = InstanceCommands.children,
	["instance.descendants"] = InstanceCommands.descendants,
	["instance.tags"] = InstanceCommands.tags,
	["instance.attributes"] = InstanceCommands.attributes,

	-- geometry
	["world.raycast"] = WorldCommands.raycast,
	["world.bounds"] = WorldCommands.bounds,
	["world.ground_support"] = WorldCommands.groundSupport,
	["world.overlaps"] = WorldCommands.overlaps,
	["world.path"] = WorldCommands.path,
	["world.summary"] = WorldCommands.summary,
	["quality.snapshot"] = QualityCommands.snapshot,
	["world.region"] = TerrainCommands.region,
	["world.spawn_points"] = TerrainCommands.spawnPoints,
	["world.navigation"] = TerrainCommands.navigation,
	["world.terrain"] = TerrainCommands.terrain,

	-- runtime
	["run.state"] = RuntimeCommands.state,
	["run.players"] = RuntimeCommands.players,
	["log.tail"] = RuntimeCommands.logTail,

	-- telemetry. A performance budget nobody measures is a comment.
	["runtime.metrics"] = TelemetryCommands.metrics,
	["runtime.memory"] = TelemetryCommands.memory,
	["runtime.physics"] = TelemetryCommands.physics,
	["runtime.network"] = TelemetryCommands.network,
	["runtime.errors"] = TelemetryCommands.errors,
	["runtime.warnings"] = TelemetryCommands.warnings,
	["runtime.events"] = TelemetryCommands.events,

	-- simulation control
	["run.start"] = SessionCommands.start,
	["run.stop"] = SessionCommands.stop,
	["run.server"] = SessionCommands.serverShape,
	["run.client"] = SessionCommands.clientShape,
	["bridge.exec"] = SessionCommands.exec,

	-- Writing code into the place, and reloading it without a restart. The
	-- loop this closes cost about a minute per iteration: write the file, run
	-- Rojo, restart Studio, reopen, try again.
	["code.write"] = CodeCommands.write,
	["code.read"] = CodeCommands.read,
	["code.reload"] = CodeCommands.reload,
	["code.list"] = CodeCommands.list,
	["code.at_start"] = CodeCommands.atStart,
	["code.compile"] = CodeCommands.compile,

	-- Looking at what is there and what changed.
	["dm.inspect"] = InspectCommands.inspect,
	["watch.start"] = InspectCommands.watchStart,
	["watch.read"] = InspectCommands.watchRead,
	["watch.stop"] = InspectCommands.watchStop,
	["test.run"] = InspectCommands.testRun,

	-- Placing things by relation rather than by coordinate.
	["transform.bounds"] = TransformCommands.bounds,
	["transform.move"] = TransformCommands.move,
	["transform.orient"] = TransformCommands.orient,
	["transform.align"] = TransformCommands.align,
	["transform.snap"] = TransformCommands.snap,
	["transform.settle"] = TransformCommands.settle,
	["transform.nearest"] = TransformCommands.nearest,
	["transform.overlaps"] = TransformCommands.overlaps,
	["bridge.install_client"] = SessionCommands.installClient,
	["bridge.remove_client"] = SessionCommands.removeClient,

	-- viewpoints
	["camera.set"] = CameraCommands.set,
	["camera.focus"] = CameraCommands.focus,
	["camera.get"] = CameraCommands.get,
	["camera.orbit"] = CameraCommands.orbit,
	["camera.follow"] = CameraCommands.follow,
	["camera.viewpoint"] = CameraCommands.viewpoint,

	-- the agent as a player
	["actor.spawn"] = ActorCommands.spawn,
	["actor.attach"] = ActorCommands.attach,
	["actor.despawn"] = ActorCommands.despawn,
	["actor.list"] = ActorCommands.list,
	["actor.state"] = ActorCommands.state,
	["actor.walk_to"] = ActorCommands.walkTo,
	["actor.navigate_to"] = ActorCommands.navigateTo,
	["actor.jump"] = ActorCommands.jump,
	["actor.interact"] = ActorCommands.interact,
	["actor.touch"] = ActorCommands.touch,
	["actor.prompts"] = ActorCommands.prompts,
	["actor.teleport"] = PlayerCommands.teleport,
	["actor.equip"] = PlayerCommands.equip,
	["actor.activate"] = PlayerCommands.activate,
	["actor.inventory"] = PlayerCommands.inventory,

	-- the client half of the engine, reached through the server
	["client.info"] = ClientCommands.info,
	["client.prompt_trigger"] = ClientCommands.promptTrigger,
	["client.gui_tree"] = ClientCommands.guiTree,
	["client.gui_click"] = ClientCommands.guiClick,
	["client.player_state"] = ClientCommands.playerState,
	["client.logs"] = ClientCommands.logs,
	["client.gui_locate"] = ClientCommands.guiLocate,
	["client.invoke_bindable"] = ClientCommands.invokeBindable,
	["client.fire_remote"] = ClientCommands.fireRemote,
	["client.probe_images"] = ClientCommands.probeImages,
	["client.ensure_channel"] = ClientCommands.ensureChannel,
	["client.gui_text"] = ClientCommands.guiText,
	["client.gui_scroll"] = ClientCommands.guiScroll,
	["client.viewport"] = ClientCommands.viewport,
	["client.camera_set"] = ClientCommands.cameraSet,
	["client.camera_release"] = ClientCommands.cameraRelease,
	["client.gui_snapshot"] = ClientCommands.guiSnapshot,
}

--- Commands that only mean something while the place is running.
local RUNTIME_ONLY: { [string]: boolean } = {
	["run.players"] = true,
}

function Dispatcher.methods(): { string }
	local names = {}
	for name in pairs(REGISTRY) do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

--- Execute one command. Never raises: failures come back as structured errors.
function Dispatcher.execute(method: string, params: { [string]: any }?): (boolean, any)
	local handler = REGISTRY[method]
	if handler == nil then
		return false, {
			code = Errors.UNKNOWN_METHOD,
			message = string.format("no such command: %s", method),
			details = { available = Dispatcher.methods() },
		}
	end

	if RUNTIME_ONLY[method] and not game:GetService("RunService"):IsRunning() then
		return false, {
			code = Errors.UNSUPPORTED_CONTEXT,
			message = string.format("%s requires a running place; Studio is in edit mode", method),
			details = { context = "edit" },
		}
	end

	local ok, result = pcall(handler, params or {})
	if ok then
		return true, result
	end
	return false, Errors.normalize(result)
end

return Dispatcher
