--!strict
--- Chat: channels, commands, bubbles -- and the filtering that is not optional.
---
--- `TextChatService` was at zero. That is a gap for social games, where chat is
--- half the product, and for any game with a `/` command -- but it is also a
--- compliance gap, and that is the part worth being loud about.
---
--- **Displaying player text without filtering it will get a game taken down.**
--- Roblox requires every piece of user-authored text shown to another player to
--- pass `TextService:FilterStringAsync`, and the requirement covers more than
--- the chat window: a pet's name over its head, a sign a player wrote, a team
--- name, a shop listing. It is not a warning, it is moderation policy, and it
--- is enforced.
---
--- So `Chat.display` exists and is the only way this module hands player text
--- to anyone. It filters per recipient, because the filter is contextual: the
--- same string is filtered differently for a 7-year-old and an adult, and
--- filtering once for everybody defeats it.
---
--- **Filtering can fail, and the safe failure is silence.** A network error
--- returns nothing rather than the raw string. A game that shows unfiltered
--- text when the filter is down has the same problem as one that never filtered
--- at all, only rarer and harder to notice.

local TextChatService = game:GetService("TextChatService")
local TextService = game:GetService("TextService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Chat = {}

export type Command = {
	--- What the player types, without the slash.
	name: string,
	alias: string?,
	--- Runs on the server with the player and the rest of the line.
	run: (Player, string) -> (),
	help: string?,
}

export type Channel = {
	name: string,
	--- Only these players see it. Nil means everybody.
	members: { Player }?,
}

local installed: { [string]: TextChatCommand } = {}

--- Filter one player's text for one audience. Returns nil when it cannot.
---
--- The nil is the point. Every caller has to decide what to do without the
--- text, and "show it anyway" is not reachable from here.
function Chat.filter(text: string, author: Player, audience: Player): string?
	if type(text) ~= "string" or text == "" then
		return nil
	end
	local ok, result = pcall(function()
		return TextService:FilterStringAsync(text, author.UserId)
	end)
	if not ok or result == nil then
		warn("[Chat] filter unavailable; showing nothing rather than raw text")
		return nil
	end
	local shown, why = pcall(function()
		return result:GetChatForUserAsync(audience.UserId)
	end)
	if not shown then
		warn("[Chat] filter failed for " .. audience.Name .. ": " .. tostring(why))
		return nil
	end
	return why
end

--- The only supported way to put one player's words in front of another.
---
--- `show` receives the filtered string, per recipient. It is never called with
--- the original.
function Chat.display(text: string, author: Player, audience: { Player },
	show: (Player, string) -> ()): number

	if not RunService:IsServer() then
		-- Filtering on the client is not filtering: the client is the thing
		-- being defended against.
		warn("[Chat] display must run on the server")
		return 0
	end
	local shown = 0
	for _, viewer in ipairs(audience) do
		local safe = Chat.filter(text, author, viewer)
		if safe ~= nil then
			local ok, err = pcall(show, viewer, safe)
			if ok then
				shown += 1
			else
				warn("[Chat] display to " .. viewer.Name .. ": " .. tostring(err))
			end
		end
	end
	return shown
end

--- Everything wrong with a command set, before any of it is typed.
function Chat.problems(commands: { Command }): { string }
	local found, seen = {}, {}
	for index, command in ipairs(commands) do
		local label = tostring(command.name or ("command " .. index))
		if type(command.name) ~= "string" or command.name == "" then
			table.insert(found, ("command %d has no name"):format(index))
		elseif string.find(command.name, "^/") ~= nil then
			-- The slash is added here. A name written with one produces `//kick`,
			-- which never matches and looks like the command is broken.
			table.insert(found, ("%s: leave the slash off the name"):format(label))
		elseif string.find(command.name, "%s") ~= nil then
			table.insert(found, ("%s: a command name cannot contain a space"):format(label))
		end
		for _, key in ipairs({ command.name, command.alias }) do
			if key ~= nil then
				if seen[key] then
					table.insert(found, ("two commands answer to /%s"):format(key))
				end
				seen[key] = true
			end
		end
		if type(command.run) ~= "function" then
			table.insert(found, ("%s: has nothing to run"):format(label))
		end
	end
	return found
end

--- Is this place actually using TextChatService?
---
--- `TextChatCommand` does nothing under `LegacyChatService`: it parents
--- cleanly, raises nothing, and never fires. A place still on legacy chat --
--- which older place files are, including this project's own -- would install a
--- whole command set and get silence.
function Chat.modern(): (boolean, string?)
	if TextChatService.ChatVersion ~= Enum.ChatVersion.TextChatService then
		return false, ("this place is on %s; TextChatCommand never fires there. "
			.. "Set TextChatService.ChatVersion to TextChatService.")
			:format(tostring(TextChatService.ChatVersion))
	end
	return true, nil
end

--- Install slash commands. Refuses the whole set on any problem.
function Chat.commands(commands: { Command }): (boolean, { string })
	local found = Chat.problems(commands)
	if #found > 0 then
		return false, found
	end

	local modern, why = Chat.modern()
	if not modern then
		return false, { why :: string }
	end

	Chat.clearCommands()
	for _, command in ipairs(commands) do
		local instance = Instance.new("TextChatCommand")
		instance.Name = "RQE_" .. command.name
		instance.PrimaryAlias = "/" .. command.name
		if command.alias ~= nil then
			instance.SecondaryAlias = "/" .. command.alias
		end
		instance.Triggered:Connect(function(source, unfiltered)
			local player = Players:GetPlayerByUserId(source.UserId)
			if player == nil then
				return
			end
			-- The rest of the line, with the alias stripped. Passed to the
			-- handler raw: it is this player's own input to their own command,
			-- and it is the handler's job to filter before showing it to anyone.
			local rest = string.gsub(unfiltered, "^%s*/%S+%s*", "")
			local ok, err = pcall(command.run, player, rest)
			if not ok then
				warn("[Chat] /" .. command.name .. ": " .. tostring(err))
			end
		end)
		instance.Parent = TextChatService
		installed[command.name] = instance
	end
	return true, {}
end

function Chat.clearCommands(): number
	local removed = 0
	for _, instance in pairs(installed) do
		instance:Destroy()
		removed += 1
	end
	installed = {}
	for _, item in ipairs(TextChatService:GetDescendants()) do
		if item:IsA("TextChatCommand") and string.sub(item.Name, 1, 4) == "RQE_" then
			item:Destroy()
			removed += 1
		end
	end
	return removed
end

--- Speech bubbles over heads, sized and ranged for the game's scale.
function Chat.bubbles(settings: { [string]: any }): { [string]: any }
	local configuration = TextChatService:FindFirstChildOfClass("BubbleChatConfiguration")
	if configuration == nil then
		return { available = false,
			reason = "this place has no BubbleChatConfiguration; "
				.. "TextChatService may be in legacy mode" }
	end
	local applied = {}
	for property, value in pairs(settings) do
		local ok = pcall(function()
			(configuration :: any)[property] = value
		end)
		applied[property] = ok
	end
	return {
		available = true,
		applied = applied,
		enabled = configuration.Enabled,
		maxDistance = configuration.MaxDistance,
	}
end

function Chat.report(): { [string]: any }
	local names = {}
	for name in pairs(installed) do
		table.insert(names, "/" .. name)
	end
	table.sort(names)
	local channels = {}
	local folder = TextChatService:FindFirstChild("TextChannels")
	if folder ~= nil then
		for _, channel in ipairs(folder:GetChildren()) do
			table.insert(channels, channel.Name)
		end
	end
	table.sort(channels)
	local modern, why = Chat.modern()
	return {
		commands = names,
		channels = channels,
		version = tostring(TextChatService.ChatVersion),
		commandsWillFire = modern,
		versionWarning = why,
		filteringNote = (
			"player text must pass Chat.display before any other player sees it "
			.. "-- names over heads and signs included, not just the chat window"
		),
	}
end

return Chat
