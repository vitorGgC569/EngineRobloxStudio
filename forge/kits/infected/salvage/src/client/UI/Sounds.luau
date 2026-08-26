--!strict
-- Sound playback + a small music director driven by remotes. Every id lives in
-- GameConfig.Sounds; an id of 0 means "not configured yet" and is skipped, so this is
-- safe before the audio pass. Sounds are routed through two SoundGroups (Music, SFX) so the
-- Settings panel can control each independently (accessibility). The music director ramps
-- in-round tension by the infected fraction and swaps to a last-stand theme on the final
-- survivor — it just needs a real RoundMusic/LastStandMusic id in GameConfig to come alive.

local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)

local Sounds = {}

-- Find-or-create the Music + SFX groups. Shared with the Settings panel (whichever runs
-- first creates them), so both see the same groups.
function Sounds.getGroups(): (SoundGroup, SoundGroup)
	local music = SoundService:FindFirstChild("MusicGroup") :: SoundGroup?
	if music == nil then
		music = Instance.new("SoundGroup")
		music.Name = "MusicGroup"
		music.Volume = 0.5
		music.Parent = SoundService
	end
	local sfx = SoundService:FindFirstChild("SfxGroup") :: SoundGroup?
	if sfx == nil then
		sfx = Instance.new("SoundGroup")
		sfx.Name = "SfxGroup"
		sfx.Volume = 0.5
		sfx.Parent = SoundService
	end
	return music :: SoundGroup, sfx :: SoundGroup
end

local function play(name: string, looped: boolean?, isMusic: boolean?): Sound?
	local id = (GameConfig.Sounds :: any)[name]
	if id == nil or id == 0 then
		return nil
	end
	local music, sfx = Sounds.getGroups()
	local sound = Instance.new("Sound")
	sound.SoundId = `rbxassetid://{id}`
	sound.SoundGroup = isMusic and music or sfx
	sound.Volume = 1 -- the SoundGroup carries the user's volume setting
	sound.Looped = looped == true
	sound.Parent = SoundService
	sound:Play()
	if not sound.Looped then
		sound.Ended:Once(function()
			sound:Destroy()
		end)
	end
	return sound
end

function Sounds.start(remotes: any)
	Sounds.getGroups() -- ensure the groups exist up front

	local heartbeat: Sound? = nil
	local lobbyMusic: Sound? = nil
	local roundMusic: Sound? = nil
	local lastStand = false

	local function stopRoundMusic()
		if roundMusic then
			local m = roundMusic
			roundMusic = nil
			TweenService:Create(m, TweenInfo.new(0.6), { Volume = 0 }):Play()
			task.delay(0.7, function()
				m:Destroy()
			end)
		end
		lastStand = false
	end

	-- Blend in-round music intensity from the infected fraction (relative to the Music
	-- group volume, which the player controls): louder + a touch faster as the horde grows.
	local function setTension(fraction: number)
		if roundMusic == nil or lastStand then
			return
		end
		local target = 0.5 + 0.5 * math.clamp(fraction, 0, 1)
		TweenService:Create(roundMusic, TweenInfo.new(0.8), { Volume = target }):Play()
		roundMusic.PlaybackSpeed = 1 + 0.15 * math.clamp(fraction, 0, 1)
	end

	remotes.on("ShotFired", function()
		play("GunShot")
	end)
	remotes.on("KnifeThrown", function()
		play("KnifeThrow")
	end)
	remotes.on("ConversionAlert", function()
		play("Conversion")
	end)
	remotes.on("SurvivorPing", function()
		if heartbeat == nil then
			heartbeat = play("Heartbeat", true)
			task.delay(20, function()
				if heartbeat then
					heartbeat:Destroy()
					heartbeat = nil
				end
			end)
		end
		if not lastStand and roundMusic then
			lastStand = true
			local old = roundMusic
			roundMusic = nil
			TweenService:Create(old, TweenInfo.new(0.5), { Volume = 0 }):Play()
			task.delay(0.55, function()
				old:Destroy()
			end)
			roundMusic = play("LastStandMusic", true, true)
			lastStand = true
		end
	end)
	remotes.on("RevealScreen", function(payload)
		if heartbeat then
			heartbeat:Destroy()
			heartbeat = nil
		end
		stopRoundMusic()
		play(payload.winner == "SURVIVORS" and "SurvivorsWin" or "InfectedWin")
	end)
	remotes.on("RoundState", function(state)
		if state.state == "ACTIVE" then
			if lobbyMusic then
				lobbyMusic:Destroy()
				lobbyMusic = nil
			end
			play("RoundStart")
			if roundMusic == nil then
				roundMusic = play("RoundMusic", true, true)
				if roundMusic then
					roundMusic.Volume = 0.5
				end
			end
			local infected = (state.playerCount or 0) - (state.survivorCount or 0)
			if state.playerCount and state.playerCount > 0 then
				setTension(infected / state.playerCount)
			end
		elseif state.state == "INTERMISSION" then
			stopRoundMusic()
			if lobbyMusic == nil then
				lobbyMusic = play("LobbyMusic", true, true)
			end
		end
	end)

	return {}
end

return Sounds
