--!strict
--[[
	Aura — o rank, lido do outro lado do pátio.

	Num jogo de cultivo a progressão dos outros tem de ser visível, senão o
	servidor compartilhado não serve para nada. É também a única propaganda
	que este jogo faz de si mesmo: quem acaba de entrar vê um cultivador de
	Alma Nascente sentado no Pico com três anéis girando e passa a querer
	aquilo. Nenhuma tela de progresso faz isso.

	Cada degrau é maior e mais chamativo que o anterior -- mais partículas,
	mais luz, mais anéis, a cor migrando de branco a dourado -- e a escada
	inteira mora em `Content.auras`, para que o desenho e qualquer coisa que
	venha a lê-la não discordem.

	Por que isto é do cliente
	-------------------------

	A aura é enfeite puro e precisa girar a sessenta quadros. Feita no
	servidor, cada anel de cada jogador vira replicação de CFrame por quadro:
	doze cultivadores num pátio somam quarenta e oito objetos girando pela
	rede, para produzir exatamente o mesmo pixel que cada cliente desenha de
	graça sozinho.

	O que ela lê são **atributos do `Player`** -- `qiRealm`, `corpoRealm`,
	`raizTier` -- que replicam para todo mundo por definição. `StateSync` não
	serviria: ele só chega ao dono, e cada um veria apenas a própria aura.

	A armadilha que este arquivo evita
	----------------------------------

	Ligar-se ao `Character` que existe agora. Um respawn traz outro modelo, a
	aura antiga vai junto com o corpo antigo, e o jogador volta apagado --
	para sempre, porque nada a reconstrói. Por isso tudo aqui é remontado em
	`CharacterAdded`, e a única coisa que sobrevive é a inscrição no sinal.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Content = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Content"))

local Aura = {}

--: Um anel montado por jogador. Guardado para que o laço de rotação tenha o
--: que girar sem varrer o `Workspace` sessenta vezes por segundo.
type Rig = {
	character: Model,
	root: BasePart,
	rings: { BasePart },
	halo: BasePart?,
	shards: { BasePart },
	crown: boolean,
	sigil: { BasePart },
	beam: BasePart?,
	speed: number,
}

local rigs: { [Player]: Rig } = {}

--[[
	Desmonta a aura de um jogador, inteira.

	A pasta `AuraDao` **não** é tudo. Os emissores e a luz moram no
	`HumanoidRootPart`, porque um `Attachment` só funciona como filho de uma
	`BasePart` -- e destruir só a pasta deixava tudo isso para trás. Cada
	remontagem somava um `AuraFonte`, um `Veu` e um `AuraLuz`, e a aura ia
	ficando mais brilhante a cada vez que o jogador sentava, levantava ou
	rompia um degrau. Medido na sessão viva: dois conjuntos completos depois de
	um único sentar.

	O sintoma, uma hora depois, é "o jogo foi ficando claro" -- que ninguém
	liga a um botão de meditar. Por isso a limpeza varre o root por nome em vez
	de confiar na pasta: assim ela também recolhe o que uma sessão anterior
	tenha deixado.
]]
local ROOT_PIECES = {
	AuraFonte = true, AuraVeu = true, AuraLuz = true,
}

local function clear(player: Player)
	local rig = rigs[player]
	local character = if rig ~= nil then rig.character else player.Character
	rigs[player] = nil
	if character == nil then
		return
	end

	local existing = character:FindFirstChild("AuraDao")
	if existing ~= nil then
		existing:Destroy()
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if root == nil then
		return
	end
	for _, item in root:GetChildren() do
		if ROOT_PIECES[item.Name] then
			item:Destroy()
		end
	end
end

--: Uma peça de aura: neon, ancorada, sem colisão, sem consulta e sem sombra.
--: As quatro últimas juntas são a diferença entre um enfeite e uma coisa que o
--: raycast do combate acerta, que a física empurra e que custa uma sombra por
--: quadro para cada jogador do pátio.
local function piece(parent: Instance, name: string, shape: Enum.PartType,
                     size: Vector3, colour: Color3,
                     transparency: number): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = shape
	part.Size = size
	part.Color = colour
	part.Material = Enum.Material.Neon
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = transparency
	part.CastShadow = false
	part.Parent = parent
	return part
end

--: Um anel: um cilindro fino e oco de neon, deitado. Fino de propósito -- um
--: anel grosso lê como um prato, e um cultivador dentro de um prato não impõe
--: respeito nenhum.
local function ring(parent: Instance, radius: number, colour: Color3,
                    thickness: number): BasePart
	return piece(parent, "Anel", Enum.PartType.Cylinder,
		Vector3.new(thickness, radius * 2, radius * 2), colour, 0.35)
end

--[[
	Monta a aura de um jogador a partir do que os atributos dele dizem.

	Reconstrói do zero em vez de ajustar o que já existe. Ajustar seria mais
	rápido e é onde mora o defeito clássico: um rompimento que devia acender
	um segundo anel encontra o primeiro com as propriedades erradas do degrau
	anterior, e a aura fica num estado que não corresponde a rank nenhum.
]]
local function build(player: Player)
	clear(player)

	local character = player.Character
	if character == nil then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return
	end

	local qiRealm = tonumber(player:GetAttribute("qiRealm")) or 1
	--: O **estágio**, e não só o realm. Sem ele a aura era idêntica do estágio
	--: I ao X -- dez rompimentos sem nada aparecer na tela, que é a razão de
	--: este defeito ter sobrevivido a três correções.
	local qiStage = tonumber(player:GetAttribute("qiEstagio")) or 1
	local bodyRealm = tonumber(player:GetAttribute("corpoRealm")) or 1
	local stance = tostring(player:GetAttribute("postura") or "nenhum")
	local farming = stance == "cultivar" or stance == "treinar"

	--[[
		A aura de rank, e a aura de **estar cultivando agora**.

		São coisas diferentes e a segunda é a que o jogador pediu para ver: um
		cultivador sentado tem de estar visivelmente envolto em Qi, não apenas
		soltando um pouco de fumaça como quem passa andando. Enquanto a postura
		durar, tudo sobe de degrau -- mais partículas, mais luz, um anel a mais,
		e o véu que se enrola no corpo abaixo.

		Cópia rasa e não mutação: `Content.auraFor` devolve a linha da tabela
		compartilhada, e multiplicá-la no lugar aumentaria a aura de **todos**
		os cultivadores daquele realm, para sempre, um pouco a cada vez que
		alguém sentasse. É o tipo de defeito que aparece uma hora depois como
		"o jogo foi ficando brilhante".
	]]
	local base = Content.auraFor(qiRealm, qiStage)
	local spec = table.clone(base)
	if farming then
		--[[
			Chamativa, e o personagem ainda visível dentro dela.

			Duas afinações, nas duas direções. A primeira era discreta demais:
			um sopro branco do tamanho de um punho, que ninguém percebia ser
			uma aura. A segunda -- `light * 2 + 3.2`, alcance +26 -- apagou o
			cultivador: a foto mostrava uma coluna de luz ciano e nenhuma
			pessoa dentro dela.

			O que ficou: muitas partículas e muito movimento, **pouca luz
			bruta**. Partícula desenha forma; `PointLight` apaga o que está
			atrás. É a diferença entre uma aura e um holofote.
		]]
		--[[
			Multiplicativo, e quase sem constante.

			O `+110` de antes dominava a soma: um cultivador de rank 1 emitia
			155 partículas e um de rank 2 emitia 193 -- vinte e cinco por cento
			de diferença, invisível na tela. O bônus de cultivo passou a
			**escalar o que já existe** em vez de somar um piso, então a
			distância entre dois ranks continua sendo a distância entre dois
			ranks enquanto se medita.

			As constantes que sobraram são as mínimas para que o rank 1, que
			não tem selo nem coluna nenhuma, ainda ganhe alguma coisa ao sentar
			-- senão o primeiro cultivo do jogo não muda nada na tela.
		]]
		spec.rate = base.rate * 2.6
		spec.size = base.size * 1.35
		spec.speed = base.speed * 1.25
		spec.rings = base.rings + 1
		spec.ringSpeed = base.ringSpeed + 0.8
		spec.sparks = true
		spec.sigil = math.max(base.sigil, 6)
		spec.shards = math.max(base.shards, 3)

		--[[
			As duas posturas não recebem a mesma aura, e isso é significado
			antes de ser desenho.

			**Meditar** é Qi subindo: coluna de luz, véu colado ao corpo, muita
			emissão para cima. **Treinar** é calor saindo: vapor rasteiro, selo
			no chão, e nenhuma coluna -- um feixe vertical atravessando alguém
			que está de bruços fazendo flexão não quer dizer nada.

			Tem também um motivo de leitura. Na foto do treino o personagem
			sumia dentro do próprio brilho: uma coluna de neon centrada no
			tronco de um corpo deitado passa exatamente por cima dele. Meditar
			é uma silhueta vertical e sobra espaço; treinar é horizontal e não
			sobra.
		]]
		--[[
			A luz tem teto; a **forma** não.

			Foi a terceira vez que a mesma foto apareceu: um cultivador
			invisível dentro do próprio brilho, agora no realm 3. A causa é
			composta -- a luz da âncora cresce com o patamar, o bônus de
			cultivo multiplica isso, e no topo da escada dariam brilho 11 com
			alcance 135. Um `PointLight` nessa faixa não desenha aura: apaga
			tudo o que está atrás dela, inclusive a pessoa.

			O teto está aqui e não nas âncoras porque o problema é o produto,
			não o fator: cada metade parecia razoável sozinha.

			O que continua crescendo sem limite é o que **desenha**: anéis,
			fragmentos, runas, coluna, cor. Chamativo é silhueta, não lúmen.
		]]
		if stance == "cultivar" then
			spec.light = math.min(base.light * 1.5, 4.2)
			spec.range = math.min(base.range * 1.3, 64)
			spec.pillar = true
			spec.beam = math.max(base.beam, 24)
		else
			spec.light = math.min(base.light * 1.1, 3.2)
			spec.range = math.min(base.range * 1.15, 52)
			spec.pillar = false
			spec.beam = 0
		end
	end

	local holder = Instance.new("Folder")
	holder.Name = "AuraDao"
	holder.Parent = character

	--: O tier da raiz tinge a aura. É o único lugar em que a sorte de alguém
	--: fica visível a trinta studs, e é o que faz um jogador atravessar o
	--: pátio para ver de perto quem tirou uma Raiz Celestial.
	local tier = tonumber(player:GetAttribute("raizTier")) or 1
	--: Um quinto, não um terço. A 0.35 a cor da raiz -- que num novato é cinza
	--: -- lavava a cor do degrau, e dois ranks vizinhos saíam do mesmo tom
	--: sujo. A escada de rank é a informação principal; a raiz é o tempero.
	local colour = spec.colour:Lerp(
		Content.tierColour[tier] or spec.colour, 0.18)

	--[[
		E então o karma escurece tudo.

		É a divisão mais antiga do gênero -- caminho ortodoxo contra caminho
		demoníaco -- e nenhuma manhwa a explica com um número: mostra o sujeito
		entrando na sala com a aura **preta**, e todo mundo entende sozinho.

		Aplicado por último, depois do rank e da raiz, porque é o que ele é: uma
		mancha por cima do que a pessoa construiu. Um cultivador de Coroa
		Imortal que matou quinze pessoas continua tendo seis anéis e uma coluna
		de duzentos studs -- pretos.
	]]
	local kills = tonumber(player:GetAttribute("karma")) or 0
	local stain = Content.karmaFor(kills)
	if stain.darkness > 0 then
		colour = colour:Lerp(Content.karmaTint, stain.darkness)
	end

	if spec.rate > 0 then
		local attachment = Instance.new("Attachment")
		attachment.Name = "AuraFonte"
		attachment.Position = Vector3.new(0, -2.4, 0)
		attachment.Parent = root

		--: Sem `Texture`. O padrão do emissor já é uma mancha macia, e um
		--: `rbxasset://` escrito de memória é o modo de falha silencioso desta
		--: engine: o caminho errado não dá erro, apenas não desenha nada.
		local qi = Instance.new("ParticleEmitter")
		qi.Name = "Qi"
		qi.Rate = spec.rate
		qi.Lifetime = NumberRange.new(0.7, 1.5)
		qi.Speed = NumberRange.new(spec.speed * 0.6, spec.speed)
		qi.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, spec.size * 0.4),
			NumberSequenceKeypoint.new(1, spec.size),
		})
		qi.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.25),
			NumberSequenceKeypoint.new(1, 1),
		})
		--: Termina numa versão clara da própria cor, não em branco puro. Branco
	--: puro num emissor de neon a esta taxa lava a cena inteira, e a aura
	--: perde justamente a cor que dizia o rank de quem está ali.
	qi.Color = ColorSequence.new(colour, colour:Lerp(Color3.new(1, 1, 1), 0.45))
		qi.LightEmission = 0.8
		qi.LightInfluence = 0
		--: Sobe. Um `Acceleration` positivo em Y é o que separa uma aura de
		--: cultivador de uma nuvem de poeira.
		qi.Acceleration = Vector3.new(0, spec.speed * 1.6, 0)
		qi.SpreadAngle = Vector2.new(18, 18)
		qi.Parent = attachment

		if spec.sparks then
			local sparks = Instance.new("ParticleEmitter")
			sparks.Name = "Faiscas"
			sparks.Rate = spec.rate * 0.25
			sparks.Lifetime = NumberRange.new(0.3, 0.7)
			sparks.Speed = NumberRange.new(spec.speed * 1.8, spec.speed * 3)
			sparks.Size = NumberSequence.new(spec.size * 0.22)
			sparks.Transparency = NumberSequence.new(0.1)
			sparks.Color = ColorSequence.new(Color3.new(1, 1, 1))
			sparks.LightEmission = 1
			sparks.SpreadAngle = Vector2.new(80, 80)
			sparks.Parent = attachment
		end

		if spec.pillar then
			--: A coluna: partículas largas e lentas que sobem muito acima da
			--: cabeça. É o que se vê do outro lado do pátio quando o próprio
			--: personagem já é um ponto.
			local pillar = Instance.new("ParticleEmitter")
			pillar.Name = "Coluna"
			pillar.Rate = spec.rate * 0.35
			pillar.Lifetime = NumberRange.new(1.8, 2.8)
			pillar.Speed = NumberRange.new(spec.speed * 2.6, spec.speed * 3.4)
			pillar.Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, spec.size * 1.6),
				NumberSequenceKeypoint.new(1, spec.size * 0.2),
			})
			pillar.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.55),
				NumberSequenceKeypoint.new(1, 1),
			})
			pillar.Color = ColorSequence.new(colour)
			pillar.LightEmission = 0.9
			pillar.SpreadAngle = Vector2.new(6, 6)
			pillar.Parent = attachment
		end
	end

	if bodyRealm >= Content.bodyAuraFrom then
		--: A assinatura do corpo: vapor quente, denso e baixo. Soma com a do
		--: Qi em vez de substituí-la, porque quem treinou os dois tem de
		--: parecer alguém que treinou os dois.
		local heat = Instance.new("Attachment")
		heat.Name = "AuraCorpo"
		heat.Position = Vector3.new(0, -2.2, 0)
		heat.Parent = root

		local steam = Instance.new("ParticleEmitter")
		steam.Name = "Vapor"
		steam.Rate = 8 + bodyRealm * 4
		steam.Lifetime = NumberRange.new(1.2, 2.2)
		steam.Speed = NumberRange.new(1.4, 2.6)
		steam.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1.2),
			NumberSequenceKeypoint.new(1, 3.6 + bodyRealm * 0.2),
		})
		steam.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.62),
			NumberSequenceKeypoint.new(1, 1),
		})
		steam.Color = ColorSequence.new(Content.bodyAuraColour)
		steam.LightEmission = 0.5
		steam.Acceleration = Vector3.new(0, 3, 0)
		steam.SpreadAngle = Vector2.new(45, 45)
		steam.Parent = heat
	end

	if farming then
		--[[
			O véu: o Qi subindo colado ao corpo, de baixo para cima.

			Ancorado no tronco e com abertura estreita, em vez de sair do chão
			e se abrir. É a diferença entre uma coluna de fumaça na qual o
			personagem por acaso está dentro e um manto que pertence a ele --
			e era exatamente a diferença que faltava: a aura estava no chão,
			não em volta de quem estava sentado.
		]]
		local torso = Instance.new("Attachment")
		torso.Name = "AuraVeu"
		torso.Position = Vector3.new(0, -0.4, 0)
		torso.Parent = root

		local veil = Instance.new("ParticleEmitter")
		veil.Name = "Veu"
		veil.Rate = spec.rate * 0.9
		veil.Lifetime = NumberRange.new(0.9, 1.6)
		veil.Speed = NumberRange.new(2.2, 4.2)
		veil.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.5),
			NumberSequenceKeypoint.new(0.4, spec.size * 0.9),
			NumberSequenceKeypoint.new(1, 0.2),
		})
		veil.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.9),
			NumberSequenceKeypoint.new(0.35, 0.55),
			NumberSequenceKeypoint.new(1, 1),
		})
		veil.Color = ColorSequence.new(colour, colour:Lerp(Color3.new(1, 1, 1), 0.4))
		veil.LightEmission = 1
		veil.LightInfluence = 0
		--: `EmissionDirection` para cima e `SpreadAngle` estreito: o véu sobe
		--: rente ao corpo em vez de se espalhar como poeira.
		veil.EmissionDirection = Enum.NormalId.Top
		veil.SpreadAngle = Vector2.new(12, 12)
		veil.Acceleration = Vector3.new(0, 6, 0)
		--[[
			A fonte é um volume e não um ponto, para que as partículas nasçam ao
			longo do corpo.

			`Size0` **não existe** nesta versão do Studio (0.737) -- só `Shape`
			e `ShapeStyle` existem. Escrever a linha derruba a construção
			inteira da aura, e o sintoma seria um cultivador sem aura nenhuma
			com zero erros no console do jogador. Foi conferido no Studio vivo,
			não lembrado.
		]]
		veil.Shape = Enum.ParticleEmitterShape.Box
		veil.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
		veil.Parent = torso
	end

	if spec.light > 0 then
		local light = Instance.new("PointLight")
		light.Name = "AuraLuz"
		light.Color = colour
		light.Brightness = spec.light
		light.Range = spec.range
		light.Shadows = false
		light.Parent = root
	end

	local rings: { BasePart } = {}
	for index = 1, spec.rings do
		--: Cada anel mais largo e mais fino que o de dentro. Um conjunto de
		--: anéis do mesmo tamanho lê como um erro de desenho, não como poder.
		rings[index] = ring(holder, 3.4 + index * 1.7, colour,
			0.42 / index + 0.1)
	end

	--[[
		O halo: um anel na **cabeça**, não nos pés.

		É a troca de silhueta do patamar do Núcleo, e a leitura mais antiga de
		santidade que existe. Um anel a mais na cintura teria sido "mais do
		mesmo"; um anel acima da cabeça é outra coisa, à distância e de
		relance, que é como uma aura é lida de verdade.
	]]
	local halo: BasePart? = nil
	if spec.halo then
		halo = ring(holder, 2.6, colour, 0.28)
	end

	--[[
		As pedras em órbita.

		É a imagem mais repetida do gênero: fragmentos parados no ar em volta
		de alguém que não os está segurando. Custa oito partes e diz, sem uma
		palavra, que a pessoa ali no meio não obedece às mesmas regras que
		você.
	]]
	local shards: { BasePart } = {}
	for index = 1, spec.shards do
		local shard = piece(holder, "Fragmento", Enum.PartType.Block,
			Vector3.new(0.5, 1.3, 0.5), colour, 0.1)
		shards[index] = shard
	end

	--[[
		O selo no chão.

		Um cultivador de rank alto sentado deixa uma marca desenhada embaixo
		dele. Fica quase deitado no chão e sem colisão, e é o que faz um pátio
		com três cultivadores parecer ocupado por gente importante em vez de
		por três bonecos parados.
	]]
	--[[
		O selo: um **círculo mágico**, não um disco.

		Era um cilindro cheio, e a foto mostrou o resultado: uma poça branca de
		onze studs de raio com o cultivador desaparecido dentro dela. Um disco
		opaco não lê como selo, lê como holofote apontado para o chão.

		Um círculo de traços curtos lê como escrita -- que é o que um selo de
		manhwa é -- e deixa a pedra do pátio aparecer entre eles. O número de
		anéis cresce com o degrau, e eles giram em sentidos opostos: duas
		rotações no mesmo sentido leem como uma peça só.
	]]
	local sigil: { BasePart } = {}
	if spec.sigil > 0 then
		local bands = 1 + math.floor(spec.sigil / 9)
		for band = 1, bands do
			local radius = spec.sigil * (0.55 + 0.22 * band)
			local marks = 12 + band * 6
			for index = 1, marks do
				--[[
					Quanto mais runa, mais fraca cada uma.

					A 0.28 elas somavam num anel praticamente sólido e o taiji
					sumia embaixo; a 0.45 resolveu para o selo pequeno e voltou a
					apagar o cultivador no realm 3, onde são quarenta e duas peças
					de `Neon` no mesmo chão. O selo tem de ficar mais **detalhado**
					com o patamar, não mais opaco.
				]]
				local fade = math.clamp(0.42 + marks * 0.012, 0.42, 0.78)
				local rune = piece(holder, "Runa", Enum.PartType.Block,
					Vector3.new(0.28, 0.12, radius * 0.22), colour, fade)
				rune:SetAttribute("banda", band)
				rune:SetAttribute("raio", radius)
				rune:SetAttribute("passo", (index - 1) / marks * math.pi * 2)
				table.insert(sigil, rune)
			end
		end
	end

	--[[
		A coluna de luz.

		A partir da Alma Nascente o cultivador vira um ponto de referência na
		montanha: dá para achar quem é o mais forte do servidor olhando o céu.
		É o degrau em que a escada deixa de ser sutil de propósito -- e é
		exatamente aí que o jogador começa a querer ser olhado.
	]]
	local beam: BasePart? = nil
	if spec.beam > 0 then
		--: Estreita e quase transparente. Uma coluna grossa e opaca é uma
		--: parede de luz na frente do personagem, não uma aura em volta dele.
		beam = piece(holder, "Coluna", Enum.PartType.Cylinder,
			Vector3.new(spec.beam, 3.2, 3.2), colour, 0.92)
	end

	rigs[player] = {
		character = character,
		root = root,
		rings = rings,
		halo = halo,
		shards = shards,
		crown = spec.crown,
		sigil = sigil,
		beam = beam,
		speed = spec.ringSpeed,
	}
