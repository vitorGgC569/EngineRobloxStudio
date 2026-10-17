--!strict
--[[
	Ascension — o avanço visto do mundo.

	O rompimento é o momento pelo qual o jogo inteiro existe: é a única decisão
	que o jogador toma no laço, e até agora ele acontecia como um cartão na
	tela e um número mudando. Um cartão é um aviso. O que o gênero faz é outra
	coisa -- o chão racha, o ar recua num anel, uma coluna de nuvem desce, e
	todo mundo no pátio olha.

	O que isto **não** faz
	----------------------

	Dano. Nada aqui colide, consulta ou toca: `CanCollide`, `CanQuery` e
	`CanTouch` são falsos em cada peça. É um evento, e um evento que machuca o
	próprio autor seria uma punição por progredir.

	Por que no servidor
	-------------------

	Porque o rompimento dos outros é metade do que faz um servidor
	compartilhado valer a pena. Um efeito que só o próprio jogador vê é um
	efeito que não existe para mais ninguém -- e a coisa que faz um novato
	querer chegar ao Alma Nascente é ver alguém chegando.

	O tremor de tela fica no cliente, onde ele pertence: `Feel.shake` mexe na
	câmera, e câmera é de quem está olhando.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debug_ = game:GetService("RunService")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Content = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Content"))

local Debug = Forge.Debug

local Ascension = {}

--: Quanto tempo o efeito inteiro dura. Curto: um evento que fica na tela por
--: muito tempo deixa de ser evento e vira cenário.
local LIFE = 2.6

local function piece(parent: Instance, name: string, shape: Enum.PartType,
                     size: Vector3, cf: CFrame, colour: Color3,
                     transparency: number): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = shape
	part.Size = size
	part.CFrame = cf
	part.Color = colour
	part.Material = Enum.Material.Neon
	part.Anchored = true
	--: As três que garantem que isto é enfeite. Sem elas o anel empurra o
	--: jogador, o raycast do golpe acerta a nuvem, e um `Touched` qualquer
	--: passa a disparar no meio do avanço.
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = transparency
	part.Parent = parent
	return part
end

--[[
	O anel de choque: um cilindro fino e deitado que abre e some.

	Deitado significa girar noventa graus em Z -- `PartType.Cylinder` nasce com
	o círculo em ±X, e essa é a linha que se esquece. Um anel que cresce sem
	desaparecer lê como um disco crescendo; o que faz o olho ler *onda de
	choque* é a transparência subindo junto com o raio.
]]
local function shockRing(parent: Instance, at: Vector3, colour: Color3,
                         radius: number, delay: number, thickness: number)
	task.delay(delay, function()
		if parent.Parent == nil then
			return
		end
		local ring = piece(parent, "Choque", Enum.PartType.Cylinder,
			Vector3.new(thickness, 4, 4),
			CFrame.new(at) * CFrame.Angles(0, 0, math.pi / 2),
			colour, 0.15)
		TweenService:Create(ring, TweenInfo.new(0.85, Enum.EasingStyle.Quint,
			Enum.EasingDirection.Out), {
			Size = Vector3.new(thickness * 0.4, radius * 2, radius * 2),
			Transparency = 1,
		}):Play()
	end)
end

--[[
	A coluna: um cilindro **em pé**, subindo do chão até bem acima da cabeça.

	É a parte que se vê do outro lado do pátio, e o motivo de o avanço de realm
	parecer diferente do avanço de estágio sem precisar de um segundo efeito:
	os dois usam esta coluna, com alturas muito diferentes.
]]
local function column(parent: Instance, at: Vector3, colour: Color3,
                      height: number, radius: number)
	local shaft = piece(parent, "Coluna", Enum.PartType.Cylinder,
		Vector3.new(height, radius * 2, radius * 2),
		CFrame.new(at + Vector3.new(0, height / 2, 0))
			* CFrame.Angles(0, 0, math.pi / 2),
		colour, 0.55)
	TweenService:Create(shaft, TweenInfo.new(LIFE * 0.8,
		Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(height * 1.6, radius * 0.6, radius * 0.6),
		Transparency = 1,
	}):Play()
end

--[[
	A nuvem que desce.

	Emissor apontado para **baixo**, bem acima da cabeça: a nuvem chega de
	cima, que é de onde o céu reclama em toda tribulação do gênero. Um emissor
	que sobe leria como fumaça de fogueira e diria a coisa oposta.
]]
local function cloud(parent: Instance, at: Vector3, colour: Color3, scale: number)
	local anchor = piece(parent, "Nuvem", Enum.PartType.Block,
		Vector3.new(2, 2, 2), CFrame.new(at + Vector3.new(0, 26 * scale, 0)),
		colour, 1)

	local puff = Instance.new("ParticleEmitter")
	puff.Name = "Bruma"
	puff.Rate = 140 * scale
	puff.Lifetime = NumberRange.new(0.9, 1.8)
	puff.Speed = NumberRange.new(14 * scale, 24 * scale)
	puff.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 3 * scale),
		NumberSequenceKeypoint.new(1, 13 * scale),
	})
	puff.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	puff.Color = ColorSequence.new(colour, Color3.fromRGB(236, 240, 248))
	puff.LightEmission = 0.4
	puff.LightInfluence = 0.4
	puff.EmissionDirection = Enum.NormalId.Bottom
	puff.SpreadAngle = Vector2.new(38, 38)
	puff.Acceleration = Vector3.new(0, -20 * scale, 0)
	puff.Parent = anchor

	--: Uma rajada e para. `Enabled = false` depois de meio segundo, senão a
	--: nuvem continua caindo até a peça morrer e o evento perde o começo, o
	--: meio e o fim.
	task.delay(0.55, function()
		puff.Enabled = false
	end)
