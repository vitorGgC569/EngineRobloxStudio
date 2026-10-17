--!strict
--[[
	Mountain — a montanha da seita, construída em código.

	O que a tela mostra, e portanto o que este arquivo tem de produzir:

	    o taiji       um disco de yin-yang no chão, e é onde se medita
	    o pátio       pedra cinza-lavanda, com borda de nuvens
	    o pagode azul alquimia: caldeirões fumegando na base
	    o pagode rubro a torre da seita, vermelha e dourada
	    o paredão     tábuas de pergaminho com anciões parados na frente
	    o horizonte   montanhas azuis, árvores, céu saturado

	O yin-yang, que é o problema interessante
	-----------------------------------------

	Não existe primitivo com essa forma, e `UnionOperation` não se cria em
	runtime. A construção clássica com régua e compasso, porém, é feita só de
	círculos:

	    um disco preto e um branco, cada um a metade
	    um círculo de raio R/2 de cada lado, centrado na metade do eixo
	    um ponto de raio R/6 dentro de cada círculo, da cor oposta

	As duas metades saem de um leque de setores -- caixas finas giradas em
	torno do centro. A trinta e seis setores o erro de polígono fica abaixo do
	que se enxerga a dez studs, e o disco inteiro custa quarenta partes.

	Por que quase tudo aqui é ancorado
	----------------------------------

	Nada neste cenário deve ser simulado. Uma torre de nove andares sem âncora
	é uma conta de física por um enfeite, e a primeira coisa que a solução faz
	é derrubá-la.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Content = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Content"))

local Rng = Forge.Core.Rng
local Rig = Forge.Rig
local Interaction = Forge.Interaction

local Mountain = {}

local stream = Rng.stream("daocultivo.montanha")

--: O centro do mundo, e a única coordenada da qual todas as outras derivam.
--: Mover a seita é mudar esta linha, não trinta.
Mountain.ORIGIN = Vector3.new(0, 12, 0)
--: O raio do pátio. O taiji é uma fração dele, o paredão fica na borda, e as
--: montanhas começam bem depois -- todos em múltiplos deste número, para que
--: aumentar o pátio não deixe um pagode dentro de uma parede.
Mountain.PLAZA = 130
Mountain.TAIJI = 26

local PALETTE = {
	pedra = Color3.fromRGB(176, 172, 186),
	pedraEscura = Color3.fromRGB(126, 122, 140),
	juntas = Color3.fromRGB(206, 202, 214),
	--: Verde de montanha, não de campo de futebol. A 118,158,88 sob a
	--: iluminação `Future` deste lugar a campina saía néon, e uma campina néon
	--: puxa o olho para o chão em vez de para o pátio.
	grama = Color3.fromRGB(92, 122, 76),
	branco = Color3.fromRGB(242, 242, 238),
	preto = Color3.fromRGB(26, 26, 32),
	ouro = Color3.fromRGB(212, 168, 74),
	rubro = Color3.fromRGB(150, 44, 46),
	azulNoite = Color3.fromRGB(38, 52, 96),
	telhaAzul = Color3.fromRGB(52, 74, 128),
	madeira = Color3.fromRGB(94, 62, 44),
	montanha = Color3.fromRGB(96, 116, 148),
	jade = Color3.fromRGB(124, 202, 178),
}

--[[
	A pasta da seita, encontrada ou criada — uma vez, para todo mundo.

	Três sistemas escrevem no mundo: `Sect` ergue o pátio, `Zones` os terraços
	e `Hunt` o bosque. Cada um tinha o seu próprio "acha ou cria", e a ordem em
	que o bootstrap carrega sistemas **não é garantida**: `Zones` subiu
	primeiro numa execução, criou `Seita`, e o `Instance.new` de `Sect` criou
	uma **segunda** pasta com o mesmo nome. Os dois mundos existiam ao mesmo
	tempo, cada um com metade das coisas, e `FindFirstChild("Seita")` devolvia
	sempre a primeira.

	O sintoma foi um jogo com terraços, bosque e bestas e nenhum pátio -- e
	dez cenários dizendo que a seita tinha subido sem o taiji, o que soa como
	um erro de construção e era um erro de nome.

	Uma função, num módulo que os três já importam. É a correção inteira.
]]
function Mountain.root(): Instance
	local existing = Workspace:FindFirstChild("Seita")
	if existing ~= nil then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "Seita"
	folder.Parent = Workspace
	return folder
end

-- ============================================================= o primitivo

--: Uma parte ancorada, que é o único tipo de parte que este arquivo cria.
--: Escrever `Anchored = true` em quarenta lugares é como um deles fica de
--: fora, e o que fica de fora é sempre o que cai em cima do jogador.
local function block(parent: Instance, name: string, size: Vector3, cf: CFrame,
                     colour: Color3, material: Enum.Material?): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Color = colour
	part.Material = material or Enum.Material.Slate
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

--: Um cilindro deitado, com as faces circulares para cima. `PartType.Cylinder`
--: nasce com o círculo em ±X, então virar noventa graus em Z é o que
--: transforma um tubo num disco -- e essa rotação é a linha que se esquece.
local function disc(parent: Instance, name: string, centre: Vector3,
                    radius: number, height: number, colour: Color3,
                    material: Enum.Material?): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(height, radius * 2, radius * 2)
	part.CFrame = CFrame.new(centre) * CFrame.Angles(0, 0, math.pi / 2)
	part.Color = colour
	part.Material = material or Enum.Material.Marble
	part.Anchored = true
	part.Parent = parent
	return part
end

--[[
	Uma fatia de disco, como leque de caixas.

	`from` e `to` em radianos. Cada setor é uma caixa que sai do centro; a
	ponta é uma corda reta, então o resultado é um polígono. A trinta e seis
	setores por volta a diferença some, e é muito mais barato do que qualquer
	tentativa de recortar geometria em runtime.
]]
local function fan(parent: Instance, name: string, centre: Vector3, radius: number,
                   height: number, colour: Color3, from: number, to: number,
                   segments: number, material: Enum.Material?)
	local span = (to - from) / segments
	--: A corda mais um fio, para que os setores se sobreponham em vez de
	--: deixarem uma fresta de fundo aparecendo entre eles.
	local width = 2 * radius * math.tan(span / 2) * 1.06
	for index = 0, segments - 1 do
		local angle = from + span * (index + 0.5)
		local middle = centre + Vector3.new(
			math.cos(angle) * radius * 0.5, 0, math.sin(angle) * radius * 0.5)
		block(parent, name .. index, Vector3.new(radius, height, width),
			CFrame.new(middle) * CFrame.Angles(0, -angle, 0), colour, material)
	end
end

-- ================================================================== o taiji

--[[
	O disco de meditação.

	Fica um dedo acima do pátio, porque um disco rente ao chão briga por
	pixels com a pedra embaixo (z-fighting) e pisca conforme a câmera anda.
]]
function Mountain.taiji(parent: Instance): BasePart
	local folder = Instance.new("Folder")
	folder.Name = "Taiji"
	folder.Parent = parent

	local centre = Mountain.ORIGIN + Vector3.new(0, 0.35, 0)
	local R = Mountain.TAIJI
	local H = 0.7

	--: As duas metades. O eixo de divisão é Z, então as metades são leste e
	--: oeste, e as duas cabeças do S ficam no eixo X.
	fan(folder, "Yin", centre, R, H, PALETTE.preto, -math.pi / 2, math.pi / 2, 24,
		Enum.Material.Slate)
	fan(folder, "Yang", centre, R, H, PALETTE.branco, math.pi / 2, math.pi * 1.5, 24,
		Enum.Material.Marble)

	--: As duas cabeças do S, meio raio cada, centradas na metade do eixo.
	local half = R * 0.5
	disc(folder, "CabecaBranca", centre + Vector3.new(0, 0.03, -half), half, H,
		PALETTE.branco, Enum.Material.Marble)
	disc(folder, "CabecaPreta", centre + Vector3.new(0, 0.03, half), half, H,
		PALETTE.preto, Enum.Material.Slate)

	--: Os dois olhos. Cada um da cor do lado oposto, que é a única coisa que
	--: distingue um taiji de dois caracóis.
	local eye = R / 6
	disc(folder, "OlhoPreto", centre + Vector3.new(0, 0.06, -half), eye, H,
		PALETTE.preto, Enum.Material.Slate)
	disc(folder, "OlhoBranco", centre + Vector3.new(0, 0.06, half), eye, H,
		PALETTE.branco, Enum.Material.Marble)

	--: A borda de nuvens: um anel de blocos claros, cada um virado para fora.
	local rim = 30
	for index = 0, rim - 1 do
		local angle = index / rim * math.pi * 2
		local at = Mountain.ORIGIN + Vector3.new(
			math.cos(angle) * (R + 1.6), 0.55, math.sin(angle) * (R + 1.6))
		local tile = block(folder, "Nuvem" .. index, Vector3.new(3.4, 0.9, 2.6),
			CFrame.new(at) * CFrame.Angles(0, -angle, 0),
			if index % 2 == 0 then PALETTE.juntas else PALETTE.branco,
			Enum.Material.Marble)
		tile.CanCollide = false
	end

	--: A âncora de meditação: invisível, no centro, e é o que a interação e a
	--: câmera do cliente usam como alvo. Uma parte nomeada vale mais que uma
	--: coordenada repetida em três arquivos.
	local anchor = block(folder, "AnelDeMeditacao", Vector3.new(2, 1, 2),
		CFrame.new(Mountain.ORIGIN + Vector3.new(0, 1, 0)), PALETTE.jade)
	anchor.Transparency = 1
	anchor.CanCollide = false
	return anchor
end

-- ================================================================= o pátio

function Mountain.plaza(parent: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "Patio"
	folder.Parent = parent

	--[[
		A campina é **terreno**, não uma laje verde.

		A diferença é grande e barata: o terreno do Roblox desenha a grama com
		textura, variação e sombreamento próprios, enquanto uma `Part` com
		`Material.Grass` fica achatada e uniforme -- que é a razão de o chão
		ler como feltro nas primeiras fotos. O preenchimento inteiro custou
		**3,4 milissegundos** medidos no Studio vivo.

		O que o terreno **não** dá aqui: grama que balança. `Terrain.Decoration`
		não existe nesta versão do Studio (0.737) -- conferido, junto com
		`GrassLength`, `Grass` e `DecorationEnabled`, todos ausentes. Adivinhar
		o nome novo seria escrever uma propriedade que não existe, que nesta
		engine não dá erro: apenas não faz nada. Então a grama que se mexe é
		feita à mão em `Mountain.meadow`.

		Depois de encher, o pátio é **escavado** com um cilindro de ar. Sem
		isso o terreno sobe até o topo das lajes e engole a pedra inteira --
		foi o que a primeira tentativa fez. O cilindro é vertical sem rotação
		nenhuma, o que também foi conferido lendo voxels dos dois lados da
		borda, não lembrado.
	]]
	local terrain = Workspace.Terrain
	local carved = pcall(function()
		terrain:FillBlock(
			CFrame.new(Mountain.ORIGIN - Vector3.new(0, 5, 0)),
			Vector3.new(1400, 10, 1400), Enum.Material.Grass)
		terrain:FillCylinder(
			CFrame.new(Mountain.ORIGIN - Vector3.new(0, 2, 0)),
			10, Mountain.PLAZA + 6, Enum.Material.Air)
	end)

	--: A rede de segurança. Se o terreno não subir -- e ele é a única coisa
	--: aqui que depende de um serviço do motor -- ninguém pode cair para
	--: sempre. Uma laje bem abaixo custa uma parte e evita isso.
	if not carved then
		block(folder, "Campina", Vector3.new(1400, 8, 1400),
			CFrame.new(Mountain.ORIGIN - Vector3.new(0, 4, 0)),
			PALETTE.grama, Enum.Material.Grass)
	else
		local net = block(folder, "RedeDeSeguranca", Vector3.new(1600, 4, 1600),
			CFrame.new(Mountain.ORIGIN - Vector3.new(0, 26, 0)),
			PALETTE.grama, Enum.Material.Slate)
		net.Transparency = 1
	end

	--: A pedra do pátio, em ladrilho. Dois tons alternados: uma laje única de
	--: 260 studs lê como um estacionamento, por melhor que seja a cor.
	local tile = 13
	local count = math.floor(Mountain.PLAZA * 2 / tile)
	for x = 0, count - 1 do
		for z = 0, count - 1 do
			local at = Mountain.ORIGIN + Vector3.new(
				-Mountain.PLAZA + (x + 0.5) * tile, -0.4,
				-Mountain.PLAZA + (z + 0.5) * tile)
			--: Fora do círculo do pátio não há pedra: um pátio quadrado num
			--: mundo redondo é a coisa que denuncia geometria gerada.
			local flat = Vector2.new(at.X - Mountain.ORIGIN.X, at.Z - Mountain.ORIGIN.Z)
			if flat.Magnitude > Mountain.PLAZA then
				continue
			end
			block(folder, "Laje", Vector3.new(tile - 0.35, 1.4, tile - 0.35),
				CFrame.new(at),
				if (x + z) % 2 == 0 then PALETTE.pedra else PALETTE.pedraEscura,
				Enum.Material.Slate)
		end
	end

	--: Os degraus que descem para a campina, ao sul, e a razão de haver um
	--: sul: é para onde o portal aponta e por onde o jogador entra.
	for step = 1, 5 do
		block(folder, "Degrau" .. step,
			Vector3.new(46 - step * 2, 1.2, 4),
			CFrame.new(Mountain.ORIGIN + Vector3.new(0, -0.4 - step * 1.1,
				Mountain.PLAZA + step * 3.4)),
			PALETTE.pedra, Enum.Material.Slate)
	end
end

-- ================================================================== a grama

--[[
	Grama que balança, feita à mão.

	`Terrain.Decoration` -- a grama nativa do Roblox -- **não existe nesta
	versão do Studio**, e isso foi conferido propriedade por propriedade em vez
	de suposto. Sem ela, o único jeito honesto é construir as folhas.

	A economia do desenho é o que importa aqui. Uma campina inteira coberta de
	folhas seria dezenas de milhares de partes; o que se faz é cobrir **onde o
	jogador anda e olha** -- o anel logo fora do pátio, entre o portal e a
	borda -- com tufos, e deixar o resto para a textura do terreno, que já é
	boa.

	Cada folha guarda a própria base, o próprio giro e a própria fase em
	atributos, para que o cliente possa balançá-las sem uma tabela paralela que
	precise ser mantida em sincronia com as instâncias.
]]
function Mountain.meadow(parent: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "Grama"
	folder.Parent = parent

	local clumps = 46
	for clump = 1, clumps do
		--: Distribuição uniforme por **área**, e não por raio. A área de um
		--: anel cresce com o raio, então sortear o raio direto amontoa tudo na
		--: borda de dentro -- o mesmo erro que amontoou as bestas no centro da
		--: clareira.
		local angle = stream:number(0, math.pi * 2)
		local inner, outer = Mountain.PLAZA + 10, Mountain.PLAZA + 132
		local radius = math.sqrt(stream:number()) * (outer - inner) + inner
		local centre = Mountain.ORIGIN + Vector3.new(
			math.cos(angle) * radius, 0, math.sin(angle) * radius)

		for blade = 1, 9 do
			local spot = centre + Vector3.new(
				stream:number(-3.4, 3.4), 0, stream:number(-3.4, 3.4))
			local height = stream:number(1.9, 3.6)
			local yaw = stream:number(0, math.pi * 2)

			local leaf = Instance.new("Part")
			leaf.Name = "Folha"
			leaf.Size = Vector3.new(0.26, height, 0.1)
			leaf.CFrame = CFrame.new(spot + Vector3.new(0, height / 2, 0))
				* CFrame.Angles(0, yaw, 0)
			leaf.Color = Color3.fromRGB(
				math.floor(stream:number(78, 116)),
				math.floor(stream:number(126, 168)),
				math.floor(stream:number(56, 84)))
			leaf.Material = Enum.Material.Grass
			leaf.Anchored = true
			leaf.CanCollide = false
			--: Sem consulta e sem toque: uma folha que o raycast do combate
			--: acerta é uma folha que come um golpe.
			leaf.CanQuery = false
			leaf.CanTouch = false
			leaf.CastShadow = false
			leaf:SetAttribute("baseX", spot.X)
			leaf:SetAttribute("baseY", spot.Y)
			leaf:SetAttribute("baseZ", spot.Z)
			leaf:SetAttribute("giro", yaw)
			leaf:SetAttribute("altura", height)
			leaf:SetAttribute("fase", stream:number(0, math.pi * 2))
			leaf.Parent = folder
		end
	end
end

-- ================================================================ o pagode

--[[
	Uma torre de N andares, cada um menor que o de baixo.

	O que faz ler como pagode não é o corpo e sim o beiral: um telhado que
	avança bem além da parede, e canta nas pontas. As pontas aqui são quatro
	blocos inclinados por andar, que a essa distância é tudo o que a silhueta
	precisa.
]]
function Mountain.pagoda(parent: Instance, at: Vector3, tiers: number,
                          body: Color3, roof: Color3, name: string): Model
	local model = Instance.new("Model")
	model.Name = name
	model.Parent = parent

	--: A base de pedra. Sem ela a torre parece plantada na grama, e um pagode
	--: sem plataforma parece um brinquedo.
	block(model, "Base", Vector3.new(38, 3, 38), CFrame.new(at),
		PALETTE.pedra, Enum.Material.Slate)

	local floorHeight = 11
	local y = at.Y + 1.5
	for tier = 1, tiers do
		local shrink = 1 - (tier - 1) * (0.62 / tiers)
		local width = 26 * shrink
		local centre = Vector3.new(at.X, y + floorHeight / 2, at.Z)

		block(model, "Andar" .. tier, Vector3.new(width, floorHeight, width),
			CFrame.new(centre), body, Enum.Material.WoodPlanks)

		--: Colunas de canto em vermelho-laca. É o detalhe que separa uma caixa
		--: colorida de um prédio.
		for _, corner in { Vector2.new(1, 1), Vector2.new(1, -1),
		                   Vector2.new(-1, 1), Vector2.new(-1, -1) } do
			block(model, "Coluna" .. tier,
				Vector3.new(1.6, floorHeight, 1.6),
				CFrame.new(centre + Vector3.new(
					corner.X * width / 2, 0, corner.Y * width / 2)),
				PALETTE.rubro, Enum.Material.Wood)
		end

		--: A janela de cada face, escura e rasa. Um pagode sem aberturas é uma
		--: torre de queijo.
		for face = 0, 3 do
			local angle = face * math.pi / 2
			block(model, "Janela" .. tier .. face,
				Vector3.new(width * 0.42, floorHeight * 0.44, 0.4),
				CFrame.new(centre + Vector3.new(
					math.sin(angle) * (width / 2 + 0.1), 1.2,
					math.cos(angle) * (width / 2 + 0.1)))
					* CFrame.Angles(0, angle, 0),
				PALETTE.azulNoite, Enum.Material.Glass)
		end

		--: O beiral: a laje que avança, e as quatro pontas erguidas.
		local eave = width * 1.62
		y += floorHeight
		block(model, "Telhado" .. tier, Vector3.new(eave, 1.6, eave),
			CFrame.new(at.X, y + 0.8, at.Z), roof, Enum.Material.Slate)
		block(model, "Cumeeira" .. tier, Vector3.new(eave * 0.7, 1.4, eave * 0.7),
			CFrame.new(at.X, y + 2.1, at.Z), roof, Enum.Material.Slate)
		for face = 0, 3 do
			local angle = face * math.pi / 2 + math.pi / 4
			block(model, "Ponta" .. tier .. face, Vector3.new(6, 0.8, 1.4),
				CFrame.new(at.X + math.cos(angle) * eave * 0.52, y + 2.4,
					at.Z + math.sin(angle) * eave * 0.52)
					* CFrame.Angles(0, -angle, math.rad(-22)),
				PALETTE.ouro, Enum.Material.Metal)
		end
		y += 2.6
	end

	--: A agulha e a pérola. A silhueta de um pagode termina em ponta; sem
	--: isso a torre fica com cara de bolo.
	block(model, "Agulha", Vector3.new(1.2, 9, 1.2),
		CFrame.new(at.X, y + 4.5, at.Z), PALETTE.ouro, Enum.Material.Metal)
	local pearl = Instance.new("Part")
	pearl.Name = "Perola"
	pearl.Shape = Enum.PartType.Ball
	pearl.Size = Vector3.new(3.4, 3.4, 3.4)
	pearl.Position = Vector3.new(at.X, y + 10.4, at.Z)
	pearl.Color = PALETTE.ouro
	pearl.Material = Enum.Material.Neon
	pearl.Anchored = true
	pearl.CanCollide = false
	pearl.Parent = model

	local glow = Instance.new("PointLight")
	glow.Color = PALETTE.ouro
	glow.Brightness = 1.4
	glow.Range = 34
	glow.Parent = pearl

	return model
end

-- ============================================================== a alquimia

--: Os caldeirões do pagode azul. Fumegam, e a fumaça é a razão de existirem:
--: é o único movimento constante do cenário, e um cenário sem movimento
--: nenhum lê como tela de carregamento por mais bonito que seja.
function Mountain.cauldrons(parent: Instance, at: Vector3)
	local folder = Instance.new("Folder")
	folder.Name = "Caldeiroes"
	folder.Parent = parent

	for index = -1, 1 do
		local spot = at + Vector3.new(index * 13, 2.6, 22)
		disc(folder, "Fornalha" .. index, spot - Vector3.new(0, 2, 0), 5.2, 1.6,
			PALETTE.pedraEscura, Enum.Material.Slate)

		local pot = Instance.new("Part")
		pot.Name = "Caldeirao" .. index
		pot.Shape = Enum.PartType.Ball
		pot.Size = Vector3.new(9, 8, 9)
		pot.Position = spot + Vector3.new(0, 1.4, 0)
		pot.Color = Color3.fromRGB(58, 54, 62)
		pot.Material = Enum.Material.Metal
		pot.Anchored = true
		pot.Parent = folder

		local mouth = disc(folder, "Boca" .. index, spot + Vector3.new(0, 5, 0),
			4.2, 0.6, Color3.fromRGB(214, 128, 62), Enum.Material.Neon)
		mouth.CanCollide = false

		--: Sem `Texture`. O padrão do `ParticleEmitter` já é uma mancha macia,
		--: e um `rbxasset://` escrito de memória é o modo de falha silencioso
		--: desta engine: o caminho errado não dá erro, só não desenha nada --
		--: e a engine inteira não referencia um único asset de textura por
		--: exatamente esse motivo.
		local smoke = Instance.new("ParticleEmitter")
		smoke.Rate = 6
		smoke.Lifetime = NumberRange.new(3.4, 5.2)
		smoke.Speed = NumberRange.new(3, 5)
		smoke.Size = NumberSequence.new(3.4)
		smoke.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.75),
			NumberSequenceKeypoint.new(1, 1),
		})
		smoke.Color = ColorSequence.new(Color3.fromRGB(198, 208, 216))
		smoke.Parent = mouth

		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(255, 148, 68)
		light.Brightness = 1.6
		light.Range = 22
		light.Parent = mouth
	end
end

-- ================================================================ o paredão

--[[
	O muro de tábuas ao norte, e os anciões diante dele.

	As tábuas são o que a tela de origem mostra ao fundo: painéis verticais de
	pergaminho, cada um numa moldura escura. Aqui elas dizem alguma coisa --
	cada tábua leva o nome de um realm de Qi, na ordem, então o muro é a
	escada inteira do jogo escrita na parede.
]]
function Mountain.boards(parent: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "Paredao"
	folder.Parent = parent

	local z = Mountain.ORIGIN.Z - Mountain.PLAZA * 0.82
	block(folder, "Muro", Vector3.new(190, 26, 4),
		CFrame.new(Mountain.ORIGIN.X, Mountain.ORIGIN.Y + 12, z),
		PALETTE.pedraEscura, Enum.Material.Slate)
	block(folder, "Beiral", Vector3.new(198, 2.2, 9),
		CFrame.new(Mountain.ORIGIN.X, Mountain.ORIGIN.Y + 26, z),
		PALETTE.rubro, Enum.Material.Slate)

	local slots = 9
	for index = 1, slots do
		local x = Mountain.ORIGIN.X + (index - (slots + 1) / 2) * 20
		local board = block(folder, "Tabua" .. index, Vector3.new(13, 17, 0.8),
			CFrame.new(x, Mountain.ORIGIN.Y + 12, z + 2.4),
			Color3.fromRGB(226, 214, 182), Enum.Material.Sand)
		block(folder, "Moldura" .. index, Vector3.new(14.4, 18.6, 0.5),
			CFrame.new(x, Mountain.ORIGIN.Y + 12, z + 2.1),
			PALETTE.madeira, Enum.Material.Wood)

		--[[
			O texto vai numa `SurfaceGui`, virada para o pátio.

			`Face` é a metade que se erra: uma GUI na face errada existe,
			replica e não aparece, e nada no jogo diz que ela está lá.

			`SizingDefinition` **não existe** nesta versão do Studio (0.737) --
			e o `Enum` também não, então escrever a linha derruba o script
			inteiro com "SurfaceGuiSizingDefinition is not a valid member of
			Enum". Foi o que aconteceu: um enum escrito de memória custou a
			montanha inteira, porque tudo depois desta linha em `Sect.start`
			deixou de rodar. `PixelsPerStud` sozinho existe e é o modo padrão.
		]]
		local surface = Instance.new("SurfaceGui")
		surface.Face = Enum.NormalId.Front
		surface.PixelsPerStud = 24
		surface.LightInfluence = 0.4
		surface.Parent = board

		local realm = Content.qiRealms[index]
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Text = string.format("%s\n\n<font size=\"22\">%s</font>",
			realm and realm.name or "?", realm and realm.note or "")
		label.RichText = true
		label.TextWrapped = true
		label.TextColor3 = Color3.fromRGB(58, 40, 30)
		label.TextSize = 34
		label.Font = Enum.Font.Merriweather
		label.Parent = surface
	end
end

-- ================================================================ os anciões

--: Quatro figuras paradas diante do muro. Não fazem nada, e é exatamente por
--: isso que estão aqui: um pátio vazio lê como cenário, um pátio com gente
--: parada lê como lugar.
function Mountain.elders(parent: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "Anciaos"
	folder.Parent = parent

	local looks = {
		{ nome = "Ancião do Fogo Interior", body = PALETTE.rubro, weapon = "staff" },
		{ nome = "Guardiã do Salão de Jade", body = PALETTE.jade, weapon = "sword" },
		{ nome = "Mestre do Caldeirão", body = PALETTE.azulNoite, weapon = nil },
		{ nome = "Escriba das Nove Tábuas", body = PALETTE.ouro, weapon = "staff" },
	}
	local z = Mountain.ORIGIN.Z - Mountain.PLAZA * 0.82 + 12
	for index, look in looks do
		local ok, model = pcall(function()
			return Rig.build({
				name = look.nome,
				scale = 1.05,
				shape = "biped",
				body = look.body,
				accent = look.body:Lerp(Color3.new(1, 1, 1), 0.45),
				eyes = Color3.fromRGB(255, 236, 190),
				glow = index == 4,
				weapon = look.weapon,
				collide = false,
				detail = true,
			})
		end)
		if not ok or model == nil then
			continue
		end
		for _, part in (model :: Model):GetDescendants() do
			if part:IsA("BasePart") then
				part.Anchored = true
				part.CanCollide = false
			end
		end
		local at = Vector3.new(Mountain.ORIGIN.X + (index - 2.5) * 26,
			Mountain.ORIGIN.Y + 3, z)
		;(model :: Model):PivotTo(CFrame.new(at) * CFrame.Angles(0, math.pi, 0))
		model.Parent = folder

		--: O nome sobre a cabeça, porque um NPC sem nome é um enfeite. Um
		--: `BillboardGui` numa parte que existe: `PrimaryPart` de um rig
		--: construído pode ser nil, e um billboard sem pai visível é o tipo
		--: de nada que não dá erro.
		local head = (model :: Model):FindFirstChild("Head")
			or (model :: Model).PrimaryPart
		if head ~= nil and head:IsA("BasePart") then
			local plate = Instance.new("BillboardGui")
			plate.Size = UDim2.fromOffset(190, 26)
			plate.StudsOffsetWorldSpace = Vector3.new(0, 3.2, 0)
			plate.AlwaysOnTop = false
			--: Setenta studs. A largura do pátio é 260, então o nome de um
			--: ancião do outro lado não desenha -- e essa é a diferença entre
			--: uma seita e uma tela coberta de legendas.
			plate.MaxDistance = 70
			plate.Parent = head

			local text = Instance.new("TextLabel")
			text.Size = UDim2.fromScale(1, 1)
			text.BackgroundTransparency = 1
			text.Text = look.nome
			text.TextColor3 = PALETTE.ouro
			text.TextStrokeTransparency = 0.2
			text.TextScaled = true
			text.Font = Enum.Font.Merriweather
			text.Parent = plate
		end
	end
end

-- ============================================================ as montanhas

--: O horizonte. Cones de blocos empilhados, longe o bastante para a névoa
--: comer a escadinha da silhueta. É o que transforma um pátio numa montanha.
function Mountain.horizon(parent: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "Horizonte"
	folder.Parent = parent

	for index = 1, 16 do
		local angle = index / 16 * math.pi * 2 + stream:number(-0.12, 0.12)
		local distance = stream:number(400, 620)
		local peak = stream:number(120, 260)
		local base = peak * stream:number(0.9, 1.4)
		local at = Mountain.ORIGIN + Vector3.new(
			math.cos(angle) * distance, -6, math.sin(angle) * distance)

		local steps = 7
		for level = 1, steps do
			local t = (level - 1) / steps
			local width = base * (1 - t) + 8
			local height = peak / steps
			local tint = PALETTE.montanha:Lerp(Color3.fromRGB(232, 238, 248), t * 0.55)
			local slab = block(folder, "Cume" .. index .. "_" .. level,
				Vector3.new(width, height * 1.25, width),
				CFrame.new(at + Vector3.new(0, height * (level - 0.5), 0))
					* CFrame.Angles(0, angle + level * 0.11, 0),
				tint, Enum.Material.Rock)
			slab.CanCollide = false
		end
	end
end

-- ========================================================= as veias de pedra

--[[
	As veias espirituais: cristais que se colhem e voltam.

	É o único caminho pelo qual pedra espiritual entra sem um avanço, e por
	isso é o que dá ao jogador algo para fazer com as pernas enquanto a poça
	enche. Um jogo de cultivo em que só se senta é um protetor de tela.
]]
function Mountain.veins(parent: Instance, onHarvest: (Player, number) -> ())
	local folder = Instance.new("Folder")
	folder.Name = "Veias"
	folder.Parent = parent

	local spots = {}
	for index = 1, 7 do
		local angle = index / 7 * math.pi * 2 + 0.4
		local radius = stream:number(Mountain.PLAZA * 0.55, Mountain.PLAZA * 0.92)
		table.insert(spots, Mountain.ORIGIN + Vector3.new(
			math.cos(angle) * radius, 1.4, math.sin(angle) * radius))
	end

	for index, at in spots do
		local cluster = Instance.new("Model")
		cluster.Name = "Veia" .. index
		cluster.Parent = folder

		local core: BasePart? = nil
		for shard = 1, 4 do
			local tall = stream:number(4.5, 9)
			local crystal = block(cluster, "Cristal" .. shard,
				Vector3.new(1.7, tall, 1.7),
				CFrame.new(at + Vector3.new(
					stream:number(-2.2, 2.2), tall / 2, stream:number(-2.2, 2.2)))
					* CFrame.Angles(stream:number(-0.24, 0.24),
						stream:number(0, math.pi), stream:number(-0.24, 0.24)),
				PALETTE.jade, Enum.Material.Neon)
			crystal.CanCollide = false
			crystal.Transparency = 0.15
			if shard == 1 then
				core = crystal
			end
		end
		if core == nil then
			continue
		end
		cluster.PrimaryPart = core

		local light = Instance.new("PointLight")
		light.Color = PALETTE.jade
		light.Brightness = 2
		light.Range = 20
		light.Parent = core

		--: Estado no próprio modelo, não numa tabela paralela. Uma tabela
		--: indexada por instância sobrevive à instância, e uma veia colhida
		--: que foi destruída continua "colhida" para sempre.
		cluster:SetAttribute("pronta", true)

		Interaction.register(cluster, {
			id = "veia",
			label = "Colher",
			objectLabel = "Veia Espiritual",
			range = 14,
			holdDuration = 0.6,
			condition = function()
				return cluster:GetAttribute("pronta") == true
			end,
			onTrigger = function(player: Player)
				if cluster:GetAttribute("pronta") ~= true then
					return
				end
				cluster:SetAttribute("pronta", false)
				for _, part in cluster:GetDescendants() do
					if part:IsA("BasePart") then
						part.Transparency = 0.88
						part.Material = Enum.Material.Glass
					end
				end
				light.Enabled = false
				onHarvest(player, 12 + math.floor(stream:number(0, 9)))

				task.delay(40, function()
					if cluster.Parent == nil then
						return
					end
					cluster:SetAttribute("pronta", true)
					for _, part in cluster:GetDescendants() do
						if part:IsA("BasePart") then
							part.Transparency = 0.15
							part.Material = Enum.Material.Neon
						end
					end
					light.Enabled = true
				end)
			end,
		})
	end
end

-- ================================================================ o portal

--: O torii ao sul, sobre os degraus. É a moldura pela qual o jogador vê o
--: pátio da primeira vez, e uma entrada emoldurada é a diferença entre
--: chegar num lugar e aparecer nele.
function Mountain.gate(parent: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "Portal"
	folder.Parent = parent

	local z = Mountain.ORIGIN.Z + Mountain.PLAZA + 20
	for side = -1, 1, 2 do
		block(folder, "Pilar", Vector3.new(3.4, 34, 3.4),
			CFrame.new(Mountain.ORIGIN.X + side * 15, Mountain.ORIGIN.Y + 15, z),
			PALETTE.rubro, Enum.Material.Wood)
	end
	block(folder, "Verga", Vector3.new(48, 3, 4.4),
		CFrame.new(Mountain.ORIGIN.X, Mountain.ORIGIN.Y + 31, z),
		PALETTE.rubro, Enum.Material.Wood)
	block(folder, "Chapeu", Vector3.new(56, 2.4, 6),
		CFrame.new(Mountain.ORIGIN.X, Mountain.ORIGIN.Y + 34, z),
		PALETTE.preto, Enum.Material.Slate)
	block(folder, "Placa", Vector3.new(12, 5, 1),
		CFrame.new(Mountain.ORIGIN.X, Mountain.ORIGIN.Y + 27, z - 2.6),
		PALETTE.ouro, Enum.Material.Metal)
end

-- ================================================================ o começo

function Mountain.spawn(parent: Instance)
	--: Nasce sob o portal, olhando para o taiji. Um spawn no centro põe o
	--: jogador dentro da coisa que ele deveria estar vendo de longe.
	local pad = Instance.new("SpawnLocation")
	pad.Name = "Chegada"
	pad.Size = Vector3.new(14, 1, 14)
	pad.CFrame = CFrame.new(Mountain.ORIGIN + Vector3.new(0, 0.6, Mountain.PLAZA + 14))
	pad.Anchored = true
	pad.Color = PALETTE.ouro
	pad.Material = Enum.Material.Marble
	pad.Transparency = 0.35
	pad.TopSurface = Enum.SurfaceType.Smooth
	pad.Duration = 0
	pad.Parent = parent
end

return Mountain
