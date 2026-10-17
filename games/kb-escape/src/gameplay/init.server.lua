--!strict
-- Boot: start the systems, then the loop that uses them.
--
-- Thin on purpose. Everything it starts is a module, so each piece can be
-- required by a test or by another system without running this.

local Gameplay = require(script.Gameplay)
local Drivers = require(script.Drivers)
local Playable = require(script.Playable)

-- Subscribe presentation before the authoritative clock starts, so
-- the first wave cannot be emitted into an empty listener set.
Playable.build(Gameplay, Drivers)

-- The clock. Everything above declares what exists; this is what makes it
-- happen without the player asking, which is the difference between a
-- world with systems in it and a game.
Drivers.start(Gameplay)

--[[
	The last line, and it says the game is up.

	Everything that photographs, measures or tests a game has to know when
	it finished starting, and without this each of them guesses. The
	guesses are all versions of watching the screen stop changing, and they
	are all wrong the same way: a HUD builds its labels in the first frame
	and fills them as answers arrive, so a watcher settles while the game
	is still building itself.

	Not one generated game emitted this, so every game this factory has
	ever produced was invisible to `forge probe` and `forge gametest` --
	the measurement half of the same repository could not read the
	production half's output.

	Written as a plain StringValue rather than through `Forge.Debug`,
	because a generated game is built on GameKit and does not have Forge.
	The *signal* is what the tooling reads; which library wrote it is not
	something any reader of it cares about.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ready = ReplicatedStorage:FindFirstChild("ForgeReady")
if ready == nil then
	local made = Instance.new("StringValue")
	made.Name = "ForgeReady"
	made.Parent = ReplicatedStorage
	ready = made
end
-- Narrowed with `IsA` rather than cast. A cast would start the
-- statement with `(`, which Luau reads as a call on the line above.
if ready ~= nil and ready:IsA("StringValue") then
	ready.Value = "kb-escape"
end

return nil
