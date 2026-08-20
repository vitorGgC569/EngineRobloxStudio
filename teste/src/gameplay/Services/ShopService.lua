local WeaponCatalog, SkinCatalog, EconomyCatalog
do
	local ok, rs = pcall(function() return game:GetService("ReplicatedStorage") end)
	if ok and rs and rs:FindFirstChild("Shared") then
		WeaponCatalog = require(rs.Shared.WeaponCatalog)
		SkinCatalog = require(rs.Shared.SkinCatalog)
		EconomyCatalog = require(rs.Shared.EconomyCatalog)
	else
		WeaponCatalog = require(script.Parent.Parent.shared.WeaponCatalog)
		SkinCatalog = require(script.Parent.Parent.shared.SkinCatalog)
		EconomyCatalog = require(script.Parent.Parent.shared.EconomyCatalog)
	end
end

local ShopService = {}
ShopService.__index = ShopService

function ShopService.new(persistenceService: any)
	local self = setmetatable({}, ShopService)
	self._persistence = persistenceService
	return self
end

function ShopService:buyWeapon(player: Player, weaponId: string): (boolean, string)
	local weaponDef = WeaponCatalog.get(weaponId)
	if not weaponDef then
		return false, "Weapon does not exist"
	end

	local data = self._persistence:get(player)
	if not data then
		return false, "Player data not loaded"
	end

	if table.find(data.unlockedWeapons, weaponId) then
		return false, "Weapon already owned"
	end

	if data.scraps < weaponDef.price then
		return false, "Insufficient scraps"
	end

	data.scraps -= weaponDef.price
	table.insert(data.unlockedWeapons, weaponId)
	self._persistence:save(player, data)

	return true, "Weapon purchased successfully"
end

function ShopService:buySkin(player: Player, skinId: string): (boolean, string)
	local skinDef = SkinCatalog.get(skinId)
	if not skinDef then
		return false, "Skin does not exist"
	end

	local data = self._persistence:get(player)
	if not data then
		return false, "Player data not loaded"
	end

	if table.find(data.unlockedSkins, skinId) then
		return false, "Skin already owned"
	end

	if data.scraps < skinDef.price then
		return false, "Insufficient scraps"
	end

	data.scraps -= skinDef.price
	table.insert(data.unlockedSkins, skinId)
	self._persistence:save(player, data)

	return true, "Skin unlocked successfully"
end

function ShopService:buySupply(player: Player, supplyId: string): (boolean, string)
	local supplyDef = EconomyCatalog.Supplies[supplyId]
	if not supplyDef then
		return false, "Supply item does not exist"
	end

	local data = self._persistence:get(player)
	if not data then
		return false, "Player data not loaded"
	end

	if data.scraps < supplyDef.cost then
		return false, "Insufficient scraps"
	end

	data.scraps -= supplyDef.cost

	if supplyDef.weaponCategory then
		local cat = supplyDef.weaponCategory
		data.ammo[cat] = (data.ammo[cat] or 0) + supplyDef.amount
	elseif supplyDef.healAmount then
		local char = player.Character
		if char then
			local hum = char:FindFirstChildOfClass("Humanoid")
			if hum then
				hum.Health = math.min(hum.MaxHealth, hum.Health + supplyDef.healAmount)
			end
		end
	elseif supplyDef.armorAmount then
		data.armor = math.min(100, (data.armor or 0) + supplyDef.armorAmount)
	end

	self._persistence:save(player, data)
	return true, "Supply purchased"
end

function ShopService:purchaseUpgrade(player: Player, upgradeId: string): (boolean, string)
	local data = self._persistence:get(player)
	if not data then return false, "Data not loaded" end

	local currentLvl = data.upgrades[upgradeId] or 0
	local cost = EconomyCatalog.calculateUpgradeCost(upgradeId, currentLvl)

	if cost <= 0 then return false, "Upgrade is already at max level" end
	if data.scraps < cost then return false, "Insufficient scraps" end

	data.scraps -= cost
	data.upgrades[upgradeId] = currentLvl + 1
	self._persistence:save(player, data)

	return true, "Upgrade applied"
end

return ShopService
