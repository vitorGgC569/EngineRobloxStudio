--!strict
-- Roblox value -> JSON-safe value.
--
-- Every Roblox datatype an agent might read has to survive JSONEncode without
-- becoming "userdata" or crashing the encoder. Anything unknown degrades to a
-- tagged string rather than silently disappearing, so an agent can tell the
-- difference between "property is nil" and "we could not represent it".

local Serialize = {}

local function vector3(value: Vector3): { number }
	return { value.X, value.Y, value.Z }
end

local function isFinite(n: number): boolean
	return n == n and n ~= math.huge and n ~= -math.huge
end

function Serialize.number(value: number): number?
	-- JSON has no NaN/Infinity; emitting them produces invalid documents.
	if not isFinite(value) then
		return nil
	end
	return value
end

function Serialize.value(value: any, depth: number?): any
	local currentDepth = depth or 0
	if currentDepth > 6 then
		return "<depth-limit>"
	end

	local valueType = typeof(value)

	if valueType == "number" then
		return Serialize.number(value)
	elseif valueType == "string" or valueType == "boolean" or valueType == "nil" then
		return value
	elseif valueType == "Vector3" then
		return vector3(value)
	elseif valueType == "Vector2" then
		return { value.X, value.Y }
	elseif valueType == "CFrame" then
		local position = value.Position
		local rx, ry, rz = value:ToOrientation()
		return {
			position = vector3(position),
			orientationDeg = { math.deg(rx), math.deg(ry), math.deg(rz) },
			lookVector = vector3(value.LookVector),
		}
	elseif valueType == "Color3" then
		return {
			math.round(value.R * 255),
			math.round(value.G * 255),
			math.round(value.B * 255),
		}
	elseif valueType == "BrickColor" then
		return value.Name
	elseif valueType == "UDim" then
		return { scale = value.Scale, offset = value.Offset }
	elseif valueType == "UDim2" then
		return {
			x = { scale = value.X.Scale, offset = value.X.Offset },
			y = { scale = value.Y.Scale, offset = value.Y.Offset },
		}
	elseif valueType == "Rect" then
		return { min = { value.Min.X, value.Min.Y }, max = { value.Max.X, value.Max.Y } }
	elseif valueType == "NumberRange" then
		return { min = value.Min, max = value.Max }
	elseif valueType == "EnumItem" then
		return tostring(value)
	elseif valueType == "Enum" then
		return tostring(value)
	elseif valueType == "Instance" then
		return { ref = value:GetFullName(), className = value.ClassName, name = value.Name }
	elseif valueType == "Ray" then
		return { origin = vector3(value.Origin), direction = vector3(value.Direction) }
	elseif valueType == "Region3" then
		return {
			center = vector3(value.CFrame.Position),
			size = vector3(value.Size),
		}
	elseif valueType == "ColorSequence" or valueType == "NumberSequence" then
		local points = {}
		for index, keypoint in ipairs(value.Keypoints) do
			points[index] = {
				time = keypoint.Time,
				value = Serialize.value(keypoint.Value, currentDepth + 1),
			}
		end
		return points
	elseif valueType == "table" then
		local result = {}
		local isArray = #value > 0
		if isArray then
			for index, item in ipairs(value) do
				result[index] = Serialize.value(item, currentDepth + 1)
			end
		else
			for key, item in pairs(value) do
				result[tostring(key)] = Serialize.value(item, currentDepth + 1)
			end
		end
		return result
	end

	return "<" .. valueType .. ">"
end

--- Round a number to a fixed precision so screenshots of the same scene do not
--- produce spurious diffs from float noise.
function Serialize.round(value: number, places: number?): number
	local factor = 10 ^ (places or 3)
	return math.round(value * factor) / factor
end

function Serialize.roundVector(value: Vector3, places: number?): { number }
	return {
		Serialize.round(value.X, places),
		Serialize.round(value.Y, places),
		Serialize.round(value.Z, places),
	}
end

return Serialize
