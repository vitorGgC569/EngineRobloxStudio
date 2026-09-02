--!strict
-- Tracks whether any interactive menu / modal is open, so CameraController releases the
-- locked combat mouse and the player can click buttons.
--
-- CONTRACT: every client UI that shows a panel the player must click (shop, settings,
-- quests, season, leaderboard, tutorial, daily reward, map vote, emote wheel, controls
-- rebind, …) MUST call MenuState.track(thatPanel). Track the outermost Visible=false
-- root (dimmer or panel) — not a permanently-visible HUD chrome button.
--
-- CameraController ALSO frees the cursor outside ACTIVE combat and while Alt is held, so
-- lobby/intermission HUD toggles work without opening a tracked panel first. MenuState is
-- still required for modals that appear mid-round (daily, emote, tutorial).

local MenuState = {}

local openPanels: { [Instance]: true } = {}
local listeners: { (boolean) -> () } = {}

local function anyOpen(): boolean
	return next(openPanels) ~= nil
end

local function notify()
	local open = anyOpen()
	for _, fn in listeners do
		task.spawn(fn, open)
	end
end

-- Watch a panel's Visible property for as long as it exists.
function MenuState.track(panel: GuiObject)
	local function sync()
		if panel.Visible then
			openPanels[panel] = true
		else
			openPanels[panel] = nil
		end
		notify()
	end
	panel:GetPropertyChangedSignal("Visible"):Connect(sync)
	panel.Destroying:Connect(function()
		openPanels[panel] = nil
		notify()
	end)
	sync()
end

function MenuState.isOpen(): boolean
	return anyOpen()
end

function MenuState.onChanged(fn: (boolean) -> ())
	table.insert(listeners, fn)
	task.spawn(fn, anyOpen())
end

return MenuState
