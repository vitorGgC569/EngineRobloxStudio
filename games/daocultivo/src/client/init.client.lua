--!strict
--[[
	A montanha, como o jogador a vê.

	A tela tem cinco zonas, e cada uma existe por uma razão diferente:

	    canto superior esquerdo   quanto você tem, e como gastar
	    lateral esquerda          a roda de Qi e Saúde, sempre visível
	    centro inferior           a poça, a taxa, o teto e o AVANÇO
	    barra inferior            as quatro ações
	    lateral direita           os quatro slots de técnica

	A regra que atravessa todas
	---------------------------

	**Nenhum número mora aqui.** Qi, pedras, teto, multiplicador e chance
	chegam resolvidos do servidor. Um cliente que recalcula qualquer um deles
	acaba com duas fórmulas para a mesma coisa, e a que fica para trás é
	sempre a do servidor -- ou seja, a tela mente a favor de quem está
	olhando, que é exatamente o erro que ninguém reporta.

	O que se aprendeu à força sobre interface aqui
	----------------------------------------------

	- `UI.mount` liga `ZIndexBehavior.Sibling`, e o nome é o contrato inteiro:
	  filho desenha **sempre** por cima do pai. Arte de fundo tem de ser irmã
	  do conteúdo, nunca mãe dele.
	- Um `UIListLayout` posiciona todo `GuiObject` visível abaixo dele. Não há
	  flag de ignorar. Um enfeite dentro de um painel com layout ocupa uma
	  linha inteira e empurra o conteúdo para fora.
	- `GuiService:GetGuiInset()` responde zero até a barra do Roblox carregar.
	  Por isso `ignoreInset = false`: quem cuida da margem é o Roblox.
	- O Studio recusa clique sintético. O jeito de um teste alcançar um botão é
	  um `BindableFunction` que o próprio cliente publica e que chama a mesma
	  função do botão -- é o que `DaoPressAction` faz no fim deste arquivo.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Content = require(Shared:WaitForChild("Content"))

--[[
	Os canais, definidos **nesta** VM.

	Sem esta linha o cliente não tem tabela de canais: `Net.send` não tem por
	onde mandar e `Net.on` liga a nada. Falha só quando alguém aperta um
	botão, e foi assim que a versão anterior deste repositório entregou um
	jogo em que o botão principal não fazia nada para ninguém.
]]
require(Shared:WaitForChild("Wire"))

--: A aura é um módulo à parte porque é a única coisa deste cliente que
--: desenha **os outros jogadores**. Tudo o mais aqui é sobre quem está
--: segurando o teclado.
local Aura = require(script:WaitForChild("Aura"))
--: O vento. Mesmo motivo da aura: enfeite puro a sessenta quadros, que o
--: servidor não tem por que replicar.
local Grass = require(script:WaitForChild("Grass"))

local UI = Forge.UI
local Net = Forge.Net
--: O tremor de câmera. Mora no cliente porque câmera é de quem está olhando --
--: um servidor que sacode a câmera de alguém sacode a de todo mundo.
local Feel = Forge.Feel
local BigNumber = Forge.Economy.BigNumber
--: Os ícones. 77 desenhos CC0 **já publicados nesta conta**, que é o detalhe
--: que decide: são os únicos que carregam em runtime, porque
--: `InsertService`/`rbxassetid` só entregam o que a conta possui.
local Icons = UI.ItchIcons

local player = Players.LocalPlayer
local T = UI.theme

--: O último estado que chegou. Uma variável, lida por tudo o que desenha:
--: guardar pedaços em cada widget é como metade da tela fica um tick atrás.
local state: any = nil

--: Formatação em um lugar só. `BigNumber` já sabe a escada de sufixos e o Qi
--: deste jogo chega a 1e19, onde `%d` vira notação científica sozinho.
local function short(value: number?): string
	return BigNumber.format(value or 0, 2)
end

local function clock(seconds: number): string
	local m = math.floor(seconds / 60)
	local s = math.floor(seconds % 60)
	return string.format("%dm %02ds", m, s)
end

local gui = UI.mount("DaoCultivo", { ignoreInset = false })

-- =================================================================== paleta

--: As cores do jogo, e não as do tema. O tema é escuro e neutro; este jogo é
--: tinta vermelha, ouro e jade. Uma tabela, para que painel, botão e moldura
--: não discordem sobre qual vermelho.
local C = {
	tinta = Color3.fromRGB(28, 24, 30),
	papel = Color3.fromRGB(238, 228, 202),
	rubro = Color3.fromRGB(168, 52, 54),
	ouro = Color3.fromRGB(224, 182, 92),
	jade = Color3.fromRGB(122, 206, 180),
	qi = Color3.fromRGB(92, 156, 240),
	corpo = Color3.fromRGB(226, 118, 84),
	sangue = Color3.fromRGB(198, 62, 66),
	fraco = Color3.fromRGB(148, 142, 152),
}

-- ============================================================ peças básicas

--: Uma moldura de laca: painel escuro com fio dourado. Repetida em toda tela
--: deste jogo, então é uma função e não seis blocos parecidos.
local function lacquer(parent: Instance, options: any): GuiObject
	local frame = UI.panel(parent, {
		size = options.size,
		pos = options.pos,
		anchor = options.anchor,
		color = options.color or C.tinta,
		radius = options.radius or 10,
		stroke = false,
		visible = options.visible,
	})
	frame.BackgroundTransparency = options.transparency or 0.12
	local edge = Instance.new("UIStroke")
	edge.Color = options.edge or C.ouro
	edge.Thickness = options.thickness or 1.6
	edge.Transparency = 0.35
	edge.Parent = frame
	return frame
end

--[[
	Um ícone desenhado, e a razão de não ser um caractere.

	A primeira versão desenhava as ações com `☯ ✧ ◉ ☁`. Num editor de texto
	isso lê como um jogo de cultivo; numa tela de mil pixels lê como um
	formulário. O gênero é ilustrado -- caldeirão, pergaminho, garra, espada --
	e nenhum glifo de fonte carrega isso.

	Devolve `nil` quando o token não existe no catálogo, e o chamador tem de
	continuar funcionando sem ícone: um botão que some porque uma imagem não
	resolveu é pior que um botão feio.
]]
local function glyph(parent: Instance, token: string, size: number,
                     position: UDim2): ImageLabel?
	local image = Instance.new("ImageLabel")
	image.Name = "Icone"
	image.BackgroundTransparency = 1
	image.Size = UDim2.fromOffset(size, size)
	image.Position = position
	image.AnchorPoint = Vector2.new(0.5, 0)
	image.ScaleType = Enum.ScaleType.Fit
	image.ImageColor3 = Color3.fromRGB(238, 228, 202)
	if not Icons.apply(image, token) then
		image:Destroy()
		return nil
	end
	image.Parent = parent
	return image
end

--: Um botão da casa. Alvo de toque com 48 px de altura por baixo, porque um
--: `UIScale` encolhe o alvo junto com o desenho e o mínimo do Roblox é 44.
local function knob(parent: Instance, text: string, options: any): TextButton
	local button = UI.button(parent, text, {
		size = options.size or UDim2.fromOffset(150, 48),
		pos = options.pos,
		anchor = options.anchor,
		color = options.color or C.tinta,
		textColor = options.textColor or C.papel,
		textSize = options.textSize or 15,
	})
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, options.radius or 8)
	corner.Parent = button
	local edge = Instance.new("UIStroke")
	edge.Color = options.edge or C.ouro
	edge.Thickness = 1.4
	edge.Transparency = 0.4
	edge.Parent = button
	button.AutoButtonColor = true
	return button
end

-- ============================================================= a coluna da esquerda

--[[
	Tudo da esquerda numa lista só, e a razão é uma tela real.

	A primeira versão posicionava cada peça à mão: a bolsa em (14,14), o
	trilho de botões em (14,92), a roda a 50% da altura. Numa janela de 680
	pixels o trilho ia até 392 e a roda começava em 262 -- os botões
	atravessados pelos anéis de Qi, e a barra de saúde escrita por cima do
	nome do jogador.

	Um `UIListLayout` não consegue se sobrepor. É a única garantia de layout
	que existe aqui, e vale mais do que qualquer coordenada escolhida com
	cuidado, porque a coordenada com cuidado está certa numa resolução só.

	O preço é conhecido e está no guia da casa: **o layout posiciona todo
	`GuiObject` visível abaixo dele, e não há flag de ignorar**. Então nada
	entra nesta coluna a não ser as fatias declaradas aqui, cada uma com sua
	altura -- um enfeite solto viraria uma linha de largura inteira e
	empurraria o resto para fora da tela.
]]
local column = Instance.new("Frame")
column.Name = "Coluna"
column.Size = UDim2.fromOffset(196, 430)
column.Position = UDim2.fromOffset(14, 12)
column.BackgroundTransparency = 1
column.Parent = gui
UI.list(column, { padding = 7 })

--[[
	Declarados aqui e preenchidos depois.

	Os botões precisam de `openPanel`, que precisa dos painéis; as linhas do
	painel do destino precisam de `startSpin`, que mora junto dos outros
	momentos, bem no fim do arquivo.

	A declaração antecipada não é estilo -- é a correção de um defeito exato.
	Sem ela, `startSpin` dentro de `redrawPanels` não é este local (ainda não
	existe quando a função é criada): resolve para um global nulo, e o botão de
	girar erra no clique. Compila, tipa, passa no doctor, e falha na primeira
	vez que alguém aperta.
]]
local openPanel: (string?) -> ()
local startSpin: (string) -> ()
--: `draw` lê estes três, e eles são construídos lá embaixo junto com os
--: outros momentos. Sem a declaração antecipada, `guideLabel` dentro de `draw`
--: não é este local -- ele ainda não existe quando a função é criada -- e
--: resolve para um global nulo. O erro só aparece no primeiro `StateSync`.
local guide: GuiObject
local guideLabel: TextLabel
local nextStep: () -> string
--: `draw` chama `reconcileFlight`, que mora com o resto do movimento no fim do
--: arquivo. Sem a declaração antecipada ela vira um global nulo e o voo nunca
--: liga -- exatamente o defeito que `startSpin` e `sprint` já tiveram.
local reconcileFlight: () -> ()
--: A porta de teste chama `sprint`, que mora junto do resto do movimento no
--: fim do arquivo. Sem a declaração antecipada ela vira um global nulo e a
--: porta erra no primeiro uso -- o mesmo defeito que `startSpin` já teve.
local sprint: (boolean) -> ()

-- ------------------------------------------------------------ a bolsa

local purse = lacquer(column, { size = UDim2.fromOffset(196, 52) })

--: O cristal. Um losango de neon em vez de um ícone: mesma leitura à
--: distância e não depende de nenhum asset ter chegado.
local crystal = Instance.new("Frame")
crystal.Size = UDim2.fromOffset(20, 20)
crystal.Position = UDim2.fromOffset(16, 16)
crystal.Rotation = 45
crystal.BackgroundColor3 = C.qi
crystal.BorderSizePixel = 0
crystal.Parent = purse
do
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 4)
	c.Parent = crystal
