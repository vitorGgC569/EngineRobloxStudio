--!strict
--[[
	ServerModePlots — server-mode detection with map/theme selection.

	Main, VIP and private servers can run different maps; gamepass themes
	re-skin a loaded map (materials/colors/gravidade/sky) without touching
	logic. Pure decision layer over injected facts.
]]

local ServerModePlots = {}

export type Mode = "main" | "vip" | "private"

export type ThemeRule = {
	gamepassId: number,
	themeName: string,
	materialSwaps: { [string]: string }?, -- Enum.Material name -> name
	colorTint: { number }?,
	gravity: number?,
	skyAssetId: number?,
}

type Self = {
	mapByMode: { [Mode]: string },
	defaultMap: string,
	themes: { ThemeRule },
}

ServerModePlots.__index = ServerModePlots

local function normalizeMode(raw: string?): Mode?
	if raw == "main" or raw == "vip" or raw == "private" then
		return raw :: Mode
	end
	return nil
end

function ServerModePlots.new(config: { mapByMode: { [Mode]: string }, defaultMap: string?, themes: { ThemeRule }? }): Self
	return setmetatable({
		mapByMode = config.mapByMode,
		defaultMap = config.defaultMap or "main_map",
		themes = config.themes or {},
	}, ServerModePlots)
end

-- Facts come from the server (PrivateServerId, vipServerId match).
function ServerModePlots.detectMode(self: Self, isPrivateServer: boolean, matchesVipTemplate: boolean): Mode
	if isPrivateServer then
		return "private"
	elseif matchesVipTemplate then
		return "vip"
	end
	return "main"
end

function ServerModePlots.mapFor(self: Self, mode: Mode): string
	return self.mapByMode[mode] or self.defaultMap
end

-- First matching owned gamepass wins; nil means stock theme.
function ServerModePlots.themeFor(self: Self, ownsGamepass: (gamepassId: number) -> boolean): ThemeRule?
	for _, rule in self.themes do
		if ownsGamepass(rule.gamepassId) then
			return rule
		end
	end
	return nil
end

return ServerModePlots
