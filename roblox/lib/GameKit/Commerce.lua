--!strict
--- Real money: passes, products, and the receipt handler that must not lose one.
---
--- `Economy` handles the currency inside the game -- coins, cash, whatever the
--- design calls it. None of that is money. There was no `MarketplaceService`
--- anywhere in this engine, no game pass, no developer product and no
--- `ProcessReceipt`, which means every game the factory made was a commercial
--- product with no way to be commercial.
---
--- **`ProcessReceipt` is the one function here that can lose a player's money.**
--- Roblox calls it after the charge has already happened. If it errors, or
--- returns `NotProcessedYet`, Roblox calls it again later -- possibly in a
--- different server, possibly after a restart. So two properties are not
--- optional:
---
---   * **Idempotent.** The same `PurchaseId` must never be granted twice. The
---     record of what has been granted lives in a DataStore, written *before*
---     returning `PurchaseGranted`, because returning first and saving second
---     loses the record on a crash and grants again on retry.
---   * **Total.** An unknown product id must return `NotProcessedYet`, not
---     `PurchaseGranted`. Granting nothing and telling Roblox it went fine is
---     how a player pays for something they never receive.
---
--- Getting this wrong is not a bug that shows up in a screenshot. It shows up
--- as a support ticket, and on Roblox it shows up as a refund.
---
--- **What this module cannot do.** It cannot create a pass or a product --
--- there is no API for that, on Open Cloud or anywhere else. Those are made on
--- the website and their ids come back here. `declare` is where they arrive.

local MarketplaceService = game:GetService("MarketplaceService")
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Commerce = {}

export type Pass = {
	id: number,
	name: string,
	--- What owning it does. Called once per player per session, and again for
	--- anyone who buys mid-session.
	grant: ((Player) -> ())?,
}

export type Product = {
	id: number,
	name: string,
	--- What one purchase does. Must be safe to call exactly once.
	grant: (Player) -> boolean,
}

export type Catalogue = {
	passes: { Pass },
	products: { Product },
}

type Wiring = {
	passes: { [number]: Pass },
	products: { [number]: Product },
	granted: { [string]: boolean },
	store: DataStore?,
	connections: { RBXScriptConnection },
	stats: { [string]: number },
	--- The receipt path, kept so it can be run without a purchase.
	---
	--- `MarketplaceService.ProcessReceipt` is a callback: it can be assigned and
	--- never read. So "is a handler installed" cannot be answered by looking at
	--- the service, and the function cannot be reached for a test either. Both
	--- are solved by keeping our own reference.
	process: ((any) -> Enum.ProductPurchaseDecision)?,
}

local wiring: Wiring? = nil

--- Where granted purchase ids are remembered.
---
--- A separate store from game saves on purpose: a wipe of player progress must
--- never be able to re-grant purchases, and the two have different lifetimes.
local RECEIPT_STORE = "RQEReceipts_v1"

local function bump(key: string)
	local live = wiring
	if live ~= nil then
		live.stats[key] = (live.stats[key] or 0) + 1
	end
end

--- Everything wrong with a catalogue, before any of it reaches a player.
function Commerce.problems(catalogue: Catalogue): { string }
	local found = {}
	if type(catalogue) ~= "table" then
		return { "catalogue must be a table" }
	end

	local seen: { [number]: string } = {}
	for _, pass in ipairs(catalogue.passes or {}) do
		if type(pass.id) ~= "number" or pass.id <= 0 or pass.id % 1 ~= 0 then
			table.insert(found, ("pass %q needs a positive integer id"):format(
				tostring(pass.name)))
		elseif seen[pass.id] ~= nil then
			table.insert(found, ("id %d is used by both %s and %s"):format(
				pass.id, seen[pass.id], tostring(pass.name)))
		else
			seen[pass.id] = tostring(pass.name)
		end
		if type(pass.name) ~= "string" or pass.name == "" then
			table.insert(found, ("pass %d has no name"):format(tonumber(pass.id) or 0))
		end
	end

	for _, product in ipairs(catalogue.products or {}) do
		if type(product.id) ~= "number" or product.id <= 0 or product.id % 1 ~= 0 then
			table.insert(found, ("product %q needs a positive integer id"):format(
				tostring(product.name)))
		elseif seen[product.id] ~= nil then
			table.insert(found, ("id %d is used by both %s and %s"):format(
				product.id, seen[product.id], tostring(product.name)))
		else
			seen[product.id] = tostring(product.name)
		end
		-- A product with no grant takes money and does nothing. There is no
		-- reading of that which is acceptable, so it is an error rather than a
		-- warning.
		if type(product.grant) ~= "function" then
			table.insert(found, ("product %q has no grant, so a purchase would "
				.. "charge the player and do nothing"):format(tostring(product.name)))
		end
	end

	return found
