--!strict
--[[
	MissionInstance — several parties running the same content, in one server.

	The problem
	-----------

	A dungeon, a raid, a heist, a wave defence. Four players go in, and while
	they are in there the rest of the server must not see their enemies, their
	loot, their timer or their failure. Roblox gives you one Workspace, so
	"instanced" is something you build rather than something you get.

	Two ways to do it and only one that scales: reserve a server per party, or
	run every instance in one server with membership and visibility handled by
	hand. The first costs a server per four players and a teleport per run; the
	second costs this module. For anything under about ten concurrent parties
	the second wins, and it wins by a lot.

		local run = MissionInstance.open("crypt", { leader = player })
		MissionInstance.join(run, otherPlayer)
		MissionInstance.advance(run, "boss_reached")
		MissionInstance.close(run, "cleared")

	What it owns and what it does not
	---------------------------------

	It owns membership, state, the objective cursor and the lifetime. It does
	**not** own geometry, spawning or rewards — those are the game's, and a
	mission system that spawned things would be a game rather than a library.
	It hands out a `run` with an id; the game builds its dungeon somewhere and
	tags it with that id.

	Why the timer is checked and not scheduled
	------------------------------------------

	Same reason as everywhere else in this engine: a `task.delay` per instance
	is a promise that a lagging server breaks silently. `sweep` compares
	deadlines against the clock, so an instance ends when its time is up rather
	than when a callback happens to fire.
]]

local Clock = require(script.Parent.Parent.Core.Clock)
local Signal = require(script.Parent.Parent.Core.Signal)

local MissionInstance = {}

export type Run = {
	id: string,
	mission: string,
	members: { Player },
	state: string,
	objective: number,
	openedAt: number,
	deadline: number?,
	data: { [string]: any },
}

type Definition = {
	label: string,
	objectives: { string },
	maxMembers: number,
	seconds: number?,
	rejoinable: boolean,
}

local definitions: { [string]: Definition } = {}
local runs: { [string]: Run } = {}
local membership: { [Player]: string } = {}
local nextId = 0

MissionInstance.opened = Signal.new()    -- (run)
MissionInstance.advanced = Signal.new()  -- (run, objective, index)
MissionInstance.closed = Signal.new()    -- (run, outcome)

-- ================================= defining =================================
function MissionInstance.define(mission: string, spec: any?)
	local definition = spec or {}
	definitions[mission] = {
		label = tostring(definition.label or mission),
		objectives = definition.objectives or {},
		maxMembers = tonumber(definition.maxMembers) or 4,
		seconds = tonumber(definition.seconds),
		--[[
			Whether somebody who disconnected can come back to it.

			Almost always yes, and the reason to say so explicitly is that the
			alternative — a player losing a forty-minute raid to a router — is
			the single most reliable way to lose that player.
		]]
		rejoinable = definition.rejoinable ~= false,
	}
end

function MissionInstance.defineMany(table_: { [string]: any })
	for mission, spec in table_ do
		MissionInstance.define(mission, spec)
	end
end

-- ================================== opening =================================
--[[
	Start a run.

	Returns the run or nil and a reason. The id is short and sequential rather
	than a GUID: it is used as a tag on hundreds of instances and read in logs
	by people, and `crypt#7` is legible where a GUID is not.
]]
function MissionInstance.open(mission: string, options: any?): (Run?, string?)
	local definition = definitions[mission]
	if not definition then
		return nil, string.format("there is no mission called '%s'", mission)
	end

	local opts = options or {}
	local leader = opts.leader
	if leader and membership[leader] then
		return nil, "already in a mission"
	end

	nextId += 1
	local run: Run = {
		id = string.format("%s#%d", mission, nextId),
		mission = mission,
		members = {},
		state = "open",
		objective = 1,
		openedAt = Clock.now(),
		deadline = definition.seconds and Clock.expiresIn(definition.seconds) or nil,
		data = opts.data or {},
	}
	runs[run.id] = run

	if leader then
		table.insert(run.members, leader)
		membership[leader] = run.id
	end

	MissionInstance.opened:Fire(run)
	return run
end

