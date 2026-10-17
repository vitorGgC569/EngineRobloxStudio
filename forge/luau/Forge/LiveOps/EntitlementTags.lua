--!strict
--[[
	EntitlementTags — validated gamepass/badge/group tags on a player.

	Whole systems gate on entitlements (VIP, Premium, seasonal artifacts),
	but ownership must be re-validated, never trusted from the client.
	The checker is injected; this module turns it into a tag set with a
	diff so servers react only to changes.
]]

local EntitlementTags = {}

-- `new` kept the caller's definition map. Changing `assetId` after that
-- made `refresh` look up a different asset than the one registered.
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

export type TagDef = {
	assetId: number?,
	badgeId: number?,
	groupId: number?,
}

export type Checker = {
	ownsAsset: (assetId: number) -> boolean,
	hasBadge: (badgeId: number) -> boolean,
	inGroup: (groupId: number) -> boolean,
}

type Self = {
	defs: { [string]: TagDef },
	checker: Checker,
	current: { [string]: boolean },
}

EntitlementTags.__index = EntitlementTags

function EntitlementTags.new(defs: { [string]: TagDef }, checker: Checker): Self
	for tag, def in defs do
		assert(def.assetId or def.badgeId or def.groupId, ("tag %q has no source"):format(tag))
	end
	return setmetatable({
		defs = deepCopy(defs, {}) :: { [string]: TagDef },
		checker = checker,
		current = {},
	}, EntitlementTags)
end

function EntitlementTags.refresh(self: Self): { added: { string }, removed: { string } }
	local next_ = {}
	for tag, def in self.defs do
		local ok = false
		if def.assetId then
			ok = ok or self.checker.ownsAsset(def.assetId)
		end
		if def.badgeId then
			ok = ok or self.checker.hasBadge(def.badgeId)
		end
		if def.groupId then
			ok = ok or self.checker.inGroup(def.groupId)
		end
		next_[tag] = ok
	end
	local added: { string } = {}
	local removed: { string } = {}
	for tag in next_ do
		if next_[tag] and not self.current[tag] then
			table.insert(added, tag)
		end
	end
	for tag in self.current do
		if not next_[tag] then
			table.insert(removed, tag)
		end
	end
	self.current = next_
	return { added = added, removed = removed }
end

function EntitlementTags.has(self: Self, tag: string): boolean
	return self.current[tag] == true
end

return EntitlementTags