end

local pedrasLabel = UI.label(purse, "250", {
	size = 22, font = T.font.bold, color = C.papel,
	pos = UDim2.fromOffset(48, 0),
})
pedrasLabel.Size = UDim2.new(1, -58, 1, 0)

local meritosLabel = UI.label(column, "0 méritos", {
	size = 12, color = C.fraco, align = Enum.TextXAlignment.Center,
})
meritosLabel.Size = UDim2.fromOffset(196, 15)

-- ------------------------------------------------------------ os botões

--[[
	Oito botões numa grade de ícones, no lugar de cinco tiras e um trio.

	A versão anterior gastava duzentos e oitenta pixels de coluna com botões
	de largura inteira -- `Inventário`, `Manuais`, `Tábuas da Seita`,
	`Terraços`, `Título` -- e mais um trio de ícones acima deles. Somados com a
	roda e a barra de saúde, a coluna da esquerda ocupava mais de meia tela de
	altura, e a queixa foi exatamente essa: poluída.

	A grade custa cento e vinte. O que se perde é o nome em corpo quinze; o que
	se ganha é a montanha aparecendo atrás dela.

	A legenda continua embaixo de cada ícone, pequena. Ícone sozinho é bonito e
	mudo: quem abre o jogo pela primeira vez não sabe que um baú é o
	inventário, e este jogo tem de ser didático antes de ser elegante.
]]
--[[
	Seis destinos, não oito -- e o rótulo dentro do próprio botão.

	Duas fusões, e as duas tornam o jogo mais fácil de entender, não só menor:

	  **Pílulas virou parte da Loja.** Eram dois lugares para gastar pedra, e a
	  diferença entre eles ("um vende pílula, o outro vende ginseng") não é uma
	  distinção que o jogador tem motivo para carregar na cabeça.

	  **As Tábuas viraram parte do Título.** As duas telas mostram a mesma
	  escada de realms; uma dizia onde ele está e a outra o que vem depois.

	O rótulo é o texto do próprio `TextButton`, alinhado embaixo do ícone, e
	não um `TextLabel` irmão. Isso resolve de uma vez duas reclamações reais do
	`forge playtest`: dezessete elementos de texto vazios (todo botão de ícone
	contava como um) e um rótulo que só acompanha o botão enquanto ninguém
	mexer no layout.
]]
local grid = Instance.new("Frame")
grid.Name = "Menu"
grid.Size = UDim2.fromOffset(196, 132)
grid.BackgroundTransparency = 1
grid.Parent = column

local gridLayout = Instance.new("UIGridLayout")
--: Três colunas de 62: largo o bastante para "Terraços" caber por extenso, e
--: bem acima do alvo de toque mínimo de 44 do Roblox.
gridLayout.CellSize = UDim2.fromOffset(62, 62)
gridLayout.CellPadding = UDim2.fromOffset(4, 4)
gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
gridLayout.Parent = grid

local MENU = {
	{ id = "inventario", label = "Bolsa", colour = C.papel },
	{ id = "destino", label = "Destino", colour = C.ouro },
	{ id = "loja", label = "Loja", colour = C.jade },
	{ id = "manuais", label = "Manuais", colour = C.ouro },
	{ id = "tecnicas", label = "Técnicas", colour = C.qi },
	{ id = "zonas", label = "Terraços", colour = C.jade },
}

for order, entry in MENU do
	--: Fundo mais claro que a tinta do painel. A 46 pixels num fundo quase
	--: preto, metade da grade lia como caixas vazias na primeira foto.
	local button = knob(grid, entry.label, {
		size = UDim2.fromOffset(62, 62), textSize = 11,
		textColor = entry.colour,
		color = Color3.fromRGB(46, 40, 50),
	})
	button.LayoutOrder = order
	button.TextYAlignment = Enum.TextYAlignment.Bottom
	button.TextTruncate = Enum.TextTruncate.AtEnd
	local pad = Instance.new("UIPadding")
	pad.PaddingBottom = UDim.new(0, 5)
	pad.Parent = button

	--: Sem tingir. `ImageColor3` multiplica a arte, então pintar um desenho já
	--: escuro com uma cor média produz um desenho mais escuro ainda. A cor
	--: informativa fica no rótulo, que é texto e não sofre disso.
	glyph(button, Content.icons[entry.id] or "", 28, UDim2.new(0.5, 0, 0, 8))

	button.Activated:Connect(function()
		openPanel(entry.id)
	end)
end

-- ------------------------------------------------------------ a zona

--[[
	Onde você está sentado, e o que isso multiplica.

	Estava numa faixa de quatrocentos pixels no topo do centro da tela, que é
	o lugar mais caro que existe -- e por onde o jogador olha para ver o
	próprio personagem. Aqui embaixo da bolsa custa trinta e quatro pixels de
	uma coluna que ele já está lendo.

	Continua mostrando o que a zona **promete** quando ela não está pagando:
	um discípulo externo sentado no Pico precisa ver o x19 que não recebe,
	senão o terraço é só um lugar bonito onde o número não mudou.
]]
local zoneBanner = lacquer(column, { size = UDim2.fromOffset(196, 36) })

local zoneName = UI.label(zoneBanner, "—", {
	size = 12, align = Enum.TextXAlignment.Center, color = C.papel,
	pos = UDim2.fromOffset(4, 3),
})
zoneName.Size = UDim2.new(1, -8, 0, 15)

local zoneMult = UI.label(zoneBanner, "—", {
	size = 11, align = Enum.TextXAlignment.Center, color = C.ouro,
	pos = UDim2.fromOffset(4, 18),
})
zoneMult.Size = UDim2.new(1, -8, 0, 14)

-- ------------------------------------------------------------ a roda de Qi

--[[
	Dois anéis de segmentos, Qi por fora e Corpo por dentro.

	Segmentos e não um arco: um arco de verdade em Roblox exige duas metades
	giradas dentro de pais que cortam, e o resultado pisca no meio quando a
	fração cruza a metade. Trinta e dois retângulos girados custam o mesmo,
	não têm caso especial nenhum, e à distância de leitura lêem como anel.
]]
local WHEEL = 152
local wheelHolder = Instance.new("Frame")
wheelHolder.Name = "Roda"
wheelHolder.Size = UDim2.fromOffset(196, WHEEL)
wheelHolder.BackgroundTransparency = 1
wheelHolder.Parent = column

local function ring(radius: number, thickness: number, colour: Color3): { Frame }
	local segments = {}
	local count = 32
	for index = 1, count do
		local angle = (index - 1) / count * math.pi * 2 - math.pi / 2
		local pip = Instance.new("Frame")
		pip.Size = UDim2.fromOffset(thickness, thickness * 2.4)
		pip.AnchorPoint = Vector2.new(0.5, 0.5)
		pip.Position = UDim2.new(0.5, math.cos(angle) * radius,
			0.5, math.sin(angle) * radius)
		pip.Rotation = math.deg(angle) + 90
		pip.BackgroundColor3 = colour
		pip.BackgroundTransparency = 0.82
		pip.BorderSizePixel = 0
		pip.Parent = wheelHolder
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 2)
		c.Parent = pip
		segments[index] = pip
	end
	return segments
end

local qiRing = ring(WHEEL * 0.44, 6, C.qi)
local bodyRing = ring(WHEEL * 0.32, 5, C.corpo)

