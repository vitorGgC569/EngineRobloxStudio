--!strict
--[[
	effects — the juice layer: what a catch looks like, and how it lands.

	The payoff moments used to be text: a toast, a card, a number in a panel.
	This module listens to signals that already exist — the `Wire` channels
	the controllers subscribe to, plus `state.changed` (state.luau:23) — and
	answers them with world-level feedback: camera shake scaled by rarity, a
	floating value where the fish was landed, a splash burst, a hitstop worth
	of weight, a flourish on level-up.

	Three rules it keeps:

	  * **No protocol changes.** Everything is client-side and driven by
	    channels already on the wire (`Wire.luau`). Nothing new is sent.
	  * **Cheap.** Splash particles come from one pooled emitter that is moved
	    and re-ranged, never rebuilt; `Feel.number` cleans up after itself;
	    no per-frame work. An idle player costs zero.
	  * **Server-authoritative.** It renders what the server already decided
	    (value, rarity, mutation); it never derives a fish itself.

	Mount it with one line from the bootstrap, after `state` is required:

		require(script.effects).install()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local Feel = Forge.Feel
local Net = Forge.Net
local UI = Forge.UI

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local FishCatalog = require(Shared.FishCatalog)
local Format = require(Shared.Format)

local state = require(script.Parent.state)
local audio = require(script.Parent.audio)

local Effects = {}

local player = Players.LocalPlayer

Effects.installed = false

-- ====================== pure math (locked by a test) ========================
--: The numbers behind every scaled effect: pure functions of a rarity order
--: (1 common .. 6 mythic) or a count. `tests/test_effects_math.py` mirrors
--: these expressions, so a balance tweak here is a two-file change.

Effects.math = {}

function Effects.math.rarityScale(order: number): number
	return 0.8 + 0.28 * math.clamp(order, 1, 6)
end

function Effects.math.catchShake(order: number): number
	return 0.13 * Effects.math.rarityScale(order)
end

function Effects.math.catchPunch(order: number): number
	return 1.0 + 0.5 * math.clamp(order, 1, 6)
end

function Effects.math.catchHitstop(order: number): number
	return 0.04 + 0.012 * math.clamp(order, 1, 6)
end

function Effects.math.splashDrops(order: number): number
	return math.floor(12 + 6 * math.clamp(order, 1, 6))
end

function Effects.math.levelPulse(level: number): number
	return math.clamp(1.0 + 0.02 * level, 1.0, 1.6)
end

function Effects.math.sellBurstScale(coins: number): number
	return math.clamp(0.6 + coins / 4000, 0.6, 2.2)
end

-- ============================== helpers =====================================
local function rootPosition(): Vector3?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

local function bobberPosition(): Vector3?
	local folder = Workspace:FindFirstChild("Bobbers")
	if not folder then
		return nil
	end
	local part = folder:FindFirstChild("Bobber_" .. tostring(player.UserId), true)
	if part and part:IsA("BasePart") then
		return part.Position
	end
	return nil
end

local function rarityOrder(id: any): number
	local tier = if type(id) == "string" then FishCatalog.rarityById[id] else nil
	return tier and tier.order or 1
end

local function rarityColor(id: any): Color3
	local tier = if type(id) == "string" then FishCatalog.rarityById[id] else nil
	return (tier and tier.color) or UI.theme.color.gold
end

local function mutationColor(id: any): Color3?
	if type(id) ~= "string" then
		return nil
	end
	for _, mutation in Config.mutations do
		if mutation.id == id and id ~= "normal" then
			return mutation.color
		end
	end
	return nil
end

-- ============================== splash pool =================================
--: One emitter, moved and re-ranged. A Part per splash would allocate at
--: exactly the moment the frame is busiest; this allocates once per session
--: and `Emit` reuses the particle memory underneath.
local splashPart: BasePart? = nil
local splashEmitter: ParticleEmitter? = nil

local function ensureSplash(): (BasePart?, ParticleEmitter?)
	if splashPart and splashPart.Parent and splashEmitter and splashEmitter.Parent then
		return splashPart, splashEmitter
	end
	local folder = Workspace:FindFirstChild("TideboundFx")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "TideboundFx"
		folder.Parent = Workspace
	end
	local part = Instance.new("Part")
	part.Name = "SplashPool"
	part.Size = Vector3.one * 0.1
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Parent = folder

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Splash"
	emitter.Enabled = false
	emitter.Color = ColorSequence.new(Color3.fromRGB(214, 236, 244))
	emitter.LightEmission = 0.2
	emitter.LightInfluence = 1
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-80, 80)
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.SpreadAngle = Vector2.new(34, 34)
	emitter.Acceleration = Vector3.new(0, -30, 0)
	emitter.Parent = part

	splashPart = part
	splashEmitter = emitter
	return part, emitter
end

--[[
	"splash" is a fast upward spray; "disturb" is the low water a bite
	leaves -- few, slow, large droplets that read as something moving
	underneath rather than a splash.
]]
function Effects.splash(position: Vector3, scale: number, drops: number?, mode: string?)
	local part, emitter = ensureSplash()
	if not part or not emitter then
		return
	end
	part.CFrame = CFrame.new(position)
	if mode == "disturb" then
		emitter.Speed = NumberRange.new(1.5, 4.5)
		emitter.Lifetime = NumberRange.new(0.45, 0.85)
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.4 * scale),
			NumberSequenceKeypoint.new(0.4, 0.9 * scale),
			NumberSequenceKeypoint.new(1, 0),
		})
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.35),
			NumberSequenceKeypoint.new(1, 1),
		})
		emitter:Emit(math.max(4, math.floor((drops or 8) * 0.6)))
	else
		emitter.Speed = NumberRange.new(9 * scale, 22 * scale)
		emitter.Lifetime = NumberRange.new(0.32, 0.65)
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.28 * scale),
			NumberSequenceKeypoint.new(1, 0),
		})
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.15),
			NumberSequenceKeypoint.new(1, 1),
		})
		emitter:Emit(drops or 20)
	end
