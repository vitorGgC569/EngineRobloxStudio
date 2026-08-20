--!strict
--[[
	Collab — more than one person editing without ruining each other's work.

	The Editor has always assumed a single author. Two people in the same
	session both grab the same rock, both move it, and the second write wins
	silently — no conflict, no warning, and the first person's work is simply
	gone. That is the failure that makes teams stop using a tool.

	Three mechanisms, in the order they matter:

	  leases    one editor owns a placement at a time, and the claim expires
	  presence  everyone can see who is here and what they are holding
	  journal   every change is attributed, so a mistake can be traced

	--- Why leases rather than locks -----------------------------------------

	A lock is held until released, which means a lock is held forever the first
	time somebody's Studio crashes while holding one. A lease expires. Editors
	renew what they are actively using and everything else falls free on its
	own, so the recovery path for a crash is "wait twenty seconds" rather than
	"find an administrator".

		if Collab.claim(player, placement) then
			Editor.setCFrame(placement, target)
			Collab.record(player, "move", placement)
		end

	--- Authority -------------------------------------------------------------

	Server only, and every function refuses to run on a client. A lease that a
	client could grant itself is not a lease, and the whole point is to be the
	one place that arbitrates between two people who both want the same thing.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Signal = require(script.Parent.Core).Signal

local Collab = {}

Collab.config = {
	-- Long enough to survive a slow frame or a moment of thought, short enough
	-- that a crashed editor frees its work while somebody is still waiting.
	leaseSeconds = 20,
	-- Renewals are cheap; this is how often an active editor is expected to
	-- confirm it still wants what it holds.
	renewSeconds = 5,
	journalLimit = 500,
}

-- (player, key)
Collab.claimed = Signal.new()
Collab.released = Signal.new()
-- (player, action, key)
Collab.changed = Signal.new()

type Lease = {
	owner: Player,
	key: string,
	until_: number,
	claimedAt: number,
}

local leases: { [string]: Lease } = {}
local presence: { [Player]: any } = {}
local journal: { any } = {}
local sweeper: thread? = nil

local function serverOnly(what: string): boolean
	if RunService:IsServer() then
		return true
	end
	warn(string.format("[Collab] %s is server-only; a client that could grant its own lease has none", what))
	return false
end

--[[
	A stable name for the thing being edited.

	Placements carry an id; instances are identified by their full path. Both
	are strings, which is what lets one table arbitrate over both without
	knowing which kind of editor is asking.
]]
function Collab.keyFor(subject: any): string?
	if typeof(subject) == "string" then
		return subject
	end
	if typeof(subject) == "Instance" then
		return subject:GetFullName()
	end
	if typeof(subject) == "table" then
		local id = subject.id or subject.name
		if typeof(id) == "string" then
			return "placement:" .. id
		end
	end
	return nil
end

-- ================================== leases ==================================
local function expired(lease: Lease): boolean
	return os.clock() > lease.until_
end

--[[
	Take ownership, or find out who has it.

	Re-claiming something you already hold renews it rather than failing: an
	editor dragging a rock calls this every frame, and a claim that refused its
	own owner would make dragging impossible.
]]
function Collab.claim(player: Player, subject: any): (boolean, Player?)
	if not serverOnly("claim") then
		return false, nil
	end
	local key = Collab.keyFor(subject)
	if not key then
		return false, nil
	end

	local existing = leases[key]
	if existing and not expired(existing) then
		if existing.owner == player then
			existing.until_ = os.clock() + Collab.config.leaseSeconds
			return true, player
		end
		return false, existing.owner
	end

	leases[key] = {
		owner = player,
		key = key,
		until_ = os.clock() + Collab.config.leaseSeconds,
		claimedAt = os.clock(),
	}
	Collab.claimed:Fire(player, key)
	Collab.startSweeper()
	return true, player
end

function Collab.release(player: Player, subject: any): boolean
	if not serverOnly("release") then
		return false
	end
	local key = Collab.keyFor(subject)
	local lease = key and leases[key]
	if not lease or lease.owner ~= player then
		return false
	end
	leases[key] = nil
	Collab.released:Fire(player, key)
	return true
end

function Collab.releaseAll(player: Player): number
	local freed = 0
	for key, lease in leases do
		if lease.owner == player then
			leases[key] = nil
			freed += 1
			Collab.released:Fire(player, key)
		end
	end
	return freed
end

function Collab.holder(subject: any): Player?
	local key = Collab.keyFor(subject)
	local lease = key and leases[key]
	if lease and not expired(lease) then
		return lease.owner
	end
	return nil
end

function Collab.mayEdit(player: Player, subject: any): boolean
	local holder = Collab.holder(subject)
	return holder == nil or holder == player
end

--[[
	Drop leases nobody renewed.

	Without this, every crashed or disconnected editor leaves its work locked
	until the server restarts, which in practice means people work around the
	system rather than with it.
]]
function Collab.startSweeper()
	if sweeper or not RunService:IsServer() then
		return
	end
	sweeper = task.spawn(function()
		while true do
			task.wait(Collab.config.renewSeconds)
			local live = 0
			for key, lease in leases do
				if expired(lease) or not lease.owner.Parent then
					leases[key] = nil
					Collab.released:Fire(lease.owner, key)
				else
					live += 1
				end
			end
			if live == 0 then
				break
			end
		end
		sweeper = nil
	end)
end

-- ================================= presence =================================
--[[
	Who is editing, and what they are looking at.

	Cheap and worth far more than it costs: most collisions are avoided by
	knowing somebody else is already in that corner of the map, long before any
	lease has to refuse anything.
]]
function Collab.here(player: Player, state: any?)
	presence[player] = {
		player = player,
		at = state and state.position,
		holding = state and state.holding,
		tool = state and state.tool,
		seen = os.clock(),
	}
end

function Collab.away(player: Player)
	presence[player] = nil
	Collab.releaseAll(player)
end

function Collab.roster(): { any }
	local out = {}
	for player, entry in presence do
		if player.Parent then
			table.insert(out, {
				name = player.Name,
				userId = player.UserId,
				holding = entry.holding,
				tool = entry.tool,
				idleFor = math.floor(os.clock() - entry.seen),
			})
		end
	end
	table.sort(out, function(a, b)
		return a.name < b.name
	end)
	return out
end

-- ================================= journal ==================================
--[[
	What changed, by whom.

	Not undo — the Editor has its own stack for that. This is the answer to
	"who moved the spawn point", which on a team is asked far more often and is
	otherwise unanswerable.
]]
function Collab.record(player: Player, action: string, subject: any, detail: any?)
	local key = Collab.keyFor(subject) or "?"
	table.insert(journal, {
		at = os.time(),
		who = player.Name,
		userId = player.UserId,
		action = action,
		key = key,
		detail = detail,
	})
	if #journal > Collab.config.journalLimit then
		table.remove(journal, 1)
	end
	Collab.changed:Fire(player, action, key)
end

function Collab.history(limit: number?): { any }
	local wanted = math.min(limit or 50, #journal)
	local out = {}
	for i = #journal - wanted + 1, #journal do
		table.insert(out, journal[i])
	end
	return out
end

function Collab.start()
	if not RunService:IsServer() then
		return
	end
	Players.PlayerRemoving:Connect(function(player)
		Collab.away(player)
	end)
end

function Collab.describe(): { [string]: any }
	local held = 0
	for _, lease in leases do
		if not expired(lease) then
			held += 1
		end
	end
	return {
		context = RunService:IsServer() and "server" or "client",
		leases = held,
		editors = #Collab.roster(),
		journal = #journal,
	}
end

return Collab
