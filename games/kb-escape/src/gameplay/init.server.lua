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

return nil
