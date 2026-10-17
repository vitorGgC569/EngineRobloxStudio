--!strict
-- Saltmere rules. DESIGN.md is the contract. Every tunable is read from Config.

local Config = require(script.Parent.Config)

local Sim = {}

export type PanState = {
	owned: boolean,
	level: number,
	brine: number,
	ready: boolean,
}

export type CrewMember = {
	id: string,
	role: string,
	panId: string,
}

export type SaltBag = {
	coarse: number,
	fine: number,
	flake: number,
	smoked: number,
}

export type QuestFlags = {
	claimed: boolean,
	collected: boolean,
	sold: boolean,
	refined: boolean,
	prestiged: boolean,
}

export type Profile = {
	cash: number,
	salt: SaltBag,
	pans: { [string]: PanState },
	upgrades: { [string]: number },
	crew: { CrewMember },
	nextCrew: number,
	prestige: number,
	lifetime: number,
	soldThisTide: SaltBag,
	quests: QuestFlags,
	slot: number,
	cosmetic: string,
}

export type Result = {
	ok: boolean,
	reason: string,
	toast: string?,
	delta: any?,
}

type QuestFlag = "claimed" | "collected" | "refined" | "sold" | "prestiged"

-- DESIGN coarse-equivalents, counted when a unit is created. Config has no key for these.
local LIFETIME_WEIGHT: { [string]: number } = {
	coarse = 1,
	fine = 4,
	flake = 4,
	smoked = 8,
}

-- DESIGN: a request amount is an integer in 1..10000 inclusive.
local AMOUNT_MAX = 10000

local PAN_START = "pan_1"

local QUEST_TOAST: { [QuestFlag]: string } = {
	claimed = "You claimed a pan.",
	collected = "Salt in hand. Walk to the stall and sell it.",
	refined = "You refined salt.",
	sold = "Coin in the box. Claim the next pan.",
	prestiged = "The spring tide turns.",
}

local function freshSalt(): SaltBag
	return { coarse = 0, fine = 0, flake = 0, smoked = 0 }
end

local function freshQuests(): QuestFlags
	return {
		claimed = false,
		collected = false,
		sold = false,
		refined = false,
		prestiged = false,
	}
end

local function zeroBag(bag: SaltBag)
	bag.coarse = 0
	bag.fine = 0
	bag.flake = 0
	bag.smoked = 0
end

local function saltAmount(bag: SaltBag, grade: string): number
	if grade == "coarse" then
		return bag.coarse
	elseif grade == "fine" then
		return bag.fine
	elseif grade == "flake" then
		return bag.flake
	elseif grade == "smoked" then
		return bag.smoked
	end
	return 0
end

local function setSalt(bag: SaltBag, grade: string, amount: number)
	if grade == "coarse" then
		bag.coarse = amount
	elseif grade == "fine" then
		bag.fine = amount
	elseif grade == "flake" then
		bag.flake = amount
	elseif grade == "smoked" then
		bag.smoked = amount
	end
end

local function isGrade(grade: any): boolean
	return grade == "coarse" or grade == "fine" or grade == "flake" or grade == "smoked"
end

local function validAmount(amount: any): boolean
	return type(amount) == "number"
		and amount == math.floor(amount)
		and amount >= 1
		and amount <= AMOUNT_MAX
end

local function panDef(panId: any): any
	if type(panId) ~= "string" then
		return nil
	end
	for _, def in Config.pans do
		if def.id == panId then
			return def
		end
	end
	return nil
end

local function upgradeDef(upgradeId: any): any
	if type(upgradeId) ~= "string" then
		return nil
	end
	for _, def in Config.upgrades do
		if def.id == upgradeId then
			return def
		end
	end
	return nil
end

local function blankPan(owned: boolean): PanState
	return { owned = owned, level = 1, brine = 0, ready = false }
end

function Sim.newProfile(): Profile
	local pans: { [string]: PanState } = {}
	for _, def in Config.pans do
		local pan = blankPan(def.id == PAN_START)
		if def.id == PAN_START then
			pan.brine = Config.production.capacityBase
			pan.ready = true
		end
		pans[def.id] = pan
	end
	return {
		cash = Config.startCash,
		salt = freshSalt(),
		pans = pans,
		upgrades = {},
		crew = {},
		nextCrew = 1,
		prestige = 0,
		lifetime = 0,
		soldThisTide = freshSalt(),
		quests = freshQuests(),
		slot = 0,
		cosmetic = "",
	}
