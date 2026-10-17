--!strict
--[[
	Scenery — o que faz a montanha parecer uma montanha.

	A crítica que gerou este arquivo foi curta e certa: pouca melhoria gráfica.
	E o diagnóstico não era textura, era **forma**. Tudo eram caixas de cor
	chapada, e o horizonte -- que ocupa um terço de cada quadro -- eram cubos
	empilhados com degraus visíveis a quatrocentos studs.

	O que este arquivo troca, em ordem de área de tela:

	    horizonte   cubos empilhados  ->  terreno de rocha com neve no cume
	    água        nenhuma           ->  lago e lagoa, que refletem e ondulam
	    ar          vazio             ->  pétalas caindo e névoa rasteira
	    árvores     cinzas do catálogo ->  cerejeiras construídas em código

	Por que terreno e não mais partes
	---------------------------------

	Medido no Studio vivo antes de escrever qualquer coisa: uma bola de raio 90
	custa **2 ms**, cem colunas custam 2,9 ms, uma cunha custa meio
	milissegundo. Preencher terreno é barato o bastante para ser a resposta
	padrão, e o terreno traz de graça o que nenhuma `Part` traz: textura de
	rocha com variação, sombra própria, e uma silhueta que não é uma escada.

	Por que as cerejeiras são código e não catálogo
	-----------------------------------------------

	As árvores do `ItchAssets` chegavam cinzas -- o modelo não tem cor e uma
	silhueta de vinte studs o `Tint` não salva. Uma cerejeira construída aqui
	custa nove partes, tem exatamente a cor que a cena precisa, e é a imagem
	mais reconhecível do gênero. O catálogo continua servindo para arbusto e
	pedra, onde cinza é uma cor aceitável.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local Mountain = require(script.Parent:WaitForChild("Mountain"))

local Rng = Forge.Core.Rng
local Debug = Forge.Debug

local Scenery = {}

local stream = Rng.stream("daocultivo.cenario")

-- ============================================================== o horizonte

--[[
	Um pico de terreno, feito de colunas.

	A altura de cada coluna é uma queda radial vezes ruído: a queda dá a forma
	de montanha, o ruído tira a simetria de cone. Sem o ruído sai um chapéu de
	bruxa; sem a queda sai um platô.

	Colunas e não uma bola porque uma bola de terreno é uma **colina**, e o que
	falta neste horizonte é justamente altura com ombros irregulares. E porque
	cem colunas custam três milissegundos, o que torna a pergunta irrelevante.
]]
local function peak(terrain: Terrain, at: Vector3, radius: number, height: number,
                    seed: number)
	local step = 18
	local reach = math.ceil(radius / step)
	local base = Mountain.ORIGIN.Y - 20

	for gx = -reach, reach do
		for gz = -reach, reach do
			local offset = Vector2.new(gx * step, gz * step)
			local distance = offset.Magnitude / radius
			if distance > 1 then
				continue
			end
			--: Queda suave até a borda. O cosseno evita o bico que uma queda
			--: linear deixa no topo.
			local falloff = (math.cos(distance * math.pi) + 1) * 0.5
			local noise = Rng.fbm01(
				(at.X + offset.X) * 0.004 + seed,
				(at.Z + offset.Y) * 0.004 + seed)
			local top = base + height * falloff * (0.55 + noise * 0.75)
			local depth = top - base
			if depth < 6 then
				continue
			end
			--: Neve só no terço de cima, e só onde a coluna é realmente alta.
			--: Neve na base transforma a montanha num bolo de aniversário.
			local material = if depth > height * 0.72
				then Enum.Material.Snow
				else Enum.Material.Rock
			terrain:FillBlock(
				CFrame.new(at.X + offset.X, base + depth / 2, at.Z + offset.Y),
				Vector3.new(step + 4, depth, step + 4),
				material)
		end
	end
end

function Scenery.horizon()
	local terrain = Workspace.Terrain
	--: Catorze picos num anel largo, com raio e altura sorteados. O anel é o
	--: que o jogador vê por cima do muro de qualquer ponto do pátio.
	for index = 1, 14 do
		local angle = index / 14 * math.pi * 2 + stream:number(-0.16, 0.16)
		local distance = stream:number(430, 640)
		local at = Mountain.ORIGIN + Vector3.new(
			math.cos(angle) * distance, 0, math.sin(angle) * distance)
		peak(terrain, at, stream:number(150, 250), stream:number(140, 290), index * 7)
	end
end

-- ==================================================================== a água

--[[
	Água de terreno, que é a única que reflete.

	`Visual.Sky` já ajusta reflexo, transparência e onda -- o que faltava era
	haver água. Um lago muda uma cena mais do que qualquer textura: ele
	devolve o céu, o pagode e a aura de quem estiver perto, de graça.

	O lago fica no terraço do **Lago do Espírito Congelado**, porque um terraço
	com esse nome e sem água é uma piada que o jogador percebe.
]]
function Scenery.water()
	local terrain = Workspace.Terrain

	--: A lagoa do pátio, fora da pedra e perto do portal. Rasa: fundo a três
	--: studs, para que ninguém se afogue no caminho de casa.
	local pond = Mountain.ORIGIN + Vector3.new(-96, 0, 118)
	terrain:FillCylinder(
		CFrame.new(pond.X, Mountain.ORIGIN.Y - 3, pond.Z), 8, 34,
		Enum.Material.Air)
	terrain:FillCylinder(
		CFrame.new(pond.X, Mountain.ORIGIN.Y - 4, pond.Z), 6, 32,
		Enum.Material.Water)

	--: A margem de pedra, para a água não terminar num corte reto de grama.
	for index = 1, 22 do
		local angle = index / 22 * math.pi * 2
		local at = pond + Vector3.new(
			math.cos(angle) * 35, -1, math.sin(angle) * 35)
		local rock = Instance.new("Part")
		rock.Name = "Margem"
		rock.Size = Vector3.new(
			stream:number(4, 8), stream:number(2, 4), stream:number(4, 8))
		rock.CFrame = CFrame.new(at) * CFrame.Angles(
			stream:number(-0.3, 0.3), stream:number(0, 6.28), stream:number(-0.3, 0.3))
		rock.Color = Color3.fromRGB(122, 118, 126)
		rock.Material = Enum.Material.Rock
		rock.Anchored = true
		rock.CanCollide = false
		rock.Parent = Workspace.Seita
	end
end

-- ================================================================ as pétalas

--[[
	Pétalas caindo, e névoa rasteira.

	É a coisa mais barata deste arquivo e a que mais muda a leitura da cena.
	Um pátio parado lê como maquete; o mesmo pátio com algo descendo devagar no
	ar lê como um lugar onde o tempo passa.

	Emissores no **teto** de uma parte invisível larga, apontando para baixo.
	Um emissor por pétala seria absurdo; três emissores cobrem o pátio inteiro.
]]
function Scenery.air(parent: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "Ar"
	folder.Parent = parent

	for index = -1, 1 do
		local sky = Instance.new("Part")
		sky.Name = "Petalas" .. index
		sky.Size = Vector3.new(140, 1, 140)
		sky.Position = Mountain.ORIGIN + Vector3.new(index * 90, 62, index * 40)
		sky.Transparency = 1
		sky.Anchored = true
		sky.CanCollide = false
		sky.CanQuery = false
		sky.CanTouch = false
		sky.Parent = folder

		local petals = Instance.new("ParticleEmitter")
		petals.Name = "Petala"
		petals.Rate = 14
		petals.Lifetime = NumberRange.new(11, 17)
		--: Devagar e para baixo. `Drag` faz a pétala perder velocidade e
		--: flutuar em vez de cair como pedra, que é a diferença entre pétala e
		--: granizo.
		petals.Speed = NumberRange.new(2, 5)
		petals.Acceleration = Vector3.new(2.5, -3.5, 1.5)
		petals.Drag = 1.6
		petals.Rotation = NumberRange.new(0, 360)
		petals.RotSpeed = NumberRange.new(-70, 70)
		petals.Size = NumberSequence.new(0.7)
		petals.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.12, 0.15),
			NumberSequenceKeypoint.new(0.85, 0.2),
			NumberSequenceKeypoint.new(1, 1),
		})
		petals.Color = ColorSequence.new(
			Color3.fromRGB(255, 196, 216), Color3.fromRGB(250, 226, 236))
		petals.LightInfluence = 0.6
		petals.EmissionDirection = Enum.NormalId.Bottom
		petals.SpreadAngle = Vector2.new(28, 28)
		petals.Parent = sky
	end

	--: A névoa rasteira, no anel entre o pátio e as montanhas. É o que dá
	--: profundidade a um terreno plano: sem ela, campina e horizonte encostam
	--: um no outro sem nada entre os dois.
	for index = 1, 16 do
		local angle = index / 16 * math.pi * 2
		local at = Mountain.ORIGIN + Vector3.new(
			math.cos(angle) * 300, 4, math.sin(angle) * 300)

		local anchor = Instance.new("Part")
		anchor.Name = "Nevoa" .. index
		anchor.Size = Vector3.new(2, 2, 2)
		anchor.Position = at
		anchor.Transparency = 1
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.CanQuery = false
		anchor.CanTouch = false
		anchor.Parent = folder

		local mist = Instance.new("ParticleEmitter")
		mist.Name = "Bruma"
		mist.Rate = 2
		mist.Lifetime = NumberRange.new(14, 22)
		mist.Speed = NumberRange.new(1, 3)
		mist.Size = NumberSequence.new(120)
		mist.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.3, 0.86),
			NumberSequenceKeypoint.new(0.8, 0.88),
			NumberSequenceKeypoint.new(1, 1),
		})
		mist.Color = ColorSequence.new(Color3.fromRGB(226, 236, 246))
		mist.LightInfluence = 1
		mist.SpreadAngle = Vector2.new(180, 180)
		mist.Parent = anchor
	end
