--!strict
-- Overhead nametags: every player's DisplayName plus their equipped title (read from the
-- character's server-set "InfectedTitle" attribute, so titles are visible to everyone).
-- Purely presentational.

local Players = game:GetService("Players")

local Theme = require(script.Parent.Theme)

local Nametags = {}

local function buildTag(character: Model, player: Player)
	local head = character:FindFirstChild("Head")
	if head == nil or not head:IsA("BasePart") then
		return
	end
	if head:FindFirstChild("InfectedNametag") then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "InfectedNametag"
	gui.Size = UDim2.new(0, 200, 0, 44)
	gui.StudsOffset = Vector3.new(0, 2.6, 0)
	gui.AlwaysOnTop = false
	gui.MaxDistance = 80
	gui.Parent = head

	local name = Theme.label(gui, {
		Size = UDim2.new(1, 0, 0, 22),
		Position = UDim2.new(0, 0, 0, 20),
		Text = player.DisplayName,
		TextSize = 14,
		TextStrokeTransparency = 0.5,
	})
	local title = Theme.label(gui, {
		Size = UDim2.new(1, 0, 0, 18),
		Position = UDim2.new(0, 0, 0, 2),
		Text = "",
		TextSize = 12,
		TextColor3 = Theme.Colors.Gold,
		TextStrokeTransparency = 0.6,
	})

	local function refresh()
		local t = character:GetAttribute("InfectedTitle")
		title.Text = (typeof(t) == "string") and t or ""
	end
	refresh()
	character:GetAttributeChangedSignal("InfectedTitle"):Connect(refresh)

	-- Role colouring. We deliberately infer "is a zombie" from the InfectionOutline the
	-- server attaches to converted characters rather than replicating a role attribute.
	--
	-- PATIENT ZERO GUARD: the outline only ever exists on a confirmed ZOMBIE, so a hidden PZ
	-- keeps the plain survivor tag. Inferring from an instance the server already replicates
	-- means this adds no new information channel that could expose them.
	local function refreshRole()
		local infected = character:FindFirstChild("InfectionOutline") ~= nil
		name.TextColor3 = infected and Theme.Colors.Infected or Theme.Colors.Text
		-- Zombies stay legible further out; a survivor tag would just be clutter at range.
		gui.MaxDistance = infected and 130 or 80
	end
	refreshRole()
	character.ChildAdded:Connect(refreshRole)
	character.ChildRemoved:Connect(refreshRole)
end

function Nametags.start(_remotes: any)
	local function hook(player: Player)
		if player == Players.LocalPlayer then
			return -- don't tag yourself; you can't see your own head usefully
		end
		local function onChar(character: Model)
			task.defer(function()
				buildTag(character, player)
			end)
		end
		player.CharacterAdded:Connect(onChar)
		if player.Character then
			onChar(player.Character)
		end
	end
	for _, player in Players:GetPlayers() do
		hook(player)
	end
	Players.PlayerAdded:Connect(hook)

	return {}
end

return Nametags
