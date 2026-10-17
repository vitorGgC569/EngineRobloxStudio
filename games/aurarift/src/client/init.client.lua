--!strict
--[[
	aurarift — client bootstrap.

	Wiring only. The interface lives in `ui/`, and every module there is built
	and routed by `ui/Rail.lua`; this file connects the wire to it and the
	character to the rig, and declares itself ready.

	Order matters twice:
	  * `Wire` before any `Net.on` — the channel contract lives in one shared
	    module because a client without it binds nothing, silently.
	  * handlers before `Hello` — the server answers Hello with a StateSync,
	    and an answer to a handler that is not connected yet is a lost frame
	    of state on every join.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

-- The same file the server requires; defines the channels in this VM.
require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Wire"))

local Net = Forge.Net
local Feel = Forge.Feel
local UI = Forge.UI
local Anim = Forge.Anim
local Rig = Forge.Rig

local player = Players.LocalPlayer

-- Camera shake, hitstop and FOV punch. Without this call they are inert.
Feel.mount()

local screen = UI.mount("Hud")
local Rail = require(script:WaitForChild("ui"):WaitForChild("Rail"))
local rail = Rail.mount(screen)

Net.on("StateSync", function(payload)
	rail.update(payload)
end)

Net.on("Notify", function(payload)
	UI.toast(payload.text, { color = payload.color })
end)

Net.on("Rolled", function(payload)
	rail.rolled(payload)
end)

Net.on("Announce", function(payload)
	rail.announce(payload)
end)

Net.on("Battle", function(payload)
	rail.battle(payload)
end)

Net.on("Board", function(payload)
	rail.board(payload)
end)

--: The client says hello when its loop is up; a client that boots after its
--: join broadcast would otherwise sit on an empty interface forever.
Net.send("Hello", {})

-- Procedural animation on the local character.
-- Rig.stripDefaultAnimate first, or Roblox's own Animate script fights it.
local animator = nil

local function onCharacter(character)
	character:WaitForChild("Humanoid")
	character:WaitForChild("HumanoidRootPart")
	Rig.stripDefaultAnimate(character)

	if animator then
		animator:destroy()
	end
	animator = Anim.new(character)
	Anim.bind(animator)
	Feel.registerAnimator(animator)
end

if player.Character then
	task.spawn(onCharacter, player.Character)
end
player.CharacterAdded:Connect(onCharacter)

--[[
	A way in from outside, for the look-and-critique pass.

	Studio refuses synthetic clicks, and driving by screen coordinates breaks
	the moment anything moves. A BindableFunction the client owns opens the
	same panel the same way a button does, so what gets photographed is what
	a player would see. `forge playtest` looks for exactly this name.
]]
do
	local opener = Instance.new("BindableFunction")
	opener.Name = "ForgeUIHook"
	opener.OnInvoke = function(command: any): any
		return rail.invoke(command)
	end
	opener.Parent = ReplicatedStorage
end

Forge.Debug.probe("interface", rail.describe)

print(string.format("[%s] client ready", Config.name))
