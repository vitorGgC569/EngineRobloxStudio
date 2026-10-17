--!strict
--[[
	CardCycle — deterministic deck / hand / next-card rotation.

	The Clash-style hand is four cards plus a preview of the fifth; playing
	a card slides `next` into the hand and pulls a fresh preview. When the
	draw pile runs dry the discard reshuffles with the same seeded stream,
	so two clients replaying the same seed see identical cycles forever.

		local cycle = CardCycle.new({ cards = deckIds, handSize = 4, seed = 7 })
		local result = cycle:play(cycle:hand()[1])
]]

local Rng = require(script.Parent.Parent.Core.Rng)

local CardCycle = {}

export type PlayResult = {
	played: string,
	drew: string,
	reshuffled: boolean,
}

type Self = {
	handSize: number,
	rng: Rng.Generator,
	pile: { string },
	discard: { string },
	held: { string },
	nextCard: string,
}

--[[
	A field must never share a name with a method on the same table.

	`CardCycle.__index = CardCycle` means an instance looks at itself first, so an
	instance field called `hand` shadows `CardCycle.hand` and the method
	becomes permanently uncallable: `instance:hand()` finds the field and
	tries to call a table.

	Nothing catches it. It compiles, the type checker is content, and the unit
	specs call the module functions directly rather than through an instance --
	which is exactly the shape that never reaches the shadow. It surfaced the
	first time a game called `cycle:hand()` and got "attempt to call a table
	value", and a scan then found the same collision in four modules.

	The field is renamed rather than the method, because the method is the
	published surface and the field is private.
]]
CardCycle.__index = CardCycle

local function refillPile(self: Self): boolean
	if #self.pile > 0 then
		return false
	end
	if #self.discard == 0 then
		error("CardCycle exhausted: no cards left in pile or discard")
	end
	self.pile = Rng.shuffle(self.rng, self.discard)
	self.discard = {}
	return true
end

function CardCycle.drawFromPile(self: Self): string
	refillPile(self)
	return table.remove(self.pile) :: string
end

function CardCycle.new(config: { cards: { string }, handSize: number?, seed: number? }): Self
	assert(#config.cards > 0, "CardCycle needs cards")
	local handSize = config.handSize or 4
	-- The hand is dealt first, then one more card is drawn for the preview.
	assert(handSize >= 1 and handSize < #config.cards, "handSize must leave one card for the preview")
	-- An empty id used to be shuffled in and dealt into the hand.
	for _, cardId in config.cards do
		assert(type(cardId) == "string" and cardId ~= "", "card id must be a non-empty string")
	end
	-- math.huge is truthy, so it used to reach the rng and the modulo became NaN.
	-- A missing seed still uses the rng default.
	if config.seed ~= nil then
		local seed = config.seed
		assert(
			type(seed) == "number" and seed == seed and seed > -math.huge and seed < math.huge,
			"seed must be a finite number"
		)
	end
	local self: Self = setmetatable({
		handSize = handSize,
		rng = Rng.xorshift(config.seed),
		pile = {},
		discard = {},
		held = {},
		nextCard = "",
	}, CardCycle)
	self.pile = Rng.shuffle(self.rng, table.clone(config.cards))
	for _ = 1, handSize do
		table.insert(self.held, self:drawFromPile())
	end
	self.nextCard = self:drawFromPile()
	return self
end

function CardCycle.hand(self: Self): { string }
	return table.clone(self.held)
end

function CardCycle.peek(self: Self): string
	return self.nextCard
end

function CardCycle.has(self: Self, cardId: string): boolean
	return table.find(self.held, cardId) ~= nil
end

function CardCycle.play(self: Self, cardId: string): PlayResult
	local index = table.find(self.held, cardId)
	assert(index, ("card %q is not in hand"):format(cardId))
	table.remove(self.held, index)
	table.insert(self.discard, cardId)

	local drew = self.nextCard
	table.insert(self.held, drew)
	local reshuffled = refillPile(self)
	self.nextCard = table.remove(self.pile) :: string
	return { played = cardId, drew = drew, reshuffled = reshuffled }
end

return CardCycle