function MissionInstance.join(run: Run, player: Player): (boolean, string?)
	local definition = definitions[run.mission]
	if run.state ~= "open" and run.state ~= "running" then
		return false, "that run is over"
	end
	if membership[player] then
		return false, "already in a mission"
	end
	if #run.members >= definition.maxMembers then
		return false, string.format("%s holds %d", definition.label, definition.maxMembers)
	end

	table.insert(run.members, player)
	membership[player] = run.id
	return true
end

--[[
	Take a player out.

	A run that loses its last member closes rather than lingering. An empty
	instance holding geometry and enemies is the leak that turns a busy server
	into a slow one over an evening.
]]
function MissionInstance.leave(player: Player): Run?
	local id = membership[player]
	if not id then
		return nil
	end
	local run = runs[id]
	membership[player] = nil
	if not run then
		return nil
	end

	local index = table.find(run.members, player)
	if index then
		table.remove(run.members, index)
	end
	if #run.members == 0 and run.state ~= "closed" then
		MissionInstance.close(run, "abandoned")
	end
	return run
end

function MissionInstance.runFor(player: Player): Run?
	local id = membership[player]
	return id and runs[id] or nil
end

-- ================================ progressing ===============================
--[[
	Move the objective cursor on.

	Named rather than numbered at the call site: `advance(run, "boss_reached")`
	says what happened, and a mission whose objectives get reordered does not
	silently start firing the wrong one. A name that is not the current
	objective is refused, which catches the double-fire that otherwise skips a
	stage.
]]
function MissionInstance.advance(run: Run, objective: string): boolean
	local definition = definitions[run.mission]
	local expected = definition.objectives[run.objective]
	if expected and expected ~= objective then
		return false
	end

	run.state = "running"
	MissionInstance.advanced:Fire(run, objective, run.objective)
	run.objective += 1

	if run.objective > #definition.objectives and #definition.objectives > 0 then
		MissionInstance.close(run, "cleared")
	end
	return true
end

function MissionInstance.close(run: Run, outcome: string)
	if run.state == "closed" then
		return
	end
	run.state = "closed"
	for _, player in run.members do
		membership[player] = nil
	end
	MissionInstance.closed:Fire(run, outcome)
	runs[run.id] = nil
end

--[[
	End whatever has run out of time.

	Returns what it closed. Call it on a slow loop; a mission measured in
	minutes does not need checking every frame.
]]
function MissionInstance.sweep(): { Run }
	local expired = {}
	for _, run in runs do
		if run.deadline and Clock.hasExpired(run.deadline) then
			table.insert(expired, run)
		end
	end
	for _, run in expired do
		MissionInstance.close(run, "timeout")
	end
	return expired
end

function MissionInstance.start(everySeconds: number?)
	task.spawn(function()
		while true do
			task.wait(everySeconds or 5)
			MissionInstance.sweep()
		end
	end)
end

-- ================================= reading ==================================
function MissionInstance.active(): { Run }
	local out = {}
	for _, run in runs do
		table.insert(out, run)
	end
	table.sort(out, function(a, b)
		return a.openedAt < b.openedAt
	end)
	return out
end

--: What a run looks like to a UI: where it is, who is in it, how long is left.
function MissionInstance.status(run: Run): { [string]: any }
	local definition = definitions[run.mission]
	local names = {}
	for _, player in run.members do
		table.insert(names, player.Name)
	end
	return {
		id = run.id,
		mission = run.mission,
		label = definition and definition.label or run.mission,
		state = run.state,
		members = names,
		objective = definition and definition.objectives[run.objective] or nil,
		objectiveIndex = run.objective,
		objectives = definition and #definition.objectives or 0,
		remaining = run.deadline and Clock.remaining(run.deadline) or nil,
		remainingText = run.deadline and Clock.format(Clock.remaining(run.deadline)) or nil,
	}
end

function MissionInstance.describe(): { [string]: any }
	local byMission: { [string]: number } = {}
	local players = 0
	for _, run in runs do
		byMission[run.mission] = (byMission[run.mission] or 0) + 1
		players += #run.members
	end
	return {
		defined = (function()
			local n = 0
			for _ in definitions do
				n += 1
			end
			return n
		end)(),
		running = byMission,
		playersInMissions = players,
	}
end

function MissionInstance.reset()
	table.clear(definitions)
	table.clear(runs)
	table.clear(membership)
	nextId = 0
end

return MissionInstance
