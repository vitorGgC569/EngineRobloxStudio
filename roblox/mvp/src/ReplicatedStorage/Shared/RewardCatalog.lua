--!strict
-- Codes, daily rewards and the Robux storefront.
--
-- Product ids are deliberately left at 0. A developer product only exists once
-- it has been created in the Creator Dashboard of the account that owns the
-- experience, and inventing an id would produce a store that looks functional
-- and silently fails at the till. `configured()` reports which entries are real
-- so the shop can hide or mark the rest.

local RewardCatalog = {}

export type Code = {
	code: string,
	reward: string,
	amount: number,
	label: string,
}

RewardCatalog.Codes = {
	{ code = "RIDGE", reward = "cash", amount = 5000, label = "$5,000" },
	{ code = "FIRSTBELT", reward = "cash", amount = 12000, label = "$12,000" },
	{ code = "LUCKYSTART", reward = "potion:luck", amount = 1, label = "1x Luck Potion" },
	{ code = "MUTATE", reward = "potion:mutation", amount = 1, label = "1x Mutation Potion" },
	{ code = "OPENING", reward = "potion:cash", amount = 2, label = "2x Cash Potion" },
}

RewardCatalog.CodeByText = {}
for _, entry in ipairs(RewardCatalog.Codes) do
	RewardCatalog.CodeByText[string.upper(entry.code)] = entry
end

--- Daily login rewards, cycling every seven days.
RewardCatalog.Daily = {
	{ day = 1, reward = "cash", amount = 2000, label = "$2,000" },
	{ day = 2, reward = "potion:cash", amount = 1, label = "Cash Potion" },
	{ day = 3, reward = "cash", amount = 10000, label = "$10,000" },
	{ day = 4, reward = "potion:luck", amount = 1, label = "Luck Potion" },
	{ day = 5, reward = "cash", amount = 40000, label = "$40,000" },
	{ day = 6, reward = "potion:production", amount = 1, label = "Production Potion" },
	{ day = 7, reward = "potion:mutation", amount = 2, label = "2x Mutation Potion" },
}

export type Product = {
	id: string,
	name: string,
	description: string,
	--- 0 means "not created in the Creator Dashboard yet".
	productId: number,
	robux: number,
	grants: string,
	amount: number,
	color: { number },
}

RewardCatalog.Products = {
	{ id = "starter_pack", name = "Pacote Iniciante", description = "Cash, a Luck Potion and two slots.", productId = 0, robux = 6, grants = "bundle:starter", amount = 1, color = { 248, 152, 72 } },
	{ id = "pro_pack", name = "Pacote Pro", description = "A large cash grant and three potions.", productId = 0, robux = 45, grants = "bundle:pro", amount = 1, color = { 92, 176, 255 } },
	{ id = "royal_pack", name = "Pacote Real", description = "Everything in Pro, plus a guaranteed mutation.", productId = 0, robux = 449, grants = "bundle:royal", amount = 1, color = { 250, 200, 92 } },
	{ id = "cash_x2", name = "2x Dinheiro", description = "Permanently doubles card box value.", productId = 0, robux = 69, grants = "multiplier:cash", amount = 2, color = { 118, 226, 118 } },
	{ id = "luck_x2", name = "2x Sorte", description = "Permanently doubles belt luck.", productId = 0, robux = 85, grants = "multiplier:luck", amount = 2, color = { 108, 178, 255 } },
	{ id = "offline_double", name = "Dobrar Offline", description = "Doubles the earnings waiting for you.", productId = 0, robux = 19, grants = "offline:double", amount = 2, color = { 190, 122, 255 } },
}

RewardCatalog.ProductById = {}
for _, product in ipairs(RewardCatalog.Products) do
	RewardCatalog.ProductById[product.id] = product
end

--- Products that can actually be sold right now.
function RewardCatalog.configured(): { Product }
	local ready = {}
	for _, product in ipairs(RewardCatalog.Products) do
		if product.productId ~= 0 then
			table.insert(ready, product)
		end
	end
	return ready
end

function RewardCatalog.isConfigured(id: string): boolean
	local product = RewardCatalog.ProductById[id]
	return product ~= nil and product.productId ~= 0
end

return RewardCatalog
