--!strict
-- L5: camera language.
--
-- Two jobs, and they are the same job. A genre needs a consistent camera --
-- field of view, pitch, distance, how much headroom the subject gets -- and a
-- measurement run needs *deterministic viewpoints* so two screenshots of the
-- same world are actually comparable. Both come from the same camera profiles in
-- the token set, which is why they live together.
--
-- `frame` is the important one. Given a target and a profile it returns a CFrame
-- that composes the subject the same way every time, from the subject's own
-- bounds rather than from a hand-tuned position. A viewpoint defined that way
-- survives the world changing underneath it; a hardcoded CFrame does not, and a
-- capture from a stale CFrame is worse than no capture because it looks valid.

local Tokens = require(script.Parent.Tokens)

local Camera = {}

export type Framing = {
	cframe: CFrame,
	fieldOfView: number,
	--- Distance actually used, after fitting the subject into the frame.
	distance: number,
	--- True when the requested distance had to grow to fit the subject.
	adjusted: boolean,
	profileId: string,
	target: Vector3,
}

local function fail(message: string): never
	error("[WorldKit.Camera] " .. message, 3)
end

--- Bounding sphere radius of whatever we were asked to look at.
local function subjectRadius(subject: any): (Vector3, number)
	if typeof(subject) == "Vector3" then
		return subject, 0
	end
	if typeof(subject) == "Instance" then
		if subject:IsA("Model") then
			local cframe, size = subject:GetBoundingBox()
			return cframe.Position, size.Magnitude / 2
		end
		if subject:IsA("BasePart") then
			return subject.Position, subject.Size.Magnitude / 2
		end
	end
	fail("camera subject must be a Vector3, BasePart or Model")
end

--- Compose a shot of `subject` using a named profile.
---
--- The distance in a profile is an intent, not a constant: a profile that frames
--- a character will not contain a 200-stud landmark. Rather than silently
--- cropping, the distance grows until the subject fits and the framing reports
--- that it was adjusted, so a capture rule can tell "framed as designed" from
--- "framed as far back as necessary".
function Camera.frame(tokens: Tokens.TokenSet, profileId: string, subject: any, options: { [string]: any }?): Framing
	local profile = tokens:camera(profileId)
	local opts = options or {}
	local target, radius = subjectRadius(subject)

	local fieldOfView = opts.fieldOfView or profile.fieldOfView
	local distance = profile.distance
	local adjusted = false

	if radius > 0 then
		-- Half-FOV in radians; the distance at which a sphere of `radius` exactly
		-- fills the vertical frame, plus a margin so the subject is not flush
		-- against the edges.
		local halfFov = math.rad(fieldOfView) / 2
		local required = (radius / math.sin(halfFov)) * (opts.margin or 1.15)
		if required > distance then
			distance = required
			adjusted = true
		end
	end

	local yaw = math.rad(opts.yawDegrees or 0)
	local pitch = math.rad(opts.pitchDegrees or profile.pitchDegrees)
	local focus = target + Vector3.new(0, profile.heightOffset, 0)

	-- Spherical placement around the focus. Positive pitch in the token file
	-- means "looking down", which is how a person describes it, so the sign is
	-- inverted exactly once, here.
	local horizontal = math.cos(pitch) * distance
	local offset = Vector3.new(
		math.sin(yaw) * horizontal,
		-math.sin(pitch) * distance,
		math.cos(yaw) * horizontal
	)

	return {
		cframe = CFrame.lookAt(focus + offset, focus),
		fieldOfView = fieldOfView,
		distance = distance,
		adjusted = adjusted,
		profileId = profileId,
		target = focus,
	}
end

--- Apply a framing to a real Camera instance.
function Camera.apply(camera: Camera, framing: Framing)
	if typeof(camera) ~= "Instance" or not camera:IsA("Camera") then
		fail("Camera.apply needs a Camera instance")
	end
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = framing.fieldOfView
	camera.CFrame = framing.cframe
end

--- Hand control back to the player.
function Camera.release(camera: Camera, subject: Humanoid?)
	camera.CameraType = Enum.CameraType.Custom
	if subject ~= nil then
		camera.CameraSubject = subject
	end
end

--- Configure the player's own camera from a profile, without seizing it.
---
--- Zoom limits live on Player, not Camera, which is easy to miss and is why a
--- carefully chosen distance often has no effect: the player simply scrolls out
--- of it on the first frame.
function Camera.configurePlayer(player: Player, tokens: Tokens.TokenSet, profileId: string)
	local profile = tokens:camera(profileId)
	if profile.minZoom ~= nil then
		player.CameraMinZoomDistance = profile.minZoom
	end
	if profile.maxZoom ~= nil then
		player.CameraMaxZoomDistance = profile.maxZoom
	end
end

--- Every profile framed against the same subject, for a capture sweep.
---
--- This is what makes a device matrix cheap: one call produces the desktop,
--- phone and tablet framings of the same thing, all derived rather than
--- hand-placed, so none of them goes stale when the world moves.
function Camera.sweep(tokens: Tokens.TokenSet, subject: any, options: { [string]: any }?): { [string]: Framing }
	local framings: { [string]: Framing } = {}
	for _, profileId in ipairs(tokens:cameraIds()) do
		framings[profileId] = Camera.frame(tokens, profileId, subject, options)
	end
	return framings
end

return Camera
