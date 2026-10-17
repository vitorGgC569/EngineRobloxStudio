--!strict
--[[
	AssetPicks — which catalogue models the world is allowed to dress in.

	Every model below was placed in a live Studio edit session as a labelled
	contact sheet, tinted exactly the way `Place.build` tints, and chosen by
	eye. What the eye rejected, and why:

	  * tree — the Retro PSX Nature Pack trees (Tree01-08) render as flat
	    angular slabs; KayKit's `Tree Desert`, `Treeb Graveyard` and
	    `Treed Graveyard` are bare skeletons; the Village `Tree` is a bare
	    branchy thing. What survived is four Titan's Floral Green trees,
	    the Village low-poly pine, KayKit's broad canopy and layered pine,
	    and five Godot birches -- tinted, they read as one stylised forest.
	  * bush — the PSX modular hedges are wall segments wearing bush names
	    (`Bush Connector High Half End Dead`), and the COZY FARM `Bushes*`
	    are pre-textured in screen-bright greens that Tint is not allowed to
	    touch. Both families are out; everything the sun colours is in.
	  * flower — `Wateringcanwflower` is a watering can, not a plant.
	  * grass patch — every member is a flat quad that reads as a green rug
	    lying on the ground. The topic is empty on purpose.

	`mix` on the foliage topics turns off the textured-first preference,
	because the corrected lists are meant to be used whole: the greys are
	the ones Tint paints, and the few pre-coloured models already carry the
	artist's own decision.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Curated = Forge.Catalog.Curated

local AssetPicks = {}

local RULES: Curated.Rules = {
	tree = {
		mix = true,
		allow = {
			-- Titan's Packs: rounded, leafy
			71973165859498, -- Tree 02
			73380086826768, -- Tree 01
			99998633805764, -- Tree 04
			129828771252604, -- Tree 05
			-- Village Asset Pack: clean stylised pine
			81551430507321, -- Tree 001
			-- KayKit: broad canopy and layered pine
			109573179148967, -- Detail Treea
			90278178286973, -- Tree Forest
			-- Godot plant pack: leafy clusters
			111598666746773, -- Birch Tree 1
			125564927414164, -- Birch Tree 2
			107515147586079, -- Birch Tree 3
			140568400837708, -- Birch Tree 4
			127089263202884, -- Birch Tree 6
		},
	},
	bush = {
		mix = true,
		denyNames = { "connector", "dead", "bushes" },
	},
	flower = {
		--: `Wateringcanwflower` is a watering can. `Flowerno` and
		--: `Flowerstack` render as flat white paper crosses lying on the
		--: lawn -- the first day-lit capture was full of them.
		mix = true,
		denyNames = { "wateringcan", "flowerno", "flowerstack" },
	},
	["grass patch"] = {
		--: Empty allow-list: the topic has nothing worth placing, and nil
		--: from `pick` is the honest answer rather than a rug.
		allow = {},
	},
	log = {
		denyNames = { "anvil" },
	},
}

AssetPicks.catalogue = Curated.new(Forge.Catalog.ItchAssets, RULES)

function AssetPicks.describe(): { [string]: any }
	return AssetPicks.catalogue:describe()
end

return AssetPicks