local function fillRing(segments: { Frame }, alpha: number)
	local lit = math.floor(math.clamp(alpha, 0, 1) * #segments + 0.5)
	for index, pip in segments do
		pip.BackgroundTransparency = if index <= lit then 0 else 0.82
	end
end

local wheelCore = UI.label(wheelHolder, "—", {
	size = 16, font = T.font.bold, align = Enum.TextXAlignment.Center,
	color = C.papel, wrap = true,
})
wheelCore.Size = UDim2.new(1, -70, 0, 38)
wheelCore.Position = UDim2.new(0, 35, 0.5, -26)

local wheelSub = UI.label(wheelHolder, "—", {
	size = 12, align = Enum.TextXAlignment.Center, color = C.fraco, wrap = true,
})
wheelSub.Size = UDim2.new(1, -70, 0, 28)
wheelSub.Position = UDim2.new(0, 35, 0.5, 14)

--: Contorno nos dois. Eles ficam **dentro** do anel de Qi, sobre segmentos
--: acesos e apagados alternados, e texto claro sobre um fundo que muda a cada
--: pixel é texto que ninguém lê. Um contorno escuro custa nada e resolve.
wheelCore.TextStrokeTransparency = 0.35
wheelSub.TextStrokeTransparency = 0.45

-- ------------------------------------------------------------ a saúde

--[[
	A saúde, que é a metade visível do caminho do corpo.

	Lida do `Humanoid` e não do `StateSync`: a vida muda por dano, por cura e
	por respawn, e nenhum desses passa pelo laço de cultivo. Um número de
	saúde vindo do estado ficaria correto só nos instantes em que ninguém
	estivesse apanhando.
]]
local healthLabel = UI.label(column, "Saúde  —", {
	size = 13, font = T.font.mono, align = Enum.TextXAlignment.Center,
	color = C.sangue,
})
healthLabel.Size = UDim2.fromOffset(196, 18)

local healthBar = UI.bar(column, {
	size = UDim2.fromOffset(196, 10),
	color = C.sangue,
	radius = 5,
})

local function watchHealth(character: Model)
	local humanoid = character:WaitForChild("Humanoid", 8)
	if humanoid == nil or not humanoid:IsA("Humanoid") then
		return
	end
	local function refresh()
		local max = math.max(humanoid.MaxHealth, 1)
		healthLabel.Text = string.format("Saúde  %s / %s",
			short(humanoid.Health), short(max))
		healthBar:set(humanoid.Health / max)
	end
	humanoid.HealthChanged:Connect(refresh)
	humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(refresh)
	refresh()
end

player.CharacterAdded:Connect(watchHealth)
if player.Character ~= nil then
	task.spawn(watchHealth, player.Character)
end

-- ============================================================ os buffs

local buffColumn = Instance.new("Frame")
buffColumn.Name = "Efeitos"
buffColumn.Size = UDim2.fromOffset(250, 130)
buffColumn.Position = UDim2.new(1, -20, 0, 14)
buffColumn.AnchorPoint = Vector2.new(1, 0)
buffColumn.BackgroundTransparency = 1
buffColumn.Parent = gui
UI.list(buffColumn, { padding = 6, align = Enum.HorizontalAlignment.Right })

local function drawBuffs(list: { any })
	for _, child in buffColumn:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	for _, buff in list do
		local row = lacquer(buffColumn, {
			size = UDim2.fromOffset(250, 34),
			edge = if buff.track == "corpo" then C.corpo else C.qi,
		})
		local name = UI.label(row, buff.name, {
			size = 14, color = C.papel, pos = UDim2.fromOffset(10, 0),
		})
		name.Size = UDim2.new(1, -80, 1, 0)
		local timer = UI.label(row, clock(buff.remaining), {
			size = 14, font = T.font.mono, color = C.ouro,
			align = Enum.TextXAlignment.Right,
		})
		timer.Size = UDim2.new(1, -12, 1, 0)
	end
end

-- ====================================================== os slots de técnica

--[[
	Quatro losangos à direita -- e nada escrito enquanto estiverem vazios.

	Antes cada um vinha com a palavra `Nenhum` ao lado, e o resultado era uma
	coluna com a mesma palavra repetida quatro vezes ocupando um terço da
	borda direita da tela. Quatro vezes a mesma informação é ruído; a moldura
	vazia já diz que está vazia.

	O nome volta assim que houver o que nomear, que é quando ele passa a ser
	informação. Os losangos também encolheram de 52 para 40: eles são um
	lembrete, não um painel.

	O losango é um `TextButton` girado 45°; o número dentro dele é irmão e não
	filho, porque um rótulo dentro de um pai girado gira junto.
]]
local slotColumn = Instance.new("Frame")
slotColumn.Name = "Tecnicas"
slotColumn.Size = UDim2.fromOffset(180, Content.techniqueSlots * 58)
slotColumn.Position = UDim2.new(1, -16, 0.5, 30)
slotColumn.AnchorPoint = Vector2.new(1, 0.5)
slotColumn.BackgroundTransparency = 1
slotColumn.Parent = gui

local slotLabels: { TextLabel } = {}
for index = 1, Content.techniqueSlots do
	local y = (index - 1) * 58

	--: Quarenta e seis, não quarenta. O `forge playtest` recusa alvo de toque
	--: abaixo de 44 -- que é o mínimo do Roblox -- e ele estava certo: um
	--: losango de 40 num celular é um botão que erra.
	local diamond = Instance.new("TextButton")
	diamond.Size = UDim2.fromOffset(46, 46)
	diamond.Position = UDim2.fromOffset(180 - 52, y + 4)
	diamond.Rotation = 45
	diamond.BackgroundColor3 = C.tinta
	diamond.BackgroundTransparency = 0.25
	diamond.Text = ""
	diamond.BorderSizePixel = 0
	diamond.AutoButtonColor = true
	diamond.Parent = slotColumn
	do
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 5)
		c.Parent = diamond
		local edge = Instance.new("UIStroke")
		edge.Color = C.ouro
		edge.Thickness = 1.3
		edge.Transparency = 0.5
		edge.Parent = diamond
	end
	diamond.Activated:Connect(function()
		openPanel("tecnicas")
	end)

	local number = UI.label(slotColumn, tostring(index), {
		size = 11, color = C.ouro, align = Enum.TextXAlignment.Center,
		pos = UDim2.fromOffset(180 - 52, y + 18),
	})
	number.Size = UDim2.fromOffset(46, 18)

	--: Nasce invisível. Um `TextLabel` vazio conta como elemento de texto vazio
	--: no `forge playtest`, e a checagem está certa: um rótulo sem texto é
	--: espaço reservado para nada.
	local caption = UI.label(slotColumn, "", {
		size = 12, color = C.ouro, align = Enum.TextXAlignment.Right,
		pos = UDim2.fromOffset(0, y + 18),
	})
	caption.Size = UDim2.fromOffset(180 - 60, 18)
	caption.Visible = false
	slotLabels[index] = caption
end

-- ============================================================== o painel central

--[[
	O centro: a poça, a taxa, o teto e o botão de avanço.

	É o único lugar da tela onde o jogo acontece, então tudo aqui é grande, e
	o `AVANÇO` só aparece quando pode ser apertado. Um botão permanentemente
	cinza ensina o jogador a não olhar para aquele canto.
]]
--[[
	Baixo, raso, e **fora do meio da tela**.

	A primeira versão ocupava 150 pixels de altura a 140 do rodapé, com o botão
	de avanço 160 acima dela. Numa janela de 675 pixels isso é a faixa central
	inteira -- e a faixa central é onde fica o personagem sentado meditando,
	que é a coisa que o jogo inteiro existe para mostrar. O HUD estava tapando
	o jogo.

	Agora ele é uma tira de 104 pixels colada na barra de ações, e o avanço fica
	ao lado dela em vez de acima. O que se perde é o tamanho do número; o que se
	ganha é poder ver o cultivador.
]]
local stage = lacquer(gui, {
	size = UDim2.fromOffset(480, 104),
	pos = UDim2.new(0.5, 0, 1, -104),
	anchor = Vector2.new(0.5, 1),
	transparency = 0.22,
})

local poolLabel = UI.label(stage, "0", {
	size = 32, font = T.font.bold, align = Enum.TextXAlignment.Center,
	color = C.papel, pos = UDim2.fromOffset(0, 4),
})
poolLabel.Size = UDim2.new(1, 0, 0, 36)

local rateLabel = UI.label(stage, "", {
	size = 14, align = Enum.TextXAlignment.Center, color = C.jade,
	pos = UDim2.fromOffset(0, 39),
})
rateLabel.Size = UDim2.new(1, 0, 0, 17)

local poolBar = UI.bar(stage, {
	size = UDim2.new(1, -32, 0, 13),
	pos = UDim2.fromOffset(16, 59),
	color = C.qi,
	radius = 7,
})

local ceilingLabel = UI.label(stage, "", {
	size = 12, color = C.fraco, pos = UDim2.fromOffset(16, 76),
})
ceilingLabel.Size = UDim2.new(0.62, 0, 0, 16)

local multLabel = UI.label(stage, "", {
	size = 12, color = C.ouro, align = Enum.TextXAlignment.Right,
	pos = UDim2.fromOffset(0, 76),
})
multLabel.Size = UDim2.new(1, -16, 0, 16)

--: A dica do toque vai para a linha da taxa em vez de ter linha própria. Uma
--: linha de dica permanente é vinte pixels de tela por uma frase que o jogador
--: lê uma vez na vida.
local tapHint = UI.label(stage, "", {
	size = 11, align = Enum.TextXAlignment.Center, color = C.fraco,
	pos = UDim2.fromOffset(0, 90),
})
tapHint.Size = UDim2.new(1, 0, 0, 14)

--: Ao lado da tira, não acima dela. Acima é onde o personagem está.
local advance = knob(gui, "AVANÇO", {
	size = UDim2.fromOffset(176, 60),
	pos = UDim2.new(0.5, 252, 1, -104),
	anchor = Vector2.new(0, 1),
	color = C.ouro, textColor = C.tinta, textSize = 20,
})
advance.Visible = false

