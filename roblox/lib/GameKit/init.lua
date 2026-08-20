--!strict
-- GameKit: reusable game systems.
--
-- WorldKit builds the place; GameKit runs the game inside it. The split is
-- deliberate -- a tycoon and a tower defence share almost no geometry and almost
-- all of their systems: currency that cannot be double-spent, saves that cannot
-- be duplicated across servers, progression that unlocks in a defined order, and
-- analytics that say whether anyone is enjoying it.
--
-- Every module here is pure Luau with no Studio-only dependency, so the same
-- code runs in a plugin, in a published experience, and in an Open Cloud Luau
-- task. That is what makes an economy simulatable headlessly instead of only
-- observable after launch.

local GameKit = {}

GameKit.Analytics = require(script.Analytics)
GameKit.Rules = require(script.Rules)
GameKit.Pursuit = require(script.Pursuit)
GameKit.Motion = require(script.Motion)
GameKit.Commerce = require(script.Commerce)
GameKit.Platform = require(script.Platform)
GameKit.Chat = require(script.Chat)
GameKit.Reach = require(script.Reach)
GameKit.Economy = require(script.Economy)
GameKit.Inventory = require(script.Inventory)
GameKit.Save = require(script.Save)
GameKit.Progression = require(script.Progression)
GameKit.Shop = require(script.Shop)
GameKit.Leaderboard = require(script.Leaderboard)
GameKit.Tower = require(script.Tower)
GameKit.Feedback = require(script.Feedback)
GameKit.Onboarding = require(script.Onboarding)

GameKit.VERSION = "1.1.0"

return GameKit
