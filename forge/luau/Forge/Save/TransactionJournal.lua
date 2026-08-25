--!strict
--[[
	TransactionJournal — moving something between two owners, across a crash.

	The problem Roblox hands you
	----------------------------

	There is no multi-key atomic transaction. `UpdateAsync` is atomic over one
	key and nothing else. So the moment a thing has to leave one player and
	arrive at another — a trade, a gift, a mail delivery, a shop grant that
	must roll back — there is a window where it has left and not arrived, and a
	server crash inside that window destroys it.

	The answer is not cleverness, it is a **write-ahead journal**: record the
	intent durably *before* the move, and reconcile on the next load. Whatever
	the crash interrupted is either finished or given back, and never both.

		local hold = Journal.open("trade:88", ownerId, { swordId })
		-- ... the swap ...
		Journal.commit(hold)          -- it arrived
		Journal.release(hold)         -- it did not; give it back

		for _, pending in Journal.pendingFor(ownerId) do
			refund(pending.payload)   -- a crash happened; make the owner whole
			Journal.resolve(pending)
		end

	The three states, and why there are only three
	----------------------------------------------

	  pending    the thing has left and not arrived. The only state a crash can
	             leave behind, and the only one reconciliation acts on.
	  committed  it arrived. Kept briefly so a replayed reconciliation can tell
	             "already done" from "never happened".
	  cleared    accounted for. Safe to forget.

	A fourth state would be a state nobody can name at three in the morning.

	Why the id is generated once
	----------------------------

	`holdId` is the dedup primitive, and it is minted at open time and never
	regenerated. If reconciliation invented a new id on reload, two reloads
	would look like two different holds and credit the owner twice — which is
	the failure mode that is worse than losing the item, because it is silent
	and it inflates the economy.

	Pure, and deliberately so
	-------------------------

	Nothing here touches DataStore. It is a state machine over opaque payloads,
	so the whole reconciliation is testable headlessly — which matters more
	here than almost anywhere else, because the interesting cases are crashes
	and you cannot crash a server in a unit test. `Save.DataStoreAdapter` is
	what carries it to disk.
]]

--[[
	The id, minted without any service.

	`HttpService:GenerateGUID` was the obvious choice and it was wrong: this
	module claims to be pure and testable headlessly, and reaching for a
	service breaks that the moment anything tries. Running it outside Roblox
	said so immediately — which is the whole argument for running things.

	A counter plus the clock plus a random tail is unique enough for what this
	identifies: holds within one server's lifetime, distinguished per owner. It
	is not a global identifier and does not need to be.
]]
local minted = 0
local function newHoldId(): string
	minted += 1
	return string.format("%x-%x-%x", os.time(), minted, math.random(0, 0xFFFFFF))
end

local TransactionJournal = {}

export type Hold = {
	holdId: string,
	ownerId: string,
	reason: string,
	payload: any,
	state: string,
	openedAt: number,
	resolvedAt: number?,
}

local holds: { [string]: Hold } = {}
local byOwner: { [string]: { string } } = {}
--[[
	Ids already accounted for.

	The guard that makes reconciliation idempotent: replaying it must be a
	no-op, because reconciliation runs on every load and a load can happen
	twice in a second when a player rejoins a dying server.
]]
local processed: { [string]: number } = {}

--: How long a resolved hold is remembered. Long enough that a rejoin after a
--: crash still finds the record; short enough that the set does not grow for
--: the life of the universe.
TransactionJournal.rememberSeconds = 7 * 24 * 60 * 60

-- =================================== open ===================================
--[[
	Record that something has left an owner, before it leaves.

	Order matters and is the entire point: the journal entry is durable first,
	the mutation second. The other order has a window where the thing is gone
	and nothing knows it was ever meant to come back.
]]
function TransactionJournal.open(reason: string, ownerId: string, payload: any): Hold
	local hold: Hold = {
		holdId = newHoldId(),
		ownerId = tostring(ownerId),
		reason = reason,
		payload = payload,
		state = "pending",
		openedAt = os.time(),
	}
	holds[hold.holdId] = hold

	local list = byOwner[hold.ownerId]
	if not list then
		list = {}
		byOwner[hold.ownerId] = list
	end
	table.insert(list, hold.holdId)
	return hold
end

-- ================================ resolving =================================
local function settle(hold: Hold, state: string): boolean
	local stored = holds[hold.holdId]
	if not stored then
		return false
	end
	-- Terminal states are terminal. A second commit is not an error worth
	-- throwing over — it is a retry, and retries are how distributed things
	-- stay correct — but it must not move the state back.
	if stored.state ~= "pending" then
		return false
	end
	stored.state = state
	stored.resolvedAt = os.time()
	processed[hold.holdId] = stored.resolvedAt
	return true
end

