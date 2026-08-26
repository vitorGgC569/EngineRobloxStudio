--!strict
--[[
	Live scenarios for the parts of this game that only exist because other
	people are in it.

	Why these were missing
	----------------------

	Every session this project has ever run had exactly one player in it. Plot
	allocation, ownership, permissions and per-owner payout have therefore never
	been exercised against a second person -- not once, in any game, at any
	point. They compile, they are typed, and the first time two people are on
	the same server is the first time they run.

	That is the same shape as the three defects found this week: `Net.fire` was
	server-only and every client control was inert, the client never called
	`Net.define` so no handler ever bound, and a replicated Model arrives before
	its children so the animator adopted nothing. None was caught by a test.
	All three were code that had simply never executed.

	What is asserted here
	---------------------

	Rules about *other people*, not balance. A second player must get their own
	plot; they must not be able to build on somebody else's; a plot must come
	back when its owner leaves; and two lines must pay their own owners rather
	than the same one twice.

	Player identity is a userId, and these use synthetic ones rather than real
	`Player` objects. That is deliberate: a scenario cannot make a second person
	join, and every one of these rules is expressed in terms of the id. What it
	cannot cover is replication -- whether the second client is actually *told*
	-- and that needs two Studio clients and a person to look.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Debug = Forge.Debug

local Systems = script.Parent.Parent:WaitForChild("systems")
local Plots = require(Systems.Plots)
local Line = require(Systems.Line)

return function(Testing)

--: Ids no real account will ever have, so a scenario can never collide with a
--: person who happens to be playing while it runs.
local GUEST_A = 900000001
local GUEST_B = 900000002

--[[
	Give a synthetic player a plot without pretending to be a `Player`.

	`Plots.claim` takes a `Player` and reads `.UserId` off it. Rather than
	building a fake instance -- which would test the fake -- these go through
	the allocator and the permission table directly, which is exactly what
	`claim` does with the id it extracts.
]]
local function claimFor(userId: number): string?
	local key = tostring(userId)
	local existing = Plots.allocator:plotOf(key)
	if existing then
		return existing
	end
	local id = Plots.allocator:assign(key)
	if not id then
		return nil
	end
	if Plots.permissions:transfer(id, userId) == false then
		Plots.permissions:createPlot(id, userId)
	end
	return id
end

local function releaseFor(userId: number)
	local key = tostring(userId)
	local id = Plots.allocator:plotOf(key)
	if id then
		Plots.allocator:release(key)
		Plots.built[id] = {}
		Line.detach(id)
	end
end

Testing.scenario("two players get two different plots", function(t)
	releaseFor(GUEST_A)
	releaseFor(GUEST_B)

	local first = claimFor(GUEST_A)
	local second = claimFor(GUEST_B)

	t:expect(first ~= nil, "the first guest got no plot at all")
	t:expect(second ~= nil, "the second guest got no plot; the pool ran out with six plots")
	t:expect(first ~= second, string.format(
		"both guests were given %s -- the allocator handed one plot to two owners",
		tostring(first)))

	Debug.info(string.format("guests hold %s and %s", tostring(first), tostring(second)))
	releaseFor(GUEST_A)
	releaseFor(GUEST_B)
end)

Testing.scenario("a plot refuses everyone except its owner", function(t)
	releaseFor(GUEST_A)
	releaseFor(GUEST_B)
	local mine = claimFor(GUEST_A)
	t:expect(mine ~= nil, "no plot to test ownership on")

	local allowed = Plots.permissions:check(mine, GUEST_A, "Build")
	t:expect(allowed, "the owner was refused permission to build on their own plot")

	--[[
		The assertion that matters.

		A tycoon where anyone can build on anyone's plot is not a tycoon, and
		this is the only line in the game that stops it. It has never run with a
		second id.
	]]
	local stranger = Plots.permissions:check(mine, GUEST_B, "Build")
	t:expect(not stranger, string.format(
		"user %d was allowed to build on %s, which belongs to %d",
		GUEST_B, tostring(mine), GUEST_A))

	releaseFor(GUEST_A)
end)

Testing.scenario("an invited visitor may build, and only while invited", function(t)
	releaseFor(GUEST_A)
	releaseFor(GUEST_B)
	local mine = claimFor(GUEST_A)
	t:expect(mine ~= nil, "no plot to invite onto")

	--[[
		`invite`, `toggle` and `uninvite` exist in the engine and no game has
		ever called any of them. Whether they work is therefore unknown, which
		is the whole reason to ask.
	]]
	local invited = Plots.permissions:invite(mine, GUEST_B, { "Build" })
	t:expect(invited, "invite refused on a plot the inviter owns")

	local canNow = Plots.permissions:check(mine, GUEST_B, "Build")
	t:expect(canNow, "an invited visitor with Build was still refused")

	Plots.permissions:uninvite(mine, GUEST_B)
	local canAfter = Plots.permissions:check(mine, GUEST_B, "Build")
	t:expect(not canAfter, "an uninvited visitor kept their build rights")

	releaseFor(GUEST_A)
end)

Testing.scenario("a plot comes back when its owner leaves", function(t)
	releaseFor(GUEST_A)
	local mine = claimFor(GUEST_A)
	t:expect(mine ~= nil, "no plot to release")

	releaseFor(GUEST_A)
	t:expect(Plots.allocator:plotOf(tostring(GUEST_A)) == nil,
		"the plot is still recorded against a guest who left")
	t:expect(Plots.allocator:ownerOf(mine) == nil, string.format(
		"%s still has an owner after release; it can never be claimed again", tostring(mine)))

	local next_ = claimFor(GUEST_B)
	t:expect(next_ ~= nil, "the freed plot did not return to the pool")
	releaseFor(GUEST_B)
end)

Testing.scenario("two lines pay their own plots, not each other's", function(t)
	releaseFor(GUEST_A)
	releaseFor(GUEST_B)
	local a = claimFor(GUEST_A)
	local b = claimFor(GUEST_B)
	t:expect(a ~= nil and b ~= nil and a ~= b, "need two distinct plots")

	Line.attach(a)
	Line.attach(b)

	--: Only A gets a complete chain. B gets a drill and nothing else, so the
	--: narrowest-link rule must leave it at zero.
	Plots.built[a] = {
		["drill:1"] = { machineId = "drill" },
		["belt:1"] = { machineId = "belt" },
		["smelter:1"] = { machineId = "smelter" },
		["depot:1"] = { machineId = "depot" },
	}
	Plots.built[b] = { ["drill:1"] = { machineId = "drill" } }

	local profile = { upgrades = {}, premium = false }
	local paidA = Line.tick(a, profile)
	local paidB = Line.tick(b, profile)

	t:expect(paidA > 0, "the complete chain earned nothing")
	t:expect(paidB == 0, string.format(
		"the incomplete plot earned %d; one plot's production is reaching another",
		paidB))

	Plots.built[a] = {}
	Plots.built[b] = {}
	Line.detach(a)
	Line.detach(b)
	releaseFor(GUEST_A)
	releaseFor(GUEST_B)
end)

end