end

-- ============================================================== as cerejeiras

--[[
	Uma cerejeira, em nove partes.

	As do catálogo chegavam cinzas: o modelo não traz cor, e uma silhueta de
	vinte studs o `Tint` não recupera. Construída aqui ela custa quase nada,
	tem exatamente o rosa que a cena pede, e é a imagem mais reconhecível do
	gênero -- um pátio de seita sem cerejeira não parece um pátio de seita.

	O tronco é inclinado de propósito. Uma árvore perfeitamente vertical lê
	como poste; dois graus de inclinação e um par de galhos tortos leem como
	árvore, e a diferença custa uma multiplicação.
]]
local function sakura(parent: Instance, at: Vector3, scale: number)
	local tree = Instance.new("Model")
	tree.Name = "Cerejeira"
	tree.Parent = parent

	local lean = CFrame.Angles(
		stream:number(-0.07, 0.07), stream:number(0, 6.28), stream:number(-0.07, 0.07))
	local height = 13 * scale

	local trunk = Instance.new("Part")
	trunk.Name = "Tronco"
	trunk.Size = Vector3.new(1.7 * scale, height, 1.7 * scale)
	trunk.CFrame = CFrame.new(at + Vector3.new(0, height / 2, 0)) * lean
	trunk.Color = Color3.fromRGB(74, 54, 48)
	trunk.Material = Enum.Material.Wood
	trunk.Anchored = true
	trunk.CanCollide = false
	trunk.Parent = tree
	tree.PrimaryPart = trunk

	for index = 1, 3 do
		local angle = index / 3 * math.pi * 2 + stream:number(-0.4, 0.4)
		local branch = Instance.new("Part")
		branch.Name = "Galho"
		branch.Size = Vector3.new(0.8 * scale, 6 * scale, 0.8 * scale)
		branch.CFrame = CFrame.new(at + Vector3.new(
			math.cos(angle) * 2.2 * scale, height * 0.78, math.sin(angle) * 2.2 * scale))
			* CFrame.Angles(math.cos(angle) * 0.5, 0, -math.sin(angle) * 0.5)
		branch.Color = Color3.fromRGB(74, 54, 48)
		branch.Material = Enum.Material.Wood
		branch.Anchored = true
		branch.CanCollide = false
		branch.Parent = tree
	end

	--: A copa: cinco bolas sobrepostas em rosas ligeiramente diferentes. Uma
	--: bola só lê como pirulito; cinco leem como folhagem.
	for index = 1, 5 do
		local angle = index / 5 * math.pi * 2
		local blossom = Instance.new("Part")
		blossom.Name = "Copa"
		blossom.Shape = Enum.PartType.Ball
		blossom.Size = Vector3.new(9, 7, 9) * scale * stream:number(0.8, 1.15)
		blossom.Position = at + Vector3.new(
			math.cos(angle) * 3.4 * scale,
			height * stream:number(0.92, 1.12),
			math.sin(angle) * 3.4 * scale)
		blossom.Color = Color3.fromRGB(
			math.floor(stream:number(238, 255)),
			math.floor(stream:number(160, 196)),
			math.floor(stream:number(196, 220)))
		blossom.Material = Enum.Material.Grass
		blossom.Anchored = true
		blossom.CanCollide = false
		blossom.CanQuery = false
		blossom.Transparency = 0.06
		blossom.Parent = tree
	end