local chanceLabel = UI.label(gui, "", {
	size = 12, align = Enum.TextXAlignment.Center, color = C.ouro, wrap = true,
	pos = UDim2.new(0.5, 252, 1, -168),
	anchor = Vector2.new(0, 1),
})
chanceLabel.Size = UDim2.fromOffset(176, 34)
chanceLabel.Visible = false

-- ============================================================== a barra de ações

--: Qual caminho a tela está mostrando. Uma variável, porque a poça, a barra,
--: o teto e o avanço têm todos de falar da mesma coluna -- e mostrar Qi com
--: um botão de avanço de corpo é o tipo de discordância que só aparece
--: quando alguém perde uma poça cheia.
local viewing = "qi"

local actionRow = Instance.new("Frame")
actionRow.Name = "Acoes"
actionRow.Size = UDim2.fromOffset(#Content.actions * 108, 78)
actionRow.Position = UDim2.new(0.5, 0, 1, -22)
actionRow.AnchorPoint = Vector2.new(0.5, 1)
actionRow.BackgroundTransparency = 1
actionRow.Parent = gui
UI.list(actionRow, { horizontal = true, padding = 12,
	align = Enum.HorizontalAlignment.Center })

local actionButtons: { [string]: TextButton } = {}

--: Uma função, dois chamadores: o botão e o `BindableFunction` dos testes.
--: Toda ação da tela passa por aqui, e é por isso que um teste consegue
--: dirigir o jogo sem clique sintético -- que o Studio recusa.
local function press(id: string)
	if id == "cultivar" or id == "treinar" then
		viewing = if id == "cultivar" then "qi" else "corpo"
		local already = state and state.action == id
		Net.send("SetAction", { action = if already then "nenhum" else id })
	elseif id == "golpe" then
		--[[
			Golpear levanta primeiro.

			Um cultivador sentado está preso ao assento: ele não anda, não é
			teleportado e não alcança nada. Golpear naquele estado mandava a
			mensagem, o servidor não achava besta nenhuma ao alcance, e o botão
			simplesmente não fazia nada -- sem recusa, sem aviso, sem pista.
			Custou uma bateria inteira de testes de caça que "não pagavam".

			Levantar sozinho é o que o jogador quer de qualquer forma: ninguém
			aperta Golpear com a intenção de continuar meditando.
		]]
		if state ~= nil and state.action ~= "nenhum" then
			Net.send("SetAction", { action = "nenhum" })
		end
		--: Sem alvo no pedido. Quem decide o que foi atingido é o servidor, a
		--: partir da posição do personagem: um alvo escolhido pelo cliente é um
		--: alvo do outro lado do mapa.
		Net.send("Swing", {})
	elseif id == "voar" then
		Net.send("Fly", { on = not (state and state.flying) })
	elseif id == "senso" then
		--: O senso é do cliente: ele acende o que já está lá. Pedir ao
		--: servidor uma informação que o cliente já tem é latência sem
		--: contrapartida.
		local veins = workspace:FindFirstChild("Seita")
		veins = veins and veins:FindFirstChild("Veias")
		if veins then
			for _, cluster in veins:GetChildren() do
				local ready = cluster:GetAttribute("pronta") == true
				for _, part in cluster:GetDescendants() do
					if part:IsA("BasePart") and ready then
						local beam = TweenService:Create(part,
							TweenInfo.new(0.9, Enum.EasingStyle.Quad,
								Enum.EasingDirection.InOut, 3, true),
							{ Transparency = 0 })
						beam:Play()
					end
				end
			end
			UI.toast("Senso de Qi: as veias prontas brilham")
		end
	end
end

--[[
	Um botão por ação: desenho em cima, nome embaixo, tudo dentro do próprio
	`TextButton`.

	O nome é o texto do botão, alinhado embaixo, e não um rótulo separado. Dois
	motivos: um `TextButton` sem texto conta como "elemento de texto vazio" no
	`forge playtest`, que é uma checagem real contra telas meio construídas; e
	um rótulo irmão precisa acompanhar o botão em toda mudança de layout, que é
	como metade de uma barra acaba deslocada da outra metade.

	O ícone é filho do botão, portanto desenha por cima dele -- e por isso fica
	no topo, longe da linha do texto. Sob `ZIndexBehavior.Sibling` um filho não
	tem como ir para trás do pai, e tentar resolver isso com ZIndex é sempre o
	caminho errado.
]]
for _, action in Content.actions do
	local button = knob(actionRow, action.name, {
		size = UDim2.fromOffset(108, 74), textSize = 13,
		color = C.tinta, textColor = C.papel,
	})
	button.TextYAlignment = Enum.TextYAlignment.Bottom
	button.TextTruncate = Enum.TextTruncate.AtEnd
	local pad = Instance.new("UIPadding")
	pad.PaddingBottom = UDim.new(0, 8)
	pad.Parent = button

	glyph(button, Content.icons[action.id] or "", 32, UDim2.new(0.5, 0, 0, 10))

	button.Activated:Connect(function()
		press(action.id)
	end)
	actionButtons[action.id] = button
end

advance.Activated:Connect(function()
	Net.send("Breakthrough", { track = viewing })
end)

-- =================================================================== painéis

--[[
	Os painéis, todos com a mesma moldura e um só aberto por vez.

	Um por vez porque a tela já tem cinco zonas ocupadas: dois painéis abertos
	cobrem a roda e o centro, que são justamente as duas coisas que o jogador
	precisa continuar vendo enquanto compra.
]]
local panels: { [string]: GuiObject } = {}
local panelBodies: { [string]: GuiObject } = {}
local current: string? = nil

local function panel(id: string, title: string): GuiObject
	local shell = lacquer(gui, {
		size = UDim2.fromOffset(520, 420),
		pos = UDim2.fromScale(0.5, 0.46),
		anchor = Vector2.new(0.5, 0.5),
		transparency = 0.02,
		visible = false,
	})
	shell.Name = "Painel_" .. id

	local heading = UI.label(shell, title, {
		size = 24, font = T.font.title, color = C.ouro,
		align = Enum.TextXAlignment.Center, pos = UDim2.fromOffset(0, 14),
	})
	heading.Size = UDim2.new(1, 0, 0, 32)

	local close = knob(shell, "✕", {
		size = UDim2.fromOffset(44, 44),
		pos = UDim2.new(1, -12, 0, 10),
		anchor = Vector2.new(1, 0),
		textSize = 18,
	})
	close.Activated:Connect(function()
		openPanel(nil)
	end)

	--: O corpo é um irmão com rolagem própria. O cabeçalho fica fora dele para
	--: não ser levado embora quando a lista rola.
	local body = Instance.new("ScrollingFrame")
	body.Name = "Corpo"
	body.Size = UDim2.new(1, -28, 1, -70)
	body.Position = UDim2.fromOffset(14, 56)
	body.BackgroundTransparency = 1
	body.BorderSizePixel = 0
	body.ScrollBarThickness = 5
	body.ScrollBarImageColor3 = C.ouro
	body.CanvasSize = UDim2.new()
	body.AutomaticCanvasSize = Enum.AutomaticSize.Y
	body.Parent = shell
	UI.list(body, { padding = 8 })

	panels[id] = shell
	panelBodies[id] = body
	return body
end

--: Definida como variável no topo e atribuída aqui: os botões precisam dela
--: antes dos painéis existirem.
local redrawPanels: () -> ()

openPanel = function(id: string?)
	for name, shell in panels do
		shell.Visible = name == id
	end
	current = id
	if id ~= nil then
		redrawPanels()
	end
end

local inventoryBody = panel("inventario", "Inventário")
local destinyBody = panel("destino", "Pavilhão do Destino")
local techniqueBody = panel("tecnicas", "Técnicas")
local shopBody = panel("loja", "Pavilhão de Trocas")
--: `alquimia` continua existindo como destino porque os balcões do mundo
--: mandam o jogador para ele por nome. Aponta para o mesmo corpo da loja: um
--: segundo painel com metade dos itens seria a mesma confusão de antes com
--: outro título.
panels.alquimia = panels.loja
panelBodies.alquimia = panelBodies.loja
local manualBody = panel("manuais", "Manuais de Cultivo")
local zonesBody = panel("zonas", "Os Terraços da Montanha")
local titleBody = panel("titulo", "Títulos e a Escada")

--[[
	Dois nomes que apontam para painéis que já existem.

	`alquimia` e `tabuas` deixaram de ser telas próprias -- a loja vende as
	pílulas, o painel de títulos mostra a escada -- mas os dois continuam sendo
	destinos válidos: os balcões do mundo mandam o jogador para `alquimia` pelo
	nome, e um `openPanel` com um id inexistente fecha tudo sem dizer nada.
]]
panels.alquimia = panels.loja
panelBodies.alquimia = panelBodies.loja
panels.tabuas = panels.titulo
panelBodies.tabuas = panelBodies.titulo

--: Uma linha de lista: nome, descrição, e um botão à direita. Todos os seis
--: painéis são feitos disto, então mudar o desenho de uma linha muda os seis.
local function row(parent: Instance, title: string, note: string,
                   action: string?, colour: Color3?, onClick: (() -> ())?)
	local holder = lacquer(parent, {
		size = UDim2.new(1, -8, 0, 74),
		edge = colour or C.ouro,
		transparency = 0.2,
	})
	local name = UI.label(holder, title, {
		size = 17, font = T.font.bold, color = colour or C.papel,
		pos = UDim2.fromOffset(14, 8),
	})
	name.Size = UDim2.new(1, -160, 0, 22)

	local blurb = UI.label(holder, note, {
		size = 13, color = C.fraco, pos = UDim2.fromOffset(14, 32), wrap = true,
	})
	blurb.Size = UDim2.new(1, -160, 0, 36)

	if action ~= nil then
		local button = knob(holder, action, {
			size = UDim2.fromOffset(124, 46),
			pos = UDim2.new(1, -12, 0.5, 0),
			anchor = Vector2.new(1, 0.5),
			color = C.rubro,
		})
		if onClick then
			button.Activated:Connect(onClick)
		end
	end
	return holder
end

local function clear(body: GuiObject)
	for _, child in body:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

redrawPanels = function()
	if state == nil or current == nil then
		return
	end

	if current == "inventario" then
		clear(inventoryBody)
		row(inventoryBody, state.root.name,
			string.format("Raiz espiritual · ×%.2f no Qi%s",
				state.root.mult, if state.root.locked then " · selada" else ""),
			if state.root.locked then "Quebrar" else "Selar",
			Content.tierColour[state.root.tier],
			function()
				Net.send("Lock", { kind = "raiz", on = not state.root.locked })
			end)
		row(inventoryBody, state.constitution.name,
			string.format("Constituição · ×%.2f no corpo%s",
				state.constitution.mult,
				if state.constitution.locked then " · selada" else ""),
			if state.constitution.locked then "Quebrar" else "Selar",
			Content.tierColour[state.constitution.tier],
			function()
				Net.send("Lock", {
					kind = "constituicao", on = not state.constitution.locked })
			end)
		row(inventoryBody, string.format("%d pedras espirituais", state.pedras),
			"Caem dos avanços e das veias. Compram pílulas, selos e giros.", nil, C.qi)
		row(inventoryBody, string.format("%d méritos", state.meritos),
			"Só o rompimento de realm paga mérito.", nil, C.ouro)
		row(inventoryBody, string.format("%d avanços · %d despertares",
			state.breaks, state.spins), "O que você já fez nesta vida.", nil, C.fraco)

	elseif current == "destino" then
		clear(destinyBody)
		row(destinyBody, state.root.name,
			string.format("Sua raiz agora · ×%.2f\n%s", state.root.mult,
				"Menos elementos é melhor: uma raiz única concentra o que uma quíntupla dispersa."),
			string.format("Girar · %d", Content.spins.raiz.cost),
			Content.tierColour[state.root.tier],
			function()
				startSpin("raiz")
				Net.send("Spin", { kind = "raiz" })
			end)
		row(destinyBody, state.constitution.name,
			string.format("Sua constituição agora · ×%.2f", state.constitution.mult),
			string.format("Girar · %d", Content.spins.constituicao.cost),
			Content.tierColour[state.constitution.tier],
			function()
				startSpin("constituicao")
				Net.send("Spin", { kind = "constituicao" })
			end)
		for _, root in Content.roots do
			local mine = root.id == state.root.id
			row(destinyBody, root.name,
				string.format("Tier %d · ×%.2f · %s", root.tier, root.mult, root.note),
				if mine then "Sua" else nil, Content.tierColour[root.tier])
		end

	elseif current == "tecnicas" then
		clear(techniqueBody)
		row(techniqueBody, string.format("Equipadas: Qi ×%.2f · golpe ×%.2f",
			state.tecnicaQi or 1, state.tecnicaPoder or 1),
			string.format("Vida ×%.2f · velocidade ×%.2f. São quatro slots: "
				.. "comprar é para sempre, equipar é a decisão.",
				state.tecnicaSaude or 1, state.tecnicaVelocidade or 1),
			nil, C.ouro)
		for _, technique in Content.techniques do
			local locked = state.qi.realm < technique.realm
			local slot = 1
			for index = 1, Content.techniqueSlots do
				if state.techniques[index] and state.techniques[index].id == "" then
					slot = index
					break
				end
			end
			--: O efeito primeiro, o sabor depois. Um jogador decide equipar por
			--: causa do número; a frase é o que o faz gostar da decisão.
			row(techniqueBody, technique.name,
				string.format("%s\nExige %s · %d pedras · %s",
					Content.techniqueBlurb(technique),
					Content.qiRealms[technique.realm].name, technique.cost,
					technique.note),
				if locked then nil else "Equipar",
				if locked then C.fraco else C.qi,
				function()
					Net.send("Equip", { slot = slot, technique = technique.id })
				end)
		end

	elseif current == "loja" or current == "alquimia" then
		clear(shopBody)
		--: Pílulas primeiro, itens depois. Eram dois painéis, e a diferença
		--: entre eles -- "um vende pílula, o outro vende ginseng" -- não é uma
		--: distinção que o jogador tem motivo para carregar na cabeça.
		for _, pill in Content.pills do
			row(shopBody, pill.name,
				string.format("%s · ×%.1f por %dm · %d pedras\n%s",
					if pill.track == "ambos" then "Qi e corpo"
						elseif pill.track == "qi" then "Qi" else "Corpo",
					pill.mult, math.floor(pill.seconds / 60), pill.cost, pill.note),
				"Tomar", C.jade,
				function()
					Net.send("Consume", { pill = pill.id })
				end)
		end
		for _, item in Content.items do
			local what = if item.kind == "instante"
				then string.format("%s de uma vez, em %s",
					if item.amount == 1 then "um degrau"
						else string.format("%d degraus", item.amount),
					if item.track == "qi" then "Qi" else "corpo")
				else "percepção para a próxima tribulação"
			row(shopBody, item.name,
				string.format("%d pedras · %s\n%s", item.cost, what, item.note),
				"Comprar",
				if item.track == "corpo" then C.corpo
					elseif item.kind == "percep" then C.ouro else C.qi,
				function()
					Net.send("Buy", { item = item.id })
				end)
		end
		row(shopBody, "O que a loja nunca vende",
			"Manual, raiz e constituição. O permanente só vem de caçar ou de "
			.. "rolar — senão juntar pedra sentado compraria o jogo inteiro.",
			nil, C.fraco)

	elseif current == "manuais" then
		clear(manualBody)
		local held = state.manuals or {}
		row(manualBody, string.format("×%.2f no Qi  ·  ×%.2f no corpo",
			state.manualQi or 1, state.manualCorpo or 1),
			string.format("%d manuais lidos. Permanentes, cumulativos, e a "
				.. "única coisa do jogo que não se compra.", #held),
			nil, C.ouro)
		for _, manual in held do
			row(manualBody, manual.name,
				string.format("%s · ×%.2f em %s%s\n%s",
					manual.grade, manual.mult,
					if manual.track == "ambos" then "ambos os caminhos"
						elseif manual.track == "qi" then "Qi" else "corpo",
					if manual.copies > 1
						then string.format(" · %d cópias", manual.copies) else "",
					manual.note),
				nil, Content.gradeColour(manual.grade))
		end
		if #held == 0 then
			row(manualBody, "Nenhum manual ainda",
				"Eles caem de bestas do Bosque, e de nada mais. Quanto maior o "
				.. "rank da besta, maior o grau que ela guarda.",
				nil, C.fraco)
		end

	elseif current == "zonas" then
		clear(zonesBody)
		for _, zone in Content.zones do
			local open = state.qi.realm >= zone.rank
			local here = state.zone ~= nil and state.zone.id == zone.id
			row(zonesBody, zone.name,
				string.format("x%.1f  ·  exige %s\n%s%s",
					zone.mult, Content.qiRealms[zone.rank].name, zone.note,
					if here then "\n— você está aqui —" else ""),
				nil,
				if here then C.ouro elseif open then zone.colour else C.fraco)
		end

	elseif current == "titulo" or current == "tabuas" then
		clear(titleBody)
		row(titleBody, state.qi.title, "Caminho do Qi", nil, C.qi)
		row(titleBody, state.corpo.title, "Caminho do Corpo", nil, C.corpo)
		row(titleBody, state.root.name,
			string.format("Tier %d · %s", state.root.tier, state.root.note or ""),
			nil, Content.tierColour[state.root.tier])
		row(titleBody, state.constitution.name,
			string.format("Tier %d", state.constitution.tier), nil,
			Content.tierColour[state.constitution.tier])

		--: A escada inteira, abaixo dos títulos atuais. Era um painel separado
		--: ("Tábuas da Seita") que mostrava exatamente a mesma coisa vista de
		--: outro ângulo -- e um jogador que precisa de dois lugares para
		--: entender uma escada tem uma escada mal explicada.
		for index, realm in Content.qiRealms do
			local here = index == state.qi.realm
			row(titleBody, realm.name,
				if here
					then string.format("Você está aqui — estágio %d de %d",
						state.qi.stage, Content.stagesPerRealm)
					else (realm.note or "—"),
				nil,
				if here then C.ouro
					elseif index < state.qi.realm then C.jade else C.fraco)
		end
	end
end

-- ================================================================== desenhar

local function draw()
	if state == nil then
		return
	end
	local track = if viewing == "qi" then state.qi else state.corpo
	local colour = if viewing == "qi" then C.qi else C.corpo

	pedrasLabel.Text = short(state.pedras)
	meritosLabel.Text = string.format("%d méritos  ·  golpe %s",
		state.meritos, short(state.golpe or 0))

	poolLabel.Text = short(track.pool)
	poolLabel.TextColor3 = if track.ready then C.ouro else C.papel
	rateLabel.Text = if state.action == "nenhum"
		then "sentado ninguém cultiva — escolha um caminho"
		else string.format("(%s / tick)", short(track.perTick))
	rateLabel.TextColor3 = colour

	poolBar.fill.BackgroundColor3 = colour
	--[[
		A barra mostra o progresso **dentro** do degrau atual, e o resto da poça
		vira uma contagem de avanços guardados.

		Sem essa segunda leitura o acúmulo fica invisível: passada a exigência
		a barra ficaria cravada em 100% e um jogador que voltou com Qi para
		cinco avanços veria exatamente a mesma tela de quem voltou com um.
	]]
	local within = if track.required > 0
		then (track.pool % track.required) / track.required
		else 0
	poolBar:set(if track.ready then (if track.banked >= 1 then 1 else within) else within)

	ceilingLabel.Text = if track.banked >= 1
		then string.format("%d avanço%s guardado%s  ·  exige %s",
			track.banked, if track.banked == 1 then "" else "s",
			if track.banked == 1 then "" else "s", short(track.required))
		else string.format("%s / %s", short(track.pool), short(track.required))
	ceilingLabel.TextColor3 = if track.ready then C.ouro else C.fraco
	multLabel.Text = string.format("Multiplicador: %.2fx", track.multiplier)

	tapHint.Text = if state.action ~= "nenhum"
		then "Toque — Impulso"
		else ""

	advance.Visible = track.ready
	advance.Text = if track.banked > 1
		then string.format("AVANÇO  x%d", track.banked)
		else "AVANÇO"
	chanceLabel.Visible = track.ready and track.chance < 1
	if chanceLabel.Visible then
		chanceLabel.Text = string.format(
			"tribulação de realm · %d%% de passar%s",
			math.floor(track.chance * 100 + 0.5),
			if track.insight > 0
				then string.format("  ·  %d percepções", track.insight)
				else "")
	end

	local zone = state.zone
	if zone ~= nil then
		zoneName.Text = zone.name
		zoneName.TextColor3 = if zone.allowed then C.papel else C.fraco
		zoneMult.Text = if zone.allowed
			then string.format("x%.1f", zone.mult)
			else string.format("x%.1f  ·  trancado: exige %s",
				zone.mult, Content.qiRealms[zone.rank].name)
		zoneMult.TextColor3 = if zone.allowed then C.ouro else C.sangue
	end

	--: Os anéis mostram o degrau corrente, não a poça inteira: cheios o tempo
	--: todo, eles não diriam mais nada depois do primeiro acúmulo.
	fillRing(qiRing, if state.qi.required > 0
		then math.min(1, (state.qi.pool % state.qi.required) / state.qi.required
			+ (if state.qi.banked >= 1 then 1 else 0))
		else 0)
	fillRing(bodyRing, if state.corpo.required > 0
		then math.min(1, (state.corpo.pool % state.corpo.required) / state.corpo.required
			+ (if state.corpo.banked >= 1 then 1 else 0))
		else 0)
	wheelCore.Text = state.qi.title
	wheelCore.TextColor3 = if state.qi.ready then C.ouro else C.papel
	wheelSub.Text = state.corpo.title

	for id, button in actionButtons do
		local on = state.action == id
			or (id == "voar" and state.flying)
		button.BackgroundColor3 = if on then C.rubro else C.tinta
	end
	actionButtons.voar.TextTransparency = if state.canFly then 0 else 0.6

	--: Vazio fica vazio. Ver `Nenhum` quatro vezes não ensina nada que a
	--: moldura vazia já não diga.
	for index = 1, Content.techniqueSlots do
		local slot = state.techniques[index]
		local named = slot ~= nil and slot.id ~= ""
		slotLabels[index].Text = if named then slot.name else ""
		slotLabels[index].Visible = named
	end

	drawBuffs(state.buffs or {})
	--: O voo entra e sai daqui, junto com o resto da tela: é o mesmo estado, no
	--: mesmo tick, e não um segundo canal que pode não chegar.
	reconcileFlight()

	local step = nextStep()
	guideLabel.Text = step
	guide.Visible = step ~= ""

	if current ~= nil then
		redrawPanels()
	end
end

-- ================================================================ o servidor

Net.on("StateSync", function(payload)
	if payload == nil then
		return
	end
	state = payload
	draw()
end)

Net.on("Notify", function(payload)
	UI.toast(tostring(payload.text))
	--: Um balcão pede um painel junto com o aviso. Um campo opcional em vez de
	--: um canal novo: abrir um painel é a mesma notificação com um destino.
	if payload.panel ~= nil then
		openPanel(tostring(payload.panel))
	end
end)

-- ============================================================== os momentos

--[[
	O avanço, que é o momento pelo qual o jogo inteiro existe.

	Um cartão que chega, segura e sai, mais um clarão colorido. Um rompimento
	dobrado dentro do `StateSync` chegaria junto com tudo e leria como um
	número mudando -- e número mudando não é por que alguém medita mais uma
	hora.
]]
local function moment(title: string, subtitle: string, colour: Color3, hold: number)
	local card = lacquer(gui, {
		size = UDim2.fromOffset(460, 170),
		pos = UDim2.fromScale(0.5, 0.36),
		anchor = Vector2.new(0.5, 0.5),
		edge = colour, thickness = 3, transparency = 0.02,
	})

	local heading = UI.label(card, title, {
		size = 34, font = T.font.title, color = colour,
		align = Enum.TextXAlignment.Center, pos = UDim2.fromOffset(0, 26),
	})
	heading.Size = UDim2.new(1, 0, 0, 44)

	local note = UI.label(card, subtitle, {
		size = 15, color = C.papel, align = Enum.TextXAlignment.Center,
		wrap = true, pos = UDim2.fromOffset(24, 78),
	})
	note.Size = UDim2.new(1, -48, 0, 66)

	--: Entra um pouco menor, o que lê como *aparecer* em vez de ser ligado.
	card.Size = UDim2.fromOffset(400, 140)
	TweenService:Create(card, TweenInfo.new(0.2, Enum.EasingStyle.Back,
		Enum.EasingDirection.Out), { Size = UDim2.fromOffset(460, 170) }):Play()

	task.delay(hold, function()
		local out = TweenService:Create(card, TweenInfo.new(0.25),
			{ BackgroundTransparency = 1 })
		out:Play()
		out.Completed:Wait()
		card:Destroy()
	end)
end

Net.on("Broke", function(report)
	--[[
		O avanço tem de ser sentido, não só lido.

		`Feel.shake` mexe na câmera com decaimento; o rompimento de **realm**
		sacode três vezes mais que um estágio comum, que é a única forma de as
		duas coisas parecerem diferentes sem um segundo efeito. O clarão de
		cor vem junto: o `Ascension` do servidor desenha o choque no mundo, e
		isto é o que acontece atrás dos olhos de quem rompeu.
	]]
	if report.ok then
		local realmBreak = report.realmBreak == true
		Feel.shake(if realmBreak then 1.5 else 0.5, if realmBreak then 1.1 else 2.2)
		Feel.screenTint(
			if realmBreak then C.ouro else C.qi,
			if realmBreak then 0.5 else 0.22,
			if realmBreak then 0.7 else 0.35)
	end
	if report.ok then
		moment(report.title or "Avanço",
			string.format("+%d pedras espirituais%s", report.pedras or 0,
				if report.note then "\n" .. report.note else ""),
			if report.realmBreak then C.ouro else C.jade,
			if report.realmBreak then 3.4 else 1.8)
	elseif report.failed then
		moment("A tribulação te rejeitou",
			string.format("Metade do que juntou se dispersou. "
				.. "A percepção fica: a próxima tentativa é %d%% mais provável.", 10),
			C.sangue, 3.0)
	elseif report.reason then
		UI.toast(tostring(report.reason))
	end
end)

--[[
	O sorteio, que numa manhwa é uma cena e não uma linha de log.

	Uma carta que já chega com a resposta não é um sorteio -- é um aviso. O que
	faz alguém gastar a segunda pedra é o segundo e meio em que os nomes passam
	rápido demais para ler e ainda pode sair qualquer coisa.

	Então: o giro roda **antes** de a resposta chegar, e a resposta espera o
	giro terminar. A ordem importa. Se o resultado interrompesse a animação, o
	jogador aprenderia que a animação é falsa em duas rolagens e passaria a
	ignorá-la; do jeito que está, a única coisa que ele não sabe é onde vai
	parar, que é exatamente o que se quer que ele não saiba.
]]
local spinning: Frame? = nil

startSpin = function(kind: string)
	if spinning ~= nil then
		return
	end
	local shell = lacquer(gui, {
		size = UDim2.fromOffset(460, 150),
		pos = UDim2.fromScale(0.5, 0.36),
		anchor = Vector2.new(0.5, 0.5),
		edge = C.ouro, thickness = 3, transparency = 0.02,
	})
	shell.Name = "Sorteio"
	spinning = shell :: any

	local heading = UI.label(shell, if kind == "raiz"
			then "Despertando a raiz espiritual..."
			else "Medindo a constituição...", {
		size = 15, color = C.fraco, align = Enum.TextXAlignment.Center,
		pos = UDim2.fromOffset(0, 16),
	})
	heading.Size = UDim2.new(1, 0, 0, 20)

	local roller = UI.label(shell, "—", {
		size = 30, font = T.font.title, align = Enum.TextXAlignment.Center,
		color = C.papel, pos = UDim2.fromOffset(0, 52),
	})
	roller.Size = UDim2.new(1, 0, 0, 44)

	local list = if kind == "raiz" then Content.roots else Content.constitutions
	task.spawn(function()
		local index = 1
		while spinning == shell do
			index = index % #list + 1
			local entry = list[index]
			roller.Text = entry.name
			roller.TextColor3 = Content.tierColour[entry.tier] or C.papel
			task.wait(0.055)
		end
	end)
end

local function stopSpin()
	local shell = spinning
	spinning = nil
	if shell ~= nil then
		shell:Destroy()
	end
end

Net.on("Spun", function(report)
	if not report.ok then
		stopSpin()
		UI.toast(tostring(report.reason))
		return
	end
	--: O giro segura um segundo e meio mesmo que a resposta já esteja aqui.
	--: É o tempo que separa um sorteio de um aviso.
	task.delay(1.5, function()
		stopSpin()
		local colour = Content.tierColour[report.tier] or C.fraco
		moment(report.name,
			string.format("tier %d  ·  ×%.2f\n%s", report.tier, report.mult,
				report.note or ""),
			colour, 2.0 + report.tier * 0.35)
	end)
end)

--[[
	O manual caído, que é o segundo momento do jogo.

	Cor por grau, e o grau vem de `Content` -- a mesma tabela que a lista de
	manuais usa, para que a carta e o inventário não discordem sobre o que é
	Celestial.
]]
Net.on("Learned", function(report)
	if not report.ok then
		return
	end
	moment(report.name,
		string.format("%s  ·  ×%.2f permanente%s\n%s",
			report.grade, report.mult,
			if report.copies > 1
				then string.format("  (cópia %d)", report.copies) else "",
			report.note or ""),
		Content.gradeColour(report.grade), 2.2 + report.tier * 0.4)
end)

--[[
	Levar uma mordida.

	Um tinta vermelha na borda da tela, e nada mais. Sem isso o jogador perde
	vida sem saber de onde -- a besta bate por trás, a barra desce, e a
	conclusão dele é que o jogo está bugado. É a diferença entre um combate e
	um dano invisível.
]]
local bloodVignette = Instance.new("Frame")
bloodVignette.Name = "Sangue"
bloodVignette.Size = UDim2.fromScale(1, 1)
bloodVignette.BackgroundColor3 = C.sangue
bloodVignette.BackgroundTransparency = 1
bloodVignette.BorderSizePixel = 0
--: Atrás de tudo o mais na tela. Sob `ZIndexBehavior.Sibling` isso funciona
--: porque ele é irmão do HUD, não pai dele.
bloodVignette.ZIndex = 0
bloodVignette.Parent = gui

--: Quem está mordendo, escrito uma vez e substituído -- não uma torrada por
--: mordida. Três javalis a uma mordida por 1,4s empilhavam duas ou três
--: torradas idênticas no meio da tela, tapando exatamente a luta que as
--: causou. O aviso que importa é o vermelho na borda; o nome é rodapé.
local struckLabel = UI.label(gui, "", {
	size = 14, align = Enum.TextXAlignment.Center, color = C.sangue,
	pos = UDim2.new(0.5, 0, 1, -196), anchor = Vector2.new(0.5, 1),
})
struckLabel.Size = UDim2.fromOffset(420, 20)

local struckUntil = 0

Net.on("Struck", function(payload)
	bloodVignette.BackgroundTransparency = 0.62
	TweenService:Create(bloodVignette, TweenInfo.new(0.45),
		{ BackgroundTransparency = 1 }):Play()

	struckLabel.Text = string.format("%s te acertou  (-%s)",
		tostring(payload.beast), short(payload.amount))
	local mine = os.clock() + 2.2
	struckUntil = mine
	task.delay(2.2, function()
		if struckUntil == mine then
			struckLabel.Text = ""
		end
	end)
end)

--[[
	O próximo passo, e por que ele é uma linha só.

	Este jogo tem duas escadas, sete terraços, oito manuais, cinco itens, duas
	roletas e um bosque. Um jogador novo abre isso e não sabe o que apertar --
	e a resposta anterior era um `nudge` que só falava quando `Loop.Hatch`
	tinha uma reclamação, ou seja, quase nunca.

	Agora há sempre uma frase, e é sempre **a próxima coisa a fazer**, na
	ordem em que o jogo quer que ela aconteça. Uma por vez: uma lista de cinco
	dicas simultâneas é a mesma confusão com mais letras.

	A ordem é deliberada -- primeiro o que devolve algo em segundos, depois o
	que devolve em minutos:

	    1. sente-se e cultive          o laço inteiro, em quinze segundos
	    2. rompa                       a primeira recompensa
	    3. gire a raiz de graça        o multiplicador que muda tudo
	    4. treine o corpo              a segunda barra, e a vida
	    5. cace                        pedra e manual permanente
	    6. suba de terraço             o multiplicador do lugar
]]
guide = lacquer(gui, {
	size = UDim2.fromOffset(430, 30),
	pos = UDim2.new(0.5, 0, 1, -212),
	anchor = Vector2.new(0.5, 1),
	transparency = 0.3,
})

guideLabel = UI.label(guide, "", {
	size = 13, align = Enum.TextXAlignment.Center, color = C.ouro,
	pos = UDim2.fromOffset(8, 0),
})
guideLabel.Size = UDim2.new(1, -16, 1, 0)

--: A dica de retenção do `Loop.Hatch` continua existindo e ganha do roteiro
--: quando dispara: ela fala de um problema **medido** neste jogador agora, e
--: o roteiro fala do caso geral.
local NUDGE = {
	first_payout_late = "Sente-se no taiji e aperte Cultivar — o primeiro avanço leva 15 segundos.",
	dead_time = "Colha uma veia espiritual: o pátio paga quem anda nele.",
	tier_two_unreached = "Você tem pedras. Gire o Destino e troque sua raiz.",
}
local finding: string? = nil

Net.on("Findings", function(payload)
	local first = (payload.findings or {})[1]
	finding = if first ~= nil then NUDGE[first.rule] else nil
end)

--: Devolve a única frase que importa agora. Fora de `draw` para caber num
--: cenário: um roteiro didático que ninguém consegue testar é um roteiro que
--: fica errado na primeira mudança de regra.
nextStep = function(): string
	if state == nil then
		return ""
	end
	if finding ~= nil then
		return finding
	end
	if state.qi.ready then
		return string.format("Sua poça está paga: aperte AVANÇO para virar %s.",
			state.qi.title)
	end
	if state.action == "nenhum" then
		return "Aperte Cultivar. Sentar é o que faz o Qi entrar."
	end
	if state.spins == 0 then
		return "Seu primeiro despertar de raiz é de graça — abra Destino."
	end
	if state.corpo.realm == 1 and state.corpo.stage <= 2 then
		return "Treine o corpo: são flexões, e cada degrau aumenta sua vida."
	end
	if #(state.manuals or {}) == 0 then
		return "Vá ao Bosque e golpeie (F). Bestas largam manuais permanentes."
	end
	if state.zone ~= nil and state.zone.id == "patio" and state.qi.realm >= 2 then
		return "Suba ao terraço do seu rank: lá o Qi entra várias vezes mais rápido."
	end
	if state.canFly and not state.flying then
		return "Você já pode voar: aperte Voar. Shift desce, Espaço sobe."
	end
	if state.pedras >= 55 then
		return "Você tem pedras: a Loja vende ginseng, que vale degraus inteiros."
	end
	return ""
end

-- ====================================================================== toque

--: O impulso manual. Só conta enquanto uma ação está em curso, e o servidor
--: confere isso de novo -- o cliente aqui está apenas evitando mandar pacote
--: que seria recusado.
local lastTap = 0
UserInputService.InputBegan:Connect(function(input, processed)
	if processed or state == nil or state.action == "nenhum" then
		return
	end
	if input.UserInputType ~= Enum.UserInputType.MouseButton1
		and input.UserInputType ~= Enum.UserInputType.Touch then
		return
	end
	local now = os.clock()
	if now - lastTap < Content.tapCooldown then
		return
	end
	lastTap = now
	Net.send("Tap", { track = viewing })
end)

-- ====================================================================== o voo

--[[
	Voar, concedido na Formação do Núcleo.

	`PlatformStand` desliga o controlador de caminhada -- sem isso o humanoide
	briga com a velocidade aplicada e o personagem treme. `BodyVelocity` e
	`BodyGyro` são antigos e continuam sendo os dois com propriedades que não
	mudaram de nome em dez anos, o que num arquivo que ninguém vai reabrir
	vale mais do que serem modernos.
]]
--: Tipado como os dois objetos que são, e não como um dicionário de
--: `Instance`. Com o dicionário genérico cada uso vira `(x :: any)`, e um
--: `;(x :: any)` como primeira linha de um bloco é erro de sintaxe em Luau --
--: o que custou um `forge doctor` vermelho por uma conversão que nem
--: precisava existir.
local flight: { velocity: BodyVelocity?, gyro: BodyGyro? } = {
	velocity = nil, gyro = nil,
}

local function stopFlying()
	if flight.velocity ~= nil then
		flight.velocity:Destroy()
		flight.velocity = nil
	end
	if flight.gyro ~= nil then
		flight.gyro:Destroy()
		flight.gyro = nil
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.PlatformStand = false
	end
end

local function startFlying()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if root == nil or humanoid == nil or not root:IsA("BasePart") then
		return
	end
	stopFlying()
	humanoid.PlatformStand = true

	local velocity = Instance.new("BodyVelocity")
	velocity.MaxForce = Vector3.new(1e5, 1e5, 1e5)
	velocity.Velocity = Vector3.zero
	velocity.Parent = root
	flight.velocity = velocity

	local gyro = Instance.new("BodyGyro")
	gyro.MaxTorque = Vector3.new(1e5, 1e5, 1e5)
	gyro.P = 6000
	gyro.D = 400
	gyro.CFrame = root.CFrame
	gyro.Parent = root
	flight.gyro = gyro
end

RunService.RenderStepped:Connect(function()
	local velocity = flight.velocity
	local gyro = flight.gyro
	if velocity == nil or gyro == nil then
		return
	end
	local camera = workspace.CurrentCamera
	if camera == nil then
		return
	end
	local move = Vector3.zero
	if UserInputService:IsKeyDown(Enum.KeyCode.W) then
		move += camera.CFrame.LookVector
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) then
		move -= camera.CFrame.LookVector
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.A) then
		move -= camera.CFrame.RightVector
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) then
		move += camera.CFrame.RightVector
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
		move += Vector3.yAxis
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then
		move -= Vector3.yAxis
	end
	--[[
		A velocidade e o teto vêm do servidor, não daqui.

		Eram 92 fixos. Um voo que não melhora é transporte: a conquista acontece
		uma vez, no realm em que ela é concedida, e nunca mais significa nada.
		Agora os dois escalam com o realm de Qi, e quem chega ao Imortal Dourado
		voa três vezes mais rápido do que quem acabou de formar a Alma Nascente.
	]]
	local speed = if state ~= nil and state.flySpeed ~= nil
		then state.flySpeed else 72
	local ceiling = if state ~= nil and state.flyCeiling ~= nil
		then state.flyCeiling else 90

	--: O teto existe porque o céu é uma textura, e porque com
	--: `StreamingEnabled` um cultivador rápido demais voa para dentro de um
	--: mundo que ainda não carregou. Empurrar para baixo é mais gentil do que
	--: travar: quem bate no teto desce sozinho em vez de encostar num vidro.
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if root ~= nil and root:IsA("BasePart") and root.Position.Y > ceiling then
		move = Vector3.new(move.X, math.min(move.Y, -0.6), move.Z)
	end

	local flat = Vector3.new(move.X, 0, move.Z)
	if move.Magnitude > 0.05 then
		velocity.Velocity = move.Unit * speed
		--: Só vira quando há direção horizontal. Subir reto com `lookAt` sobre
		--: um vetor nulo devolve uma CFrame inválida e o personagem gira de
		--: costas para o mundo.
		if flat.Magnitude > 0.05 then
			gyro.CFrame = CFrame.lookAt(Vector3.zero, flat)
		end
	else
		velocity.Velocity = Vector3.zero
	end
