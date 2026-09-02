--!strict
-- Single source of truth for every remote: name, payload validator, and rate limit.
-- Server calls Remotes.server() once to create instances + get a validated connect API.
-- Client calls Remotes.client() to get typed fire/listen handles.
-- Any payload failing validation or rate limit is dropped and counted against the sender.

local Validators = require(script.Parent.Validators)

local FOLDER_NAME = "Remotes"

export type Spec = {
	validator: Validators.Validator?, -- client->server payload validator (nil = no args allowed)
	ratePerSecond: number?, -- max client->server calls per second (nil = server->client only)
}

local v = Validators

local Specs: { [string]: Spec } = {
	-- Client -> Server
	FireWeapon = {
		validator = v.shape({
			origin = v.vector3(4096),
			direction = v.unitVector3(),
			weaponId = v.oneOf({ "AssaultRifle", "Shotgun", "SMG", "Pistol", "Minigun" }),
		}),
		-- Above any legit fire rate; CombatService enforces per-weapon cooldowns. Held-trigger
		-- fire means the Minigun genuinely sends 25/s, so the flood guard needs headroom.
		ratePerSecond = 40,
	},
	ThrowKnife = {
		validator = v.shape({ origin = v.vector3(4096), direction = v.unitVector3() }),
		ratePerSecond = 4,
	},
	MeleeAttack = {
		validator = v.shape({ targetUserId = v.integer(1) }),
		ratePerSecond = 6,
	},
	MeleeSwing = {
		validator = v.shape({ origin = v.vector3(4096), direction = v.unitVector3() }),
		ratePerSecond = 6,
	},
	VoteMap = { validator = v.shape({ mapIndex = v.integer(1, 3) }), ratePerSecond = 5 },
	SelectLoadout = {
		validator = v.shape({ primary = v.oneOf({ "AssaultRifle", "Shotgun", "SMG" }) }),
		ratePerSecond = 5,
	},
	BuyCrate = { validator = v.shape({ currency = v.oneOf({ "Coins", "Keys" }) }), ratePerSecond = 2 },
	EquipSkin = { validator = v.shape({ skinId = v.str(64) }), ratePerSecond = 5 },
	EquipTitle = { validator = v.shape({ titleId = v.str(64) }), ratePerSecond = 5 },
	SprintState = { validator = v.shape({ sprinting = v.oneOf({ "on", "off" }) }), ratePerSecond = 10 },
	Reload = {
		validator = v.shape({ weaponId = v.oneOf({ "AssaultRifle", "Shotgun", "SMG", "Pistol", "Minigun" }) }),
		ratePerSecond = 4,
	},
	UseAbility = { validator = nil, ratePerSecond = 4 }, -- activate your zombie-class ability
	ClaimDaily = { validator = nil, ratePerSecond = 2 }, -- claim today's login reward
	MarkTutorialSeen = { validator = nil, ratePerSecond = 2 }, -- FTUE overlay dismissed
	ClaimQuest = {
		validator = v.shape({ scope = v.oneOf({ "daily", "weekly" }), questId = v.str(64) }),
		ratePerSecond = 5,
	},
	ClaimSeasonTier = {
		validator = v.shape({ tier = v.integer(1, 30), track = v.oneOf({ "free", "premium" }) }),
		ratePerSecond = 8,
	},

	PlayEmote = { validator = v.shape({ emoteId = v.str(32) }), ratePerSecond = 2 },

	-- Server -> Client (no validator/rate limit; server is trusted)
	EmotePlayed = {},
	RoundState = {},
	RoleAssigned = {},
	KillFeed = {},
	ConversionAlert = {},
	RevealScreen = {},
	SurvivorPing = {},
	ProfileSync = {},
	CrateResult = {},
	HordeUpdate = {},
	ShotFired = {},
	KnifeThrown = {},
	HitConfirm = {},
	DailyStatus = {}, -- current login-streak status + payout for the client popup
	DailyClaimed = {}, -- confirmation of a granted daily reward
	QuestStatus = {}, -- resolved daily/weekly quest list with progress for the client
	RoundModifier = {}, -- active round modifier (banner + client lighting effects)
	LevelUp = {}, -- fired when a player crosses a level threshold (toast + reward)
	Leaderboard = {}, -- top wins/conversions for the leaderboard panel
	SeasonStatus = {}, -- season-pass tier track + progress for the client
	AbilityState = {}, -- your zombie ability id + cooldown, for the client button/HUD
}