end

--: Faíscas subindo do chão, que é o Qi que sobrou do degrau anterior. Só no
--: rompimento de realm: se toda subida de estágio tivesse isto, nada
--: distinguiria a décima da primeira.
local function sparks(parent: Instance, at: Vector3, colour: Color3)
	local anchor = piece(parent, "Faiscas", Enum.PartType.Block,
		Vector3.new(2, 2, 2), CFrame.new(at + Vector3.new(0, 1, 0)), colour, 1)

	local emitter = Instance.new("ParticleEmitter")
	emitter.Rate = 260
	emitter.Lifetime = NumberRange.new(0.6, 1.4)
	emitter.Speed = NumberRange.new(28, 52)
	emitter.Size = NumberSequence.new(0.6)
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Color = ColorSequence.new(colour, Color3.new(1, 1, 1))
	emitter.LightEmission = 1
	emitter.SpreadAngle = Vector2.new(30, 30)
	emitter.Acceleration = Vector3.new(0, -34, 0)
	emitter.Parent = anchor

	task.delay(0.5, function()
		emitter.Enabled = false
	end)
end

--[[
	O evento inteiro, montado num lugar só e apagado por inteiro.

	Uma pasta e um `task.delay` para destruí-la: cada peça com o próprio
	temporizador é como um efeito deixa lixo para trás quando uma delas falha
	em criar.
]]
function Ascension.burst(player: Player, report: { [string]: any })
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return
	end

	local realmBreak = report.realmBreak == true
	local realm = tonumber(report.realm) or 1
	--: A cor do degrau alcançado, pela mesma tabela que a aura usa. Um avanço
	--: que pisca numa cor e deixa o cultivador com aura de outra é um avanço
	--: que não parece ter acontecido.
	local aura = Content.auraFor(realm)
	local colour = aura.colour

	local host = Instance.new("Folder")
	host.Name = "Avanco"
	host.Parent = Workspace

	local at = root.Position - Vector3.new(0, 2.6, 0)
	local scale = if realmBreak then 1.0 else 0.55

	--: Três anéis escalonados, não um. Um anel só lê como um pulso; três
	--: escalonados leem como algo abrindo caminho no ar.
	shockRing(host, at, colour, 34 * scale, 0.00, 2.2)
	shockRing(host, at, colour, 24 * scale, 0.10, 1.6)
	shockRing(host, at, colour, 46 * scale, 0.22, 1.1)

	column(host, at, colour, if realmBreak then 120 else 46,
		if realmBreak then 5 else 3)
	cloud(host, at, colour, scale)

	if realmBreak then
		sparks(host, at, colour)
	end

	--: Luz que some junto. Sem ela o clarão é só geometria clara; com ela o
	--: pátio inteiro muda de cor por um segundo, que é o que faz alguém do
	--: outro lado virar a cabeça.
	local flash = Instance.new("PointLight")
	flash.Color = colour
	flash.Brightness = if realmBreak then 14 else 6
	flash.Range = if realmBreak then 130 else 70
	flash.Shadows = false
	flash.Parent = host:FindFirstChild("Coluna") or root

	task.delay(LIFE, function()
		if host.Parent ~= nil then
			host:Destroy()
		end
	end)
end

function Ascension.start()
	Debug.info("avanço: choque, nuvem e coluna — e nenhum dano")
end

return Ascension
