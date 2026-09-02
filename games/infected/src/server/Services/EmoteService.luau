--!strict
-- Emotes, played server-side so every client sees them.
--
-- The animation is loaded onto the character's own Animator by the server, which is what
-- makes it replicate; a client-side LoadAnimation would only ever be visible to the person
-- who pressed the button.
--
-- PATIENT ZERO GUARD: the hidden PZ is deliberately allowed to emote. Waving along with the
-- group is the cheapest available bluff and feeds the core mind-game. Revealed zombies are
-- refused — a dancing zombie looks broken, and it would give a converted player a channel
-- to signal the living.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Emotes = require(Shared.Emotes)

local EmoteService = {}
EmoteService.__index = EmoteService

export type Deps = {
	remotes: any,
	roleService: any,
}

function EmoteService.new(deps: Deps)
	local self = setmetatable({}, EmoteService)
	self._deps = deps
	self._playing = {} :: { [Player]: AnimationTrack }
	self._lastAt = {} :: { [Player]: number }
	game:GetService("Players").PlayerRemoving:Connect(function(player)
		self._playing[player] = nil
		self._lastAt[player] = nil
	end)
	return self
end

function EmoteService:stop(player: Player)
	local track = self._playing[player]
	if track then
		pcall(function()
			track:Stop(0.15)
		end)
		self._playing[player] = nil
	end
end

function EmoteService:play(player: Player, emoteId: string)
	local emote = Emotes.byId(emoteId)
	if emote == nil then
		return
	end
	local role = self._deps.roleService:getRole(player)
	if not Emotes.canPlay(role) then
		return
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if character == nil or humanoid == nil or humanoid.Health <= 0 then
		return
	end
	-- Emoting mid-air or mid-fall looks broken and would let players animation-cancel.
	local state = humanoid:GetState()
	if state == Enum.HumanoidStateType.Freefall or state == Enum.HumanoidStateType.Jumping then
		return
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator == nil then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	self:stop(player)

	local animation = Instance.new("Animation")
	animation.AnimationId = "rbxassetid://" .. emote.animationId
	local ok, track = pcall(function()
		return (animator :: Animator):LoadAnimation(animation)
	end)
	if not ok or track == nil then
		return
	end

	local loaded = track :: AnimationTrack
	loaded.Priority = Enum.AnimationPriority.Action
	loaded.Looped = false
	loaded:Play(0.15)
	self._playing[player] = loaded
	self._lastAt[player] = os.clock()

	-- Moving cancels the emote, so you can't emote-lock yourself in a doorway.
	local moveConn: RBXScriptConnection? = nil
	moveConn = humanoid:GetPropertyChangedSignal("MoveDirection"):Connect(function()
		if humanoid.MoveDirection.Magnitude > 0.1 then
			if moveConn then
				moveConn:Disconnect()
				moveConn = nil
			end
			if self._playing[player] == loaded then
				self:stop(player)
			end
		end
	end)
	task.delay(emote.duration, function()
		if moveConn then
			moveConn:Disconnect()
		end
		if self._playing[player] == loaded then
			self._playing[player] = nil
		end
	end)

	-- Broadcast so clients can show a nameplate flourish; the animation itself already
	-- replicates. Deliberately carries no role information.
	self._deps.remotes.fireAllClients("EmotePlayed", {
		userId = player.UserId,
		emoteId = emote.id,
	})
end

function EmoteService:start()
	self._deps.remotes.onValidated("PlayEmote", function(player: Player, payload: { emoteId: string })
		self:play(player, payload.emoteId)
	end)
end

return EmoteService
