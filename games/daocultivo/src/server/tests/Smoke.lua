--!strict
--[[
	A montanha existe, e existe do jeito certo.

	`Caminho.lua` afirma as regras; este arquivo afirma o **lugar**. É a
	metade que nenhum teste de lógica alcança e a metade que o jogador vê
	primeiro: um jogo cujas regras estão perfeitas e cujo mundo não subiu é um
	jogo vazio com a consciência limpa, e este repositório já publicou um.

	O que está afirmado aqui não é aparência -- para isso existe a
	fotografia. É **presença**: o taiji está no chão, os pagodes subiram, há
	onde nascer, e as veias podem ser colhidas. Um cenário não sabe se está
	bonito; sabe dizer se está lá.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Content = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Content"))
local Mountain = require(script.Parent.Parent.systems.Mountain)
local Sect = require(script.Parent.Parent.systems.Sect)
local Hunt = require(script.Parent.Parent.systems.Hunt)

return function(Testing)
	Testing.scenario("todo contêiner declarado no config existe", function(t)
		--: Barato, e pega uma classe real de erro: um sistema que escreve numa
		--: pasta que o bootstrap nunca criou põe o trabalho dele em nil e
		--: falha calado.
		for _, name in Config.containers do
			t:expect(Workspace:FindFirstChild(name) ~= nil,
				"o contêiner '" .. name .. "' nunca foi criado")
		end
	end)

	Testing.scenario("a seita subiu inteira", function(t)
		local sect = Workspace:FindFirstChild("Seita")
		t:expect(sect ~= nil, "a pasta da seita não existe — Sect.start não rodou")
		if sect == nil then
			return
		end
		--: `Horizonte` saiu da lista de propósito: as montanhas deixaram de ser
		--: uma pasta de partes e viraram terreno, que não tem pasta. O cenário
		--: abaixo mede o terreno, que é o que passou a existir.
		for _, name in { "Patio", "Taiji", "Portal", "Paredao",
		                 "PagodeDaAlquimia", "PagodeDaSeita", "Veias",
		                 "Anciaos", "Balcoes", "Zonas", "Cerejeiras", "Ar" } do
			t:expect(sect:FindFirstChild(name) ~= nil,
				"a seita subiu sem '" .. name .. "'")
		end
	end)

	Testing.scenario("cada terraço subiu, com placa e trilha", function(t)
		--[[
			Um terraço sem trilha é um terraço que ninguém alcança a pé -- e o
			voo só chega no terceiro realm, ou seja, dois terraços depois do
			primeiro que precisa ser alcançado. O sintoma no jogo é um jogador
			pulando numa parede de pedra sem entender que aquilo era para ser
			um caminho.
		]]
		local zones = Workspace:FindFirstChild("Seita")
		zones = zones and zones:FindFirstChild("Zonas")
		t:expect(zones ~= nil, "os terraços não subiram")
		if zones == nil then
			return
		end
		for _, zone in Content.zones do
			if zone.radius <= 0 then
				continue
			end
			local model = zones:FindFirstChild("Zona_" .. zone.id)
			t:expect(model ~= nil, "falta o terraço '" .. zone.name .. "'")
			if model == nil then
				continue
			end
			t:expect(model:FindFirstChild("Terraco") ~= nil,
				"'" .. zone.name .. "' não tem plataforma")
			t:expect(model:FindFirstChild("Trilha") ~= nil,
				"'" .. zone.name .. "' não tem trilha: ninguém chega lá a pé")
			t:expect(model:FindFirstChildWhichIsA("BillboardGui", true) ~= nil,
				"'" .. zone.name .. "' não tem placa: o rank exigido fica invisível")
		end
	end)

	Testing.scenario("o horizonte é rocha de verdade, não caixas empilhadas", function(t)
		--[[
			As montanhas eram cubos empilhados e a escada aparecia a
			quatrocentos studs -- o horizonte ocupa um terço de cada quadro, e
			era a maior coisa feia da tela.

			O que se afirma aqui é o que mudou: existe **terreno** de rocha
			longe do pátio, e ele é alto. Ler voxels é a única forma de provar
			isso: terreno não tem instâncias para contar.
		]]
		local terrain = Workspace.Terrain
		local ground = Mountain.ORIGIN.Y
		local found, snowy = 0, false

		for index = 1, 14 do
			local angle = index / 14 * math.pi * 2
			for _, distance in { 430, 520, 610 } do
				local at = Mountain.ORIGIN + Vector3.new(
					math.cos(angle) * distance, 0, math.sin(angle) * distance)
				--: Bem acima do chão do pátio: qualquer rocha aqui em cima só
				--: pode ser montanha, e não a campina.
				local region = Region3.new(
					Vector3.new(at.X - 4, ground + 60, at.Z - 4),
					Vector3.new(at.X + 4, ground + 68, at.Z + 4)):ExpandToGrid(4)
				local voxels = terrain:ReadVoxels(region, 4)
				for x = 1, #voxels do
					for y = 1, #voxels[x] do
						for z = 1, #voxels[x][y] do
							local material = voxels[x][y][z]
							if material == Enum.Material.Rock then
								found += 1
							elseif material == Enum.Material.Snow then
								found += 1
								snowy = true
							end
						end
					end
				end
			end
		end

		t:expect(found > 0,
			"não há rocha nenhuma a sessenta studs de altura no anel do horizonte")
		t:expect(snowy, "nenhum cume passou da altura da neve")
	end)

	Testing.scenario("há água, e ela reflete", function(t)
		--: Um terraço chamado Lago do Espírito Congelado sem água é uma piada
		--: que o jogador percebe. Água de terreno é também a única que devolve
		--: o céu e o pagode de graça.
		local terrain = Workspace.Terrain
		local pond = Mountain.ORIGIN + Vector3.new(-96, 0, 118)
		local region = Region3.new(
			Vector3.new(pond.X - 8, Mountain.ORIGIN.Y - 6, pond.Z - 8),
			Vector3.new(pond.X + 8, Mountain.ORIGIN.Y - 2, pond.Z + 8)):ExpandToGrid(4)
		local voxels = terrain:ReadVoxels(region, 4)
		local water = 0
		for x = 1, #voxels do
			for y = 1, #voxels[x] do
				for z = 1, #voxels[x][y] do
					if voxels[x][y][z] == Enum.Material.Water then
						water += 1
					end
				end
			end
		end
		t:expect(water > 0, "a lagoa do pátio está seca")
		t:expect(terrain.WaterReflectance > 0,
			"a água não reflete: `Visual.Sky` não passou por aqui")
	end)

	Testing.scenario("o taiji é um disco de verdade, não um plano de intenções", function(t)
		local taiji = Workspace:FindFirstChild("Seita")
		taiji = taiji and taiji:FindFirstChild("Taiji")
		t:expect(taiji ~= nil, "o taiji não foi construído")
		if taiji == nil then
			return
		end
		--: As duas metades, as duas cabeças e os dois olhos. Sem os olhos é um
		--: par de caracóis; sem as cabeças são duas metades de pizza.
		for _, name in { "CabecaBranca", "CabecaPreta", "OlhoPreto", "OlhoBranco" } do
			t:expect(taiji:FindFirstChild(name) ~= nil,
				"o taiji ficou sem '" .. name .. "'")
		end
		local parts = 0
		for _, item in taiji:GetDescendants() do
			if item:IsA("BasePart") then
				parts += 1
				t:expect(item.Anchored,
					"'" .. item.Name .. "' não está ancorado — o pátio vai desabar")
			end
		end
		t:expect(parts > 40, "o disco saiu com poucas peças: " .. tostring(parts))
	end)

	Testing.scenario("há onde nascer, e não é dentro do taiji", function(t)
		local pad: BasePart? = nil
		for _, item in Workspace:GetDescendants() do
			if item:IsA("SpawnLocation") then
				pad = item
				break
			end
		end
		t:expect(pad ~= nil, "nenhum SpawnLocation — o jogador cai no vazio")
		if pad == nil then
			return
		end
		local flat = Vector2.new(pad.Position.X - Mountain.ORIGIN.X,
			pad.Position.Z - Mountain.ORIGIN.Z)
		t:expect(flat.Magnitude > Mountain.TAIJI + 10,
			"nascer em cima do taiji põe o jogador dentro da coisa que ele "
			.. "deveria estar vendo de longe")
	end)

	Testing.scenario("as veias estão prontas para serem colhidas", function(t)
		local veins = Workspace:FindFirstChild("Seita")
		veins = veins and veins:FindFirstChild("Veias")
		t:expect(veins ~= nil, "não há veias — não há como ganhar pedra andando")
		if veins == nil then
			return
		end
		local ready = 0
		for _, cluster in veins:GetChildren() do
			if cluster:GetAttribute("pronta") == true then
				ready += 1
			end
			t:expect(cluster:FindFirstChildWhichIsA("ProximityPrompt", true) ~= nil,
				"'" .. cluster.Name .. "' não tem prompt: não dá para colher")
		end
		t:expect(ready >= 5, "veias prontas de menos: " .. tostring(ready))
	end)

	Testing.scenario("o bosque existe e as bestas nasceram nele", function(t)
		--[[
			O único lugar do jogo de onde sai um multiplicador permanente. Se
			ele não subir, o caminho do corpo perde a razão de existir e a
			única decisão do jogo volta a ser quanto tempo esperar.
		]]
		local sect = Workspace:FindFirstChild("Seita")
		local grove = sect and sect:FindFirstChild("Bosque")
		t:expect(grove ~= nil, "o bosque não foi construído")
		t:expect(sect ~= nil and sect:FindFirstChild("Bestas") ~= nil,
			"não há cercado de bestas")

		local pen = sect and sect:FindFirstChild("Bestas")
		if pen == nil then
			return
		end
		--: Elas nascem num laço com espera, então este cenário aceita que
		--: ainda estejam chegando. O que ele recusa é o cercado vazio depois
		--: de o jogo inteiro ter subido, que é o sintoma de um rig que não
		--: monta.
		local alive = 0
		for _, model in pen:GetChildren() do
			if model:IsA("Model") and model:FindFirstChildOfClass("Humanoid") then
				alive += 1
			end
		end
		t:expect(alive > 0, "nenhuma besta viva no cercado")
	end)

	Testing.scenario("o bosque fica longe do taiji", function(t)
		--: Uma besta a caminho do jogador mais próximo não pode acabar no meio
		--: de quem está meditando. A distância é a única coisa que garante
		--: isso, porque o laço de perseguição não conhece o pátio.
		local distance = (Hunt.CENTRE - Mountain.ORIGIN).Magnitude
		t:expect(distance > Mountain.PLAZA + 40, string.format(
			"o bosque está a %.0f studs do centro; o pátio tem raio %d",
			distance, Mountain.PLAZA))
	end)

	Testing.scenario("uma besta fraca nunca larga um manual de grau alto", function(t)
		--[[
			A regra que sustenta a escada de rank inteira. Se o Lobo das
			Neblinas pudesse largar o Cânone do Vazio Absoluto, farmar a besta
			mais fácil do jogo seria a estratégia dominante e as outras seis
			existiriam por decoração.

			Testado com os sorteios entrando por parâmetro, e não jogando: seis
			abates a vinte por cento cada é uma moeda, e um cenário que dependa
			dela falha por azar num dia e passa no outro -- que é como uma
			suíte deixa de ser lida.
		]]
		local weakest = Content.beasts[1]
		for step = 0, 40 do
			local pick = step / 40
			local id = Hunt.rollManual(weakest, 0, pick)
			t:expect(id ~= nil, "com a chance garantida tem de cair algo")
			if id ~= nil then
				local manual = Content.manual(id)
				t:expect(manual ~= nil and manual.tier <= weakest.manualTier,
					string.format("'%s' largou '%s', acima do grau dela",
						weakest.name, id))
			end
		end
	end)

	Testing.scenario("a chance de manual é respeitada", function(t)
		--: A recusa é a metade que ninguém testa, e é a que decide se caçar
		--: vinte bestas rende vinte manuais.
		local beast = Content.beasts[1]
		t:expect(Hunt.rollManual(beast, 1.0, 0.5) == nil,
			"um sorteio acima da chance não pode largar nada")
		t:expect(Hunt.rollManual(beast, 0.0, 0.5) ~= nil,
			"um sorteio abaixo da chance tem de largar")
	end)

	Testing.scenario("a besta mais forte alcança o grau celestial", function(t)
		--: O outro lado: se nenhum sorteio do dragão alcançasse o topo da
		--: tabela, os dois manuais celestiais seriam conteúdo inalcançável.
		local strongest = Content.beasts[#Content.beasts]
		local best = 0
		for step = 0, 200 do
			local id = Hunt.rollManual(strongest, 0, step / 200)
			local manual = if id ~= nil then Content.manual(id) else nil
			if manual ~= nil and manual.tier > best then
				best = manual.tier
			end
		end
		t:expectEqual(best, 4,
			"o Dragão Carmesim tem de conseguir largar grau Celestial")
	end)

	Testing.scenario("o catálogo vestiu o cenário, e sabemos quanto", function(t)
		--[[
			Não é uma asserção sobre beleza; é sobre honestidade do relatório.
			Um jogo cinza com zero erros é o modo de falha desta etapa, e a
			única defesa é medir a taxa em vez de inferi-la de "não deu erro".
		]]
		local report = Sect.report()
		t:expect(report.asked > 0, "nada foi pedido ao catálogo")
		--: A taxa **não** é afirmada alta. `LoadAsset` é rede, e uma sessão
		--: sem rede tem de continuar passando: o que se afirma é que o número
		--: foi medido e existe.
		t:expect(report.rate ~= nil, "a taxa de vestimenta não foi medida")
	end)
end
