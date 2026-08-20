--!strict
-- Client presentation for GameKit.Feedback packets.
--
-- This module owns no gameplay decision. It never fires a remote, spends a
-- currency, grants an item or chooses an asset id from a network payload. It
-- turns an already-authoritative semantic event into three redundant signals:
-- a short toast, a UI sound and (when a position is present) a budgeted burst.

local Audio = require(script.Parent.Audio)
local Tokens = require(script.Parent.Tokens)
local Ui = require(script.Parent.Ui)
local Vfx = require(script.Parent.Vfx)

local Feedback = {}

local EVENT_AUDIO = {
	success = "success",
	error = "error",
	purchase = "purchase",
	reward = "reward",
	build = "build",
	upgrade = "upgrade",
	unlock = "unlock",
	damage = "damage",
	wave = "wave",
	victory = "victory",
	defeat = "defeat",
}

local EVENT_ROLE = {
	success = "accentSuccess",
	error = "accentDanger",
	purchase = "accentSuccess",
	reward = "accentGold",
	build = "accentSuccess",
	upgrade = "accentRare",
	unlock = "accentRare",
	damage = "accentDanger",
	wave = "accentGold",
	victory = "accentSuccess",
	defeat = "accentDanger",
}

local REASONS = {
	insufficient_funds = "Not enough currency",
	unavailable = "Unavailable",
	locked = "Locked",
	invalid = "That action is not available",
}

local function eventMessage(payload: { [string]: any }): string?
	local event = payload.event
	local item = if type(payload.itemName) == "string" then payload.itemName else nil
	if event == "success" then
		return if item then item .. " ready" else "Done"
	elseif event == "error" then
		return REASONS[payload.reasonKey] or "Action failed"
	elseif event == "purchase" then
		return if item then "Purchased " .. item else "Purchase complete"
	elseif event == "reward" then
		local amount = tonumber(payload.amount)
		return if amount then "+" .. tostring(math.floor(amount)) else "Reward earned"
	elseif event == "build" then
		return if item then "Built " .. item else "Build complete"
	elseif event == "upgrade" then
		return if item then "Upgraded " .. item else "Upgrade complete"
	elseif event == "unlock" then
		return if item then "Unlocked " .. item else "Unlocked"
	elseif event == "damage" then
		local amount = tonumber(payload.amount)
		return if amount then "-" .. tostring(math.floor(amount)) .. " integrity" else "Damage taken"
	elseif event == "wave" then
		return "Wave " .. tostring(math.floor(tonumber(payload.round) or 0))
	elseif event == "victory" then
		return "Victory"
	elseif event == "defeat" then
		return "Defeat"
	end
	return nil
end

function Feedback.events(): { string }
	local names = {}
	for name in pairs(EVENT_AUDIO) do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

export type Presenter = {
	present: (self: Presenter, payload: { [string]: any }) -> boolean,
	destroy: (self: Presenter) -> (),
	audioReceipts: (self: Presenter) -> { { [string]: any } },
}

--- Construct one presenter under PlayerGui.
---
--- `config.audio` is local trusted configuration emitted with the place. Asset
--- ids in packets are never read. Missing audio configuration retains Roblox's
--- built-in sounds and reports that provenance through `audioReceipts()`.
function Feedback.presenter(tokens: Tokens.TokenSet, playerGui: Instance,
	config: { [string]: any }?): Presenter
	local options = config or {}
	local bank = Audio.define(options.audio)
	local screen = Ui.screen(playerGui, "Feedback", { enabled = true, displayOrder = 50 })
	local toast = Ui.panel(tokens, screen, {
		name = "Toast",
		anchorPoint = Vector2.new(0.5, 0),
		position = UDim2.new(0.5, 0, 0, tokens:space("loose") * 4),
		size = UDim2.fromOffset(360, 64),
		visible = false,
	})
	local label = Ui.text(tokens, toast, "body", "", {
		name = "Message",
		size = UDim2.fromScale(1, 1),
	})
	local generation = 0
	local lastSequence = 0
	local presenter = {} :: any

	function presenter:present(payload: { [string]: any }): boolean
		if type(payload) ~= "table" or EVENT_AUDIO[payload.event] == nil then
			return false
		end
		local sequence = tonumber(payload.sequence)
		if sequence == nil or sequence <= lastSequence then
			return false
		end
		lastSequence = sequence
		generation += 1
		local current = generation
		local event = payload.event
		local message = eventMessage(payload)
		if message == nil then
			return false
		end

		label.Text = message
		label.TextColor3 = tokens:color(EVENT_ROLE[event])
		toast.Visible = true
		toast:SetAttribute("FeedbackEvent", event)
		toast:SetAttribute("FeedbackSequence", sequence)
		local key = "RQEPresented_" .. event
		local count = playerGui:GetAttribute(key)
		playerGui:SetAttribute(key, (if type(count) == "number" then count else 0) + 1)
		local total = playerGui:GetAttribute("RQEPresentedTotal")
		playerGui:SetAttribute("RQEPresentedTotal", (if type(total) == "number" then total else 0) + 1)

		bank:play(EVENT_AUDIO[event])
		if typeof(payload.position) == "Vector3" then
			Vfx.feedback(tokens, event, payload.position)
		end
		task.delay(if event == "victory" or event == "defeat" then 3 else 1.6, function()
			if generation == current and toast.Parent ~= nil then
				toast.Visible = false
			end
		end)
		return true
	end

	function presenter:audioReceipts(): { { [string]: any } }
		local receipts = {}
		local seen = {}
		for _, audioEvent in pairs(EVENT_AUDIO) do
			if not seen[audioEvent] then
				seen[audioEvent] = true
				local receipt = bank:receipt(audioEvent)
				if receipt ~= nil then
					table.insert(receipts, receipt)
				end
			end
		end
		table.sort(receipts, function(a, b)
			return a.event < b.event
		end)
		return receipts
	end

	function presenter:destroy()
		screen:Destroy()
	end

	return presenter :: Presenter
end

return Feedback