local Remotes = {}

local function getFolder(): Folder
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if folder == nil then
		folder = Instance.new("Folder")
		folder.Name = FOLDER_NAME
		folder.Parent = ReplicatedStorage
	end
	return folder :: Folder
end

-- SERVER ---------------------------------------------------------------------

export type ServerApi = {
	-- Connect a client->server remote; handler only runs for valid, rate-limited payloads.
	onValidated: (name: string, handler: (player: Player, payload: any) -> ()) -> RBXScriptConnection,
	fireClient: (name: string, player: Player, ...any) -> (),
	fireAllClients: (name: string, ...any) -> (),
	-- Exposed for AntiCheatService: how many invalid/over-rate payloads a player has sent.
	getViolations: (player: Player) -> number,
}

function Remotes.server(): ServerApi
	local folder = getFolder()
	local instances: { [string]: RemoteEvent } = {}
	for name in Specs do
		local remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = folder
		instances[name] = remote
	end

	-- Token bucket per player+remote: refills continuously at ratePerSecond with a
	-- burst cap of one second's worth. A fixed window would allow 2x bursts across
	-- the window boundary.
	local buckets: { [Player]: { [string]: { tokens: number, last: number } } } = {}
	local violations: { [Player]: number } = {}

	game:GetService("Players").PlayerRemoving:Connect(function(player)
		buckets[player] = nil
		violations[player] = nil
	end)

	local function flag(player: Player)
		violations[player] = (violations[player] or 0) + 1
	end

	local api = {} :: ServerApi

	function api.onValidated(name, handler)
		local spec = Specs[name]
		assert(spec ~= nil, "unknown remote: " .. name)
		assert(spec.ratePerSecond ~= nil, name .. " is not a client->server remote")
		local remote = instances[name]
		return remote.OnServerEvent:Connect(function(player, payload)
			-- Rate limit (token bucket)
			local rate = spec.ratePerSecond :: number
			local now = os.clock()
			local playerBuckets = buckets[player]
			if playerBuckets == nil then
				playerBuckets = {}
				buckets[player] = playerBuckets
			end
			local bucket = playerBuckets[name]
			if bucket == nil then
				bucket = { tokens = rate, last = now }
				playerBuckets[name] = bucket
			end
			bucket.tokens = math.min(rate, bucket.tokens + (now - bucket.last) * rate)
			bucket.last = now
			if bucket.tokens < 1 then
				flag(player)
				return
			end
			bucket.tokens -= 1
			-- Payload validation
			if spec.validator ~= nil then
				if not (spec.validator :: Validators.Validator)(payload) then
					flag(player)
					return
				end
			elseif payload ~= nil then
				flag(player)
				return
			end
			handler(player, payload)
		end)
	end

	function api.fireClient(name, player, ...)
		instances[name]:FireClient(player, ...)
	end

	function api.fireAllClients(name, ...)
		instances[name]:FireAllClients(...)
	end

	function api.getViolations(player)
		return violations[player] or 0
	end

	return api
end

-- CLIENT ---------------------------------------------------------------------

export type ClientApi = {
	fire: (name: string, payload: any?) -> (),
	on: (name: string, handler: (...any) -> ()) -> RBXScriptConnection,
}

function Remotes.client(): ClientApi
	local folder = game:GetService("ReplicatedStorage"):WaitForChild(FOLDER_NAME)

	local api = {} :: ClientApi

	function api.fire(name, payload)
		local remote = folder:WaitForChild(name) :: RemoteEvent
		remote:FireServer(payload)
	end

	function api.on(name, handler)
		local remote = folder:WaitForChild(name) :: RemoteEvent
		return remote.OnClientEvent:Connect(handler)
	end

	return api
end

Remotes.Specs = Specs

return Remotes