end

-- ============================== the loop ====================================
--: The bobber is destroyed server-side the moment a fish is landed, so the
--: landing spot has to be captured while it is still in the water.
local lastWater: Vector3? = nil

local function onCastState(payload: any)
	local at = payload and payload.at
	if typeof(at) ~= "Vector3" then
		return
	end
	lastWater = at
	audio.sfx("tidebound.cast")
	local landsIn = tonumber(payload.landsIn) or Config.bobberSettleSeconds
	task.delay(landsIn, function()
		Effects.splash(at, 0.55, 14)
		audio.sfxAt("tidebound.splash", at, { volume = 0.4, pitch = 0.95 })
	end)
end

local function onBite(payload: any)
	local at = bobberPosition() or lastWater
	if not at then
		return
	end
	lastWater = at
	Effects.splash(at, 0.5, 9, "disturb")
	audio.sfxAt("tidebound.bite", at)
end

local function onCatch(payload: any)
	local order = rarityOrder(payload and payload.rarity)
	local at = lastWater or bobberPosition() or rootPosition()
	local value = tonumber(payload and payload.value) or 0
	local anchor = at or rootPosition()

	--: The weight of the catch, in the order the player feels it: a short
	--: pause, a punch of FOV, then a shake that decays on its own.
	Feel.hitstop(Effects.math.catchHitstop(order))
	Feel.punch(Effects.math.catchPunch(order))
	Feel.shake(Effects.math.catchShake(order))

	if at then
		Effects.splash(at, Effects.math.rarityScale(order), Effects.math.splashDrops(order))
		audio.sfxAt("tidebound.splash", at, { volume = 0.6, pitch = 0.9 })
	end
	if anchor then
		--: `Format.money` already speaks in dollars; the `+` is the "gain".
		Feel.number(anchor + Vector3.new(0, 1.6, 0), "+" .. Format.money(value), {
			color = rarityColor(payload and payload.rarity),
			crit = order >= 4,
		})
		if payload and payload.mutation and payload.mutation ~= "normal" then
			--: The bonus line: a mutation is the thing a player screenshots.
			Feel.number(anchor + Vector3.new(0, 3.4, 0), string.upper(tostring(payload.mutationName or payload.mutation)), {
				color = mutationColor(payload.mutation) or UI.theme.color.accent,
				lifetime = 1.3,
			})
		end
	end
	lastWater = nil
