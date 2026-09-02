--!strict
-- Movement sanity + violation aggregation. Speed is the #1 exploit surface here
-- (a speed-hacked infected ruins rounds), so every player's displacement is checked
-- each window against the fastest legitimately-attainable speed. Flagged players are
-- snapped back; repeat offenders are kicked.
--
-- Critical: legitimate game teleports (LoadCharacter, map spawns, zombie respawns)
-- must never look like cheats. We:
--   1. give a grace window after every CharacterAdded / trusted teleport
--   2. keep lastPos in sync with the root AFTER snaps (old bug: lastPos stayed at the
--      teleported spot while the body was snapped back, so the next window re-flagged
--      forever and kicked real players with "Suspicious activity detected.")
--   3. decay movement flags while the player is behaving

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)
local AntiCheatMath = require(Shared.AntiCheatMath)

local KICK_THRESHOLD = 18 -- combined flags before kick (raised; false positives used to hit 12 fast)
local SNAP_THRESHOLD = 4 -- movement flags before we start snapping back
local SPAWN_GRACE_SECONDS = 4 -- ignore movement right after character spawn / trusted teleport
local FLAG_DECAY_PER_OK = 1 -- how many movement flags drop on a clean window

local AntiCheatService = {}
AntiCheatService.__index = AntiCheatService

export type Deps = {
	remotes: any, -- Remotes.ServerApi (invalid-payload violations)
	combatService: any, -- combat flags
}

function AntiCheatService.new(deps: Deps)
	local self = setmetatable({}, AntiCheatService)
	self._deps = deps
	self._lastPos = {} :: { [Player]: Vector3 }
	self._movementFlags = {} :: { [Player]: number }
	self._graceUntil = {} :: { [Player]: number }
	return self
end

-- Call after any intentional server teleport (map spawn, zombie respawn, etc.) so the
-- next check windows do not treat the jump as a cheat.
function AntiCheatService:noteTrustedTeleport(player: Player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		self._lastPos[player] = root.Position
	else
		self._lastPos[player] = nil
	end
	self._graceUntil[player] = os.clock() + SPAWN_GRACE_SECONDS
end

function AntiCheatService:_inGrace(player: Player): boolean
	local untilT = self._graceUntil[player]
	return untilT ~= nil and os.clock() < untilT
end

function AntiCheatService:_checkPlayer(player: Player, interval: number)
	local character = player.Character
	if character == nil then
		self._lastPos[player] = nil
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return
	end
	local pos = root.Position

	-- Grace: accept whatever the server just did (spawn, respawn, map load) and re-anchor.
	if self:_inGrace(player) then
		self._lastPos[player] = pos
		return
	end

	local last = self._lastPos[player]
	self._lastPos[player] = pos
	if last == nil then
		return
	end

	-- Horizontal displacement only: falling is legitimate vertical speed.
	local delta = pos - last
	local horizontal = Vector3.new(delta.X, 0, delta.Z).Magnitude
	local verdict = AntiCheatMath.classify(
		horizontal,
		interval,
		GameConfig.Movement.MaxToleratedSpeed,
		GameConfig.Movement.TeleportFlagStuds
	)

	if verdict == "ok" then
		local flags = self._movementFlags[player]
		if flags and flags > 0 then
			self._movementFlags[player] = math.max(0, flags - FLAG_DECAY_PER_OK)
		end
		return
	end

	if verdict == "teleport" then
		-- Hard jump: snap back and count it. Keep lastPos on the snapped body so the
		-- next window does not re-measure the same jump and loop-flag until kick.
		self._movementFlags[player] = (self._movementFlags[player] or 0) + 2
		root.CFrame = CFrame.new(last)
		self._lastPos[player] = last
	elseif verdict == "speed" then
		local flags = (self._movementFlags[player] or 0) + 1
		self._movementFlags[player] = flags
		if flags >= SNAP_THRESHOLD then
			root.CFrame = CFrame.new(last)
			self._lastPos[player] = last
		end
	end
end

function AntiCheatService:totalFlags(player: Player): number
	return (self._movementFlags[player] or 0)
		+ self._deps.remotes.getViolations(player)
		+ self._deps.combatService:getFlags(player)
end

function AntiCheatService:_hookPlayer(player: Player)
	player.CharacterAdded:Connect(function()
		self._lastPos[player] = nil
		self._graceUntil[player] = os.clock() + SPAWN_GRACE_SECONDS
	end)
	if player.Character then
		self._graceUntil[player] = os.clock() + SPAWN_GRACE_SECONDS
	end
end

function AntiCheatService:start()
	for _, player in Players:GetPlayers() do
		self:_hookPlayer(player)
	end
	Players.PlayerAdded:Connect(function(player)
		self:_hookPlayer(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		self._lastPos[player] = nil
		self._movementFlags[player] = nil
		self._graceUntil[player] = nil
	end)

	task.spawn(function()
		local interval = GameConfig.Movement.CheckIntervalSeconds
		while true do
			task.wait(interval)
			for _, player in Players:GetPlayers() do
				self:_checkPlayer(player, interval)
				if self:totalFlags(player) >= KICK_THRESHOLD then
					player:Kick("Suspicious activity detected.")
				end
			end
		end
	end)
end

return AntiCheatService
