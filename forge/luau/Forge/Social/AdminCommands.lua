--!strict
--[[
	AdminCommands — permission-gated admin command surface.

	Admin commands are a table of definitions (name, required flag or
	permission level, run function) plus a single dispatcher that checks
	gates before executing. The Cmdr/Chat wiring is the server's job;
	this module owns authorization and audit trail.
]]

local AdminCommands = {}

export type Context = {
	actorUserId: number,
	actorFlags: { string },
	actorLevel: number,
	args: { string },
}

export type CommandDef = {
	name: string,
	requiredFlag: string?,
	minLevel: number?,
	run: (ctx: Context) -> (boolean, string?),
}

type Self = {
	commands: { [string]: CommandDef },
	audit: { { at: number, userId: number, name: string, ok: boolean, reason: string? } },
	clock: () -> number,
}

AdminCommands.__index = AdminCommands

function AdminCommands.new(clock: (() -> number)?): Self
	return setmetatable({
		commands = {},
		audit = {},
		clock = clock or os.time,
	}, AdminCommands)
end

function AdminCommands.register(self: Self, def: CommandDef): ()
	assert(not self.commands[def.name], ("duplicate command %q"):format(def.name))
	self.commands[def.name] = def
end

function AdminCommands.execute(self: Self, ctx: Context): (boolean, string?)
	local def = self.commands[ctx.args[1] and string.lower(ctx.args[1]) or ""]
	if not def then
		return false, "unknown_command"
	end
	if def.requiredFlag and not table.find(ctx.actorFlags, def.requiredFlag) then
		return false, "missing_flag"
	end
	if def.minLevel and ctx.actorLevel < def.minLevel then
		return false, "insufficient_level"
	end
	local invocationArgs = {}
	for i = 2, #ctx.args do
		table.insert(invocationArgs, ctx.args[i])
	end
	local ok, message = def.run({ actorUserId = ctx.actorUserId, actorFlags = ctx.actorFlags, actorLevel = ctx.actorLevel, args = invocationArgs })
	table.insert(self.audit, { at = self.clock(), userId = ctx.actorUserId, name = def.name, ok = ok, reason = message })
	return ok, message
end

return AdminCommands
