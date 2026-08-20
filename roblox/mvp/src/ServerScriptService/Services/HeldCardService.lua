--!strict
-- The card a player is carrying, visible in their hand.
--
-- Held state already existed as an attribute, which the HUD could show but
-- nobody else could see. Putting the card in the hand makes it readable at a
-- glance and from across the plot: another player can tell you are mid-run,
-- and you can tell you are still holding something before walking away.
--
-- Welded rather than tweened. The card has to survive respawns and stay put
-- while the character moves, and a weld is the only thing that does both for
-- free.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CardArt = require(ReplicatedStorage.Shared.CardArt)

local HeldCardService = {}
HeldCardService.__index = HeldCardService

local HOLDER_NAME = "HeldCard"

function HeldCardService.new()
	local self = setmetatable({}, HeldCardService)
	self.byUserId = {}
	return self
end

local function handOf(character: Model): BasePart?
	-- R15 first, then R6, then anything that will do: a card in the wrong hand
	-- is better than no card at all.
	return (character:FindFirstChild("RightHand")
		or character:FindFirstChild("Right Arm")
		or character:FindFirstChild("HumanoidRootPart")) :: BasePart?
end

--- Put a card in the player's hand, replacing whatever was there.
function HeldCardService:show(player: Player, cardId: string, rarity: string, mutationId: string?)
	self:clear(player)

	local character = player.Character
	local hand = character and handOf(character)
	if hand == nil then
		return { ok = false, reason = "no_character" }
	end

	local card = CardArt.build(cardId, rarity, mutationId, 0.42)
	card.Name = HOLDER_NAME

	-- Held out in front and tilted, so the face points at the player's camera
	-- rather than at the sky or into the character's chest.
	local offset = CFrame.new(0.6, 1.6, -1.2) * CFrame.Angles(math.rad(-18), math.rad(12), 0)
	card:PivotTo(hand.CFrame * offset)

	for _, part in ipairs(card:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = false
			part.CanCollide = false
			part.Massless = true
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = hand
			weld.Part1 = part
			weld.Parent = part
		end
	end

	card.Parent = character
	self.byUserId[player.UserId] = card
	return { ok = true, cardId = cardId, rarity = rarity, mutation = mutationId }
end

function HeldCardService:clear(player: Player)
	local existing = self.byUserId[player.UserId]
	if existing and existing.Parent ~= nil then
		existing:Destroy()
	end
	self.byUserId[player.UserId] = nil

	-- A respawn can leave an orphan behind; sweep the character too.
	local character = player.Character
	if character then
		local stray = character:FindFirstChild(HOLDER_NAME)
		if stray then
			stray:Destroy()
		end
	end
end

--- Re-show the held card after a respawn, so dying does not silently eat it.
function HeldCardService:bind(player: Player, resolve: () -> (string?, string?, string?))
	player.CharacterAdded:Connect(function()
		task.wait(0.6)
		local cardId, rarity, mutation = resolve()
		if cardId and rarity then
			self:show(player, cardId, rarity, mutation)
		end
	end)
end

function HeldCardService:release(player: Player)
	self:clear(player)
end

return HeldCardService