end)

--: `F` golpeia. Um jogo em que a única forma de bater é mirar um botão de
--: 108 pixels com o mouse é um jogo em que ninguém caça duas vezes.
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if input.KeyCode == Enum.KeyCode.F then
		press("golpe")
	end
end)

--[[
	Correr: segurar Shift.

	A mesma tecla desce enquanto se voa, e os dois contextos não se cruzam --
	quem está voando não está correndo, e o servidor recusa a corrida de quem
	está no ar ou sentado. Mandar os dois estados é barato e evita a alternativa,
	que seria o cliente decidir sozinho em qual modo está.

	`InputEnded` importa tanto quanto `InputBegan`: sem ele o jogador solta a
	tecla e continua correndo para sempre, o que é o bug clássico de tecla
	segurada e o mais fácil de não notar em teste.
]]
sprint = function(on: boolean)
	if state ~= nil and state.flying then
		return
	end
	Net.send("Sprint", { on = on })
end

UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and (input.KeyCode == Enum.KeyCode.LeftShift
		or input.KeyCode == Enum.KeyCode.RightShift) then
		sprint(true)
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.LeftShift
		or input.KeyCode == Enum.KeyCode.RightShift then
		sprint(false)
	end
end)

--: Soltar a corrida ao morrer. Um respawn com o estado de corrida pendurado
--: devolve um personagem que anda rápido sem ninguém estar segurando nada.
player.CharacterRemoving:Connect(function()
	sprint(false)
end)

