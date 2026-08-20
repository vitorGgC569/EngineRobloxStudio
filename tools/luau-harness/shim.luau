--!nolint
-- Minimal Roblox environment for running SDK modules under the plain Luau CLI.
--
-- This exists because the plan's architectural spine is that SDK modules are
-- pure Luau and therefore run in three places: a Studio plugin, a published
-- experience, and a headless Open Cloud task. A claim like that is worth nothing
-- until something actually executes the modules outside Roblox -- so this is the
-- proof, and it doubles as the runtime for headless economy simulation.
--
-- Deliberately partial. It implements the datatypes and services the pure
-- modules use, and nothing else. A module that reaches for an engine feature not
-- shimmed here fails loudly, which is the correct outcome: it means the module
-- is not portable and the spine does not hold for it.

local shim = {}

-- ------------------------------------------------------------------ datatypes

local Color3 = {}
Color3.__index = Color3
function Color3.new(r, g, b)
	return setmetatable({ R = r or 0, G = g or 0, B = b or 0, __brand = "Color3" }, Color3)
end
function Color3.fromRGB(r, g, b)
	return Color3.new((r or 0) / 255, (g or 0) / 255, (b or 0) / 255)
end
Color3.__eq = function(a, b)
	return a.R == b.R and a.G == b.G and a.B == b.B
end
Color3.__tostring = function(self)
	return string.format("Color3(%.3f, %.3f, %.3f)", self.R, self.G, self.B)
end

local Vector3 = {}
Vector3.__index = Vector3
function Vector3.new(x, y, z)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0, __brand = "Vector3" }, Vector3)
end
Vector3.__add = function(a, b)
	return Vector3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
Vector3.__sub = function(a, b)
	return Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