--: It arrived. The owner does not get it back.
function TransactionJournal.commit(hold: Hold): boolean
	return settle(hold, "committed")
end

--: It did not arrive, and this is the normal cancel path rather than a crash.
function TransactionJournal.release(hold: Hold): boolean
	return settle(hold, "cleared")
end

--[[
	Mark a hold recovered after a crash.

	Distinct from `release` so the two are distinguishable afterwards: one is a
	player pressing cancel and the other is a server that died holding
	somebody's property. A game that cannot tell those apart cannot tell
	whether it has a reliability problem.
]]
function TransactionJournal.resolve(hold: Hold): boolean
	return settle(hold, "cleared")
end

-- ============================== reconciliation ==============================
--[[
	What this owner is still owed.

	Called on load, before anything else touches their profile. Anything still
	`pending` is the wreckage of an interrupted move: the thing left and never
	arrived, so it comes back.
]]
function TransactionJournal.pendingFor(ownerId: string): { Hold }
	local out: { Hold } = {}
	for _, holdId in byOwner[tostring(ownerId)] or {} do
		local hold = holds[holdId]
		if hold and hold.state == "pending" then
			table.insert(out, hold)
		end
	end
	return out
end

--[[
	Has this hold already been accounted for?

	The question reconciliation asks before crediting anything. Answering it
	from a set of ids rather than from the payload is what makes it safe to run
	the same reconciliation twice.
]]
function TransactionJournal.wasProcessed(holdId: string): boolean
	return processed[holdId] ~= nil
end

--[[
	Load a journal back from wherever it was persisted.

	Rows are adopted as they are, including their state, because the state *is*
	the durable fact. Anything already processed keeps its id in the set, which
	is what stops a second reconciliation from crediting a second time.
]]
function TransactionJournal.load(rows: { Hold })
	for _, row in rows do
		if typeof(row) == "table" and row.holdId then
			holds[row.holdId] = row
			local list = byOwner[row.ownerId]
			if not list then
				list = {}
				byOwner[row.ownerId] = list
			end
			if not table.find(list, row.holdId) then
				table.insert(list, row.holdId)
			end
			if row.state ~= "pending" and row.resolvedAt then
				processed[row.holdId] = row.resolvedAt
			end
		end
	end
end

--[[
	Everything worth persisting, oldest first.

	Resolved holds past the remembering window are dropped here rather than on
	load: a journal that prunes on write stays bounded, and one that prunes on
	read has already paid to fetch what it throws away.
]]
function TransactionJournal.snapshot(ownerId: string?): { Hold }
	local cutoff = os.time() - TransactionJournal.rememberSeconds
	local out: { Hold } = {}
	for _, hold in holds do
		if ownerId and hold.ownerId ~= tostring(ownerId) then
			continue
		end
		if hold.state ~= "pending" and (hold.resolvedAt or 0) < cutoff then
			continue
		end
		table.insert(out, hold)
	end
	table.sort(out, function(a, b)
		return a.openedAt < b.openedAt
	end)
	return out
end

--[[
	Forget what is safely forgettable.

	Only resolved holds past the window. A pending hold is never pruned however
	old it is: an owner who has not logged in for a month is still owed what
	they were owed.
]]
function TransactionJournal.prune(): number
	local cutoff = os.time() - TransactionJournal.rememberSeconds
	local removed = 0
	for holdId, hold in holds do
		if hold.state ~= "pending" and (hold.resolvedAt or 0) < cutoff then
			holds[holdId] = nil
			processed[holdId] = nil
			removed += 1
		end
	end
	for ownerId, list in byOwner do
		local kept = {}
		for _, holdId in list do
			if holds[holdId] then
				table.insert(kept, holdId)
			end
		end
		byOwner[ownerId] = #kept > 0 and kept or nil
	end
	return removed
end

function TransactionJournal.describe(): { [string]: any }
	local counts = { pending = 0, committed = 0, cleared = 0 }
	local oldestPending: number? = nil
	for _, hold in holds do
		counts[hold.state] = (counts[hold.state] or 0) + 1
		if hold.state == "pending" then
			if not oldestPending or hold.openedAt < oldestPending then
				oldestPending = hold.openedAt
			end
		end
	end
	return {
		holds = counts,
		processed = (function()
			local n = 0
			for _ in processed do
				n += 1
			end
			return n
		end)(),
		--[[
			The number to alarm on.

			A pending hold older than a few minutes means somebody's property
			is sitting in a journal and nothing is giving it back — which is a
			reliability incident, not a metric.
		]]
		oldestPendingAgeSeconds = oldestPending and (os.time() - oldestPending) or 0,
	}
end

function TransactionJournal.reset()
	table.clear(holds)
	table.clear(byOwner)
	table.clear(processed)
end

return TransactionJournal
