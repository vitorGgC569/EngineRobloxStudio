--!strict
--[[
	Store — the four upgrades, and the server that decides whether you got one.

	The whole file is one handler, and its shape is the point. The client sends
	an id and nothing else. The server looks up what that id costs, checks the
	profile it holds, deducts, writes, and answers. There is no quantity in the
	packet, no price in the packet, and no "confirm" step the client could skip.

	The reason it is worth a module rather than four lines in `Power`: this is
	the only place in the game where a player's persistent balance goes down,
	and a balance that can be decremented from two files is a balance that will
	eventually go negative in production and nowhere else.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Debug = Forge.Debug
local Net = Forge.Net
local Save = Forge.Save

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Shift = require(script.Parent.Parent:WaitForChild("core"):WaitForChild("Shift"))
--: No cycle: Roster requires Cells and Shift, neither of which requires Store.
local Roster = require(script.Parent:WaitForChild("Roster"))

local Store = {}

local function specFor(id: string): any?
	for _, spec in Config.upgrades do
		if spec.id == id then
			return spec
		end
	end
	return nil
end

--[[
	Buy one level of one upgrade, or say why not.

	Exported so the live suite runs the same path the packet does. `onBuy`
	below is a two-line wrapper that unpacks the payload — which means a
	scenario testing purchases is testing the purchase, not a parallel
	implementation written to be testable.

	Returns `(ok, message)`. The message is what the player is told either way,
	so the caller never has to compose one.
]]
function Store.buyFor(player: Player, id: any): (boolean, string)
	--: The shape check upstream has already guaranteed `id` is a string of
	--: sane length. What it cannot know is whether it names anything.
	local spec = specFor(id)
	if not spec then
		Debug.warn(string.format("%s asked to buy unknown upgrade '%s'", player.Name, tostring(id)))
		return false, "No such upgrade."
	end

	local profile = Save.get(player)
	if not profile then
		return false, "Profile still loading."
	end

	profile.upgrades = profile.upgrades or {}
	local level = tonumber(profile.upgrades[spec.id]) or 0

	local cost = Shift.upgradeCost(spec, level)
	if not cost then
		return false, spec.label .. " is maxed."
	end

	local watts = tonumber(profile.watts) or 0
	if watts < cost then
		return false, string.format("Need %d W more.", math.ceil(cost - watts))
	end

	profile.watts = watts - cost
	profile.upgrades[spec.id] = level + 1

	--[[
		Written through immediately rather than left to the autosave.

		An upgrade is the one thing in this game a player would be genuinely
		angry to lose, and the window between "spent the watts" and "the
		autosave ran" is a real two minutes in which a server can restart. The
		write is cheap and the alternative is a support ticket.
	]]
	Save.write(player)

	--: The player list holds the balance too, and a purchase is the one moment
	--: it goes down. Refreshed here rather than on a timer.
	Roster.refresh(player)

	Debug.info(string.format("%s bought %s L%d for %d W", player.Name, spec.id, level + 1, cost))
	return true, string.format("%s → level %d", spec.label, level + 1)
end

local function onBuy(player: Player, payload: any)
	local ok, message = Store.buyFor(player, payload.id)
	Net.fire(player, "Notify", { text = message, tone = if ok then "good" else "warn" })
	if ok then
		Net.fire(player, "You", Shift.crewSnapshot(player))
	end
end

function Store.start()
	Net.on("Buy", onBuy)

	--: Every player gets their own state the moment their profile exists, so
	--: the HUD has real numbers in it before they have taken a step.
	Save.observe(function(player)
		Net.fire(player, "You", Shift.crewSnapshot(player))
	end)

	Debug.probe("store", function()
		return { upgrades = #Config.upgrades }
	end)
end

return Store
