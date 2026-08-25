--!strict
--[[
	AdminChatBridge — chat-driven admin commands with authorization.

	Staff type commands in chat ("/give 50 gold"); the bridge filters by
	StaffFlags/level through AdminCommands.execute BEFORE running, keeps
	the audit trail there, and never echoes failures to other players.
	Framework-neutral: no Cmdr dependency.
]]

local Players = game:GetService("Players")

local AdminChatBridge = {}

type Self = {
	commands: any,
	flagsFor: (userId: number) -> { string },
	levelFor: (userId: number) -> number,
	prefix: string,
	connection: RBXScriptConnection?,
}

AdminChatBridge.__index = AdminChatBridge

function AdminChatBridge.new(config: {
	commands: any,
	flagsFor: (number) -> { string },
	levelFor: (number) -> number,
	prefix: string?,
}): any
	return setmetatable({
		commands = config.commands,
		flagsFor = config.flagsFor,
		levelFor = config.levelFor,
		prefix = config.prefix or "/",
		connection = nil,
	}, AdminChatBridge)
end

-- Parses "/cmd a b" into { "cmd", "a", "b" }.
function AdminChatBridge.parse(self: any, message: string): { string }?
	if string.sub(message, 1, #self.prefix) ~= self.prefix then
		return nil
	end
	local parts: { string } = {}
	for token in string.gmatch(string.sub(message, #self.prefix + 1), "%S+") do
		table.insert(parts, token)
	end
	if #parts == 0 then
		return nil
	end
	return parts
end

function AdminChatBridge.start(self: any): ()
	assert(not self.connection, "bridge already started")
	self.connection = Players.PlayerAdded:Connect(function(player)
		player.Chatted:Connect(function(message)
			local args = self:parse(message)
			if not args then
				return
			end
			self.commands:execute({
				actorUserId = player.UserId,
				actorFlags = self.flagsFor(player.UserId),
				actorLevel = self.levelFor(player.UserId),
				args = args,
			})
		end)
	end)
end

function AdminChatBridge.stop(self: any): ()
	if self.connection then
		self.connection:Disconnect()
		self.connection = nil
	end
end

return AdminChatBridge
