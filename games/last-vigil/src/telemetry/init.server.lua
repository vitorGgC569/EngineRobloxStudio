--!strict
-- Telemetry: onboarding and session events.
--
-- Emitted where the event happens rather than where somebody remembered to log
-- it. Without this the first session is unmeasurable, and the first session is
-- the one every other number is judged against.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local GameKit = require(ReplicatedStorage.GameKit)

Players.PlayerAdded:Connect(function(player: Player)
	GameKit.Analytics.onboardingStep(player, 1, "joined")
	GameKit.Analytics.custom(player, "session_start", 1, {
		genre = "tower_defense",
		theme = "ruins",
	})
end)

return true
