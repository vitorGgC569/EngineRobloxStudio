--!strict
--[[
	PromoCodes — one-shot promotional redemptions with conditions.

	A redeemed code must never pay twice, even across servers: redemption
	state is a plain table the caller persists (ledger semantics live in
	Save.ReceiptLedger if preferred). Each code may gate on context —
	owning a gamepass, being in a group — through an injected checker.
]]

local PromoCodes = {}

export type PlayerContext = {
	userId: number,
	ownsAsset: (assetId: number) -> boolean,
	inGroup: (groupId: number) -> boolean,
}

export type CodeDef = {
	rewardId: string,
	requiresAsset: number?,
	requiresGroup: number?,
}

type Self = {
	defs: { [string]: CodeDef },
}

PromoCodes.__index = PromoCodes

function PromoCodes.new(defs: { [string]: CodeDef }): Self
	return setmetatable({ defs = defs }, PromoCodes)
end

-- state: {[code]=true} for codes this player already redeemed.
function PromoCodes.redeem(self: Self, code: string, state: { [string]: boolean }, ctx: PlayerContext): (boolean, string?)
	local def = self.defs[code]
	if not def then
		return false, "unknown_code"
	end
	if state[code] then
		return false, "already_redeemed"
	end
	if def.requiresAsset and not ctx.ownsAsset(def.requiresAsset) then
		return false, "asset_required"
	end
	if def.requiresGroup and not ctx.inGroup(def.requiresGroup) then
		return false, "group_required"
	end
	return true, def.rewardId
end

return PromoCodes
