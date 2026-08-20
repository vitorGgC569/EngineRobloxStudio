--!strict
-- Boot: start the systems, then the loop that uses them.
--
-- Thin on purpose. Everything it starts is a module, so each piece can be
-- required by a test or by another system without running this.

local Gameplay = require(script.Gameplay)
local Playable = require(script.Playable)

Playable.build(Gameplay)

-- The clock. Everything above declares what exists; this is what makes it
-- happen without the player asking, which is the difference between a
-- world with systems in it and a game.
local Drivers = require(script.Drivers)
Drivers.start(Gameplay)

return nil