end

--[[
	Segue um jogador para sempre: nascimento, morte e cada rompimento.

	O `task.wait` depois de `CharacterAdded` não é superstição. O
	`HumanoidRootPart` existe no instante do evento, mas o modelo replicado
	chega em pedaços -- ler as partes no momento em que o modelo aparece é a
	armadilha número um desta engine, e o sintoma é uma aura que só falha para
	quem tem internet ruim.
]]
local function follow(player: Player)
	local function rebuild()
		task.defer(build, player)
	end

	player.CharacterAdded:Connect(function()
		task.wait(0.4)
		build(player)
	end)
	player.CharacterRemoving:Connect(function()
		clear(player)
	end)
	--: `postura` está na lista porque a aura de quem está cultivando é outra
	--: aura, e ela tem de aparecer no instante em que o jogador senta -- não no
	--: próximo rompimento.
	--: `karma` entra na lista porque a mancha tem de aparecer no instante da
	--: morte, não no próximo rompimento de realm.
	--: `qiEstagio` na lista: é o sinal de "avancei um degrau", e é o que faz a
	--: aura crescer entre um realm e outro.
	for _, attribute in { "qiRealm", "qiEstagio", "corpoRealm", "raizTier",
	                      "postura", "karma" } do
		player:GetAttributeChangedSignal(attribute):Connect(rebuild)
	end
	if player.Character ~= nil then
		rebuild()
	end