Vector3.__mul = function(a, b)
	if type(b) == "number" then
		return Vector3.new(a.X * b, a.Y * b, a.Z * b)
	end
	return Vector3.new(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
Vector3.__div = function(a, b)
	if type(b) == "number" then
		return Vector3.new(a.X / b, a.Y / b, a.Z / b)
	end
	return Vector3.new(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
end
Vector3.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y and a.Z == b.Z
end
Vector3.__tostring = function(self)
	return string.format("Vector3(%g, %g, %g)", self.X, self.Y, self.Z)
end
function Vector3:Min(other)
	return Vector3.new(math.min(self.X, other.X), math.min(self.Y, other.Y), math.min(self.Z, other.Z))
end
function Vector3:Max(other)
	return Vector3.new(math.max(self.X, other.X), math.max(self.Y, other.Y), math.max(self.Z, other.Z))
end
--- Linear interpolation, which anything laying something out between two points
--- reaches for: walls, paths, rails, camera rails.
function Vector3:Lerp(other, alpha)
	return Vector3.new(
		self.X + (other.X - self.X) * alpha,
		self.Y + (other.Y - self.Y) * alpha,
		self.Z + (other.Z - self.Z) * alpha)
end
Vector3.zero = Vector3.new(0, 0, 0)
rawset(Vector3, "Magnitude", nil)
local vectorIndex = function(self, key)
	if key == "Magnitude" then
		return math.sqrt(self.X * self.X + self.Y * self.Y + self.Z * self.Z)
	end
	if key == "Unit" then
		local magnitude = math.sqrt(self.X * self.X + self.Y * self.Y + self.Z * self.Z)
		if magnitude == 0 then
			return Vector3.new(0, 0, 0)
		end
		return Vector3.new(self.X / magnitude, self.Y / magnitude, self.Z / magnitude)
	end
	return rawget(Vector3, key)
end
Vector3.__index = vectorIndex

local Vector2 = {}
Vector2.__index = Vector2
function Vector2.new(x, y)
	return setmetatable({ X = x or 0, Y = y or 0, __brand = "Vector2" }, Vector2)
end
Vector2.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y
end
Vector2.__tostring = function(self)
	return string.format("Vector2(%g, %g)", self.X, self.Y)
end

local UDim = {}
UDim.__index = UDim
function UDim.new(scale, offset)
	return setmetatable({ Scale = scale or 0, Offset = offset or 0, __brand = "UDim" }, UDim)
end

local UDim2 = {}
UDim2.__index = UDim2
function UDim2.new(xs, xo, ys, yo)
	return setmetatable({
		X = UDim.new(xs, xo),
		Y = UDim.new(ys, yo),
		__brand = "UDim2",
	}, UDim2)
end
function UDim2.fromScale(x, y)
	return UDim2.new(x, 0, y, 0)
end
function UDim2.fromOffset(x, y)
	return UDim2.new(0, x, 0, y)
end

-- ------------------------------------------------------------------- CFrame
--
-- Position and yaw only. Enough for placement and framing maths, which is all
-- the portable layers do; anything needing a full rotation basis is engine work
-- and belongs on the other side of the bridge.

local CFrame = {}
CFrame.__index = CFrame
local function makeCFrame(position, yaw)
	return setmetatable({
		Position = position,
		Yaw = yaw or 0,
		__brand = "CFrame",
	}, CFrame)
end
function CFrame.new(x, y, z)
	if type(x) == "table" and x.__brand == "Vector3" then
		return makeCFrame(x, 0)
	end
	return makeCFrame(Vector3.new(x or 0, y or 0, z or 0), 0)
end
function CFrame.Angles(_, y, _z)
	return makeCFrame(Vector3.new(0, 0, 0), y or 0)
end
function CFrame.lookAt(from, to)
	local delta = to - from
	return makeCFrame(from, math.atan2(delta.X, delta.Z))
end
CFrame.identity = makeCFrame(Vector3.new(0, 0, 0), 0)
CFrame.__mul = function(a, b)
	if type(b) == "table" and b.__brand == "CFrame" then
		return makeCFrame(a.Position + b.Position, a.Yaw + b.Yaw)
	end
	if type(b) == "table" and b.__brand == "Vector3" then
		return a.Position + b
	end
	return a
end
CFrame.__tostring = function(self)
	return string.format("CFrame(%s, yaw=%.3f)", tostring(self.Position), self.Yaw)
end

-- ------------------------------------------------------- sequences and ranges

local NumberRange = {}
NumberRange.__index = NumberRange
function NumberRange.new(min, max)
	return setmetatable({ Min = min, Max = max or min, __brand = "NumberRange" }, NumberRange)
end

local ColorSequenceKeypoint = {}
ColorSequenceKeypoint.__index = ColorSequenceKeypoint
function ColorSequenceKeypoint.new(time, value)
	return setmetatable({ Time = time, Value = value, __brand = "ColorSequenceKeypoint" }, ColorSequenceKeypoint)
end

local NumberSequenceKeypoint = {}
NumberSequenceKeypoint.__index = NumberSequenceKeypoint
function NumberSequenceKeypoint.new(time, value, envelope)
	return setmetatable({
		Time = time, Value = value, Envelope = envelope or 0,
		__brand = "NumberSequenceKeypoint",
	}, NumberSequenceKeypoint)
end

local ColorSequence = {}
ColorSequence.__index = ColorSequence
function ColorSequence.new(a, b)
	if type(a) == "table" and a.__brand == nil then
		return setmetatable({ Keypoints = a, __brand = "ColorSequence" }, ColorSequence)
	end
	return setmetatable({
		Keypoints = {
			ColorSequenceKeypoint.new(0, a),
			ColorSequenceKeypoint.new(1, b or a),
		},
		__brand = "ColorSequence",
	}, ColorSequence)
end

local NumberSequence = {}
NumberSequence.__index = NumberSequence
function NumberSequence.new(a, b)
	if type(a) == "table" then
		return setmetatable({ Keypoints = a, __brand = "NumberSequence" }, NumberSequence)
	end
	return setmetatable({
		Keypoints = {
			NumberSequenceKeypoint.new(0, a),
			NumberSequenceKeypoint.new(1, b or a),
		},
		__brand = "NumberSequence",
	}, NumberSequence)
end

-- --------------------------------------------------------------------- Font

local Font = {}
Font.__index = Font
function Font.new(family, weight, style)
	return setmetatable({
		Family = family,
		Weight = weight,
		Style = style,
		__brand = "Font",
	}, Font)
end
Font.__tostring = function(self)
	return string.format("Font(%s, %s)", tostring(self.Family), tostring(self.Weight and self.Weight.Name))
end

-- ------------------------------------------------------------------- Random

local RandomClass = {}
RandomClass.__index = RandomClass
function RandomClass.new(seed)
	-- Deterministic LCG rather than math.random, so a harness run reproduces
	-- exactly and a seeded world is the same world every time.
	return setmetatable({ state = (seed or 0) % 2147483647, __brand = "Random" }, RandomClass)
end
function RandomClass:_step()
	self.state = (self.state * 1103515245 + 12345) % 2147483648
	return self.state / 2147483648
end
function RandomClass:NextNumber(low, high)
	local value = self:_step()
	if low == nil then
		return value
	end
	return low + value * (high - low)
end
function RandomClass:NextInteger(low, high)
	return math.floor(low + self:_step() * (high - low + 1 - 1e-9))
end

-- ----------------------------------------------------------------------- Enum

local function enumItem(enumName, name, value)
	return setmetatable({
		Name = name,
		Value = value,
		EnumType = enumName,
		__brand = "EnumItem",
	}, {
		__tostring = function()
			return "Enum." .. enumName .. "." .. name
		end,
	})
end

local function enumOf(enumName, names)
	local container = {}
	for index, name in ipairs(names) do
		container[name] = enumItem(enumName, name, index - 1)
	end
	return setmetatable(container, {
		__index = function(_, key)
			-- Unknown members return nil rather than erroring, which is what the
			-- real engine does and what the SDK's `typeof(x) ~= "EnumItem"`
			-- validation is written against.
			return nil
		end,
	})
end

local Enum = {
	Material = enumOf("Material", {
		"Plastic", "SmoothPlastic", "Metal", "Wood", "WoodPlanks", "Slate", "Concrete",
		"Brick", "Cobblestone", "Grass", "Sand", "Rock", "Granite", "Marble", "Pebble",
		"Ice", "Glass", "Neon", "ForceField", "Foil", "DiamondPlate", "CorrodedMetal",
		"Fabric", "Glacier", "Asphalt", "LeafyGrass", "Limestone", "Mud", "Salt",
		"Sandstone", "Snow", "CrackedLava", "Basalt", "Ground", "Air", "Water",
	}),
	EasingStyle = enumOf("EasingStyle", {
		"Linear", "Sine", "Back", "Quad", "Quart", "Quint", "Bounce", "Elastic",
		"Exponential", "Circular", "Cubic",
	}),
	EasingDirection = enumOf("EasingDirection", { "In", "Out", "InOut" }),
	FontWeight = enumOf("FontWeight", {
		"Thin", "ExtraLight", "Light", "Regular", "Medium", "SemiBold", "Bold",
		"ExtraBold", "Heavy",
	}),
	PartType = enumOf("PartType", { "Ball", "Block", "Cylinder", "Wedge", "CornerWedge" }),
	-- Surfaces exist so a module can smooth them. A shim that omits them fails
	-- any builder that cares how a part meets its neighbour, which is every
	-- builder that produces architecture rather than boxes.
	SurfaceType = enumOf("SurfaceType", {
		"Smooth", "Glue", "Weld", "Studs", "Inlet", "Universal", "SmoothNoOutlines",
	}),
	Technology = enumOf("Technology", { "Legacy", "Voxel", "Compatibility", "ShadowMap", "Future" }),
	SortOrder = enumOf("SortOrder", { "Name", "Custom", "LayoutOrder" }),
	FillDirection = enumOf("FillDirection", { "Horizontal", "Vertical" }),
	UIFlexMode = enumOf("UIFlexMode", { "None", "Grow", "Shrink", "Fill", "Custom" }),
	UIFlexAlignment = enumOf("UIFlexAlignment", { "None", "Fill", "SpaceAround", "SpaceBetween", "SpaceEvenly" }),
	AnalyticsEconomyFlowType = enumOf("AnalyticsEconomyFlowType", { "Source", "Sink" }),
	AnalyticsCustomFieldKeys = enumOf("AnalyticsCustomFieldKeys", {
		"CustomField01", "CustomField02", "CustomField03",
	}),
	RollOffMode = enumOf("RollOffMode", { "Inverse", "Linear", "InverseTapered", "LinearSquare" }),
	AutomaticSize = enumOf("AutomaticSize", { "None", "X", "Y", "XY" }),
	TextXAlignment = enumOf("TextXAlignment", { "Left", "Center", "Right" }),
	TextYAlignment = enumOf("TextYAlignment", { "Top", "Center", "Bottom" }),
	HorizontalAlignment = enumOf("HorizontalAlignment", { "Center", "Left", "Right" }),
	VerticalAlignment = enumOf("VerticalAlignment", { "Center", "Top", "Bottom" }),
	ApplyStrokeMode = enumOf("ApplyStrokeMode", { "Contextual", "Border" }),
	ScrollingDirection = enumOf("ScrollingDirection", { "X", "Y", "XY" }),
	ScreenInsets = enumOf("ScreenInsets", { "None", "DeviceSafeInsets", "CoreUISafeInsets", "TopbarSafeInsets" }),
	ZIndexBehavior = enumOf("ZIndexBehavior", { "Global", "Sibling" }),
	HighlightDepthMode = enumOf("HighlightDepthMode", { "AlwaysOnTop", "Occluded" }),
}

-- -------------------------------------------------------------------- typeof

local rawTypeof = typeof
local function shimTypeof(value)
	if type(value) == "table" then
		local brand = rawget(value, "__brand")
		if brand ~= nil then
			return brand
		end
		local meta = getmetatable(value)
		if type(meta) == "table" and rawget(meta, "__brand") ~= nil then
			return rawget(meta, "__brand")
		end
		if rawget(value, "__isInstance") then
			return "Instance"
		end
	end
	return rawTypeof(value)
end

-- ------------------------------------------------------------------ Instance
--
-- A real enough DataModel: parenting, children, attributes, tags, class
-- hierarchy and destruction. That is the whole surface the world-building layers
-- touch, so `Kit`, `Blockout` and `Ui` can be exercised here rather than only
-- inside Studio -- which is what turns "the builder is portable" from an
-- intention into something a test asserts.

local CLASS_PARENTS = {
	Instance = nil,
	Folder = "Instance",
	Model = "Instance",
	Configuration = "Instance",
	BasePart = "Instance",
	Part = "BasePart",
	WedgePart = "BasePart",
	MeshPart = "BasePart",
	SpawnLocation = "Part",
	Light = "Instance",
	PointLight = "Light",
	SpotLight = "Light",
	SurfaceLight = "Light",
	GuiObject = "Instance",
	Frame = "GuiObject",
	TextLabel = "GuiObject",
	TextButton = "GuiObject",
	ImageLabel = "GuiObject",
	ScrollingFrame = "Frame",
	ScreenGui = "Instance",
	UIListLayout = "Instance",
	UIGridLayout = "Instance",
	UIPadding = "Instance",
	UICorner = "Instance",
	UIStroke = "Instance",
	UIFlexItem = "Instance",
	UIScale = "Instance",
	BillboardGui = "Instance",
	ProximityPrompt = "Instance",
	Attachment = "Instance",
	Atmosphere = "Instance",
	Clouds = "Instance",
	Sky = "Instance",
	BloomEffect = "Instance",
	ColorCorrectionEffect = "Instance",
	SunRaysEffect = "Instance",
	DepthOfFieldEffect = "Instance",
	Sound = "Instance",
	SoundGroup = "Instance",
	AudioPlayer = "Instance",
	AudioEmitter = "Instance",
	AudioListener = "Instance",
	AudioFader = "Instance",
	AudioDeviceOutput = "Instance",
	Wire = "Instance",
	ParticleEmitter = "Instance",
	Beam = "Instance",
	Trail = "Instance",
	Highlight = "Instance",
	Explosion = "Instance",
}

local DEFAULTS = {
	Part = function(self)
		self.Size = Vector3.new(4, 1, 2)
		self.Position = Vector3.new(0, 0, 0)
		self.CFrame = CFrame.new(0, 0, 0)
		self.Color = Color3.new(0.64, 0.64, 0.64)
		self.Material = Enum.Material.Plastic
		self.Transparency = 0
		self.Reflectance = 0
		self.Anchored = false
		self.CanCollide = true
		self.CanTouch = true
		self.CanQuery = true
		self.CastShadow = true
		self.Shape = Enum.PartType.Block
		self.Orientation = Vector3.new(0, 0, 0)
	end,
}
DEFAULTS.WedgePart = DEFAULTS.Part
DEFAULTS.SpawnLocation = DEFAULTS.Part
DEFAULTS.MeshPart = DEFAULTS.Part

-- GUI defaults matter as much as part defaults: a validator that reads
-- `TextTransparency` on a label the engine would have defaulted to 0 crashes on
-- nil here, and would have quietly passed there. Modelling the defaults keeps
-- the harness honest in both directions.
local function guiDefaults(self)
	self.Visible = true
	self.BackgroundTransparency = 0
	self.BackgroundColor3 = Color3.new(1, 1, 1)
	self.BorderSizePixel = 1
	self.LayoutOrder = 0
	self.ZIndex = 1
	self.Size = UDim2.new(0, 0, 0, 0)
	self.Position = UDim2.new(0, 0, 0, 0)
	self.AnchorPoint = Vector2.new(0, 0)
	self.AutomaticSize = Enum.AutomaticSize.None
end

local function textDefaults(self)
	guiDefaults(self)
	self.Text = ""
	self.TextSize = 14
	self.TextColor3 = Color3.new(0, 0, 0)
	self.TextTransparency = 0
	self.TextScaled = false
	self.TextWrapped = false
	self.TextXAlignment = Enum.TextXAlignment.Center
	self.TextYAlignment = Enum.TextYAlignment.Center
	self.RichText = false
end

DEFAULTS.Frame = guiDefaults
DEFAULTS.ScrollingFrame = guiDefaults
DEFAULTS.ImageLabel = guiDefaults
DEFAULTS.TextLabel = textDefaults
DEFAULTS.TextButton = textDefaults

DEFAULTS.ParticleEmitter = function(self)
	self.Enabled = true
	self.Rate = 20
	self.Lifetime = NumberRange.new(5, 10)
	self.Emitted = 0
end
DEFAULTS.Attachment = function(self)
	self.Position = Vector3.new(0, 0, 0)
end

local instanceCount = 0
local Instance = {}

local InstanceMeta = {}
InstanceMeta.__index = function(self, key)
	local stored = rawget(self, "__props")[key]
	if stored ~= nil then
		return stored
	end
	local method = rawget(InstanceMeta, "__methods")[key]
	if method ~= nil then
		return method
	end
	-- Child lookup by name, the way `script.Parent.Thing` resolves in Roblox.
	for _, child in ipairs(rawget(self, "__children")) do
		if child.Name == key then
			return child
		end
	end
	return nil
end
InstanceMeta.__newindex = function(self, key, value)
	if key == "Parent" then
		local previous = rawget(self, "__props").Parent
		if previous ~= nil then
			local siblings = rawget(previous, "__children")
			for index, child in ipairs(siblings) do
				if child == self then
					table.remove(siblings, index)
					break
				end
			end
		end
		rawget(self, "__props").Parent = value
		if value ~= nil then
			table.insert(rawget(value, "__children"), self)
		end
		return
	end
	rawget(self, "__props")[key] = value
end
InstanceMeta.__tostring = function(self)
	return rawget(self, "__props").Name
end

local tagRegistry = {}

InstanceMeta.__methods = {
	IsA = function(self, className)
		local current = rawget(self, "__props").ClassName
		while current ~= nil do
			if current == className then
				return true
			end
			current = CLASS_PARENTS[current]
		end
		return false
	end,
	GetChildren = function(self)
		return table.clone(rawget(self, "__children"))
	end,
	GetDescendants = function(self)
		local found = {}
		local function walk(node)
			for _, child in ipairs(rawget(node, "__children")) do
				table.insert(found, child)
				walk(child)
			end
		end
		walk(self)
		return found
	end,
	FindFirstChild = function(self, name)
		for _, child in ipairs(rawget(self, "__children")) do
			if child.Name == name then
				return child
			end
		end
		return nil
	end,
	FindFirstChildOfClass = function(self, className)
		for _, child in ipairs(rawget(self, "__children")) do
			if rawget(child, "__props").ClassName == className then
				return child
			end
		end
		return nil
	end,
	GetFullName = function(self)
		local segments = { rawget(self, "__props").Name }
		local parent = rawget(self, "__props").Parent
		while parent ~= nil do
			table.insert(segments, 1, rawget(parent, "__props").Name)
			parent = rawget(parent, "__props").Parent
		end
		return table.concat(segments, ".")
	end,
	SetAttribute = function(self, name, value)
		rawget(self, "__attributes")[name] = value
	end,
	GetAttribute = function(self, name)
		return rawget(self, "__attributes")[name]
	end,
	GetAttributes = function(self)
		return table.clone(rawget(self, "__attributes"))
	end,
	Destroy = function(self)
		self.Parent = nil
		rawget(self, "__props").Destroyed = true
	end,
	Clone = function(self)
		error("[harness] Instance:Clone is not shimmed", 2)
	end,
	GetBoundingBox = function(self)
		local parts = {}
		for _, descendant in ipairs(InstanceMeta.__methods.GetDescendants(self)) do
			if InstanceMeta.__methods.IsA(descendant, "BasePart") then
				table.insert(parts, descendant)
			end
		end
		if #parts == 0 then
			return CFrame.new(0, 0, 0), Vector3.new(0, 0, 0)
		end
		local low, high
		for _, part in ipairs(parts) do
			local half = part.Size / 2
			local minimum = part.Position - half
			local maximum = part.Position + half
			low = if low then low:Min(minimum) else minimum
			high = if high then high:Max(maximum) else maximum
		end
		return CFrame.new((low + high) / 2), high - low
	end,
	PivotTo = function(self, cframe)
		rawget(self, "__props").Pivot = cframe
	end,
	Emit = function(self, amount)
		local props = rawget(self, "__props")
		props.Emitted = (props.Emitted or 0) + (amount or 1)
	end,
}

function Instance.new(className, parent)
	if CLASS_PARENTS[className] == nil and className ~= "Instance" then
		error("[harness] class not shimmed: " .. tostring(className), 2)
	end
	instanceCount += 1
	local object = setmetatable({
		__isInstance = true,
		__props = { ClassName = className, Name = className, Parent = nil },
		__children = {},
		__attributes = {},
	}, InstanceMeta)
	if DEFAULTS[className] ~= nil then
		DEFAULTS[className](object)
	end
	if parent ~= nil then
		object.Parent = parent
	end
	return object
end

local CollectionService = {
	__isInstance = true,
	AddTag = function(_, instance, tag)
		local bucket = tagRegistry[tag]
		if bucket == nil then
			bucket = {}
			tagRegistry[tag] = bucket
		end
		bucket[instance] = true
	end,
	RemoveTag = function(_, instance, tag)
		if tagRegistry[tag] ~= nil then
			tagRegistry[tag][instance] = nil
		end
	end,
	HasTag = function(_, instance, tag)
		return tagRegistry[tag] ~= nil and tagRegistry[tag][instance] == true
	end,
	GetTagged = function(_, tag)
		local found = {}
		for instance in pairs(tagRegistry[tag] or {}) do
			table.insert(found, instance)
		end
		return found
	end,
}

-- ------------------------------------------------------------------ services

--- Services are recorded rather than simulated. A pure module should only ever
--- probe for their presence; one that depends on their behaviour is not pure and
--- the harness should not paper over that.
local serviceCalls = {}

local RunService = {
	__isInstance = true,
	IsStudio = function()
		return false
	end,
	IsRunning = function()
		return true
	end,
	IsServer = function()
		return true
	end,
	IsClient = function()
		return false
	end,
}

local AnalyticsService = {
	__isInstance = true,
	events = {},
}
function AnalyticsService:LogEconomyEvent(player, flowType, currency, amount, balance, transactionType, sku)
	table.insert(AnalyticsService.events, {
		kind = "economy",
		userId = player.UserId,
		flow = flowType.Name,
		currency = currency,
		amount = amount,
		balance = balance,
		transactionType = transactionType,
		sku = sku,
	})
end
function AnalyticsService:LogFunnelStepEvent(player, funnel, sessionId, step, stepName)
	table.insert(AnalyticsService.events, {
		kind = "funnel",
		userId = player.UserId,
		funnel = funnel,
		step = step,
		stepName = stepName,
	})
end
function AnalyticsService:LogCustomEvent(player, name, value, fields)
	table.insert(AnalyticsService.events, {
		kind = "custom",
		userId = player.UserId,
		name = name,
		value = value,
		fields = fields,
	})
end

local Workspace = Instance.new("Folder")
Workspace.Name = "Workspace"
local Terrain = Instance.new("Folder", Workspace)
Terrain.Name = "Terrain"
Workspace.Terrain = Terrain

local Lighting = Instance.new("Folder")
Lighting.Name = "Lighting"

local SoundService = Instance.new("Folder")
SoundService.Name = "SoundService"

local TweenService = {
	__isInstance = true,
	Create = function(_, instance, info, goal)
		-- Applies the goal immediately and reports it. Tween timing is engine
		-- behaviour; what a portable test needs to know is that the right
		-- properties were targeted with the right token-derived curve.
		return {
			Play = function()
				for property, value in pairs(goal) do
					instance[property] = value
				end
			end,
			Info = info,
			Goal = goal,
		}
	end,
}

-- Present but featureless on purpose. `Fab` probes for `CreateEditableMeshAsync`
-- and friends and must degrade visibly when they are absent -- which is exactly
-- the situation on a real client without ID verification and the Mesh/Image
-- toggle. Shimming the service empty lets that path be tested rather than
-- assumed.
local AssetService = { __isInstance = true }

local services = {
	RunService = RunService,
	AnalyticsService = AnalyticsService,
	AssetService = AssetService,
	CollectionService = CollectionService,
	Workspace = Workspace,
	Lighting = Lighting,
	SoundService = SoundService,
	TweenService = TweenService,
	Players = {
		__isInstance = true,
		GetPlayerByUserId = function()
			return nil
		end,
		PlayerRemoving = { Connect = function() end },
	},
}

local game = {
	__isInstance = true,
	JobId = "harness",
	PlaceId = 0,
	GetService = function(_, name)
		table.insert(serviceCalls, name)
		local service = services[name]
		if service == nil then
			error("[harness] service not shimmed: " .. tostring(name) .. " -- this module is not portable", 2)
		end
		return service
	end,
	BindToClose = function() end,
}

-- ------------------------------------------------------------------- players

local Player = {}
Player.__index = Player
local function makePlayer(userId, name)
	return setmetatable({
		__isInstance = true,
		UserId = userId,
		Name = name or ("Player" .. tostring(userId)),
		Parent = game,
		IsA = function(self, className)
			return className == "Player" or className == "Instance"
		end,
	}, Player)
end

-- ---------------------------------------------------------------------- task

local task = {
	wait = function(seconds)
		return seconds or 0
	end,
	spawn = function(fn, ...)
		return fn(...)
	end,
	defer = function(fn, ...)
		return fn(...)
	end,
	-- Deferred work is recorded, not run. Executing it immediately would make a
	-- cleanup scheduled for "after the particles finish" destroy them before the
	-- caller ever sees them, and the harness would report a defect the engine
	-- does not have. `Harness.pendingDelays()` lets a test assert the cleanup was
	-- scheduled, which is the fact worth checking.
	delay = function(seconds, fn, ...)
		table.insert(shim.__delays, { seconds = seconds, run = fn, arguments = table.pack(...) })
		return nil
	end,
	cancel = function() end,
}
shim.__delays = {}

shim.Color3 = Color3
shim.Vector2 = Vector2
shim.Vector3 = Vector3
shim.UDim = UDim
shim.UDim2 = UDim2
shim.CFrame = CFrame
shim.Random = RandomClass
shim.Font = Font
shim.NumberRange = NumberRange
shim.ColorSequence = ColorSequence
shim.NumberSequence = NumberSequence
shim.ColorSequenceKeypoint = ColorSequenceKeypoint
shim.NumberSequenceKeypoint = NumberSequenceKeypoint
shim.Instance = Instance
shim.Enum = Enum
shim.typeof = shimTypeof
shim.game = game
shim.task = task
shim.makePlayer = makePlayer
shim.AnalyticsService = AnalyticsService
shim.CollectionService = CollectionService
shim.Workspace = Workspace
shim.Lighting = Lighting
shim.serviceCalls = serviceCalls
shim.instanceCount = function()
	return instanceCount
end
shim.pendingDelays = function()
	return #shim.__delays
end
--- Run every deferred callback, for tests that need the cleanup to happen.
shim.flushDelays = function()
	local queued = shim.__delays
	shim.__delays = {}
	for _, entry in ipairs(queued) do
		entry.run(table.unpack(entry.arguments, 1, entry.arguments.n))
	end
	return #queued
end
shim.warn = function(...)
	print("[warn]", ...)
end

--- Count instances of a class beneath a root, for structural assertions.
function shim.countClass(root, className)
	local total = 0
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA(className) then
			total += 1
		end
	end
	return total
end

return shim
