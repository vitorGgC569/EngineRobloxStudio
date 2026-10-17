--!strict
--[[
	Hunt — o bosque das bestas demoníacas, e o único lugar de onde sai um
	multiplicador permanente.

	Por que existe combate num jogo de sentar
	-----------------------------------------

	Sem ele, o caminho do corpo não tem para que servir e a única decisão do
	jogo é quanto tempo esperar. Com ele, o jogo passa a ter duas economias que
	se pagam:

	    sentar   dá Qi, que sobe a escada
	    caçar    dá pedra, que compra o que acelera -- e **manual**, que é
	             permanente e não se compra em lugar nenhum

	O manual é a peça que faz caçar não ser apenas "sentar de outro jeito". É
	também o motivo pelo qual, em toda manhwa do gênero, alguém entra numa
	caverna que sabe ser perigosa.

	Como a luta funciona, e por que é simples
	-----------------------------------------

	Clique perto e a besta apanha; fique perto e você apanha. Não há mira, não
	há combos, não há esquiva. Isso é deliberado: o interesse desta luta não
	está nos dedos, está na **decisão de quando entrar** -- com que saúde, com
	que golpe, contra qual rank. Um sistema de combate mais fundo competiria
	com o cultivo pela atenção do jogador e perderia.

	O golpe sai de `Cultivation.strike`, ou seja, dos dois caminhos, com o
	corpo pesando mais. Quem só meditou tem Qi enorme e morre para o primeiro
	javali -- é a lição inteira das duas barras, ensinada por uma mordida.

	As armadilhas que este arquivo já pagou
	---------------------------------------

	- **Um rig do `Forge.Rig` não tem `PrimaryPart` garantido.** Um `PivotTo`
	  sobre um modelo sem pivô move a coisa errada, e um `BillboardGui` sem pai
	  visível é um nada que não dá erro.
	- **Partes ancoradas não andam.** A besta precisa do `Humanoid` do rig e do
	  `HumanoidRootPart` livre; ancorar tudo, como se faz com cenário, produz
	  uma estátua que dá dano e nunca alcança ninguém.
	- **`Combat.damage` recusa alvo morto e alvo em i-frames.** Um laço que não
	  checa isso conta abates duas vezes e paga duas vezes.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Content = require(Shared:WaitForChild("Content"))

require(Shared:WaitForChild("Wire"))

local Mountain = require(script.Parent:WaitForChild("Mountain"))
local Cultivation = require(script.Parent:WaitForChild("Cultivation"))
local Body = require(script.Parent:WaitForChild("Body"))

local Net = Forge.Net
local Rig = Forge.Rig
local Rng = Forge.Core.Rng
local Combat = Forge.Combat
local Debug = Forge.Debug
local Telemetry = Forge.Telemetry

local Hunt = {}

local stream = Rng.stream("daocultivo.caca")

--: O centro do bosque, derivado da montanha e não escrito à mão: mover a
--: seita move a caça junto.
local CENTRE = Mountain.ORIGIN + Vector3.new(
	math.cos(Content.hunt.angle) * Content.hunt.radius,
	0,
	math.sin(Content.hunt.angle) * Content.hunt.radius)

Hunt.CENTRE = CENTRE

type Live = {
	model: Model,
	beast: any,
	humanoid: Humanoid,
	root: BasePart,
	--: Onde ela nasceu. É para onde volta quando perde o alvo, e o centro da
	--: coleira -- sem isso a perseguição não tem fim geográfico.
	home: Vector3,
	--: De quem é o abate. O último a bater leva, que é a regra mais simples que
	--: não deixa ninguém sem pagamento -- dividir o crédito exigiria uma
	--: tabela de dano por jogador e não muda nada com a população deste jogo.
	lastHit: Player?,
	nextSwing: number,
}

local live: { [Model]: Live } = {}
local population = 0

-- =============================================================== o bosque

local function ground(parent: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "Bosque"
	folder.Parent = parent

	--: Uma clareira escura de terra batida. O contraste com a pedra clara do
	--: pátio é o que diz ao jogador, de longe, que aquilo ali é outra coisa.
	local clearing = Instance.new("Part")
	clearing.Name = "Clareira"
	clearing.Shape = Enum.PartType.Cylinder
	clearing.Size = Vector3.new(2, Content.hunt.spread * 2, Content.hunt.spread * 2)
	clearing.CFrame = CFrame.new(CENTRE + Vector3.new(0, 0.2, 0))
		* CFrame.Angles(0, 0, math.pi / 2)
	clearing.Color = Color3.fromRGB(74, 62, 52)
	clearing.Material = Enum.Material.Ground
	clearing.Anchored = true
	clearing.Parent = folder

	--: Estacas com crânios em volta, que é a placa de "aqui moram bestas" do
	--: gênero. Vale mais que qualquer texto: ninguém lê um aviso e todo mundo
	--: entende um crânio numa vara.
	for index = 1, 14 do
		local angle = index / 14 * math.pi * 2
		local at = CENTRE + Vector3.new(
			math.cos(angle) * Content.hunt.spread,
			0, math.sin(angle) * Content.hunt.spread)

		local stake = Instance.new("Part")
		stake.Name = "Estaca"
		stake.Size = Vector3.new(0.9, 12, 0.9)
		stake.CFrame = CFrame.new(at + Vector3.new(0, 6, 0))
			* CFrame.Angles(stream:number(-0.1, 0.1), 0, stream:number(-0.1, 0.1))
		stake.Color = Color3.fromRGB(62, 48, 40)
		stake.Material = Enum.Material.Wood
		stake.Anchored = true
		stake.CanCollide = false
		stake.Parent = folder

		local skull = Instance.new("Part")
		skull.Name = "Cranio"
		skull.Shape = Enum.PartType.Ball
		skull.Size = Vector3.new(2.2, 2.4, 2.2)
		skull.Position = at + Vector3.new(0, 13, 0)
		skull.Color = Color3.fromRGB(228, 220, 200)
		skull.Material = Enum.Material.Sand
		skull.Anchored = true
		skull.CanCollide = false
		skull.Parent = folder
	end

	--: A placa da clareira. Fica alta e é lida de longe de propósito: é o
	--: convite, e um convite que só se lê de perto não convida ninguém.
	local sign = Instance.new("Part")
	sign.Name = "Placa"
	sign.Size = Vector3.new(20, 8, 1)
	sign.CFrame = CFrame.new(CENTRE + Vector3.new(0, 16,
		Content.hunt.spread - 4))
	sign.Color = Color3.fromRGB(96, 40, 40)
	sign.Material = Enum.Material.Wood
	sign.Anchored = true
	sign.CanCollide = false
	sign.Parent = folder

	local board = Instance.new("BillboardGui")
	board.Size = UDim2.fromOffset(300, 60)
	board.StudsOffsetWorldSpace = Vector3.new(0, 7, 0)
	board.MaxDistance = 260
	board.LightInfluence = 0
	board.Parent = sign

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 32)
	title.BackgroundTransparency = 1
	title.Text = "Bosque das Bestas Demoníacas"
	title.TextScaled = true
	title.Font = Enum.Font.Merriweather
	title.TextColor3 = Color3.fromRGB(236, 132, 118)
	title.TextStrokeTransparency = 0.25
	title.Parent = board

	local note = Instance.new("TextLabel")
	note.Size = UDim2.new(1, 0, 0, 24)
	note.Position = UDim2.fromOffset(0, 32)
	note.BackgroundTransparency = 1
	note.Text = "manuais caem aqui, e em nenhum outro lugar"
	note.TextScaled = true
	note.Font = Enum.Font.SourceSansItalic
	note.TextColor3 = Color3.fromRGB(212, 200, 186)
	note.TextStrokeTransparency = 0.4
	note.Parent = board
end

-- ================================================================ a besta

local function nameplate(model: Model, beast: any, humanoid: Humanoid)
	local head = model:FindFirstChild("Head") or model.PrimaryPart
	if head == nil or not head:IsA("BasePart") then
		return
	end
	local plate = Instance.new("BillboardGui")
	plate.Name = "Vida"
	--: Estreita e de perto. A 180 px e 110 studs, catorze barras de vida
	--: viravam listras vermelhas atravessando a clareira inteira.
	plate.Size = UDim2.fromOffset(126, 30)
	plate.StudsOffsetWorldSpace = Vector3.new(0, 3.4, 0)
	plate.MaxDistance = 72
	plate.LightInfluence = 0
	plate.Parent = head

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 18)
	title.BackgroundTransparency = 1
	title.Text = beast.name
	title.TextScaled = true
	title.Font = Enum.Font.GothamBold
	title.TextColor3 = beast.colour
	title.TextStrokeTransparency = 0.3
	title.Parent = plate

	local track = Instance.new("Frame")
	track.Size = UDim2.new(1, 0, 0, 8)
	track.Position = UDim2.fromOffset(0, 22)
	track.BackgroundColor3 = Color3.fromRGB(24, 20, 24)
	track.BorderSizePixel = 0
	track.Parent = plate

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(198, 62, 66)
	fill.BorderSizePixel = 0
	fill.Parent = track

	humanoid.HealthChanged:Connect(function(value)
		local max = math.max(humanoid.MaxHealth, 1)
		fill.Size = UDim2.fromScale(math.clamp(value / max, 0, 1), 1)
	end)
end

local function spawnOne(parent: Instance, beast: any): Model?
	local ok, model = pcall(function()
		return Rig.build({
			name = beast.name,
			scale = beast.scale,
			shape = beast.shape,
			body = beast.colour,
			accent = beast.colour:Lerp(Color3.new(0, 0, 0), 0.4),
			eyes = Color3.fromRGB(255, 96, 78),
			glow = beast.rank >= 4,
			spikes = beast.rank >= 5,
			weapon = beast.weapon,
			--: Colide, ao contrário de tudo o mais que este jogo constrói.
			--: Uma besta atravessável é um alvo que o jogador nunca sente.
			collide = true,
			detail = true,
		})
	end)
	if not ok or model == nil then
		return nil
	end

	local humanoid = (model :: Model):FindFirstChildOfClass("Humanoid")
	local root = (model :: Model):FindFirstChild("HumanoidRootPart")
	if humanoid == nil or root == nil or not root:IsA("BasePart") then
		model:Destroy()
		return nil
	end

	humanoid.MaxHealth = beast.vida
	humanoid.Health = beast.vida
	humanoid.WalkSpeed = beast.velocidade
	--: Sem o nome padrão do Roblox por cima da placa própria.
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None

	--[[
		Raio pela raiz do sorteio, não pelo sorteio.

		Um raio uniforme em `[12, 110]` distribui igual **por raio**, e a área
		de um anel cresce com o raio -- então a densidade perto do centro fica
		muito maior que na borda. Na prática as catorze bestas se amontoavam no
		meio da clareira, e entrar nela era chegar a um metro e meio de cinco
		delas ao mesmo tempo. Foi assim que o primeiro teste de caça morreu
		antes do primeiro golpe.

		`sqrt(u)` corrige isso: distribuição uniforme por **área**, que é o que
		"espalhadas pela clareira" quer dizer.
	]]
	local angle = stream:number(0, math.pi * 2)
	local inner, outer = 26, Content.hunt.spread - 14
	local radius = math.sqrt(stream:number()) * (outer - inner) + inner
	local at = CENTRE + Vector3.new(
		math.cos(angle) * radius, 4, math.sin(angle) * radius)
	;(model :: Model):PivotTo(CFrame.new(at) * CFrame.Angles(0, angle, 0))
	model.Parent = parent

	nameplate(model :: Model, beast, humanoid)

	live[model :: Model] = {
		model = model :: Model,
		beast = beast,
		humanoid = humanoid,
		root = root,
		home = at,
		lastHit = nil,
		nextSwing = 0,
	}
	population += 1
	return model :: Model
end

--[[
	Que bestas nascem, dado quem está na montanha.

	O rank mais alto entre os jogadores presentes decide o topo da tabela, e o
	sorteio é enviesado para baixo: um bosque em que só nasce a besta mais
	forte disponível não tem escada nenhuma, e um jogador que subiu um realm
	perde de vista tudo o que já venceu.
]]
local function pick(): any
	local top = 1
	for _, player in Players:GetPlayers() do
		local state = Cultivation.stateOf(player)
		if state ~= nil and state.qiRealm > top then
			top = state.qiRealm
		end
	end
	local allowed = {}
	for _, beast in Content.beasts do
		if beast.rank <= top then
			table.insert(allowed, beast)
		end
	end
	if #allowed == 0 then
		return Content.beasts[1]
	end
	--: Enviesado para o fim da lista permitida: o que acabou de abrir aparece
	--: mais, sem que o que já era fácil desapareça.
	local roll = stream:number() ^ 0.6
	local index = math.clamp(math.floor(roll * #allowed) + 1, 1, #allowed)
	return allowed[index]
end

-- ================================================================ o abate

--[[
	Que manual esta besta larga, dado dois sorteios entre 0 e 1.

	Pura, e com os sorteios de fora, porque uma queda aleatória **não se
	verifica jogando**: seis abates com vinte por cento de chance cada é uma
	moeda, e um cenário que dependa dela falha por azar. Com os números
	entrando por parâmetro, um teste pode perguntar exatamente o que importa --
	que uma besta fraca nunca larga um grau alto, e que o peso da tabela é
	respeitado.

	Devolve `nil` quando não caiu nada, que é o caso comum.
]]
function Hunt.rollManual(beast: any, chance: number, pick: number): string?
	if chance > beast.manualChance then
		return nil
	end
	--: Só manuais até o grau que esta besta guarda. Um Lobo das Neblinas que
	--: pudesse largar um Cânone Celestial faria da besta mais fraca a melhor
	--: fonte do jogo, e a escada de rank deixaria de significar nada.
	local pool = {}
	local total = 0
	for _, manual in Content.manuals do
		if manual.tier <= beast.manualTier then
			table.insert(pool, manual)
			total += manual.weight
		end
	end
	if total <= 0 then
		return nil
	end
	local roll = pick * total
	local acc = 0
	for _, manual in pool do
		acc += manual.weight
		if roll < acc then
			return manual.id
		end
	end
	return pool[#pool].id
end

local function drop(killer: Player, entry: Live)
	local beast = entry.beast
	Cultivation.grant(killer, beast.pedras, beast.name)

	local manualId = Hunt.rollManual(beast, stream:number(), stream:number())
	if manualId == nil then
		return
	end
	Cultivation.award(killer, manualId)
	local manual = Content.manual(manualId)
	Telemetry.event("daocultivo.manual", {
		manual = manualId, beast = beast.id,
		tier = if manual ~= nil then manual.tier else 0,
	})
end

local function kill(entry: Live)
	if live[entry.model] == nil then
		return
	end
	live[entry.model] = nil
	population -= 1

	local killer = entry.lastHit
	if killer ~= nil and killer.Parent ~= nil then
		drop(killer, entry)
		Telemetry.event("daocultivo.abate", { beast = entry.beast.id })
	end

	--: O corpo fica dois segundos e some. Instantâneo lê como um bug de
	--: replicação; muito mais tempo e a clareira vira um cemitério que o
	--: jogador tem de atravessar.
	task.delay(2, function()
		if entry.model.Parent ~= nil then
			entry.model:Destroy()
		end
	end)
end

-- ================================================================ o golpe

--: O último golpe de cada jogador, para que a taxa seja do servidor e não uma
--: promessa do cliente. `Net` já limita a mensagem; isto limita o **efeito**,
--: que é o que um cliente modificado tentaria contornar.
local lastSwing: { [Player]: number } = {}

function Hunt.swing(player: Player): { [string]: any }
	local state = Cultivation.stateOf(player)
	local character = player.Character
	if state == nil or character == nil then
		return { ok = false }
	end
	--[[
		Sentado não se golpeia.

		O cliente levanta antes de mandar, então isto nunca recusa um jogador
		honesto. Existe porque o servidor não pode acreditar nele: sem a
		checagem, um cliente modificado bate de dentro do assento -- imóvel,
		invulnerável ao empurrão da física, e ainda cultivando.
	]]
	if state.action ~= "nenhum" then
		return { ok = false, reason = "levante-se antes de golpear" }
	end

	local now = os.clock()
	if now - (lastSwing[player] or 0) < Content.hunt.swingSeconds then
		return { ok = false, reason = "ainda recuperando o golpe" }
	end
	lastSwing[player] = now

	local root = character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return { ok = false }
	end

	local damage = Cultivation.strike(state)
	local hits = 0

	--[[
		O golpe também alcança outros cultivadores -- fora do pátio.

		O pátio é chão sagrado, o que é canônico e também a única coisa que
		impede o jogo de virar um campo de camping em cima do ponto de
		nascimento. Fora dele todo mundo é alcançável, e matar alguém escurece
		a sua aura para sempre (até uma Pílula da Purificação, que é cara).

		A checagem é da posição de **quem bate**: entrar no pátio para ficar
		imune e continuar batendo em quem está fora seria a primeira coisa que
		alguém descobriria.
	]]
	local flat = Vector2.new(root.Position.X - Mountain.ORIGIN.X,
		root.Position.Z - Mountain.ORIGIN.Z)
	if flat.Magnitude > Content.safeRadius then
		for _, other in Players:GetPlayers() do
			if other == player then
				continue
			end
			local body = other.Character
			local victim = body and body:FindFirstChild("HumanoidRootPart")
			local pulse = body and body:FindFirstChildOfClass("Humanoid")
			if victim == nil or pulse == nil or not victim:IsA("BasePart") then
				continue
			end
			if pulse.Health <= 0 then
				continue
			end
			--: A vítima também precisa estar fora do pátio. Um golpe que
			--: atravessa a borda do chão sagrado torna o chão sagrado inútil.
			local theirs = Vector2.new(victim.Position.X - Mountain.ORIGIN.X,
				victim.Position.Z - Mountain.ORIGIN.Z)
			if theirs.Magnitude <= Content.safeRadius then
				continue
			end
			if (victim.Position - root.Position).Magnitude > Content.hunt.reach then
				continue
			end
			Combat.damage(body :: Model, {
				amount = damage, kind = "cultivo", source = player,
			})
			Body.hurt(other)
			Net.fire(other, "Struck", {
				beast = player.DisplayName, amount = damage,
			})
			hits += 1
			if pulse.Health <= 0 then
				Cultivation.markKill(player, other)
			end
		end
	end

	for model, entry in live do
		if not Combat.isAlive(model) then
			continue
		end
		if (entry.root.Position - root.Position).Magnitude > Content.hunt.reach then
			continue
		end
		entry.lastHit = player
		Combat.damage(model, { amount = damage, kind = "cultivo", source = player })
		hits += 1
		if not Combat.isAlive(model) then
			kill(entry)
		end
	end
	return { ok = true, hits = hits, damage = damage }
end

-- ================================================================== o laço

--[[
	As bestas andam, batem e voltam.

	Um laço só para todas, a cinco quadros por segundo. A besta persegue o
	jogador mais próximo dentro da clareira e bate quando alcança; longe de
	todo mundo ela volta para o centro, porque uma besta que persegue para fora
	da clareira acaba no pátio -- e um javali no meio da meditação de outro
	jogador é o tipo de coisa que ninguém consegue reproduzir depois.
]]
local function step()
	local now = os.clock()
	--: Quantas já estão batendo em cada jogador neste passo. É o que impede
	--: que o dano por segundo cresça com o tamanho do bando -- o cerco
	--: continua existindo e assustando, e só três mordem.
	local engaged: { [Player]: number } = {}

	for model, entry in live do
		if not Combat.isAlive(model) then
			kill(entry)
			continue
		end

		--[[
			Quem ela persegue.

			`aggro` e não `spread`: o raio de acordar é uma fração da clareira,
			então entrar puxa as duas ou três que estão perto em vez das
			catorze. Uma vez acordada, ela persegue até a coleira -- senão a
			besta desiste no primeiro passo que o jogador dá para trás.
		]]
		local awake = entry.lastHit ~= nil
			or (entry.root.Position - entry.home).Magnitude > 4
		local wake = if awake then Content.hunt.leash else Content.hunt.aggro

		local closest: Player? = nil
		local best = math.huge
		for _, player in Players:GetPlayers() do
			local character = player.Character
			local target = character and character:FindFirstChild("HumanoidRootPart")
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if target == nil or humanoid == nil or humanoid.Health <= 0 then
				continue
			end
			if not target:IsA("BasePart") then
				continue
			end
			local distance = (target.Position - entry.root.Position).Magnitude
			if distance < best and distance < wake then
				best, closest = distance, player
			end
		end

		--: Longe demais de casa é o mesmo que sem alvo. Sem isso a
		--: perseguição atravessa o bosque e termina com um javali no meio da
		--: meditação de outra pessoa.
		if (entry.root.Position - entry.home).Magnitude > Content.hunt.leash then
			closest = nil
		end

		if closest == nil then
			--: Volta para onde nasceu, e esquece quem bateu nela. Uma besta
			--: parada onde matou alguém é a razão pela qual o próximo jogador
			--: não consegue entrar na clareira.
			entry.lastHit = nil
			if (entry.root.Position - entry.home).Magnitude > 6 then
				entry.humanoid:MoveTo(entry.home)
			end
			continue
		end

		local character = closest.Character
		local target = character and character:FindFirstChild("HumanoidRootPart")
		if target == nil or not target:IsA("BasePart") then
			continue
		end
		entry.humanoid:MoveTo(target.Position)

		local biting = engaged[closest] or 0
		if best <= Content.hunt.reach and now >= entry.nextSwing
			and biting < Content.hunt.maxEngaged then
			engaged[closest] = biting + 1
			entry.nextSwing = now + 1.4
			local victim = character :: Model
			if Combat.isAlive(victim) then
				Combat.damage(victim, {
					amount = entry.beast.poder,
					kind = "besta",
					source = model,
				})
				--: A regeneração fica em pausa enquanto se apanha. Sem esta
				--: linha ela cura durante a briga e toda luta perdida vira
				--: empate.
				Body.hurt(closest)
				Net.fire(closest, "Struck", {
					beast = entry.beast.name,
					amount = entry.beast.poder,
				})
			end
		end
	end
end

function Hunt.start()
	local root = Mountain.root()

	local ok, err = pcall(ground, root)
	if not ok then
		Debug.error("o bosque não subiu: " .. tostring(err))
	end

	local pen = Instance.new("Folder")
	pen.Name = "Bestas"
	pen.Parent = root

	Net.on("Swing", function(player: Player)
		Hunt.swing(player)
	end)

	--: A população. Um laço lento e separado do de combate: nascer é caro e
	--: acontece a cada poucos segundos, bater é barato e acontece sempre.
	task.spawn(function()
		while true do
			if population < Content.hunt.population then
				local beast = pick()
				local born = spawnOne(pen, beast)
				if born == nil then
					--: Um rig que não montou não pode virar um laço apertado
					--: tentando de novo cinco vezes por segundo.
					task.wait(2)
				end
			end
			task.wait(Content.hunt.respawnSeconds / Content.hunt.population)
		end
	end)

	--: Cinco quadros por segundo para o comportamento. `Heartbeat` cheio
	--: seria sessenta buscas de jogador mais próximo por besta por segundo,
	--: para produzir um passo que o `Humanoid` leva um décimo de segundo para
	--: começar a dar.
	task.spawn(function()
		while true do
			task.wait(0.2)
			local fine, problem = pcall(step)
			if not fine then
				Debug.error("passo da caça falhou: " .. tostring(problem))
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		lastSwing[player] = nil
		for _, entry in live do
			if entry.lastHit == player then
				entry.lastHit = nil
			end
		end
	end)

	Debug.probe("caca", function()
		local counts: { [string]: number } = {}
		for _, entry in live do
			counts[entry.beast.id] = (counts[entry.beast.id] or 0) + 1
		end
		return {
			vivas = population,
			teto = Content.hunt.population,
			centro = { x = CENTRE.X, y = CENTRE.Y, z = CENTRE.Z },
			porEspecie = counts,
		}
	end)
	Debug.info(string.format("caça: bosque com %d bestas, %d espécies",
		Content.hunt.population, #Content.beasts))
end

return Hunt
