--!strict
--[[
	Client bootstrap. Order is small: audio, theme, wire, doors, controllers.

	The client is a renderer. Everything it knows arrives through `Wire`
	channels; everything it wants goes back as a request. The only local
	simulation is the fight minigame, which is deliberately the same module
	the server could audit.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local Net = Forge.Net
local UI = Forge.UI
local Debug = Forge.Debug

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

--: The network contract must be declared in this VM before anything listens.
local Wire = require(Shared.Wire)
assert(Wire, "wire declared")

local audio = require(script.audio)
audio.start()

-- ================================= theme ====================================
--: A deep-water palette: cold panels, warm gold for money, one cyan accent
--: for everything that is the player. Set before any widget is built.
UI.theme.color.bg = Color3.fromRGB(6, 13, 18)
UI.theme.color.panel = Color3.fromRGB(13, 25, 32)
UI.theme.color.panelAlt = Color3.fromRGB(20, 38, 48)
UI.theme.color.stroke = Color3.fromRGB(44, 82, 96)
UI.theme.color.text = Color3.fromRGB(226, 238, 240)
UI.theme.color.textDim = Color3.fromRGB(128, 156, 164)
UI.theme.color.accent = Color3.fromRGB(94, 198, 214)
UI.theme.color.gold = Color3.fromRGB(236, 196, 108)
UI.theme.color.danger = Color3.fromRGB(212, 88, 88)
UI.theme.color.warning = Color3.fromRGB(232, 172, 92)
UI.theme.color.good = Color3.fromRGB(122, 208, 148)
UI.theme.toastTop = 110

local state = require(script.state)

local effects = require(script.effects)
effects.install()

local Panels = require(script.ui.Panels)
local Hud = require(script.ui.Hud)
local CatchCard = require(script.ui.CatchCard)

local DialogueUI = require(script.ui.DialogueUI)

local CastController = require(script.controllers.CastController)
local BoatController = require(script.controllers.BoatController)
local AmbienceController = require(script.controllers.AmbienceController)
local QuestTrackerController = require(script.controllers.QuestTrackerController)

-- ============================== state intake ================================
Net.on("ProfileSync", function(payload: any)
	state.apply(payload)
end)

-- ============================== toast + level ===============================
local function toast(payload: any)
	local tone = payload.tone
	local color = if tone == "good" then UI.theme.color.good
		elseif tone == "warn" then UI.theme.color.warning
		else UI.theme.color.text
	UI.toast(payload.text or "", { color = color, duration = 5 })
end

Net.on("Notify", toast)

Net.on("LevelUp", function(payload: any)
	UI.toast(string.format("LEVEL %d  --  +$%d", payload.level, payload.coins), {
		color = UI.theme.color.gold,
		duration = 6,
	})
	audio.sfx("ui.success")
end)

Net.on("CatchResult", function(payload: any)
	CatchCard.show(payload)
	audio.sfx("reward.pickup")
	if payload.mutation and payload.mutation ~= "normal" then
		audio.sfx("reward.coin")
	end
end)

--: The sell hint writes itself the first time the profile shows a sale.
state.changed:Connect(function(profile: any)
	if profile.stats.sold > 0 and not profile.tutorial.seen.sell then
		Net.send("TutorialDone", { step = "sell" })
	end
end)

-- ================================= mount ====================================
--: Opening a door by any road -- a HUD button or an NPC's offer -- counts
--: as having seen that door, so the tutorial hint retires either way.
local function markSeen(id: string)
	local profile = state.get()
	if not profile then
		return
	end
	if id == "shop" and not profile.tutorial.seen.shop then
		Net.send("TutorialDone", { step = "shop" })
	elseif id == "quests" and not profile.tutorial.seen.quests then
		Net.send("TutorialDone", { step = "quests" })
	end
end

local panels = Panels.mount()
local hud = Hud.mount(function(id: string)
	Panels.toggle(id)
	markSeen(id)
end)

--: A dialogue choice that names a door (the merchant's shop, the clerk's
--: board) opens it outright -- the conversation is over once it does, so
--: toggle semantics would be wrong here.
DialogueUI.mount(function(id: string)
	Panels.open(id)
	markSeen(id)
end)

QuestTrackerController.start(hud)

CastController.start()
BoatController.start()
AmbienceController.start()

Debug.info(string.format("Tidebound client up -- %s", Config.name))
Debug.expose()

return {
	state = state,
	hud = hud,
	panels = panels,
}
