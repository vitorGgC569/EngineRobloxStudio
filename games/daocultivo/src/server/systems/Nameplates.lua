--!strict
--[[
	Nameplates — as duas escadas escritas sobre a cabeça.

	Na tela de origem é a primeira coisa que se lê: dois títulos empilhados
	sobre o personagem, um do Qi e um do corpo. Não é enfeite -- é a única
	parte da interface que **os outros jogadores** enxergam, e num jogo de
	cultivo saber em que realm está quem passou por você é metade da razão de
	haver um servidor compartilhado.

	Por que aqui e não no cliente
	-----------------------------

	Um `BillboardGui` que o cliente cria só existe para quem o criou. Feito no
	servidor, ele replica, e os títulos vêm de atributos do `Player` -- que
	replicam para todo mundo e sobrevivem a respawn. Um `StateSync`, que só
	chega ao dono, não serviria: cada um veria a própria placa e mais nenhuma.

	O erro clássico que este arquivo evita
	--------------------------------------

	Ligar o handler ao `Character` que existe agora. Um respawn traz outro
	modelo, a placa antiga vai junto com o corpo antigo, e o jogador volta sem
	nome -- para sempre, porque não há nada que reconstrua. Por isso a placa é
	remontada em `CharacterAdded`, e o texto é redesenhado por sinal de
	atributo em vez de por laço.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Content = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Content"))

local Debug = Forge.Debug

local Nameplates = {}

local TIER_COLOUR = Content.tierColour

local function attach(player: Player, character: Model)
	local head = character:WaitForChild("Head", 8)
	if head == nil or not head:IsA("BasePart") then
		return
	end

	local existing = head:FindFirstChild("Placa")
	if existing then
		existing:Destroy()
	end

	local plate = Instance.new("BillboardGui")
	plate.Name = "Placa"
	--: Pequena e alta. A câmera fica atrás do personagem, então esta placa cai
	--: exatamente no meio da tela -- a 330 px de largura ela cobria a roda de
	--: Qi e a barra de saúde ao mesmo tempo.
	plate.Size = UDim2.fromOffset(210, 54)
	plate.StudsOffsetWorldSpace = Vector3.new(0, 4.2, 0)
	--: Não `AlwaysOnTop`. Uma placa que atravessa um pagode diz ao jogador
	--: que a parede não é sólida, e a informação não vale a mentira.
	plate.AlwaysOnTop = false
	plate.MaxDistance = 90
	plate.LightInfluence = 0
	plate.Parent = head

	local name = Instance.new("TextLabel")
	name.Size = UDim2.new(1, 0, 0, 18)
	name.BackgroundTransparency = 1
	name.Text = player.DisplayName
	name.TextScaled = true
	name.Font = Enum.Font.GothamBold
	name.TextColor3 = Color3.fromRGB(242, 238, 230)
	name.TextStrokeTransparency = 0.3
	name.Parent = plate

	local qi = Instance.new("TextLabel")
	qi.Size = UDim2.new(1, 0, 0, 18)
	qi.Position = UDim2.fromOffset(0, 18)
	qi.BackgroundTransparency = 1
	qi.TextScaled = true
	qi.Font = Enum.Font.Merriweather
	qi.TextColor3 = Color3.fromRGB(122, 178, 250)
	qi.TextStrokeTransparency = 0.35
	qi.Parent = plate

	local body = Instance.new("TextLabel")
	body.Size = UDim2.new(1, 0, 0, 18)
	body.Position = UDim2.fromOffset(0, 36)
	body.BackgroundTransparency = 1
	body.TextScaled = true
	body.Font = Enum.Font.Merriweather
	body.TextColor3 = Color3.fromRGB(238, 150, 110)
	body.TextStrokeTransparency = 0.35
	body.Parent = plate

	local function refresh()
		qi.Text = tostring(player:GetAttribute("tituloQi") or "—")
		body.Text = tostring(player:GetAttribute("tituloCorpo") or "—")
		--: A cor do nome é o tier da raiz. É o único lugar em que a sorte de
		--: alguém fica visível de longe, e é o que faz um jogador atravessar o
		--: pátio para ver de perto quem tem uma raiz celestial.
		local tier = tonumber(player:GetAttribute("raizTier")) or 1
		name.TextColor3 = TIER_COLOUR[tier] or Color3.fromRGB(242, 238, 230)
	end

	player:GetAttributeChangedSignal("tituloQi"):Connect(refresh)
	player:GetAttributeChangedSignal("tituloCorpo"):Connect(refresh)
	player:GetAttributeChangedSignal("raizTier"):Connect(refresh)
	refresh()
end

local function follow(player: Player)
	player.CharacterAdded:Connect(function(character)
		attach(player, character)
	end)
	if player.Character then
		task.spawn(attach, player, player.Character)
	end
end

function Nameplates.start()
	Players.PlayerAdded:Connect(follow)
	--: O jogador local do Studio entra antes deste sistema existir, então
	--: `PlayerAdded` já passou e nunca dispara para ele. Sem esta reposição o
	--: único jogador da sessão de teste é o único sem placa.
	for _, player in Players:GetPlayers() do
		follow(player)
	end
	Debug.info("placas: dois títulos por cabeça")
end

return Nameplates
