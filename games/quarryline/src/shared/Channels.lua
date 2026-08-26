--!strict
--[[
	Every network channel this game has, defined once for both sides.

	Why this file exists
	--------------------

	`Net.define` populates a table that is **per-VM**, and `Net.on` errors on a
	name that VM has never been told about. The server defined all of these and
	the client defined none, so the very first `Net.on` in the client threw --
	and everything after it, which was every handler in the game, never ran.

	The failure was almost perfectly silent. The HUD is built above the
	handlers, so it appeared, laid out correctly, and then sat there showing
	`0` for ever. The server was paying correctly the whole time; a
	`leaderstats` value added to tell the two apart read 344, then 350, then
	356, while the label above the player's head read zero.

	Nothing catches that. Both halves compile, both pass the type checker, the
	economy scenarios pass because they run on the server, and no test in this
	repository looks at what a player can actually see.

	So the definitions live in one place that both `init.server.lua` and
	`init.client.lua` require. Two copies of this table would drift, and the
	way they drift is exactly the bug above: a channel one side knows and the
	other does not.
]]

local Channels = {}

Channels.definitions = {
	--: The client asks; the server decides. Every one of these is re-checked
	--: server-side, because a rate limit is not a permission.
	ClaimPlot = { dir = "c2s", rate = 2 },
	Build = { dir = "c2s", rate = 8 },
	BuyUpgrade = { dir = "c2s", rate = 6 },
	Rebirth = { dir = "c2s", rate = 1 },
	ClaimDaily = { dir = "c2s", rate = 2 },

	--[[
		What the client actually managed to bind.

		Added because a client-side animator is invisible from the server by
		construction: it moves parts locally, which never replicates, so the
		only way to tell "animating" from "silently adopted nothing" was to
		photograph the screen twice and diff the pixels. That works and it is
		far too slow to debug with.

		So the client says how many machines it adopted and the server logs it.
		One message per join, and it turns a whole class of "the client half is
		not running" into a line in the output.
	]]
	ClientReady = { dir = "c2s", rate = 6 },

	StateSync = { dir = "s2c" },
	Notify = { dir = "s2c" },
	LineSync = { dir = "s2c" },

	--[[
		Where the money landed, not just that it arrived.

		`LineSync` already carries the new balance, and a balance is a number in
		a corner. This carries the plot, so the client can put the payout on the
		depot that earned it -- which is the difference between being told you
		earned and watching yourself earn.

		Broadcast rather than sent to the owner: a tycoon is a place you walk
		through other people's factories, and a row of lines visibly paying out
		is most of what makes the row feel alive.
	]]
	Sold = { dir = "s2c" },

	--: Where a machine just appeared, so the placement has a sound and a puff
	--: of dust at the spot instead of a box silently existing.
	Built = { dir = "s2c" },
}

--[[
	Register them in whichever VM is asking.

	The server half also creates the RemoteEvents; the client half only fills
	its local table, and `Net.on` waits for the instance itself. That split is
	`Net`'s, not this file's -- both sides make the same call.
]]
function Channels.define(Net: any)
	Net.define(Channels.definitions)
end

return Channels
