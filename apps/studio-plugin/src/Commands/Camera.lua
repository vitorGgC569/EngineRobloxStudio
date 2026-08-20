--!strict
-- Deterministic camera placement: the foundation for reproducible QA viewpoints.
--
-- A screenshot is only evidence if the shot can be retaken from exactly the same
-- place. These commands set the camera from explicit coordinates or frame a
-- named instance, so a viewpoint becomes data instead of a manual drag.

local Errors = require(script.Parent.Parent.Errors)
local Resolve = require(script.Parent.Parent.Resolve)
local Serialize = require(script.Parent.Parent.Serialize)

local CameraCommands = {}

local function currentCamera(): Camera
	local camera = workspace.CurrentCamera
	if camera == nil then
		Errors.raise(Errors.NOT_FOUND, "workspace has no CurrentCamera")
	end
	return camera :: Camera
end

local function describe(camera: Camera): { [string]: any }
	local cframe = camera.CFrame
	return {
		position = Serialize.roundVector(cframe.Position, 3),
		lookVector = Serialize.roundVector(cframe.LookVector, 4),
		fieldOfView = Serialize.round(camera.FieldOfView, 2),
		viewportSize = { camera.ViewportSize.X, camera.ViewportSize.Y },
		cameraType = tostring(camera.CameraType),
	}
end

--- camera.set: place the camera at an exact position looking at an exact point.
function CameraCommands.set(params: { [string]: any }): any
	local camera = currentCamera()
	local position = Errors.expectVector(params, "position")
	local target = if params.lookAt ~= nil then Errors.expectVector(params, "lookAt") else nil

	if target ~= nil then
		camera.CFrame = CFrame.lookAt(position, target)
	else
		camera.CFrame = CFrame.new(position)
	end

	if params.fieldOfView ~= nil then
		camera.FieldOfView = math.clamp(tonumber(params.fieldOfView) or 70, 1, 120)
	end

	return { applied = true, camera = describe(camera) }
end

--- camera.focus: frame an instance's bounding box from a chosen angle.
---
--- Distance is derived from the measured bounding sphere, so the same call
--- frames a small prop and a whole district correctly without hand-tuning.
function CameraCommands.focus(params: { [string]: any }): any
	local camera = currentCamera()
	local instance = Resolve.spatial(Errors.expect(params, "path", "string"))
	local cframe, size = Resolve.boundingBox(instance)
	local center = cframe.Position

	local radius = size.Magnitude / 2
	local fov = math.rad(camera.FieldOfView)
	local margin = tonumber(params.margin) or 1.35
	local distance = (radius / math.max(math.tan(fov / 2), 0.05)) * margin

	-- Default to a three-quarter elevated view: it reveals depth and footprint
	-- at once, which is what a reviewer needs from a single frame.
	local pitch = math.rad(tonumber(params.pitchDegrees) or 35)
	local yaw = math.rad(tonumber(params.yawDegrees) or 45)

	local offset = Vector3.new(
		math.cos(pitch) * math.sin(yaw),
		math.sin(pitch),
		math.cos(pitch) * math.cos(yaw)
	) * distance

	camera.CFrame = CFrame.lookAt(center + offset, center)

	return {
		applied = true,
		target = instance:GetFullName(),
		boundingBox = {
			center = Serialize.roundVector(center, 3),
			size = Serialize.roundVector(size, 3),
			radius = Serialize.round(radius, 3),
		},
		distance = Serialize.round(distance, 3),
		pitchDegrees = tonumber(params.pitchDegrees) or 35,
		yawDegrees = tonumber(params.yawDegrees) or 45,
		camera = describe(camera),
	}
end

