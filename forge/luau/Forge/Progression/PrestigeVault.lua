--!strict
--[[
	PrestigeVault — the sacrifice vault, as pure item bookkeeping.

	Mined from minershaven: sacrificing seals gear away in storage, soulbound
	items never leave your hands, and milestone lives (10, 100) pay the stash
	back — ReturnItems fires the moment a rebirth crosses life 100. The vault
	only accepts while `life` is below `requiredLife`; past that point sealing
	is refused because every deposit would be returned immediately.

		local vault = PrestigeVault.new({
			requiredLife = 100,
			soulboundCheck = function(item) return item.soulbound == true end,
			milestoneUnlocks = { [10] = { "final_upgrader" }, [100] = { "vault_refund" } },
		})

		local result = vault:seal(inventory, life)
		drop(result.kept)
		save.vault = result.vaulted
		grant(result.unlocked)

	Pure: `seal` returns a report and never mutates its inputs; the caller
	persists `result.vaulted`. `returnAll(vault)` hands the sealed items back.
]]

local PrestigeVault = {}
PrestigeVault.__index = PrestigeVault

export type VaultConfig = {
	requiredLife: number?,
	soulboundCheck: ((item: any) -> boolean)?,
	milestoneUnlocks: { [number]: { any } }?,
}

export type SealResult = {
	vaulted: { any },
	kept: { any },
	unlocked: { any },
}

type Internal = {
	requiredLife: number,
	soulboundCheck: (item: any) -> boolean,
	milestoneUnlocks: { [number]: { any } },
	milestones: { number },
}

export type Vault = typeof(setmetatable({} :: Internal, PrestigeVault))

local DEFAULT_REQUIRED_LIFE = 999

-- The unlock list used to keep the caller's reward tables. Renaming an id
-- after `new`, or renaming the table `seal` inserted into `unlocked`, rewrote
-- the reward the next seal handed out.
local function deepCopy(value: any, seen: { [any]: any }): any
	if type(value) ~= "table" then
		return value
	end
	if seen[value] then
		return seen[value]
	end
	local copy = {}
	seen[value] = copy
	for key, item in value :: { [any]: any } do
		copy[key] = deepCopy(item, seen)
	end
	return copy
end

function PrestigeVault.new(config: VaultConfig): Vault
	local self: Internal = setmetatable({}, PrestigeVault)
	self.requiredLife = config.requiredLife or DEFAULT_REQUIRED_LIFE
	self.soulboundCheck = config.soulboundCheck or function(_item: any)
		return false
	end
	self.milestones = {}
	self.milestoneUnlocks = {}

	if config.milestoneUnlocks then
		for milestone in pairs(config.milestoneUnlocks) do
			table.insert(self.milestones, milestone)
		end
		table.sort(self.milestones)
		for _, milestone in self.milestones do
			self.milestoneUnlocks[milestone] = deepCopy(config.milestoneUnlocks[milestone], {})
		end
	end
	return self :: any
end

function PrestigeVault.seal(self: Vault, items: { any }, life: number): SealResult
	local accepting = life < self.requiredLife

	local result: SealResult = {
		vaulted = {},
		kept = {},
		unlocked = {},
	}

	for _, item in items do
		if accepting and not self.soulboundCheck(item) then
			table.insert(result.vaulted, item)
		else
			table.insert(result.kept, item)
		end
	end

	for _, milestone in self.milestones do
		if life >= milestone then
			for _, reward in (self.milestoneUnlocks[milestone] or {}) do
				table.insert(result.unlocked, deepCopy(reward, {}))
			end
		end
	end

	return result
end

function PrestigeVault.returnAll(vault: SealResult): { any }
	local items = {}
	for _, item in vault.vaulted do
		table.insert(items, item)
	end
	return items
end

return PrestigeVault