--[[
	O voo é ligado pelo `StateSync`, não por um atributo.

	Era `player:GetAttributeChangedSignal("voando")`, e **não funcionava**.
	Medido: o servidor concedia (`voando = true` na sua tabela de atributos) e
	no cliente não aparecia `BodyVelocity` nenhum e `PlatformStand` continuava
	falso -- ou seja, o handler não rodava. Não achei a causa da não-entrega do
	sinal, e continuar procurando custaria mais do que trocar de mecanismo.

	`StateSync` chega a cada tick e o HUD inteiro é desenhado a partir dele, o
	que é prova de que ele chega. Comparar com o estado anterior custa uma
	variável e remove uma dependência que eu não consegui explicar.

	Também é mais correto: quem sabe se este jogador está voando é o estado
	dele, e o estado já vem inteiro por este canal.
]]
local wasFlying = false

reconcileFlight = function()
	local flying = state ~= nil and state.flying == true
	if flying == wasFlying then
		return
	end
	wasFlying = flying
	if flying then
		startFlying()
		UI.toast("Você pisa no vento. WASD, Espaço para subir, Shift para descer.")
	else
		stopFlying()
	end
end

player.CharacterAdded:Connect(function()
	--: Um respawn destrói os constraints junto com o corpo antigo. Sem esta
	--: linha o jogador reaparece com o estado dizendo que voa e sem nada que o
	--: faça voar, e a única saída é apertar o botão duas vezes.
	task.wait(0.6)
	wasFlying = false
	reconcileFlight()
end)