--- camera.get: report the current viewpoint so a screenshot can carry metadata.
--- camera.orbit: move around a subject without changing how it is framed.
---
--- The command a critique actually needs. "The rear face is undetailed" is only
--- checkable if the same subject can be photographed from behind at the same
--- distance and the same pitch, and dragging a viewport to get there produces a
--- shot nobody can retake.
function CameraCommands.orbit(params: { [string]: any }): any
	local camera = currentCamera()
	local subject
	if params.path ~= nil then
		local instance = Resolve.spatial(params.path)
		local cframe, size = Resolve.boundingBox(instance)
		subject = cframe.Position
		if params.distance == nil then
			-- Derived from the subject rather than chosen, so an object that
			-- grows between revisions stays framed the same way.
			params.distance = math.max(size.Magnitude * 1.6, 12)
		end
	elseif params.target ~= nil then
		local target = params.target
		if type(target) ~= "table" or #target ~= 3 then
			Errors.raise(Errors.BAD_PARAMS, "target must be three numbers")
		end
		subject = Vector3.new(target[1], target[2], target[3])
	else
		Errors.raise(Errors.BAD_PARAMS, "orbit needs a path or a target")
	end

	local distance = tonumber(params.distance) or 32
	if distance <= 0 then
		Errors.raise(Errors.BAD_PARAMS, "distance must be positive")
	end
	local yaw = math.rad(tonumber(params.yawDegrees) or 0)
	local pitch = math.rad(tonumber(params.pitchDegrees) or 25)
	if math.abs(pitch) >= math.rad(89) then
		-- At the pole the look vector degenerates and the roll becomes
		-- undefined, which produces a shot that cannot be reproduced.
		Errors.raise(Errors.BAD_PARAMS, "pitchDegrees must stay inside -89..89")
	end

	local horizontal = math.cos(pitch) * distance
	local offset = Vector3.new(
		math.sin(yaw) * horizontal,
		math.sin(pitch) * distance,
		math.cos(yaw) * horizontal
	)

	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = CFrame.lookAt(subject + offset, subject)
	if params.fieldOfView ~= nil then
		camera.FieldOfView = tonumber(params.fieldOfView) :: number
	end

	return {
		conclusive = true,
		subject = Serialize.roundVector(subject, 3),
		distance = Serialize.round(distance, 3),
		yawDegrees = tonumber(params.yawDegrees) or 0,
		pitchDegrees = tonumber(params.pitchDegrees) or 25,
		camera = describe(camera),
	}
end

--- camera.follow: hand the camera back to a subject.
---
--- The counterpart to every scriptable placement. A camera left Scriptable
--- after a capture stays frozen for the player, which looks like the game has
--- hung.
function CameraCommands.follow(params: { [string]: any }): any
	local camera = currentCamera()

	if params.release == true or params.path == nil then
		camera.CameraType = Enum.CameraType.Custom
		return {
			conclusive = true,
			action = "release",
			cameraType = tostring(camera.CameraType),
			camera = describe(camera),
		}
	end

	local instance = Resolve.instance(params.path)
	local subject: Instance? = nil
	if instance:IsA("Humanoid") or instance:IsA("BasePart") then
		subject = instance
	elseif instance:IsA("Model") then
		subject = instance:FindFirstChildOfClass("Humanoid")
			or instance:FindFirstChild("HumanoidRootPart")
	end
	if subject == nil then
		Errors.raise(Errors.BAD_PARAMS, instance:GetFullName()
			.. " is not something a camera can follow; give a Humanoid, a BasePart, or a character Model")
	end

	camera.CameraType = Enum.CameraType.Custom
	camera.CameraSubject = subject

	return {
		conclusive = true,
		action = "follow",
		subject = (subject :: Instance):GetFullName(),
		cameraType = tostring(camera.CameraType),
		camera = describe(camera),
	}
end

--- camera.viewpoint: apply a named framing supplied by the caller.
---
--- The plugin holds no camera profiles. They live in the token set, on the
--- engine side, and arrive here already resolved -- the same split as every
--- other threshold, for the same reason: a validator that carries its own
--- numbers into the thing it measures ends up grading itself.
function CameraCommands.viewpoint(params: { [string]: any }): any
	local camera = currentCamera()
	Errors.expect(params, "name", "string")

	local framing = params.framing
	if type(framing) ~= "table" then
		Errors.raise(Errors.BAD_PARAMS,
			"viewpoint needs a resolved framing {position, target, fieldOfView}; "
			.. "camera profiles live in the token set, not in the plugin")
	end
	local position = framing.position
	local target = framing.target
	if type(position) ~= "table" or #position ~= 3 or type(target) ~= "table" or #target ~= 3 then
		Errors.raise(Errors.BAD_PARAMS, "framing needs position and target as three numbers each")
	end

	local from = Vector3.new(position[1], position[2], position[3])
	local at = Vector3.new(target[1], target[2], target[3])
	if (from - at).Magnitude < 1e-3 then
		Errors.raise(Errors.BAD_PARAMS, "the camera cannot sit on its own target")
	end

	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = CFrame.lookAt(from, at)
	if framing.fieldOfView ~= nil then
		camera.FieldOfView = tonumber(framing.fieldOfView) :: number
	end

	return {
		conclusive = true,
		viewpoint = params.name,
		requestedPosition = Serialize.roundVector(from, 3),
		requestedTarget = Serialize.roundVector(at, 3),
		camera = describe(camera),
	}
end

function CameraCommands.get(_params: { [string]: any }): any
	return describe(currentCamera())
end

return CameraCommands