end

function Sim.clone(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy: { [any]: any } = {}
	for key, child in value do
		copy[key] = Sim.clone(child)
	end
	return copy
end

function Sim.copyInto(dst: any, src: any): any
	for key, value in src do
		dst[key] = value
	end
	return dst
end

function Sim.reconcile(profile: any): Profile
	if type(profile) ~= "table" then
		return Sim.newProfile()
	end

	local template = Sim.newProfile()

	if type(profile.cash) ~= "number" then
		profile.cash = template.cash
	end
	if type(profile.prestige) ~= "number" then
		profile.prestige = template.prestige
	end
	if type(profile.lifetime) ~= "number" then
		profile.lifetime = template.lifetime
	end
	if type(profile.nextCrew) ~= "number" then
		profile.nextCrew = template.nextCrew
	end
	if type(profile.slot) ~= "number" then
		profile.slot = template.slot
	end
	if type(profile.cosmetic) ~= "string" then
		profile.cosmetic = template.cosmetic
	end

	if type(profile.salt) ~= "table" then
		profile.salt = freshSalt()
	else
		for _, grade in { "coarse", "fine", "flake", "smoked" } do
			if type(profile.salt[grade]) ~= "number" then
				profile.salt[grade] = 0
			end
		end
	end

	if type(profile.soldThisTide) ~= "table" then
		profile.soldThisTide = freshSalt()
	else
		for _, grade in { "coarse", "fine", "flake", "smoked" } do
			if type(profile.soldThisTide[grade]) ~= "number" then
				profile.soldThisTide[grade] = 0
			end
		end
	end

	if type(profile.upgrades) ~= "table" then
		profile.upgrades = {}
	end

	if type(profile.crew) ~= "table" then
		profile.crew = {}
	else
		for index = 1, #profile.crew do
			local member = profile.crew[index]
			if type(member) == "table" and type(member.panId) ~= "string" then
				member.panId = ""
			end
		end
	end

	if type(profile.quests) ~= "table" then
		profile.quests = freshQuests()
	else
		for flag, value in template.quests do
			if type(profile.quests[flag]) ~= "boolean" then
				profile.quests[flag] = value
			end
		end
	end

	if type(profile.pans) ~= "table" then
		profile.pans = template.pans
	else
		for id, panTemplate in template.pans do
			local pan = profile.pans[id]
			if type(pan) ~= "table" then
				profile.pans[id] = Sim.clone(panTemplate)
			else
				if type(pan.owned) ~= "boolean" then
					pan.owned = panTemplate.owned
				end
				if type(pan.level) ~= "number" then
					pan.level = panTemplate.level
				end
				if type(pan.brine) ~= "number" then
					pan.brine = panTemplate.brine
				end
				if type(pan.ready) ~= "boolean" then
					pan.ready = panTemplate.ready
				end
			end
		end
	end

	local highest = 0
	for index = 1, #profile.crew do
		local member = profile.crew[index]
		if type(member) == "table" and type(member.id) == "string" then
			local digits = string.match(member.id, "^crew_(%d+)$")
			local serial = if digits then tonumber(digits) else nil
			if serial and serial > highest then
				highest = serial
			end
		end
	end
	-- Hire ids are floor(nextCrew). Bump only far enough that the next id cannot collide.
	if profile.nextCrew ~= profile.nextCrew
		or profile.nextCrew == math.huge
		or math.floor(profile.nextCrew) <= highest
	then
		profile.nextCrew = highest + 1
	end

	return profile :: Profile
end

local function reject(profile: Profile, reason: string): (Profile, Result)
	return profile, { ok = false, reason = reason }
end

local function accept(profile: Profile): (Profile, Result)
	return Sim.clone(profile) :: Profile, { ok = true, reason = "" }
end

local function flipQuest(profile: Profile, result: Result, flag: QuestFlag)
	if profile.quests[flag] then
		return
	end
	profile.quests[flag] = true
	result.toast = QUEST_TOAST[flag]
end

local function upgradeLevel(profile: Profile, id: string): number
	local upgrades = profile.upgrades
	if type(upgrades) ~= "table" then
		return 0
	end
	local level = upgrades[id]
	if type(level) ~= "number" then
		return 0
	end
	return level
end

local function prestigeMult(profile: Profile): number
	return 1 + profile.prestige * Config.production.prestigeYieldBonus
end

local function capacityOf(profile: Profile, pan: PanState): number
	return Config.production.capacityBase
		+ (pan.level - 1) * Config.production.capacityPerLevel
		+ upgradeLevel(profile, "cistern") * Config.effects.cisternCapacity
end

local function existingPan(profile: Profile, panId: string): PanState?
	if type(profile.pans) ~= "table" then
		return nil
	end
	local pan = profile.pans[panId]
	if type(pan) ~= "table" then
		return nil
	end
	return pan
end

local function hasCrewRole(profile: Profile, role: string): boolean
	if type(profile.crew) ~= "table" then
		return false
	end
	for index = 1, #profile.crew do
		local member = profile.crew[index]
		if type(member) == "table" and member.role == role then
			return true
		end
	end
	return false
end

local function findCrew(profile: Profile, crewId: string): CrewMember?
	if type(profile.crew) ~= "table" then
		return nil
	end
	for index = 1, #profile.crew do
		local member = profile.crew[index]
		if type(member) == "table" and member.id == crewId then
			return member
		end
	end
	return nil
end

local function addCreated(profile: Profile, grade: string, count: number)
	if count <= 0 then
		return
	end
	setSalt(profile.salt, grade, saltAmount(profile.salt, grade) + count)
	local weight = LIFETIME_WEIGHT[grade]
	if type(weight) == "number" then
		profile.lifetime += weight * count
	end
end

-- Converts one ready pan into coarse and flake, then empties it.
local function rakePan(profile: Profile, pan: PanState): (number, number)
	local brine = if type(pan.brine) == "number" then pan.brine else 0
	local yield = math.max(0, math.floor(
		brine
			* Config.production.yieldPerBrine
			* (1 + upgradeLevel(profile, "rake") * Config.effects.rakeYield)
			* prestigeMult(profile)
	))
	local flake = 0
	if pan.level >= Config.refine.flakePanLevel and upgradeLevel(profile, "lighthouse") >= 1 then
		flake = math.floor(yield * Config.refine.flakeChanceAtMaxPan)
		if flake > yield then
			flake = yield
		end
	end
	local coarse = yield - flake
	addCreated(profile, "coarse", coarse)
	addCreated(profile, "flake", flake)
	pan.brine = 0
	pan.ready = false
	return coarse, flake
end

function Sim.price(profile: Profile, grade: string): number
	local base = Config.prices[grade]
	if type(base) ~= "number" then
		return 0
	end
	local sold = 0
	if type(profile.soldThisTide) == "table" and isGrade(grade) then
		local stored = saltAmount(profile.soldThisTide, grade)
		if type(stored) == "number" then
			sold = stored
		end
	end
	local pressure = 1 / (1 + sold * Config.prices.pressure)
	local bonus = 1
		+ upgradeLevel(profile, "lighthouse") * Config.effects.lighthousePrice
		+ upgradeLevel(profile, "cooperage") * Config.effects.cooperagePrice
	return math.max(1, math.floor(base * pressure * bonus))
end

function Sim.prestigeNeed(profile: Profile): number
	local count = profile.prestige
	if type(count) ~= "number" or count ~= count then
		count = 0
	end
	return math.floor(Config.prestige.lifetimeBase * (Config.prestige.lifetimeStep ^ count))
end

function Sim.claim(profile: Profile, panId: string): (Profile, Result)
	local def = panDef(panId)
	if not def then
		return reject(profile, "bad_id")
	end
	local pan = existingPan(profile, panId)
	if pan and pan.owned == true then
		return reject(profile, "already_owned")
	end
	local cost = def.claimCost
	if type(cost) ~= "number" or profile.cash < cost then
		return reject(profile, "not_enough_cash")
	end

	local nextProfile, result = accept(profile)
	local claimed = existingPan(nextProfile, panId)
	if not claimed then
		claimed = blankPan(true)
		nextProfile.pans[panId] = claimed
	end
	nextProfile.cash -= cost
	claimed.owned = true
	flipQuest(nextProfile, result, "claimed")
	result.delta = { panId = panId, cost = cost }
	return nextProfile, result
end

function Sim.collect(profile: Profile, panId: string, phase: string): (Profile, Result)
	if not panDef(panId) then
		return reject(profile, "bad_id")
	end
	local pan = existingPan(profile, panId)
	if not pan or pan.owned ~= true then
		return reject(profile, "not_owned")
	end
	-- Ready salt can be raked in any phase. Gating it on "harvest" made the
	-- prompt appear and then refuse, which is a game that does not play.
	if pan.ready ~= true then
		return reject(profile, "not_ready")
	end

	local nextProfile, result = accept(profile)
	local target = existingPan(nextProfile, panId)
	if not target then
		return reject(profile, "not_owned")
	end
	local coarse, flake = rakePan(nextProfile, target)
	flipQuest(nextProfile, result, "collected")
	result.delta = { panId = panId, coarse = coarse, flake = flake }
	return nextProfile, result
end

function Sim.refine(profile: Profile, kind: string, amount: number): (Profile, Result)
	if kind ~= "fine" and kind ~= "smoked" then
		return reject(profile, "bad_id")
	end
	if not validAmount(amount) then
		return reject(profile, "bad_amount")
	end
	if kind == "fine" then
		if upgradeLevel(profile, "grader_bench") < 1 and not hasCrewRole(profile, "grader") then
			return reject(profile, "missing_upgrade")
		end
	elseif upgradeLevel(profile, "smokehouse") < 1 then
		return reject(profile, "missing_upgrade")
	end

	local inputGrade = if kind == "fine" then "coarse" else "fine"
	local ratio = if kind == "fine" then Config.refine.coarsePerFine else Config.refine.finePerSmoked
	local spent = amount * ratio
	if saltAmount(profile.salt, inputGrade) < spent then
		return reject(profile, "bad_amount")
	end

	local nextProfile, result = accept(profile)
	setSalt(nextProfile.salt, inputGrade, saltAmount(nextProfile.salt, inputGrade) - spent)
	addCreated(nextProfile, kind, amount)
	flipQuest(nextProfile, result, "refined")
	result.delta = { kind = kind, amount = amount, spent = spent }
	return nextProfile, result
end

function Sim.sell(profile: Profile, grade: string, amount: number): (Profile, Result)
	if not isGrade(grade) then
		return reject(profile, "bad_id")
	end
	if not validAmount(amount) then
		return reject(profile, "bad_amount")
	end
	if saltAmount(profile.salt, grade) < amount then
		return reject(profile, "bad_amount")
	end

	-- One unit price for the whole order, taken before soldThisTide moves.
	local unit = Sim.price(profile, grade)
	local nextProfile, result = accept(profile)
	setSalt(nextProfile.salt, grade, saltAmount(nextProfile.salt, grade) - amount)
	setSalt(nextProfile.soldThisTide, grade, saltAmount(nextProfile.soldThisTide, grade) + amount)
	local payout = unit * amount
	nextProfile.cash += payout
	flipQuest(nextProfile, result, "sold")
	result.delta = { grade = grade, amount = amount, cash = payout, unit = unit }
	return nextProfile, result
end

function Sim.upgradePan(profile: Profile, panId: string): (Profile, Result)
	local def = panDef(panId)
	if not def then
		return reject(profile, "bad_id")
	end
	local pan = existingPan(profile, panId)
	if not pan or pan.owned ~= true then
		return reject(profile, "not_owned")
	end
	if pan.level >= Config.panUpgrade.maxLevel then
		return reject(profile, "max_level")
	end
	local column = if type(def.col) == "number" then def.col else 0
	local cost = math.floor(Config.panUpgrade.baseCost * (pan.level ^ Config.panUpgrade.costPower) * (1 + column))
	if profile.cash < cost then
		return reject(profile, "not_enough_cash")
	end

	local nextProfile, result = accept(profile)
	local target = existingPan(nextProfile, panId)
	if not target then
		return reject(profile, "not_owned")
	end
	nextProfile.cash -= cost
	target.level += 1
	result.delta = { panId = panId, level = target.level, cost = cost }
	return nextProfile, result
end

function Sim.buyUpgrade(profile: Profile, upgradeId: string): (Profile, Result)
	local def = upgradeDef(upgradeId)
	if not def then
		return reject(profile, "bad_id")
	end
	local level = upgradeLevel(profile, upgradeId)
	if level >= def.maxLevel then
		return reject(profile, "max_level")
	end
	local cost = math.floor(def.baseCost * (def.costGrowth ^ level))
	if profile.cash < cost then
		return reject(profile, "not_enough_cash")
	end

	local nextProfile, result = accept(profile)
	if type(nextProfile.upgrades) ~= "table" then
		nextProfile.upgrades = {}
	end
	local nextLevel = level + 1
	nextProfile.upgrades[upgradeId] = nextLevel
	nextProfile.cash -= cost
	if upgradeId == "lantern" then
		nextProfile.cosmetic = "lantern"
	end
	result.delta = { upgradeId = upgradeId, level = nextLevel, cost = cost }
	return nextProfile, result
end

function Sim.hire(profile: Profile, roleId: string): (Profile, Result)
	local cost = if type(roleId) == "string" then Config.crew.hireCost[roleId] else nil
	if type(cost) ~= "number" then
		return reject(profile, "bad_id")
	end
	if type(profile.crew) == "table" and #profile.crew >= Config.crew.max then
		return reject(profile, "crew_full")
	end
	if profile.cash < cost then
		return reject(profile, "not_enough_cash")
	end

	local nextProfile, result = accept(profile)
	if type(nextProfile.crew) ~= "table" then
		nextProfile.crew = {}
	end
	local serial = math.floor(nextProfile.nextCrew)
	local crewId = string.format("crew_%d", serial)
	nextProfile.nextCrew = serial + 1
	local member: CrewMember = { id = crewId, role = roleId, panId = "" }
	table.insert(nextProfile.crew, member)
	nextProfile.cash -= cost
	result.delta = { crewId = crewId, role = roleId, cost = cost }
	return nextProfile, result
end

function Sim.assign(profile: Profile, crewId: string, panId: string): (Profile, Result)
	if type(crewId) ~= "string" or type(panId) ~= "string" then
		return reject(profile, "bad_id")
	end
	local member = findCrew(profile, crewId)
	if not member then
		return reject(profile, "bad_id")
	end
	if member.role == "raker" and panId ~= "" then
		if not panDef(panId) then
			return reject(profile, "bad_id")
		end
		local pan = existingPan(profile, panId)
		if not pan or pan.owned ~= true then
			return reject(profile, "not_owned")
		end
	end

	local nextProfile, result = accept(profile)
	local stored = findCrew(nextProfile, crewId)
	if not stored then
		return reject(profile, "bad_id")
	end
	if stored.role == "raker" then
		stored.panId = panId
	else
		stored.panId = ""
	end
	result.delta = { crewId = crewId, panId = stored.panId }
	return nextProfile, result
end

function Sim.prestige(profile: Profile): (Profile, Result)
	if upgradeLevel(profile, "lighthouse") < 1 then
		return reject(profile, "need_lighthouse")
	end
	if profile.lifetime < Sim.prestigeNeed(profile) then
		return reject(profile, "need_lifetime")
	end

	local nextProfile, result = accept(profile)
	nextProfile.prestige += 1
	nextProfile.cash = Config.prestige.cashReset
	zeroBag(nextProfile.salt)
	zeroBag(nextProfile.soldThisTide)

	local seen: { [string]: boolean } = {}
	for _, def in Config.pans do
		seen[def.id] = true
		local pan = nextProfile.pans[def.id]
		if type(pan) ~= "table" then
			pan = blankPan(false)
			nextProfile.pans[def.id] = pan
		end
		pan.brine = 0
		pan.ready = false
		pan.level = 1
		pan.owned = def.id == PAN_START
	end
	for id, pan in nextProfile.pans do
		if type(id) == "string" and not seen[id] and type(pan) == "table" then
			pan.brine = 0
			pan.ready = false
			pan.level = 1
			pan.owned = false
		end
	end

	local lighthouse = upgradeLevel(nextProfile, "lighthouse")
	nextProfile.upgrades = {}
	if lighthouse > 0 then
		nextProfile.upgrades.lighthouse = lighthouse
	end

	flipQuest(nextProfile, result, "prestiged")
	result.delta = { prestige = nextProfile.prestige }
	return nextProfile, result
end

function Sim.integrate(profile: Profile, dt: number, phase: string): (Profile, Result)
	local nextProfile, result = accept(profile)
	local finite = type(dt) == "number" and dt >= 0 and dt == dt and dt ~= math.huge
	if phase ~= "flood" or not finite then
		return nextProfile, result
	end

	local rate = Config.production.fillPerSecond
		* (1 + upgradeLevel(nextProfile, "sluice") * Config.effects.sluiceFill)
		* prestigeMult(nextProfile)
	local added = 0
	for _, pan in nextProfile.pans do
		if type(pan) == "table" and pan.owned == true then
			local cap = capacityOf(nextProfile, pan)
			if cap > 0 then
				local brine = if type(pan.brine) == "number" then pan.brine else 0
				-- Fill stops at capacity. Brine already above the cap is left where it is.
				if brine < cap then
					local filled = math.min(cap, brine + rate * dt)
					added += filled - brine
					pan.brine = filled
				end
			end
		end
	end
	if added ~= 0 then
		result.delta = { brine = added }
	end
	return nextProfile, result
end

local function markReady(profile: Profile): { string }
	local threshold = Config.production.readyThreshold
	local became: { string } = {}
	for id, pan in profile.pans do
		if type(id) == "string" and type(pan) == "table" and pan.owned == true then
			local cap = capacityOf(profile, pan)
			local brine = if type(pan.brine) == "number" then pan.brine else 0
			if cap > 0 and brine / cap >= threshold then
				if pan.ready ~= true then
					table.insert(became, id)
				end
				pan.ready = true
			end
		end
	end
	return became
end

local function autoCollect(profile: Profile, result: Result): { any }
	local collected: { any } = {}
	if type(profile.crew) ~= "table" or type(profile.pans) ~= "table" then
		return collected
	end
	for index = 1, #profile.crew do
		local member = profile.crew[index]
		if type(member) == "table" and member.role == "raker" and type(member.panId) == "string" and member.panId ~= "" then
			local pan = profile.pans[member.panId]
			if type(pan) == "table" and pan.owned == true and pan.ready == true then
				local coarse, flake = rakePan(profile, pan)
				table.insert(collected, { panId = member.panId, coarse = coarse, flake = flake })
				flipQuest(profile, result, "collected")
			end
		end
	end
	return collected
end

local function spoilPans(profile: Profile): number
	local keep = if hasCrewRole(profile, "watch")
		then Config.production.watchSpoilKeep
		else Config.production.spoilKeep
	local spoiled = 0
	for _, pan in profile.pans do
		if type(pan) == "table" and pan.ready == true then
			local brine = if type(pan.brine) == "number" then pan.brine else 0
			pan.brine = brine * keep
			pan.ready = false
			spoiled += 1
		end
	end
	return spoiled
end

local function wageOf(role: any): number
	if type(role) ~= "string" then
		return 0
	end
	local wage = Config.crew.wage[role]
	if type(wage) ~= "number" then
		return 0
	end
	return wage
end

local function wageBill(profile: Profile): number
	local total = 0
	if type(profile.crew) ~= "table" then
		return 0
	end
	for index = 1, #profile.crew do
		local member = profile.crew[index]
		if type(member) == "table" then
			total += wageOf(member.role)
		end
	end
	return total
end

local function dismissalToast(dismissed: { CrewMember }): string
	local parts: { string } = {}
	for _, member in dismissed do
		local id = if type(member.id) == "string" then member.id else "someone"
		local role = if type(member.role) == "string" then member.role else "hand"
		table.insert(parts, string.format("%s the %s", id, role))
	end
	if #parts == 1 then
		return parts[1] .. " was dismissed."
	end
	return table.concat(parts, ", ") .. " were dismissed."
end

local function payWages(profile: Profile, result: Result)
	if type(profile.crew) ~= "table" then
		profile.crew = {}
	end
	local dismissed: { CrewMember } = {}
	while wageBill(profile) > profile.cash and #profile.crew > 0 do
		local member = table.remove(profile.crew)
		if not member then
			break
		end
		table.insert(dismissed, member)
	end
	local due = wageBill(profile)
	profile.cash -= due
	if #dismissed > 0 then
		result.toast = dismissalToast(dismissed)
	end
	if due > 0 or #dismissed > 0 then
		local ids: { string } = {}
		for _, member in dismissed do
			if type(member.id) == "string" then
				table.insert(ids, member.id)
			end
		end
		result.delta = { wages = due, dismissed = ids }
	end
end

function Sim.onPhase(profile: Profile, phase: string): (Profile, Result)
	local nextProfile, result = accept(profile)
	if phase == "harvest" then
		local ready = markReady(nextProfile)
		if #ready > 0 then
			result.delta = { ready = ready }
		end
	elseif phase == "spoil" then
		local collected = autoCollect(nextProfile, result)
		local spoiled = spoilPans(nextProfile)
		if #collected > 0 or spoiled > 0 then
			result.delta = { collected = collected, spoiled = spoiled }
		end
	elseif phase == "flood" then
		payWages(nextProfile, result)
		if type(nextProfile.soldThisTide) ~= "table" then
			nextProfile.soldThisTide = freshSalt()
		else
			zeroBag(nextProfile.soldThisTide)
		end
	end
	return nextProfile, result
end

return Sim