end

local function receiptKey(receipt: any): string
	return tostring(receipt.PlayerId) .. ":" .. tostring(receipt.PurchaseId)
end

local function alreadyGranted(live: Wiring, key: string): boolean
	if live.granted[key] then
		return true
	end
	if live.store == nil then
		return false
	end
	local ok, value = pcall(function()
		return live.store:GetAsync(key)
	end)
	if ok and value ~= nil then
		live.granted[key] = true
		return true
	end
	return false
end

--- Write down that this purchase was delivered. Retries, because the common
--- failure is transient.
---
--- **The order matters and both orders lose something.** Granting first and
--- recording second risks granting twice if the record never lands. Recording
--- first and granting second risks the player paying for something the grant
--- then failed to deliver. Between "the player gets two" and "the player gets
--- nothing", the second is worse, so the grant goes first -- and this function
--- works hard to make the record land.
---
--- Observed in Studio with API Services off: the grant ran, `SetAsync` threw,
--- and the handler returned `NotProcessedYet`. Roblox retried, the in-memory
--- record answered, and the player received exactly one. That self-heals on the
--- same server and does not across a restart, which is why the retries are here
--- and why `report()` says plainly whether writes actually work.
local function remember(live: Wiring, key: string): boolean
	live.granted[key] = true
	if live.store == nil then
		-- No DataStore means no memory across servers. Studio has none by
		-- default, and pretending otherwise would make a test pass that a live
		-- game fails.
		return not RunService:IsStudio()
	end
	for attempt = 1, 4 do
		local ok = pcall(function()
			live.store:SetAsync(key, os.time())
		end)
		if ok then
			return true
		end
		bump("recordRetry")
		-- Throttling clears in seconds; a permissions failure never does. Both
		-- end the same way, and the cost of trying is a few seconds on a path
		-- that already has the player's money.
		task.wait(attempt * 0.5)
	end
	return false
end

--- Wire a catalogue up. Refuses the whole thing on any problem.
function Commerce.declare(catalogue: Catalogue): (boolean, { string })
	local found = Commerce.problems(catalogue)
	if #found > 0 then
		return false, found
	end

	Commerce.clear()

	local store: DataStore? = nil
	local ok, opened = pcall(function()
		return DataStoreService:GetDataStore(RECEIPT_STORE)
	end)
	if ok then
		store = opened
	end

	local live: Wiring = {
		passes = {},
		products = {},
		granted = {},
		store = store,
		connections = {},
		stats = {},
	}
	for _, pass in ipairs(catalogue.passes or {}) do
		live.passes[pass.id] = pass
	end
	for _, product in ipairs(catalogue.products or {}) do
		live.products[product.id] = product
	end
	wiring = live

	local function process(receipt): Enum.ProductPurchaseDecision
		local current = wiring
		if current == nil then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local product = current.products[receipt.ProductId]
		if product == nil then
			-- Unknown id. Never `PurchaseGranted`: that tells Roblox the charge
			-- was honoured when nothing was delivered.
			bump("unknownProduct")
			warn(("[Commerce] no product %d declared; leaving it unprocessed")
				:format(receipt.ProductId))
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local key = receiptKey(receipt)
		if alreadyGranted(current, key) then
			-- Already delivered on an earlier call. Say granted so Roblox stops
			-- retrying, without granting twice.
			bump("duplicate")
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end

		local player = Players:GetPlayerByUserId(receipt.PlayerId)
		if player == nil then
			bump("playerGone")
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local delivered, err = pcall(product.grant, player)
		if not delivered then
			bump("grantFailed")
			warn("[Commerce] " .. product.name .. " grant failed: " .. tostring(err))
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		-- Saved before returning. The other order loses the record on a crash
		-- between the two, and the retry grants a second time.
		if not remember(current, key) then
			bump("recordFailed")
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		bump("granted")
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	live.process = process
	MarketplaceService.ProcessReceipt = process

	local function applyPasses(player: Player)
		for id, pass in pairs(live.passes) do
			local owns, why = pcall(function()
				return MarketplaceService:UserOwnsGamePassAsync(player.UserId, id)
			end)
			if owns and why == true and pass.grant ~= nil then
				pcall(pass.grant, player)
				bump("passApplied")
			end
		end
	end

	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(applyPasses, player)
	end
	table.insert(live.connections, Players.PlayerAdded:Connect(function(player)
		task.spawn(applyPasses, player)
	end))
	-- Bought mid-session: without this the player pays and sees nothing until
	-- they rejoin, which reads as the purchase having failed.
	table.insert(live.connections,
		MarketplaceService.PromptGamePassPurchaseFinished:Connect(
			function(player, passId, purchased)
				local pass = live.passes[passId]
				if purchased and pass ~= nil and pass.grant ~= nil then
					pcall(pass.grant, player)
					bump("passApplied")
				end
			end))

	return true, {}
