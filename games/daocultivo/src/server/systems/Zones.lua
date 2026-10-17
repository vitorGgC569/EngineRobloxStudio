--!strict
--[[
	Zones — os terraços de treino, e o caminho que sobe até eles.

	O rank não é um número no HUD: é **onde te deixam sentar**. Discípulo
	externo respira no pátio, interno no salão, nuclear na caverna, e o ancião
	sobe ao pico. É a estrutura de toda seita de manhwa e resolve, de uma vez,
	o problema mais chato de um jogo de cultivo -- que é não ter para onde ir
	enquanto a poça enche.

	O que este arquivo faz
	----------------------

	    ergue    um terraço por zona, cada um mais alto e mais longe
	    liga     uma trilha em rampa do pátio até cada terraço
	    observa  quem está em cima de qual, e conta a `Cultivation`

	A porta é o Qi, não uma parede
	------------------------------

	Nada aqui impede ninguém de subir. Um discípulo externo pode caminhar até
	o Salão dos Ancestrais, sentar no meio dele e não receber nada -- a placa
	diz `x34` e o multiplicador dele continua `x1`. Uma barreira invisível
	ensinaria a mesma regra e custaria um jogador travado numa borda sem
	entender por quê; assim ele aprende subindo, e volta com um motivo.

	Por que a posição é lida pelo servidor
	--------------------------------------

	Uma zona pedida por mensagem é uma zona que qualquer um escolhe sem sair
	do lugar, e o multiplicador é a coisa mais valiosa do jogo. O servidor lê
	a posição do personagem, que é a única fonte que o jogador não escreve.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Content = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Content"))

local Mountain = require(script.Parent:WaitForChild("Mountain"))
local Cultivation = require(script.Parent:WaitForChild("Cultivation"))

local Debug = Forge.Debug

local Zones = {}

--: O centro de cada terraço no mundo, resolvido uma vez. A geometria e o
--: teste de presença leem a mesma tabela: um jogador em cima da pedra e fora
--: da zona é o defeito que ninguém consegue descrever.
local centres: { [string]: Vector3 } = {}

function Zones.centre(zone: any): Vector3
	if zone.radius <= 0 then
		return Mountain.ORIGIN
	end
	return Mountain.ORIGIN + Vector3.new(
		math.cos(zone.angle) * zone.radius,
		zone.height,
		math.sin(zone.angle) * zone.radius)
end

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

--: Um disco deitado. `PartType.Cylinder` nasce com o círculo em ±X, e virar
--: noventa graus em Z é a linha que se esquece.
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

-- ================================================================ a trilha

--[[
	A rampa que liga o pátio a um terraço.

	Rampa e não escada. Uma escada de trinta degraus com 4,7 studs de subida
	cada -- que é o que a altura do Salão dos Ancestrais dividida por trinta
	dá -- é uma escada que o humanoide não sobe: o limite de degrau do Roblox
	fica perto de dois studs e o jogador para no primeiro. Uma laje inclinada
	a 25° sobe caminhando, sempre, e é o que a montanha de qualquer manhwa
	é de verdade.

	`CFrame.lookAt` orienta o -Z da peça para o alvo, então o comprimento vai
	no eixo Z do `Size`. Escrever o comprimento em X é como se produz uma
	rampa de dois studs de comprimento e trezentos de largura, que existe,
	replica e não leva a lugar nenhum.
]]
local function trail(parent: Instance, zone: any, top: Vector3)
	local direction = Vector3.new(math.cos(zone.angle), 0, math.sin(zone.angle))
	local foot = Mountain.ORIGIN + direction * (Mountain.PLAZA * 0.86)
	local head = top - direction * (Content.zoneRadius * 0.8)

	local span = (head - foot)
	local length = span.Magnitude
	if length < 8 then
		return
	end
	local middle = foot + span * 0.5

	local ramp = block(parent, "Trilha",
		Vector3.new(16, 1.6, length),
		CFrame.lookAt(middle, head),
		Color3.fromRGB(158, 152, 168), Enum.Material.Slate)
	ramp.CanCollide = true

	--[[
		A encosta sob a trilha.

		Sem ela a rampa é uma prancha de pedra de trezentos studs **flutuando
		no ar** -- que foi exatamente o que a foto de paisagem mostrou. Uma
		trilha precisa de morro, senão ela não é uma trilha: é um andaime.

		O morro é feito de colunas de terreno ao longo da linha, cada uma
		subindo até um pouco abaixo da laje, para que a pedra continue
		aparecendo por cima. A largura afina conforme sobe -- larga na base,
		estreita no alto -- que é a silhueta de qualquer encosta e custa uma
		multiplicação.

		Terreno e não partes: são vinte e oito colunas por terraço e seis
		terraços, e cento e sessenta e oito caixas de pedra seriam cento e
		sessenta e oito peças a mais para o motor desenhar. Preencher terreno
		mediu 3,4 ms para um bloco de 900 x 900; isto é uma fração disso.
	]]
	local terrain = Workspace.Terrain
	pcall(function()
		local steps = 28
		local ground = Mountain.ORIGIN.Y
		for index = 0, steps do
			local t = index / steps
			local at = foot:Lerp(head, t)
			--: Do fundo do vale até logo abaixo da laje. Sem o desconto, o
			--: terreno nasce por cima da trilha e o jogador sobe um morro liso
			--: em que a pedra que ele viu do pátio sumiu.
			local top = at.Y - 2.2
			local depth = top - (ground - 14)
			if depth <= 2 then
				continue
			end
			local width = 40 - 22 * t
			terrain:FillBlock(
				CFrame.new(at.X, top - depth / 2, at.Z)
					* CFrame.Angles(0, zone.angle, 0),
				Vector3.new(width, depth, width * 0.8),
				Enum.Material.Rock)
		end
	end)

	--: Postes ao longo da subida. São o que diz ao jogador, do pátio, que
	--: aquilo é um caminho e não um acidente do terreno.
	local posts = math.max(4, math.floor(length / 26))
	for index = 0, posts do
		local t = index / posts
		local at = foot:Lerp(head, t) + Vector3.new(0, 3.4, 0)
		local side = direction:Cross(Vector3.yAxis).Unit * 8.6
		for _, offset in { side, -side } do
			local post = block(parent, "Poste",
				Vector3.new(0.7, 5.5, 0.7),
				CFrame.new(at + offset),
				Color3.fromRGB(120, 46, 44), Enum.Material.Wood)
			post.CanCollide = false
		end
	end
end

-- =============================================================== o terraço

local function terrace(parent: Instance, zone: any)
	local model = Instance.new("Model")
	model.Name = "Zona_" .. zone.id
	model.Parent = parent

	local centre = Zones.centre(zone)
	centres[zone.id] = centre

	--: O pátio já é o taiji. Erguer um segundo disco por cima dele seria uma
	--: plataforma flutuando sobre o yin-yang, e a zona de rank 1 é justamente
	--: a que não precisa de convite.
	if zone.radius <= 0 then
		return
	end

	local base = disc(model, "Terraco", centre - Vector3.new(0, 1.4, 0),
		Content.zoneRadius, 2.8, Color3.fromRGB(168, 164, 180), Enum.Material.Slate)
	model.PrimaryPart = base

	--: O anel de cor: é o que se enxerga do pátio, e a única forma de saber de
	--: longe qual terraço é qual.
	local ring = disc(model, "Anel", centre - Vector3.new(0, 0.1, 0),
		Content.zoneRadius * 0.72, 0.5, zone.colour, Enum.Material.Neon)
	ring.CanCollide = false
	ring.Transparency = 0.25

	local glow = Instance.new("PointLight")
	glow.Color = zone.colour
	glow.Brightness = 2.2
	glow.Range = 46
	glow.Parent = ring

	--: Pilares em volta, com a altura crescendo junto com o rank. Um terraço
	--: de rank nove tem de ler como um lugar maior, não só como um lugar mais
	--: alto -- de longe, altura de plataforma e altura de coluna somem juntas.
	local pillars = 8
	for index = 0, pillars - 1 do
		local angle = index / pillars * math.pi * 2
		local at = centre + Vector3.new(
			math.cos(angle) * (Content.zoneRadius - 2.4),
			zone.rank * 0.9 + 5,
			math.sin(angle) * (Content.zoneRadius - 2.4))
		local column = block(model, "Pilar" .. index,
			Vector3.new(2.2, zone.rank * 1.8 + 10, 2.2),
			CFrame.new(at), Color3.fromRGB(140, 40, 42), Enum.Material.Wood)
		column.CanCollide = false
		local cap = block(model, "Capitel" .. index,
			Vector3.new(3.4, 1, 3.4),
			CFrame.new(at + Vector3.new(0, zone.rank * 0.9 + 5.5, 0)),
			zone.colour, Enum.Material.Metal)
		cap.CanCollide = false
	end

	--[[
		O mastro, e por que a placa precisava de um.

		A placa flutuava sete studs acima dos pilares, sem nada embaixo dela --
		e de longe, com o terraço inteiro no enquadramento, ela lia como estando
		**no chão**: um texto solto perto da base da construção. Foi exatamente
		essa a queixa.

		Um mastro central resolve as duas coisas de uma vez: dá à placa um lugar
		de onde pender, e a leva para o topo real da construção, bem acima dos
		pilares do anel. É também o que uma seita de manhwa faz -- o estandarte
		fica no ponto mais alto, para ser visto do vale.
	]]
	local mastHeight = zone.rank * 2.6 + 26
	local mast = block(model, "Mastro",
		Vector3.new(1.5, mastHeight, 1.5),
		CFrame.new(centre + Vector3.new(0, mastHeight / 2, 0)),
		Color3.fromRGB(84, 62, 58), Enum.Material.Wood)
	mast.CanCollide = false

	--: A travessa do estandarte, e a ponta dourada. É o que faz o mastro ler
	--: como um estandarte de seita e não como um poste.
	local cross = block(model, "Travessa",
		Vector3.new(13, 0.8, 0.8),
		CFrame.new(centre + Vector3.new(0, mastHeight - 2, 0)),
		zone.colour, Enum.Material.Metal)
	cross.CanCollide = false

	local finial = block(model, "Ponta",
		Vector3.new(1.1, 3.4, 1.1),
		CFrame.new(centre + Vector3.new(0, mastHeight + 1.6, 0)),
		Color3.fromRGB(212, 168, 74), Enum.Material.Neon)
	finial.CanCollide = false

	local lamp = Instance.new("PointLight")
	lamp.Color = zone.colour
	lamp.Brightness = 2.4
	lamp.Range = 40
	lamp.Parent = finial

	--: A flâmula pendurada na travessa, na cor do terraço. Dá ao mastro uma
	--: silhueta larga, que é o que se enxerga do pátio quando o texto ainda
	--: está longe demais para ser lido.
	local banner = block(model, "Flamula",
		Vector3.new(11, 9, 0.3),
		CFrame.new(centre + Vector3.new(0, mastHeight - 6.6, 0)),
		zone.colour, Enum.Material.Fabric)
	banner.CanCollide = false
	banner.Transparency = 0.15

	--: A placa. Nome, rank exigido e multiplicador -- os três números que o
	--: jogador precisa para decidir se vale a subida, ditos no lugar onde a
	--: decisão é tomada e não numa aba do menu.
	local sign = Instance.new("BillboardGui")
	sign.Name = "Placa"
	sign.Size = UDim2.fromOffset(300, 68)
	--: Presa ao mastro, e não à laje. `StudsOffsetWorldSpace` é relativo ao
	--: pai: pendurada na base, ela precisava de um deslocamento inventado que
	--: nunca acompanhava a altura real da construção.
	sign.StudsOffsetWorldSpace = Vector3.new(0, 4.5, 0)
	--: Cento e vinte studs, e não setecentos. Com setecentos os sete terraços
	--: desenham a placa ao mesmo tempo, de qualquer ponto da montanha, e o
	--: jogador olha para uma tela coberta de texto sobreposto em que nada se
	--: lê. De perto a placa informa; de longe informa o anel colorido, que é
	--: para o que ele existe.
	sign.MaxDistance = 120
	sign.LightInfluence = 0
	sign.Parent = finial

	local name = Instance.new("TextLabel")
	name.Size = UDim2.new(1, 0, 0, 28)
	name.BackgroundTransparency = 1
	name.Text = zone.name
	name.TextScaled = true
	name.Font = Enum.Font.Merriweather
	name.TextColor3 = zone.colour
	name.TextStrokeTransparency = 0.25
	name.Parent = sign

	local rank = Instance.new("TextLabel")
	rank.Size = UDim2.new(1, 0, 0, 22)
	rank.Position = UDim2.fromOffset(0, 29)
	rank.BackgroundTransparency = 1
	rank.Text = string.format("x%.1f  ·  exige %s",
		zone.mult, Content.qiRealms[zone.rank].name)
	rank.TextScaled = true
	rank.Font = Enum.Font.GothamBold
	rank.TextColor3 = Color3.fromRGB(238, 230, 210)
	rank.TextStrokeTransparency = 0.35
	rank.Parent = sign

	local note = Instance.new("TextLabel")
	note.Size = UDim2.new(1, 0, 0, 17)
	note.Position = UDim2.fromOffset(0, 51)
	note.BackgroundTransparency = 1
	note.Text = zone.note
	note.TextScaled = true
	note.Font = Enum.Font.SourceSansItalic
	note.TextColor3 = Color3.fromRGB(180, 176, 186)
	note.TextStrokeTransparency = 0.5
	note.Parent = sign

	trail(model, zone, centre)
end

-- ================================================================ o vigia

--[[
	Quem está em qual terraço.

	Meio segundo entre leituras. Mais rápido não muda nada -- o multiplicador
	só é lido no tick, que é de um segundo -- e mais devagar deixa o jogador
	sentado sem render, que é a única forma de esta mecânica parecer quebrada.
]]
local function zoneAt(position: Vector3): string
	for _, zone in Content.zones do
		if zone.radius <= 0 then
			continue
		end
		local centre = centres[zone.id]
		if centre == nil then
			continue
		end
		local flat = Vector2.new(position.X - centre.X, position.Z - centre.Z)
		--: Distância no plano mais uma folga vertical. Sem a folga um jogador
		--: pulando no terraço sai da zona no ar, e o multiplicador pisca.
		if flat.Magnitude <= Content.zoneRadius
			and math.abs(position.Y - centre.Y) < 30 then
			return zone.id
		end
	end
	--: O pátio é o fundo. Quem está no bosque também está "no pátio", o que é
	--: honesto: rende x1 e nenhuma tela precisa aprender um sétimo estado.
	return "patio"
end

function Zones.start()
	local root = Mountain.root()

	local folder = Instance.new("Folder")
	folder.Name = "Zonas"
	folder.Parent = root

	for _, zone in Content.zones do
		local ok, err = pcall(terrace, folder, zone)
		if not ok then
			Debug.error(string.format("terraço '%s' não subiu: %s",
				zone.id, tostring(err)))
		end
	end

	task.spawn(function()
		while true do
			task.wait(0.5)
			for _, player in Players:GetPlayers() do
				local character = player.Character
				local root2 = character and character:FindFirstChild("HumanoidRootPart")
				if root2 == nil or not root2:IsA("BasePart") then
					continue
				end
				Cultivation.setZone(player, zoneAt(root2.Position))
			end
		end
	end)

	Debug.probe("zonas", function()
		local out = {}
		for id, centre in centres do
			out[id] = { x = centre.X, y = centre.Y, z = centre.Z }
		end
		return out
	end)
	Debug.info(string.format("zonas: %d terraços, do pátio ao pico",
		#Content.zones))
end

return Zones
