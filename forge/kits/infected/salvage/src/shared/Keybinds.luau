--!strict
-- Rebindable keyboard controls. The default bindings + the pure resolver live here (unit-
-- testable); the client helpers read/write per-action overrides on the LocalPlayer so a
-- rebind persists for the session and every input handler agrees on the current key.
-- Mouse buttons and gamepad buttons stay fixed; only keyboard actions rebind.

local Keybinds = {}

-- action -> default Enum.KeyCode name
Keybinds.Defaults = {
	sprint = "LeftShift",
	reload = "R",
	throwKnife = "F",
	melee = "E",
	ability = "Q",
	shop = "B",
} :: { [string]: string }

-- Human-readable order for the rebind UI.
Keybinds.Order = { "sprint", "reload", "throwKnife", "melee", "ability", "shop" }
Keybinds.Labels = {
	sprint = "Sprint",
	reload = "Reload",
	throwKnife = "Throw Knife",
	melee = "Melee",
	ability = "Ability",
	shop = "Shop",
} :: { [string]: string }

-- Pure: the key name for an action given a table of overrides (falls back to the default).
function Keybinds.resolve(action: string, overrides: { [string]: string }?): string?
	if overrides and overrides[action] then
		return overrides[action]
	end
	return Keybinds.Defaults[action]
end

-- Client helpers (LocalPlayer-attribute backed) ---------------------------------

local function attr(action: string): string
	return "Bind_" .. action
end

function Keybinds.get(player: Instance, action: string): string
	local override = player:GetAttribute(attr(action))
	if typeof(override) == "string" then
		return override
	end
	return Keybinds.Defaults[action] or ""
end

function Keybinds.set(player: Instance, action: string, keyName: string)
	player:SetAttribute(attr(action), keyName)
end

-- Does a pressed KeyCode match the current binding for `action`?
function Keybinds.matches(player: Instance, action: string, keyCode: EnumItem): boolean
	local name = Keybinds.get(player, action)
	return name ~= "" and (Enum.KeyCode :: any)[name] == keyCode
end

return Keybinds