end

function Scenery.grove(parent: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "Cerejeiras"
	folder.Parent = parent

	for index = 1, 26 do
		--: Uniforme por área, não por raio -- o mesmo erro que amontoou as
		--: bestas no centro da clareira e a grama na borda de dentro.
		local angle = stream:number(0, math.pi * 2)
		local inner, outer = Mountain.PLAZA + 16, Mountain.PLAZA + 190
		local radius = math.sqrt(stream:number()) * (outer - inner) + inner
		local at = Mountain.ORIGIN + Vector3.new(
			math.cos(angle) * radius, -1, math.sin(angle) * radius)
		sakura(folder, at, stream:number(0.85, 1.5))
	end

	--: Quatro dentro do pátio, ladeando o caminho do portal. São as que o
	--: jogador vê de perto, e as únicas que ele vai fotografar.
	for _, offset in { Vector3.new(-34, 0, 74), Vector3.new(34, 0, 74),
	                   Vector3.new(-34, 0, 30), Vector3.new(34, 0, 30) } do
		sakura(folder, Mountain.ORIGIN + offset + Vector3.new(0, 0.6, 0), 1.25)
	end
end

-- ================================================================== a partida

function Scenery.start()
	local root = Mountain.root()

	local function stage(name: string, build: () -> ())
		local ok, err = pcall(build)
		if not ok then
			Debug.error(string.format("cenário '%s' falhou: %s", name, tostring(err)))
		end
	end

	--: As partes podem subir agora: ninguém mais mexe nelas.
	stage("ar", function() Scenery.air(root) end)
	stage("cerejeiras", function() Scenery.grove(root) end)

	--[[
		O terreno espera todo mundo terminar, e essa linha é uma correção.

		`Mountain.plaza` preenche 1400 x 1400 de grama e `Scenery` cava o lago e
		levanta as montanhas -- **os dois escrevem o mesmo terreno**. A ordem em
		que o bootstrap carrega sistemas não é garantida, e na execução em que
		`Scenery` veio primeiro a grama do pátio passou por cima da água: o
		cenário "há água, e ela reflete" pegou a lagoa seca.

		É a mesma família de defeito que já custou uma pasta `Seita` duplicada
		neste projeto: dois donos para o mesmo recurso, resolvidos por sorte de
		ordenação. Aqui o dono do **chão** é `Mountain.plaza`; tudo o que
		esculpe por cima dele vem depois, e `task.defer` garante isso sem que
		`Scenery` precise conhecer `Sect`.
	]]
	task.defer(function()
		stage("horizonte", Scenery.horizon)
		stage("agua", Scenery.water)
		Debug.info("cenário: montanhas de terreno, água, pétalas e cerejeiras")
	end)
end

return Scenery
