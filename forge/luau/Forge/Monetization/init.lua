--!strict
--[[
	Monetization — passes, products and receipts that cannot double-grant.

	`ProcessReceipt` is the most dangerous callback in Roblox. Roblox retries it
	until it returns `PurchaseGranted`, which means:

	  * return the wrong value and the player is charged and gets nothing;
	  * grant without recording and a retry grants twice;
	  * error inside the handler and Roblox keeps calling it, forever.

	So the grant and the record are one operation, keyed on the receipt's own
	`PurchaseId`, in a DataStore. That is the entire correctness story and it is
	not optional.

		Monetization.defineProduct("small_coins", {
			productId = 123456,
			grant = function(player) addCoins(player, 500) end,
		})

		Monetization.definePass("vip", {
			passId = 987654,
			onOwned = function(player) applyVip(player) end,
		})

		Monetization.prompt(player, "small_coins")
		if Monetization.owns(player, "vip") then ... end
]]

local MarketplaceService = game:GetService("MarketplaceService")
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Signal = require(script.Parent.Core.Signal)

local Monetization = {}

Monetization.purchased = Signal.new() -- (player, kind, name)
Monetization.passGranted = Signal.new() -- (player, name)

type Product = {
	productId: number,
	grant: (player: Player) -> boolean?,
	label: string?,
	price: number?,
}

type Pass = {
	passId: number,
	onOwned: ((player: Player) -> ())?,
	label: string?,
}

local products: { [string]: Product } = {}
local productsById: { [number]: string } = {}
local passes: { [string]: Pass } = {}
local ownership: { [Player]: { [string]: boolean } } = {}
local receiptStore: DataStore? = nil
local started = false
local stats = { granted = 0, duplicates = 0, failed = 0 }

Monetization.config = {
	receiptStoreName = "ForgeReceipts_v1",
	ownershipCacheSeconds = 60,
	enabled = true,
}

-- =============================== definitions ================================
function Monetization.defineProduct(name: string, product: Product)
	products[name] = product
	productsById[product.productId] = name
end

function Monetization.definePass(name: string, pass: Pass)
	passes[name] = pass
end

function Monetization.defineMany(definitions: { products: { [string]: Product }?, passes: { [string]: Pass }? })
	for name, product in (definitions.products or {}) do
		Monetization.defineProduct(name, product)
	end
	for name, pass in (definitions.passes or {}) do
		Monetization.definePass(name, pass)
	end
end

function Monetization.productNames(): { string }
	local out = {}
	for name in products do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

function Monetization.passNames(): { string }
	local out = {}
	for name in passes do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

-- ================================ ownership =================================
--[[
	Cached, because `UserOwnsGamePassAsync` is a web call and gameplay asks
	"does this player have VIP" in places that run every frame. The cache
	expires so a mid-session purchase is picked up without a rejoin.
]]
function Monetization.owns(player: Player, name: string): boolean
	local pass = passes[name]
	if not pass then
		return false
	end
	local cache = ownership[player]
	if not cache then
		cache = {}
		ownership[player] = cache
	end
	if cache[name] ~= nil and (cache[name .. "_at"] or 0) + Monetization.config.ownershipCacheSeconds > os.clock() then
		return cache[name] :: boolean
	end

	local ok, result = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, pass.passId)
	end)
	local owned = ok and result == true
	cache[name] = owned
	;(cache :: any)[name .. "_at"] = os.clock()

	if owned and pass.onOwned then
		pcall(pass.onOwned, player)
	end
	return owned
end

function Monetization.refreshOwnership(player: Player)
	ownership[player] = nil
	for name in passes do
		Monetization.owns(player, name)
	end
end

-- ================================= prompts ==================================
function Monetization.prompt(player: Player, name: string): boolean
	local product = products[name]
	if product then
		local ok = pcall(function()
			MarketplaceService:PromptProductPurchase(player, product.productId)
		end)
		return ok
	end
	local pass = passes[name]
	if pass then
		local ok = pcall(function()
			MarketplaceService:PromptGamePassPurchase(player, pass.passId)
		end)
		return ok
	end
	warn(string.format("[Monetization] nothing named '%s'", name))
	return false
end

-- ================================ receipts ==================================
local function receiptKey(receipt: any): string
	return "r_" .. tostring(receipt.PurchaseId)
end

--[[
	The grant path.

	`UpdateAsync` is what makes this idempotent: the read and the write are one
	atomic operation, so two servers processing the same retry cannot both see
	"not yet granted".
]]
local function processReceipt(receipt: any): Enum.ProductPurchaseDecision
	if not Monetization.config.enabled then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	if not player then
		-- They left. Do not grant, do not consume: Roblox will retry when they
		-- come back, and returning Granted here would take their Robux for
		-- nothing.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local name = productsById[receipt.ProductId]
	local product = name and products[name]
	if not product then
		warn(string.format("[Monetization] unknown product id %d", receipt.ProductId))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if not receiptStore then
		warn("[Monetization] no receipt store; refusing to grant without a record")
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local alreadyGranted = false
	local ok, err = pcall(function()
		(receiptStore :: DataStore):UpdateAsync(receiptKey(receipt), function(existing)
			if existing then
				alreadyGranted = true
				return existing -- untouched: a retry of something already done
			end
			-- The grant happens inside the transaction. If it throws, nothing
			-- is written and Roblox retries cleanly.
			local granted = product.grant(player)
			if granted == false then
				error("grant refused")
			end
			return {
				at = os.time(),
				userId = receipt.PlayerId,
				product = name,
				spent = receipt.CurrencySpent,
			}
		end)
	end)

	if not ok then
		stats.failed += 1
		warn(string.format("[Monetization] grant failed for %s: %s", tostring(name), tostring(err)))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if alreadyGranted then
		stats.duplicates += 1
	else
		stats.granted += 1
		Monetization.purchased:Fire(player, "product", name)
	end
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

--[[
	The receipt handler, callable directly.

	Roblox owns the real one, which makes it unreachable from a test — and this
	is the one function in the engine whose bug costs money. Exposing it lets a
	live suite deliver the same receipt twice and assert that the grant happened
	once, which is the failure Roblox's retry behaviour causes routinely.
]]
function Monetization.processReceipt(receipt: any): Enum.ProductPurchaseDecision
	return processReceipt(receipt)
end

function Monetization.start()
	if started or not RunService:IsServer() then
		return
	end
	started = true

	local ok, store = pcall(function()
		return DataStoreService:GetDataStore(Monetization.config.receiptStoreName)
	end)
	receiptStore = ok and store or nil
	if not receiptStore then
		warn("[Monetization] receipt store unavailable; purchases will not be granted")
	end

	MarketplaceService.ProcessReceipt = processReceipt

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, wasPurchased)
		if not wasPurchased then
			return
		end
		for name, pass in passes do
			if pass.passId == passId then
				ownership[player] = nil
				if pass.onOwned then
					pcall(pass.onOwned, player)
				end
				Monetization.purchased:Fire(player, "pass", name)
				Monetization.passGranted:Fire(player, name)
				break
			end
		end
	end)

	Players.PlayerAdded:Connect(function(player)
		task.spawn(Monetization.refreshOwnership, player)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(Monetization.refreshOwnership, player)
	end
	Players.PlayerRemoving:Connect(function(player)
		ownership[player] = nil
	end)
end

function Monetization.describe(): { [string]: any }
	return {
		products = Monetization.productNames(),
		passes = Monetization.passNames(),
		granted = stats.granted,
		duplicatesRefused = stats.duplicates,
		failed = stats.failed,
		receiptStore = receiptStore ~= nil,
		started = started,
	}
end

return Monetization