-- ================================================================ os testes

--[[
	A porta dos cenários.

	O Studio recusa clique sintético (`virtual_input_refused`), então um
	`BindableFunction` que chama exatamente a mesma função dos botões é o
	único jeito de um teste exercitar o caminho do cliente. `invoke_bindable`
	passa **um** argumento, não uma lista.

	Isso não é conveniência: o defeito mais caro que este repositório já
	produziu foi um botão que não fazia nada, e ele sobreviveu porque todo
	teste disparava o RemoteEvent direto e pulava justamente a metade
	quebrada.
]]
do
	local door = Instance.new("BindableFunction")
	door.Name = "DaoPressAction"
	door.OnInvoke = function(id: string?)
		--[[
			Sem argumento, não faz nada.

			O padrão era `"cultivar"`, e isso produziu um defeito de teste
			perfeitamente silencioso: uma sequência de quarenta chamadas de
			golpe em que alguma delas chegou sem argumento deixou o cultivador
			**meditando** no meio do bosque, e a leitura seguinte disse que a
			caça não pagava nada. Levou uma rodada inteira para ver que o
			problema era o valor padrão e não o combate.

			Um harness que esquece o argumento tem de receber um não, nunca uma
			ação escolhida por engano.
		]]
		if id == nil or id == "" then
			return false
		end
		local what = tostring(id)
		if what == "avanco" then
			Net.send("Breakthrough", { track = viewing })
		elseif string.sub(what, 1, 6) == "painel" then
			openPanel(string.sub(what, 8))
		elseif string.sub(what, 1, 7) == "comprar" then
			--: `comprar:ginseng_centenario`. Mesmo motivo do sprint: o Studio
			--: recusa clique sintético, e sem esta porta a loja só é alcançável
			--: pelo RemoteEvent -- que é justamente a metade que sempre
			--: funciona e esconde o defeito na outra.
			Net.send("Buy", { item = string.sub(what, 9) })
		elseif what == "correr" then
			--: A mesma função que a tecla Shift chama. O Studio recusa clique e
			--: tecla sintéticos, então esta porta é a única forma de um cenário
			--: exercitar a corrida pelo caminho do cliente -- e o caminho do
			--: cliente é justamente a metade que já entregou um botão morto
			--: neste repositório.
			sprint(true)
		elseif what == "parar" then
			sprint(false)
		elseif what == "girar" then
			startSpin("raiz")
			Net.send("Spin", { kind = "raiz" })
		elseif string.sub(what, 1, 8) == "equipar:" then
			--[[
				`equipar:<slot>:<id>`.

				Existe para que um cenário exercite o **caminho do cliente** ao
				equipar, e não o handler de rede direto. É a distinção que
				custou mais caro neste repositório: todo teste antigo disparava
				o RemoteEvent na mão, o que exercita a metade que funciona e
				pula a metade que quebra.
			]]
			local rest = string.sub(what, 9)
			local divider = string.find(rest, ":", 1, true)
			if divider ~= nil then
				local slot = tonumber(string.sub(rest, 1, divider - 1))
				local id = string.sub(rest, divider + 1)
				if slot ~= nil then
					Net.send("Equip", { slot = slot, technique = id })
				end
			end
		else
			press(what)
		end
		return true
	end
	door.Parent = gui
end

--: As auras, depois de tudo. Elas seguem jogadores e não a tela, então nada
--: acima depende delas -- mas se subissem primeiro, um erro no enfeite levaria
--: junto a interface inteira, que é a única parte que o jogador precisa.
--: `Feel.mount` precisa existir antes do primeiro `shake`: ele é quem prende
--: o tremor na câmera. Sem esta linha `shake` acumula trauma que ninguém lê,
--: e o avanço não sacode nada.
Feel.mount()

Aura.start()
Grass.start()

print("[daocultivo] interface no ar")