end

--- Run the receipt path without a purchase.
---
--- The only way to find out whether buying works is otherwise to buy something,
--- which costs real money and cannot be undone. This runs the same function
--- Roblox calls, so a retry with the same `PurchaseId` can be checked to grant
--- once -- the property that decides whether a player gets charged twice.
---
--- Grants really run. Call it with a test product, not the live one.
function Commerce.simulate(receipt: any): string
	local live = wiring
	if live == nil or live.process == nil then
		return "NOT_DECLARED"
	end
	local ok, decision = pcall(live.process, receipt)
	if not ok then
		return "ERRORED: " .. tostring(decision)
	end
	return decision.Name
end

--- Ask a player to buy something.
function Commerce.prompt(player: Player, kind: string, id: number): boolean
	local ok = pcall(function()
		if kind == "pass" then
			MarketplaceService:PromptGamePassPurchase(player, id)
		elseif kind == "product" then
			MarketplaceService:PromptProductPurchase(player, id)
		else
			error("kind must be pass or product", 0)
		end
	end)
	return ok
end

function Commerce.owns(player: Player, passId: number): boolean
	local ok, result = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
	end)
	return ok and result == true
end

function Commerce.clear()
	local live = wiring
	if live ~= nil then
		for _, connection in ipairs(live.connections) do
			connection:Disconnect()
		end
	end
	wiring = nil
end

--- Can receipts actually be written, as opposed to a store handle existing?
---
--- Answered by writing. There is no property that tells you, and the difference
--- decides whether a purchase survives a server restart.
function Commerce.canPersist(): boolean
	local live = wiring
	if live == nil or live.store == nil then
		return false
	end
	local ok = pcall(function()
		live.store:SetAsync("__rqe_probe", os.time())
	end)
	return ok
end

--- What is wired and what has happened, so a receipt path can be inspected
--- without spending money to find out.
function Commerce.report(): { [string]: any }
	local live = wiring
	if live == nil then
		return { declared = false }
	end
	local passes, products = {}, {}
	for id, pass in pairs(live.passes) do
		table.insert(passes, { id = id, name = pass.name, grants = pass.grant ~= nil })
	end
	for id, product in pairs(live.products) do
		table.insert(products, { id = id, name = product.name })
	end
	return {
		declared = true,
		passes = passes,
		products = products,
		receiptHandler = live.process ~= nil,
		-- Whether a handle exists is not whether writes work. In Studio with API
		-- Services off, `GetDataStore` succeeds and every `SetAsync` throws.
		persistentReceipts = live.store ~= nil and Commerce.canPersist(),
		stats = live.stats,
		note = if live.store == nil
			then "no DataStore: receipts are remembered only for this server"
			else "receipts persist across servers",
	}
end

return Commerce
