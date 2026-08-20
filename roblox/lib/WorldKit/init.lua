--!strict
-- WorldKit: reusable world-building primitives for Roblox production.
--
-- Owned by the platform, not by any one game. When a map needs "a shop", "eight
-- plots", "a treeline" or "lighting that does not look flat", the answer belongs
-- here so the next game gets it too -- rather than another 400-line service full
-- of literal coordinates.
--
--   local WorldKit = require(ServerScriptService.WorldKit)
--   local theme = WorldKit.Palette.MinersRidge
--   local layout = WorldKit.Grid.layout(8, 110, 26, Vector3.new(0, 0, -260), 60)

local WorldKit = {}

-- L0: art direction as data. Everything above reads its numbers from here.
WorldKit.Tokens = require(script.Tokens)
WorldKit.Architecture = require(script.Architecture)
WorldKit.Props = require(script.Props)
WorldKit.Threat = require(script.Threat)
WorldKit.Setpiece = require(script.Setpiece)
WorldKit.Audio = require(script.Audio)
-- Named FeedbackPresenter on disk so the headless multi-library harness can
-- load it beside GameKit.Feedback without flattening two modules to one name.
WorldKit.Feedback = require(script.FeedbackPresenter)
WorldKit.Guidance = require(script.Guidance)

-- L1: primitives.
WorldKit.Palette = require(script.Palette)
WorldKit.Build = require(script.Build)
WorldKit.Grid = require(script.Grid)
WorldKit.Semantics = require(script.Semantics)

-- L2: fabrication. Geometry that could not be assembled from boxes.
WorldKit.Fab = require(script.Fab)

-- L3/L4: kits, the greybox grammar, and the pass that dresses one with the other.
WorldKit.Kit = require(script.Kit)
WorldKit.Blockout = require(script.Blockout)
WorldKit.Dress = require(script.Dress)

-- L5: presentation. Costs nothing in assets and carries most of the polish.
WorldKit.Mood = require(script.Mood)
WorldKit.Sound = require(script.Sound)
WorldKit.Camera = require(script.Camera)
WorldKit.Vfx = require(script.Vfx)

-- L6: interface.
WorldKit.Ui = require(script.Ui)
WorldKit.Compose = require(script.Compose)

-- Composed builders.
WorldKit.Conveyor = require(script.Conveyor)
WorldKit.Nature = require(script.Nature)
WorldKit.Land = require(script.Land)
WorldKit.Acoustics = require(script.Acoustics)
WorldKit.Interact = require(script.Interact)
WorldKit.Physics = require(script.Physics)
WorldKit.Sky = require(script.Sky)

WorldKit.VERSION = "2.2.0"

return WorldKit
