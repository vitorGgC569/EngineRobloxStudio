--!strict
--[[
	Beyond — everything about this game that is not this server.

	Written because the engine grew a cross-server layer, a policy layer and a
	set of measurement tools that had no caller. By this project's own rule,
	code nobody exercises is not engine — it is inventory with an engine
	address, and the whole point of a second consumer is to find out whether an
	API is usable before somebody else does.

	So each one earns its place here on Proving Ground's terms:

	  `Cluster`   the arena's best score is a *global* board, and a boss
	              spawning is worth telling other servers about
	  `Travel`    a run that ends sends the player onward with their score
	  `Social`    the shop only appears to players whose policy permits it,
	              and a good run offers to invite a friend
	  `Collab`    the editing leases, so two people can dress the arena
	  `Bench`     the load numbers, published where a machine can read them
	  `Platform`  a phone check on join, reported rather than assumed

	None of these decides what the game is. They decide what happens at its
	edges, which until now this engine pretended did not exist.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Cluster = Forge.Cluster
local Travel = Forge.Travel
local Social = Forge.Social
local Collab = Forge.Collab
local Bench = Forge.Bench
local Platform = Forge.Platform
local Capability = Forge.Capability
local Access = Forge.Access
local Save = Forge.Save
local Net = Forge.Net
local Debug = Forge.Debug
local Telemetry = Forge.Telemetry

local Beyond = {}

local BOARD = "arena_best"

-- ================================ cross-server ==============================
--[[
	One leaderboard for the whole experience.

	`Save` already keeps a personal best, and a personal best is not a
	leaderboard: twelve people in a room compared against each other is a
	scoreboard, and what a player wants to know is where they stand among
	everyone. That question cannot be answered from inside one server, which is
	precisely the gap `Cluster` exists to close.
]]
function Beyond.submitScore(player: Player, score: number)
	if score <= 0 then
		return
	end
	Cluster.board(BOARD):submit(tostring(player.UserId), score)
end

function Beyond.topScores(count: number?): { any }
	return Cluster.board(BOARD):top(count or 10)
end

--[[
	Tell the other servers something happened.

	A brute spawning is the kind of event that makes an experience feel
	inhabited: somebody in another server hears that one is loose here. A
	shout rather than shared state, because it is news and not a fact — nobody
	needs to read it later.
]]
function Beyond.announceBoss(name: string)
	Cluster.shout("arena.boss", { name = name, server = Cluster.serverId })
	Cluster.counter("bosses.spawned"):add(1)
end

-- ================================== policy ==================================
--[[
	Whether this player may be shown the shop at all.

	Not a preference — compliance. Paid and random items are restricted by
	region and age, and a game that renders a purchase prompt to a player whose
	policy forbids it has a real problem rather than a cosmetic one.

	`Social.may` fails closed, so an unreachable policy service hides the shop
	rather than showing it to everyone.
]]
function Beyond.mayShop(player: Player): boolean
	return Social.may(player, "paidItems")
end

--[[
	Offer to bring a friend, after a good run.

	Asked at the moment a player is enjoying themselves rather than on join,
	because an invite prompt in the first ten seconds is an interruption and
	one after a personal best is an offer.
]]
function Beyond.offerInvite(player: Player, score: number)
	local profile = Save.get(player)
	if not profile or score < (profile.best or 0) then
		return
	end
	if Social.canInvite(player) then
		Social.inviteFriend(player, {
			message = "Come and hold the Proving Ground with me",
		})
		Telemetry.event("invite.offered", { score = score })
	end
end

-- ================================== start ===================================
function Beyond.start()
	Cluster.start()
	Travel.start()
	Social.start()
	Collab.start()

	--[[
		Where a finished run goes.

		Defined even though this experience is currently one place: a
		destination with a placeId of zero is a declaration of intent that
		`Travel.send` will refuse safely, and it means adding the lobby later
		is a number rather than a rewrite.
	]]
	Travel.defineMany({
		lobby = { placeId = 0, reserved = false, party = true },
	})

	--[[
		Captions for the cues that carry information.

		Not every sound: a footstep tells a deaf player nothing they need. A
		telegraph does, and so does running out of breath — both are moments
		where missing the audio means missing the mechanic.
	]]
	Access.captionsFor({
		["hit.crit"] = "Critical hit",
		["hurt"] = "You are hit",
		["shot.cannon"] = "Hand cannon fires",
		["reload"] = "Reloading",
	})

	Cluster.on("arena.boss", function(payload)
		--[[
			Another server's news, shown here.

			Deliberately quiet. A cross-server announcement that interrupts is
			an announcement players turn off, and the whole value of it is that
			the experience feels larger than the room.
		]]
		for _, player in Players:GetPlayers() do
			Net.fire(player, "Notify", {
				text = string.format("%s is loose in another arena", tostring(payload.name)),
			})
		end
	end)

	Players.PlayerAdded:Connect(function(player)
		--[[
			Ask the client what device it is on, once.

			`Platform` runs on the client because a viewport is a client fact.
			The server asks, records what came back, and reports it — which is
			how a phone problem becomes a number in a dashboard rather than a
			complaint in a review.
		]]
		task.delay(6, function()
			if player.Parent then
				Net.fire(player, "PlatformCheck", {})
			end
		end)
	end)

	Net.on("PlatformReport", function(player, payload)
		if typeof(payload) ~= "table" then
			return
		end
		Telemetry.event("platform.audit", {
			device = tostring(payload.device),
			offscreen = tonumber(payload.offscreen) or 0,
			tooSmall = tonumber(payload.tooSmall) or 0,
			withinBudget = payload.withinBudget == true,
		})
		if (tonumber(payload.tooSmall) or 0) > 0 then
			Debug.warn(string.format(
				"%s on %s has %d touch targets under the minimum",
				player.Name, tostring(payload.device), payload.tooSmall))
		end
	end)

	--[[
		The load numbers, published rather than run by hand.

		`Bench` has existed since the first version of this engine with no
		caller at all. Running it once at startup and putting the result on the
		debug seam means the cost of this game is a number somebody can read
		instead of a thing somebody has to profile.
	]]
	task.defer(function()
		local ok, report = pcall(function()
			return Bench.run and Bench.run() or Bench.describe()
		end)
		if ok then
			Debug.probe("bench", function()
				return report
			end)
		end
	end)

	Debug.probe("beyond", function()
		return {
			cluster = Cluster.describe(),
			travel = Travel.describe(),
			social = Social.describe(),
			collab = Collab.describe(),
			access = Access.describe(),
			--[[
				What this Roblox build refused.

				`Capability` records every property write the engine could not
				make. Surfacing it here turns "the grass never appeared" from a
				mystery into a line in the snapshot.
			]]
			unavailable = Capability.missing(),
		}
	end)

	Debug.info("beyond ready (cluster, travel, social, collab, access)")
end

return Beyond
