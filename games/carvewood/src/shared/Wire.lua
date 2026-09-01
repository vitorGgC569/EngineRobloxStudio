--!strict
--[[
	Wire — the messages the client and the server agree on.

	One file, required by both, so a name cannot drift between them. A remote
	spelled two ways is the classic silent failure: the client fires into
	something nobody listens on, and firing into nothing raises no error
	anywhere.

	Every `c2s` entry is a **request**, never an instruction. `strike` does not
	mean "take four hit points off that tree"; it means "I swung at plot 3".
	Whether that plot holds a grown tree, how hard the axe bites and what falls
	out of it is the server's to decide from its own state. That is why these
	payloads carry only a slot number, an id or a price: a payload the server
	trusts is an exploit waiting for the developer console.

	The one entry that looks like an exception is `stock`'s price, and it is
	not one -- the server clamps it into a band around the piece's fair value,
	so the client is choosing inside a range the server drew.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local Wire = {}

Wire.definitions = {
	--: "I pressed plant on this plot, with this seed selected." Planting spends
	--: a seed, so the server checks the stock rather than the purse.
	plant = { dir = "c2s", kind = "function", rate = 6,
		shape = { plot = "number", species = "string" } },

	--: "I swung at this plot." Reach, cooldown and axe power are read
	--: server-side. This rate is a ceiling on the remote; the real gate is the
	--: swing cooldown the server keeps per player.
	strike = { dir = "c2s", kind = "function", rate = 14,
		shape = { plot = "number" } },

	--: The bench. `carveBegin` takes a log and opens a session; `carveStrike`
	--: says "now", and the server -- which owns the clock -- works out where
	--: the marker was.
	carveBegin = { dir = "c2s", kind = "function", rate = 4,
		shape = { species = "string" } },
	carveStrike = { dir = "c2s", kind = "function", rate = 10 },

	--: The counter, at 60%. Kept so a player with no shop, or with full
	--: shelves, is never stuck holding stock they cannot turn into money.
	sell = { dir = "c2s", kind = "function", rate = 4 },

	--: Seeds. One pack, one seed; essence turns a pile of duplicates into the
	--: species you actually wanted.
	rollSeed = { dir = "c2s", kind = "function", rate = 4 },
	convert = { dir = "c2s", kind = "function", rate = 4,
		shape = { species = "string" } },

	--: The shop floor.
	stock = { dir = "c2s", kind = "function", rate = 8,
		shape = { stand = "number", carving = "number", price = "number" } },
	unstock = { dir = "c2s", kind = "function", rate = 8,
		shape = { stand = "number" } },
	setPrice = { dir = "c2s", kind = "function", rate = 8,
		shape = { stand = "number", price = "number" } },
	buyUpgrade = { dir = "c2s", kind = "function", rate = 4,
		shape = { node = "string" } },
	autoAccept = { dir = "c2s", kind = "function", rate = 4,
		shape = { percent = "number" } },

	--: Answering a customer's offer. `id` is the customer's, not the stand's:
	--: two people can be haggling over different shelves at once.
	haggle = { dir = "c2s", kind = "function", rate = 8,
		shape = { id = "number", accept = "boolean" } },

	buyPlot = { dir = "c2s", kind = "function", rate = 3 },
	buyAxe = { dir = "c2s", kind = "function", rate = 3 },
	hire = { dir = "c2s", kind = "function", rate = 3 },

	--: The whole yard, for drawing it. Attributes carry the hot numbers; this
	--: carries the shape, which is too big for an attribute and changes only
	--: when the player acts.
	yard = { dir = "c2s", kind = "function", rate = 8 },

	-- ---------------------------------------------------- server -> client
	--: What just happened, as opposed to what the numbers are.
	notice = { dir = "s2c", kind = "event" },

	--: "You walked up to something that opens a panel."
	openPanel = { dir = "s2c", kind = "event" },

	--: A swing landed. Carries the tree's remaining health, so the client can
	--: draw the bite without asking for it.
	struck = { dir = "s2c", kind = "event" },

	--: The bench, stroke by stroke. The client draws the bar from `centre`,
	--: `halfWidth` and `sweep`; it never scores anything.
	carveState = { dir = "s2c", kind = "event" },

	--: Somebody is standing at a shelf with an offer, and the clock is running.
	customerOffer = { dir = "s2c", kind = "event" },

	--: A sale closed, whether or not the player was looking at it.
	saleMade = { dir = "s2c", kind = "event" },
}

function Wire.install()
	Forge.Net.define(Wire.definitions)
end

return Wire
