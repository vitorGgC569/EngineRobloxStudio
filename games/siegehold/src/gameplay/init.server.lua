--!strict
-- Boot: start the systems, then the loop that uses them.
--
-- Thin on purpose. Everything it starts is a module, so each piece can be
-- required by a test or by another system without running this.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Gameplay = require(script.Gameplay)
local Playable = require(script.Playable)

--: The remotes, before anything that listens on them. `Net.define` creates the
--: RemoteFunction instances; a handler registered first would attach to
--: nothing and the client's call would hang until it timed out.
require(ReplicatedStorage.Shared.Wire).install()

Playable.build(Gameplay)

--: The daily calendar. The first loop in this game that runs from the profile
--: rather than from the session, which is why it is also the first thing that
--: loads and writes one.
require(script.Rewards).start(Gameplay)

-- The clock. Everything above declares what exists; this is what makes it
-- happen without the player asking, which is the difference between a
-- world with systems in it and a game.
local Drivers = require(script.Drivers)
Drivers.start(Gameplay)

--: The probes, published where the bridge can read them. Geometry can be
--: measured from outside; whether the daily calendar tracked this player, or
--: which panel is open, cannot -- and those are the things a UI flow test
--: needs to assert on.
require(ReplicatedStorage.Forge).Debug.expose()

return nil