end

local function onCastEnd(payload: any)
	local outcome = payload and payload.outcome
	local at = lastWater
	if outcome == "snapped" then
		--: The one moment the player is meant to wince.
		audio.sfx("tidebound.snap")
		Feel.shake(0.22)
		if at then
			Effects.splash(at, 0.9, 22)
			audio.sfxAt("tidebound.splash", at, { volume = 0.45, pitch = 0.8 })
		end
	elseif outcome == "escaped" or outcome == "lost" then
		if at then
			Effects.splash(at, 0.45, 8, "disturb")
			audio.sfxAt("tidebound.splash", at, { volume = 0.3, pitch = 0.85 })
		end
	end
	lastWater = nil
end

local function onLevelUp(payload: any)
	local level = tonumber(payload and payload.level) or 0
	--: The success ping is the bootstrap's (`init.client.luau:78`); layering
	--: this one's own chime over the same clip would flam. The coin jingle
	--: and the visuals are the additions here.
	audio.sfx("tidebound.coins")

	local at = rootPosition()
	if not at then
		return
	end
	--: A ring and a golden tint -- distinct from the toast, which only says
	--: the number. The flourishes live under the player's feet so they read
	--: in third person and while the HUD is busy.
	Feel.impact(at - Vector3.new(0, 2.4, 0), {
		kind = "ring",
		color = UI.theme.color.gold,
		scale = Effects.math.levelPulse(level),
	})
	Feel.number(at + Vector3.new(0, 3.0, 0), "LEVEL " .. tostring(level), {
		color = UI.theme.color.gold,
		crit = true,
		lifetime = 1.4,
	})
	Feel.screenTint(UI.theme.color.gold, 0.08, 0.5)
end

--[[
	A sale, derived without touching the protocol.

	`SellCrate` is client-to-server and the server answers with a fresh
	ProfileSync; there is no s2c "Sold" channel and this module may not add
	one. `stats.sold` only ever increases, so a delta in the profile the
	client already receives is a sale, and the coin delta is what it paid.
	The baseline is the first sync after join.
]]
local lastSold: number? = nil
local lastCoins: number? = nil

local function onProfile(profile: any)
	local stats = profile and profile.stats
	if not stats then
		return
	end
	local sold = tonumber(stats.sold) or 0
	local coins = tonumber(profile.coins) or 0
	if lastSold == nil then
		lastSold, lastCoins = sold, coins
		return
	end
	local saleCount = sold - lastSold
	local coinGain = coins - (lastCoins or coins)
	lastSold, lastCoins = sold, coins
	if saleCount <= 0 or coinGain <= 0 then
		return
	end

	audio.sfx("tidebound.sell")
	local at = rootPosition()
	if not at then
		return
	end
	local burstAt = at + Vector3.new(0, 1.2, 0)
	Feel.impact(burstAt, {
		kind = "burst",
		color = UI.theme.color.gold,
		scale = Effects.math.sellBurstScale(coinGain),
		--: Selling happens often enough that a light per sale would stack
		--: additively across the map (the PointLights lesson).
		light = false,
	})
	Feel.number(burstAt + Vector3.new(0, 1.4, 0), "+" .. Format.money(coinGain), {
		color = UI.theme.color.gold,
		lifetime = 1.2,
	})
end

-- ============================== install =====================================
function Effects.install()
	if Effects.installed or not RunService:IsClient() then
		return
	end
	Effects.installed = true

	--: Without this call, shake and punch record a number nobody reads.
	Feel.mount()
	Net.on("CastState", onCastState)
	Net.on("Bite", onBite)
	Net.on("CatchResult", onCatch)
	Net.on("CastEnd", onCastEnd)
	Net.on("LevelUp", onLevelUp)
	state.changed:Connect(onProfile)
end

return Effects
