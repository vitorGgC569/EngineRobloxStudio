--!strict
--[[
	Sect — monta a montanha e a veste.

	`Mountain` sabe fazer as peças; este arquivo decide onde cada uma fica e
	pendura nelas o que é do jogo: as veias pagam pedra ao cultivador certo, o
	taiji tem um lugar para sentar, e as árvores vêm do catálogo em vez de
	serem cilindros verdes.

	Por que a vegetação vem de um catálogo e não daqui
	--------------------------------------------------

	Caixas sem textura são a razão número um pela qual um projeto de Roblox lê
	como inacabado, e este repositório já entregou um jogo assim: todos os
	sistemas funcionando, onze cenários verdes, e a primeira pessoa que abriu
	disse que não tinha nada dentro. `Forge.Catalog.ItchAssets` são 538 modelos
	CC0 **já publicados nesta conta**, o que é o detalhe que importa:
	`InsertService:LoadAsset` recusa quase todo id da Creator Store e aceita
	estes.

	E o que ele nunca pode fazer é derrubar o jogo. `LoadAsset` é uma chamada
	de rede contra um serviço que tem minutos ruins; toda colocação aqui é
	opcional, e `Sect.report()` diz quantas de fato chegaram -- porque inferir
	isso de "não deu erro" é como se publica um jogo cinza acreditando que ele
	está vestido.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local Mountain = require(script.Parent:WaitForChild("Mountain"))
local Cultivation = require(script.Parent:WaitForChild("Cultivation"))

local Place = Forge.Catalog.Place
local ItchAssets = Forge.Catalog.ItchAssets
local Rng = Forge.Core.Rng
local Sky = Forge.Visual.Sky
local Debug = Forge.Debug
local Interaction = Forge.Interaction
local Net = Forge.Net

local Sect = {}

local stream = Rng.stream("daocultivo.vestir")
local asked, landed = 0, 0

--[[
	O que este jogo entende por tamanho, onde ele discorda do catálogo.

	`Scale` classifica `tree` como folhagem e mira 34 studs -- altura certa para
	uma floresta e errada para um pátio de seita. Com o `jitter` de até 1,6 que
	este arquivo pedia, as árvores saíam com **cinquenta e quatro studs**: mais
	altas que os pagodes, cinzas (o modelo veio sem cor, e uma silhueta daquele
	tamanho o `Tint` não salva), plantadas em volta do pátio como torres.

	Uma tabela só, lida por toda colocação. Um `jitter` generoso num lugar e um
	alvo de altura noutro é exatamente como uma árvore de cinquenta studs
	aparece sem ninguém ter pedido.
]]
local SIZES = {
	foliage = { height = 18, spread = 1.5 },
	undergrowth = { height = 3, spread = 3.0 },
}

local function put(topic: string, at: Vector3, parent: Instance, options: any?): Instance?
	local o = options or {}
	asked += 1
	local model = Place.put(ItchAssets, {
		topic = topic,
		seed = math.floor(at.X * 61 + at.Z * 137 + (o.seed or 0)),
		at = at,
		parent = parent,
		yaw = o.yaw or stream:number(0, math.pi * 2),
		jitter = o.jitter,
		solid = o.solid,
		--: Alturas proprias, e nao as do catalogo. Ver `SIZES` acima.
		sizes = o.sizes or SIZES,
	})
	if model ~= nil then
		landed += 1
	end
	return model
end

function Sect.report(): { [string]: any }
	return {
		asked = asked,
		landed = landed,
		--: O número que importa. Vestido não é "sem erros", é isto perto de um.
		rate = if asked > 0 then landed / asked else 0,
	}
end

-- ============================================================== a vegetação

--[[
	Árvores e arbustos num anel em volta do pátio.

	Num anel e não espalhados num quadrado, porque para o que servem é o
	horizonte que se vê por cima do muro -- e um espalhamento uniforme põe a
	maior parte do trabalho onde ninguém olha.
]]
local function greenery(root: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "Vegetacao"
	folder.Parent = root

	for index = 1, 60 do
		local angle = index / 60 * math.pi * 2 + stream:number(-0.05, 0.05)
		local radius = Mountain.PLAZA + stream:number(14, 190)
		local at = Mountain.ORIGIN + Vector3.new(
			math.cos(angle) * radius, -2.2, math.sin(angle) * radius)
		local roll = stream:number()
		local topic = if roll < 0.48 then "tree"
			elseif roll < 0.78 then "bush"
			elseif roll < 0.92 then "rock"
			else "flower"
		--: Variedade é bom; o dobro do tamanho não é variedade.
			put(topic, at, folder, { jitter = stream:number(0.8, 1.15) })
	end

	--: Um punhado dentro do pátio também, longe do taiji. Um pátio de pedra
	--: pura lê como praça de cidade; três vasos e uma pedra lê como jardim.
	for index = 1, 10 do
		local angle = stream:number(0, math.pi * 2)
		local radius = stream:number(Mountain.TAIJI + 16, Mountain.PLAZA - 20)
		local at = Mountain.ORIGIN + Vector3.new(
			math.cos(angle) * radius, 0.4, math.sin(angle) * radius)
		put(if stream:number() < 0.6 then "bush" else "flower", at, folder,
			{ jitter = stream:number(0.7, 1.1), solid = false })
	end
end

-- ============================================================== as lanternas

--[[
	Lanternas de pedra, construídas — não buscadas no catálogo.

	Eram `put("torch", ...)`: modelos do `ItchAssets` que chegavam **cinzas**
	e sem forma reconhecível, dezesseis deles ladeando o caminho principal. Na
	foto de paisagem eram a coisa mais feia do quadro -- blocos claros com
	braços, plantados em fila entre o portal e o taiji, exatamente onde o
	jogador olha ao entrar.

	Uma lanterna de pedra é seis partes e todo mundo reconhece: base larga,
	fuste, caixa de luz, telhado, ponta. É a peça de jardim mais canônica que
	existe no gênero e não depende de rede nenhuma para chegar certa.

	A luz continua sendo feita à mão e separada da geometria: um pátio
	iluminado só onde um asset carregou é um pátio cuja iluminação depende da
	rede.
]]
local function lantern(parent: Instance, at: Vector3, scale: number)
	local model = Instance.new("Model")
	model.Name = "Lanterna"
	model.Parent = parent

	local function piece(name: string, size: Vector3, offset: Vector3,
	                     colour: Color3, material: Enum.Material): BasePart
		local part = Instance.new("Part")
		part.Name = name
		part.Size = size * scale
		part.CFrame = CFrame.new(at + offset * scale)
		part.Color = colour
		part.Material = material
		part.Anchored = true
		part.CanCollide = false
		part.Parent = model
		return part
	end

	local stone = Color3.fromRGB(150, 146, 138)
	local dark = Color3.fromRGB(104, 100, 96)

	piece("Base", Vector3.new(3.4, 1.0, 3.4), Vector3.new(0, 0.5, 0), dark,
		Enum.Material.Slate)
	piece("Fuste", Vector3.new(1.1, 5.2, 1.1), Vector3.new(0, 3.6, 0), stone,
		Enum.Material.Slate)
	piece("Prato", Vector3.new(3.0, 0.5, 3.0), Vector3.new(0, 6.4, 0), dark,
		Enum.Material.Slate)

	--: A caixa de luz é o que a lanterna é. Neon quente e translúcida, para
	--: que ela pareça acesa e não pintada de amarelo.
	local box = piece("Caixa", Vector3.new(2.4, 2.4, 2.4), Vector3.new(0, 7.9, 0),
		Color3.fromRGB(255, 196, 122), Enum.Material.Neon)
	box.Transparency = 0.22

	--: As quatro colunas de canto da caixa, escuras. São o que a lê como
	--: lanterna de pedra em vez de cubo brilhante.
	for _, corner in { Vector2.new(1, 1), Vector2.new(1, -1),
	                   Vector2.new(-1, 1), Vector2.new(-1, -1) } do
		piece("Coluna", Vector3.new(0.3, 2.5, 0.3),
			Vector3.new(corner.X * 1.15, 7.9, corner.Y * 1.15), dark,
			Enum.Material.Slate)
	end

	piece("Telhado", Vector3.new(4.0, 0.8, 4.0), Vector3.new(0, 9.4, 0), stone,
		Enum.Material.Slate)
	piece("Beiral", Vector3.new(2.8, 0.7, 2.8), Vector3.new(0, 10.0, 0), stone,
		Enum.Material.Slate)
	piece("Ponta", Vector3.new(0.7, 1.1, 0.7), Vector3.new(0, 10.8, 0), dark,
		Enum.Material.Slate)

	local light = Instance.new("PointLight")
	--: Dezesseis destas em volta do caminho. A 2.2 cada elas somam um segundo
	--: sol; a 0.8 são lanternas, que é o que são.
	light.Color = Color3.fromRGB(255, 190, 132)
	light.Brightness = 0.8
	light.Range = 22 * scale
	light.Shadows = false
	light.Parent = box

	--: Uma brasa lenta dentro da caixa. É pouquíssimo movimento, e é o que
	--: separa uma lanterna acesa de um bloco amarelo.
	local ember = Instance.new("ParticleEmitter")
	ember.Rate = 3
	ember.Lifetime = NumberRange.new(1.2, 2.4)
	ember.Speed = NumberRange.new(0.4, 1.2)
	ember.Size = NumberSequence.new(0.35 * scale)
	ember.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(1, 1),
	})
	ember.Color = ColorSequence.new(Color3.fromRGB(255, 206, 148))
	ember.LightEmission = 1
	ember.Acceleration = Vector3.new(0, 2, 0)
	ember.Parent = box
end

local function lanterns(root: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "Lanternas"
	folder.Parent = root

	for step = 1, 8 do
		for side = -1, 1, 2 do
			local at = Mountain.ORIGIN + Vector3.new(
				side * 13, 0.6,
				Mountain.TAIJI + 12 + step * ((Mountain.PLAZA - Mountain.TAIJI - 12) / 8))
			lantern(folder, at, 1.0)
		end
	end

	--: Quatro maiores nos cantos do taiji, que é o lugar que o jogo quer que
	--: seja olhado.
	for _, corner in { Vector2.new(1, 1), Vector2.new(1, -1),
	                   Vector2.new(-1, 1), Vector2.new(-1, -1) } do
		lantern(folder, Mountain.ORIGIN + Vector3.new(
			corner.X * (Mountain.TAIJI + 9), 0.6,
			corner.Y * (Mountain.TAIJI + 9)), 1.45)
	end
end

-- ============================================================== os balcões

--[[
	Os dois balcões que fecham a economia: o alquimista e o adivinho.

	Existem como lugares no mundo e não só como abas no HUD porque um menu que
	se abre de qualquer lugar não dá razão para andar, e andar é metade do que
	há para fazer enquanto a poça enche. Os botões do HUD continuam existindo;
	o balcão é o mesmo pedido feito de perto.
]]
local function counters(root: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "Balcoes"
	folder.Parent = root

	local desks = {
		{
			name = "Salão dos Caldeirões",
			label = "Comprar pílula",
			at = Mountain.ORIGIN + Vector3.new(-58, 3, 8),
			colour = Color3.fromRGB(52, 74, 128),
			channel = "alquimia",
		},
		{
			name = "Pavilhão do Destino",
			label = "Girar a raiz",
			at = Mountain.ORIGIN + Vector3.new(58, 3, 8),
			colour = Color3.fromRGB(150, 44, 46),
			channel = "destino",
		},
	}

	for _, desk in desks do
		local counter = Instance.new("Model")
		counter.Name = desk.name
		counter.Parent = folder

		local top = Instance.new("Part")
		top.Name = "Balcao"
		top.Size = Vector3.new(16, 5, 6)
		top.CFrame = CFrame.new(desk.at)
		top.Color = desk.colour
		top.Material = Enum.Material.WoodPlanks
		top.Anchored = true
		top.Parent = counter
		counter.PrimaryPart = top

		local cloth = Instance.new("Part")
		cloth.Name = "Toalha"
		cloth.Size = Vector3.new(16.6, 0.4, 6.6)
		cloth.CFrame = CFrame.new(desk.at + Vector3.new(0, 2.6, 0))
		cloth.Color = Color3.fromRGB(212, 168, 74)
		cloth.Material = Enum.Material.Fabric
		cloth.Anchored = true
		cloth.Parent = counter

		local plate = Instance.new("BillboardGui")
		plate.Size = UDim2.fromOffset(210, 30)
		plate.StudsOffsetWorldSpace = Vector3.new(0, 5, 0)
		--: Quarenta studs. A oitenta, a placa do Salão dos Caldeirões alcançava
		--: o taiji e caía por cima da coluna da esquerda do HUD.
		plate.MaxDistance = 40
		plate.Parent = top

		local text = Instance.new("TextLabel")
		text.Size = UDim2.fromScale(1, 1)
		text.BackgroundTransparency = 1
		text.Text = desk.name
		text.TextColor3 = Color3.fromRGB(244, 232, 204)
		text.TextStrokeTransparency = 0.25
		text.TextScaled = true
		text.Font = Enum.Font.Merriweather
		text.Parent = plate

		--: O balcão só pede ao cliente que abra o painel certo. A compra
		--: continua sendo do servidor: um balcão que vendesse por conta
		--: própria seria um segundo caminho para gastar pedra, e dois
		--: caminhos para gastar é onde um deles esquece de cobrar.
		Interaction.register(counter, {
			id = "balcao",
			label = desk.label,
			objectLabel = desk.name,
			range = 16,
			onTrigger = function(player: Player)
				Net.fire(player, "Notify", { text = desk.name, panel = desk.channel })
			end,
		})
	end
end

-- ================================================================ a partida

--[[
	Uma etapa da construção, isolada das outras.

	O bootstrap já embrulha `start` num `pcall`, e por isso mesmo um erro
	qualquer aqui custava **a montanha inteira**: um `Enum` que não existe
	nesta versão do Studio parou a construção na quarta linha, e o que subiu
	foi um pátio com um portal e mais nada. Nenhum erro na tela do jogador,
	nenhuma pista no jogo -- só um mundo pela metade.

	Com uma etapa por `pcall`, uma peça que falha custa aquela peça. É a mesma
	lição que `Visual.Sky` aprendeu com `Terrain.Decoration`: uma propriedade
	que falta deve custar aquela propriedade, não o céu.
]]
local failures: { string } = {}

local function stage(name: string, build: () -> ())
	local ok, err = pcall(build)
	if not ok then
		table.insert(failures, name .. ": " .. tostring(err))
		Debug.error(string.format("a seita subiu sem '%s': %s", name, tostring(err)))
	end
end

function Sect.start()
	--: A mesma pasta que `Zones` e `Hunt` usam. Criá-la aqui com
	--: `Instance.new` produzia uma segunda `Seita` sempre que outro sistema
	--: subisse primeiro, e o mundo saía partido em dois.
	local root = Mountain.root()

	stage("patio", function() Mountain.plaza(root) end)
	stage("taiji", function() Mountain.taiji(root) end)
	stage("portal", function() Mountain.gate(root) end)
	stage("paredao", function() Mountain.boards(root) end)
	--: O horizonte agora é de `Scenery`, em terreno. Os cubos empilhados de
	--: `Mountain.horizon` ficavam com a escada visível a quatrocentos studs, e
	--: chamar os dois deixaria as duas montanhas no mesmo lugar.
	stage("chegada", function() Mountain.spawn(root) end)

	--: O pagode azul é a alquimia, o rubro é a seita. Um de cada lado do
	--: eixo, recuados do taiji, para que a vista do portal tenha os dois nas
	--: bordas e o disco no meio -- que é o enquadramento da tela de origem.
	local alchemy = Mountain.ORIGIN + Vector3.new(-72, 1.5, -34)
	local hall = Mountain.ORIGIN + Vector3.new(72, 1.5, -34)
	stage("pagode da alquimia", function()
		Mountain.pagoda(root, alchemy, 5,
			Color3.fromRGB(46, 62, 108), Color3.fromRGB(52, 74, 128), "PagodeDaAlquimia")
	end)
	stage("pagode da seita", function()
		Mountain.pagoda(root, hall, 7,
			Color3.fromRGB(150, 44, 46), Color3.fromRGB(120, 34, 38), "PagodeDaSeita")
	end)
	stage("caldeiroes", function() Mountain.cauldrons(root, alchemy) end)
	stage("anciaos", function() Mountain.elders(root) end)
	stage("balcoes", function() counters(root) end)
	stage("lanternas", function() lanterns(root) end)
	stage("vegetacao", function() greenery(root) end)
	stage("grama", function() Mountain.meadow(root) end)

	--: As veias pagam ao cultivador. A ligação é feita aqui e não dentro de
	--: `Mountain` de propósito: a montanha não deve saber que existe economia,
	--: senão o cenário deixa de ser reaproveitável.
	stage("veias", function()
		Mountain.veins(root, function(player: Player, pedras: number)
			Cultivation.grant(player, pedras, "veia espiritual")
		end)
	end)

	--: O céu. `install` é idempotente e `pin` congela a hora: um ciclo
	--: dia-e-noite num jogo em que se fica sentado significa metade das
	--: sessões no escuro, e a tela de origem é um meio-dia limpo.
	Sky.install()
	Sky.pin(10)

	local report = Sect.report()
	Debug.probe("seita", function()
		return {
			pedidos = report.asked,
			chegaram = report.landed,
			taxa = report.rate,
			partes = #root:GetDescendants(),
		}
	end)
	Debug.info(string.format(
		"seita erguida: %d instâncias, catálogo %d/%d (%.0f%%)",
		#root:GetDescendants(), report.landed, report.asked, report.rate * 100))
	print(string.format("[%s] seita erguida: %d instâncias, catálogo %d/%d",
		"daocultivo", #root:GetDescendants(), report.landed, report.asked))
end

return Sect
