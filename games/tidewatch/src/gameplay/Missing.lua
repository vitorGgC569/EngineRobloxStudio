--!strict
-- Systems this game asked for that the SDK does not implement yet.
--
-- Each is a function that raises. A stub returning a plausible empty value is
-- how a shop ships with nothing to sell and nobody notices until a player
-- clicks Buy: the game does not crash, it just quietly does nothing where a
-- feature should be. Failing on first use puts the gap where it can be seen.

local reasons = {
	crafting = "the crafting system is planned in the SDK and has no module yet; this game declared it and nothing implements it"
}

local Missing = {}

function Missing.require(name: string): never
	local reason = reasons[name]
	error("[Missing] " .. (reason or ("unknown system " .. name)), 0)
end

function Missing.list(): { string }
	local names = {}
	for name in pairs(reasons) do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

return Missing
