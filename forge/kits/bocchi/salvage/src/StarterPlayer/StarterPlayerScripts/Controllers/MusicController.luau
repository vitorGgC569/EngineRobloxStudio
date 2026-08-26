--!optimize 2

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local constants = require(ReplicatedStorage.constants)
local Lumin = require(ReplicatedStorage.Packages.framework)
local Packets = require(ReplicatedStorage.Packets)

local MusicController = {}
MusicController.__index = MusicController

local leaderstats = constants.LOCAL_PLAYER:WaitForChild("leaderstats")
MusicController.currentlyPlayingLabel = constants.INTERFACE.MusicLabel

function MusicController:FadeOut(sound)
	local tween = TweenService:Create(sound, TweenInfo.new(1), {
		Volume = 0,
	})
	tween.Completed:Once(function()
		sound:Stop()
	end)
	tween:Play()
end

function MusicController:FadeIn(sound)
	sound.Volume = 0
	if not sound.IsPlaying then
		sound:Play()
	end
	TweenService:Create(sound, TweenInfo.new(1), { Volume = sound:GetAttribute("OriginalVolume") or 0.5 }):Play()
	MusicController.playing = sound
	MusicController.currentlyPlayingLabel.Text = "NOW PLAYING: " .. sound.Name
end

function MusicController:RefreshMusic(force)
	local area = leaderstats.Area.Value :: string
	if self.playing ~= nil then
		local _result = self.playing.Parent
		if _result ~= nil then
			_result = _result.Name
		end
		local _condition = _result ~= area
		if not _condition then
			_condition = force == true
		end
		if _condition then
			self:FadeOut(self.playing)
		else
			return nil
		end
	end
	if area ~= nil and ReplicatedStorage:GetAttribute("Intro") ~= true then
		local music = self:GetRandomMusic(area)
		self:FadeIn(music)
		if self.connection ~= nil then
			self.connection:Disconnect()
		end
		self.connection = music.Ended:Once(function()
			if self.playing == music then
				self.playing = nil
				self.currentlyPlayingLabel.Text = "currently not playing anything ;-;"
			end
			task.delay(math.random(5, 10), function()
				return self:RefreshMusic()
			end)
		end)
	end
end

function MusicController:GetRandomMusic(area: string)
	local folder = workspace[area].Music
	local current = folder:GetAttribute("Current")
	local sounds = folder:GetChildren()
	local s = #sounds - 1
	local newCurrent = math.random(0, s)
	if current == newCurrent and s > 0 then
		return self:GetRandomMusic(area)
	end
	folder:SetAttribute("Current", newCurrent)
	return sounds[newCurrent + 1]
end

function MusicController:Init()
	leaderstats.Area.Changed:Connect(function(value: string)
		MusicController:RefreshMusic(value)
	end)
	MusicController:RefreshMusic()
	
	-- debug
	workspace:SetAttribute("ChangeMusic", false)
	workspace:GetAttributeChangedSignal("ChangeMusic"):Connect(function()
		return self:RefreshMusic()
	end)
end


return MusicController