end

function Aura.start()
	Players.PlayerAdded:Connect(follow)
	--: Quem já estava aqui quando este módulo subiu. Em Studio esse é sempre
	--: o jogador local, ou seja, exatamente o único que importa em teste.
	for _, player in Players:GetPlayers() do
		follow(player)
	end
	Players.PlayerRemoving:Connect(clear)

	--[[
		A rotação, num laço só para todos os anéis de todos os jogadores.

		Um `RenderStepped` por anel é a mesma conta dividida em N inscrições
		que o Roblox tem de acordar separadamente, e num pátio com doze
		cultivadores de rank alto isso são quarenta e oito.

		Os anéis são ancorados e posicionados por CFrame em vez de soldados:
		uma solda os arrastaria para dentro da física do personagem, e um anel
		com massa é uma coisa que o solucionador vai eventualmente usar para
		derrubar alguém.
	]]
	local phase = 0
	RunService.RenderStepped:Connect(function(dt)
		phase += dt
		for player, rig in rigs do
			if rig.root.Parent == nil then
				clear(player)
				continue
			end
			local base = rig.root.Position - Vector3.new(0, 2.6, 0)
			for index, band in rig.rings do
				local spin = phase * rig.speed * (if index % 2 == 0 then -1 else 1)
				local tilt = math.rad(8 * index)
				band.CFrame = CFrame.new(base + Vector3.new(0, index * 0.55, 0))
					* CFrame.Angles(0, spin, 0)
					* CFrame.Angles(tilt, 0, math.pi / 2)
			end

			--: O halo acompanha a cabeça e inclina de leve. Um anel perfeitamente
			--: horizontal parado sobre alguém lê como um adereço colado; a
			--: inclinação lenta é o que o faz parecer flutuar por conta própria.
			if rig.halo ~= nil then
				rig.halo.CFrame = CFrame.new(base + Vector3.new(0, 6.4, 0))
					* CFrame.Angles(0, phase * rig.speed * 0.5, 0)
					* CFrame.Angles(math.rad(8 + math.sin(phase) * 5), 0, math.pi / 2)
			end

			--[[
				Os fragmentos: em órbita na cintura, ou em **coroa** acima da
				cabeça nos patamares altos.

				A coroa é a segunda troca de silhueta. Os mesmos fragmentos,
				noutro lugar do corpo -- e "noutro lugar do corpo" é o que
				separa dois patamares à distância, não "mais um deles".
			]]
			local count = #rig.shards
			for index, shard in rig.shards do
				local turn = phase * rig.speed * 0.7
					+ index / math.max(count, 1) * math.pi * 2
				if rig.crown then
					local wobble = math.sin(phase * 1.3 + index) * 0.35
					shard.CFrame = CFrame.new(base + Vector3.new(
						math.cos(turn) * 2.9, 7.6 + wobble, math.sin(turn) * 2.9))
						* CFrame.Angles(math.rad(-32), turn, 0)
				else
					local lift = 1.4 + math.sin(phase * 1.6 + index) * 0.9
						+ (if index % 2 == 0 then 1.8 else 0)
					shard.CFrame = CFrame.new(base + Vector3.new(
						math.cos(turn) * 4.6, lift + 2.2, math.sin(turn) * 4.6))
						* CFrame.Angles(phase * 2.2, turn, 0)
				end
			end

			--: As runas do selo. Bandas alternadas giram em sentidos opostos:
			--: duas rotações no mesmo sentido leem como uma peça só girando.
			for _, rune in rig.sigil do
				local band = tonumber(rune:GetAttribute("banda")) or 1
				local radius = tonumber(rune:GetAttribute("raio")) or 6
				local step = tonumber(rune:GetAttribute("passo")) or 0
				local spin = phase * rig.speed * 0.4
					* (if band % 2 == 0 then -1 else 1)
				local angle = step + spin
				rune.CFrame = CFrame.new(base + Vector3.new(
					math.cos(angle) * radius, -0.3, math.sin(angle) * radius))
					* CFrame.Angles(0, -angle, 0)
			end

			--: A coluna nasce no chão e sobe. Deitada de lado no `Size` porque
			--: um `PartType.Cylinder` tem o eixo em X: escrever a altura em Y
			--: produz um disco enorme sobre a cabeça do jogador.
			if rig.beam ~= nil then
				local height = rig.beam.Size.X
				rig.beam.CFrame = CFrame.new(base + Vector3.new(0, height / 2, 0))
					* CFrame.Angles(0, 0, math.pi / 2)
			end
		end
	end)
end

return Aura
