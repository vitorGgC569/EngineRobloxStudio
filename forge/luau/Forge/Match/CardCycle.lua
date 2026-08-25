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
	hand: { string },
	nextCard: string,
}

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
	assert(handSize >= 1 and handSize <= #config.cards, "handSize must fit inside the deck")
	local self: Self = setmetatable({
		handSize = handSize,
		rng = Rng.xorshift(config.seed),
		pile = {},
		discard = {},
		hand = {},
		nextCard = "",
	}, CardCycle)
	self.pile = Rng.shuffle(self.rng, table.clone(config.cards))
	for _ = 1, handSize do
		table.insert(self.hand, self:drawFromPile())
	end
	self.nextCard = self:drawFromPile()
	return self
end

function CardCycle.hand(self: Self): { string }
	return table.clone(self.hand)
end

function CardCycle.peek(self: Self): string
	return self.nextCard
end

function CardCycle.has(self: Self, cardId: string): boolean
	return table.find(self.hand, cardId) ~= nil
end

function CardCycle.play(self: Self, cardId: string): PlayResult
	local index = table.find(self.hand, cardId)
	assert(index, ("card %q is not in hand"):format(cardId))
	table.remove(self.hand, index)
	table.insert(self.discard, cardId)

	local drew = self.nextCard
	table.insert(self.hand, drew)
	local reshuffled = refillPile(self)
	self.nextCard = table.remove(self.pile) :: string
	return { played = cardId, drew = drew, reshuffled = reshuffled }
end

return CardCycle
