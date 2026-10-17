--!strict
--[[
	Pose — o corpo faz o que a barra diz que está fazendo.

	Um cultivador que "está meditando" em pé, andando pelo pátio, com uma barra
	subindo no canto da tela, não está meditando: está com um número subindo.
	A postura é o que transforma o cultivo de um relatório numa cena, e é a
	única parte disso que **os outros jogadores** enxergam.

	    cultivar   senta no chão, imóvel, virado para o taiji
	    treinar    faz flexões, no lugar
	    nenhum     volta a andar

	Por que um `Seat` e não uma pose animada
	----------------------------------------

	A tentação é montar a flor de lótus com `Forge.Anim`, e para um rig
	construído em código isso funciona. Para o personagem **de um jogador**,
	não: as juntas dele são `AnimationConstraint`, animadas por `Transform`
	dentro do passo de física, e o dono dessa física é o cliente dele. Uma pose
	escrita no servidor chega como um pedido que o solucionador do outro lado
	pode simplesmente não atender.

	Pior: `Anim` só ganha das juntas depois que `Rig.stripDefaultAnimate` tira
	o `Animate` do Roblox do caminho -- e se a pose falhar depois disso, o que
	sobra é um jogador em T-pose até morrer. Um modo de falha pior que o
	problema.

	`Seat:Sit()` é do próprio Roblox: replica sozinho, prende o movimento sem
	`WalkSpeed = 0`, sobrevive a respawn porque é reconstruído, e a animação de
	sentar é a que o cliente já tem. Menos bonito que uma flor de lótus, e
	confiável nos doze casos em que a outra não seria.

	A armadilha que este arquivo evita
	----------------------------------

	**Nunca escrever `Humanoid.HipHeight` para baixar alguém.** A altura do
	quadril é um termo do solucionador de física, não um deslocamento visual:
	forçá-la lança o personagem. É uma das linhas mais caras que este
	repositório já escreveu, e a sentar num `Seat` o problema nem existe.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Content = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Content"))

local Mountain = require(script.Parent:WaitForChild("Mountain"))
local Cultivation = require(script.Parent:WaitForChild("Cultivation"))
local Body = require(script.Parent:WaitForChild("Body"))

local Debug = Forge.Debug

local Pose = {}

local seats: { [Player]: Seat } = {}

--: Quem está fazendo flexão, e onde. Uma tabela e um laço só: um `task.spawn`
--: por jogador é o mesmo trabalho dividido em N agendamentos que o Roblox tem
--: de acordar separados.
type Drill = {
	root: BasePart, humanoid: Humanoid, base: Vector3, yaw: number,
	--: As juntas que a flexão move, resolvidas uma vez. Procurá-las a cada
	--: quadro é uma varredura de `GetDescendants` sessenta vezes por segundo
	--: por jogador, para achar sempre as mesmas cinco.
	joints: { [string]: AnimationConstraint },
	animate: BaseScript?,
}
local drills: { [Player]: Drill } = {}

local function release(player: Player)
	local seat = seats[player]
	seats[player] = nil
	if seat == nil then
		return
	end
	local occupant = seat.Occupant
	if occupant ~= nil then
		--: Levantar antes de destruir. Destruir o assento com alguém em cima
		--: deixa o humanoide num estado sentado sem assento -- de pé por
		--: dentro, sentado por fora, e nada o tira disso a não ser morrer.
		occupant.Sit = false
	end
	seat:Destroy()
end

--[[
	Senta o jogador onde ele está, virado para o taiji.

	Virado para o centro porque é para lá que se olha: um pátio de meditantes
	todos de costas para o disco parece um estacionamento, e a direção é a
	coisa mais barata que existe para dizer o contrário.
]]
local function sit(player: Player): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid == nil or root == nil or not root:IsA("BasePart") then
		return false
	end
	if humanoid.Health <= 0 then
		return false
	end

	release(player)

	--: O chão embaixo dos pés, e não a posição do tronco. Sentar na altura do
	--: tronco põe o cultivador flutuando dois studs acima da pedra, o que é
	--: exatamente o tipo de erro que ninguém consegue nomear ao ver.
	local filter = RaycastParams.new()
	filter.FilterType = Enum.RaycastFilterType.Exclude
	filter.FilterDescendantsInstances = { character :: Instance }
	local hit = Workspace:Raycast(root.Position, Vector3.new(0, -14, 0), filter)
	local floor = if hit ~= nil then hit.Position.Y else root.Position.Y - 3

	local flat = Vector3.new(
		Mountain.ORIGIN.X - root.Position.X, 0,
		Mountain.ORIGIN.Z - root.Position.Z)
	local facing = if flat.Magnitude > 1
		then CFrame.lookAt(Vector3.zero, flat.Unit).Rotation
		else root.CFrame.Rotation

	local seat = Instance.new("Seat")
	seat.Name = "AssentoDeMeditacao"
	seat.Size = Vector3.new(2.4, 0.4, 2.4)
	seat.Transparency = 1
	seat.Anchored = true
	seat.CanCollide = false
	--: Sem toque. Um assento invisível que aceita quem esbarrar nele é uma
	--: armadilha no meio do pátio, e o jogador que cai nela não faz ideia do
	--: que aconteceu.
	seat.CanTouch = false
	seat.CFrame = CFrame.new(
		Vector3.new(root.Position.X, floor + 1.2, root.Position.Z)) * facing
	seat.Parent = Workspace

	seats[player] = seat
	seat:Sit(humanoid)
	return true
end

--[[
	Larga a flexão e devolve o corpo à física.

	A ordem importa: soltar a âncora **antes** de desligar `PlatformStand`.
	Ao contrário, o humanoide tenta se levantar durante um quadro em que o
	tronco ainda está preso, e o solucionador responde arremessando o
	personagem -- que é a mesma família de defeito que escrever `HipHeight`.
]]
local function stopDrill(player: Player)
	local drill = drills[player]
	drills[player] = nil
	if drill == nil then
		return
	end
	--[[
		Devolver as juntas à identidade **antes** de religar o `Animate`.

		Uma `Transform` deixada escrita é uma pose que ninguém está mais
		atualizando: o jogador levanta e continua com os cotovelos dobrados
		para sempre. E religar o `Animate` primeiro faria os dois escreverem na
		mesma junta durante um quadro, que é a única janela em que dá para ver
		o personagem tremer.
	]]
	for _, joint in drill.joints do
		if joint.Parent ~= nil then
			joint.Transform = CFrame.identity
		end
	end
	if drill.root.Parent ~= nil then
		drill.root.Anchored = false
	end
	if drill.humanoid.Parent ~= nil then
		drill.humanoid.PlatformStand = false
	end
	if drill.animate ~= nil and drill.animate.Parent ~= nil then
		drill.animate.Disabled = false
	end
end

--[[
	Flexões, com braços.

	A primeira versão movia só o tronco -- corpo rígido na diagonal, subindo e
	descendo -- e a primeira pessoa que olhou disse o óbvio: ele não está
	usando os braços. Estava certa. Aquilo era uma prancha oscilando, não uma
	flexão.

	A razão de eu ter parado no tronco era uma suposição que **não conferi**: o
	personagem do jogador não tem `Motor6D`, são quinze `AnimationConstraint`
	cuja física pertence ao cliente, e a conclusão fácil é que uma pose escrita
	no servidor não seria atendida. Testei com uma foto: **é atendida**. Uma
	`Transform` escrita no servidor replica e o cliente a resolve.

	Então a flexão é de verdade, e para todo mundo:

	    tronco    inclinado a 74°, subindo e descendo a duas por segundo
	    ombro     fixo, braço apontado para o chão
	    cotovelo  de quase esticado a bem dobrado -- é aqui que ela acontece
	    pescoço   olhando para a frente, não para o chão

	O `Animate` do Roblox fica **desabilitado**, não destruído. Desabilitar é
	reversível; destruir deixa o jogador sem animação nenhuma até morrer, que é
	um modo de falha pior que o problema que ele resolveria.
]]
function Pose.drill(player: Player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid == nil or root == nil or not root:IsA("BasePart") then
		return
	end
	if humanoid.Health <= 0 then
		return
	end

	release(player)
	stopDrill(player)

	local filter = RaycastParams.new()
	filter.FilterType = Enum.RaycastFilterType.Exclude
	filter.FilterDescendantsInstances = { character :: Instance }
	local hit = Workspace:Raycast(root.Position, Vector3.new(0, -14, 0), filter)
	local floor = if hit ~= nil then hit.Position.Y else root.Position.Y - 3

	--: Guarda o ângulo em que ele já estava. Girar alguém para o norte porque
	--: apertou treinar é o tipo de detalhe que ninguém reporta e todo mundo
	--: percebe.
	local _, yaw = root.CFrame:ToEulerAnglesYXZ()

	--: Os nomes são de um rig R15 vivo, conferidos, não lembrados. Um nome
	--: errado aqui não dá erro: a junta simplesmente não é encontrada e o
	--: membro fica parado, que é a forma mais cara de errar.
	local joints: { [string]: AnimationConstraint } = {}
	for _, item in character:GetDescendants() do
		if item:IsA("AnimationConstraint") then
			local name = item.Name
			if name == "RightShoulder" or name == "LeftShoulder"
				or name == "RightElbow" or name == "LeftElbow"
				or name == "Neck" then
				joints[name] = item
			end
		end
	end

	--: Desabilitado, não destruído. O `Animate` do Roblox reescreve as mesmas
	--: juntas todo quadro e nenhuma prioridade de render é tarde o bastante
	--: para ganhar dele.
	local animate = character:FindFirstChild("Animate")
	if animate ~= nil and animate:IsA("BaseScript") then
		animate.Disabled = true
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator ~= nil then
		for _, track in animator:GetPlayingAnimationTracks() do
			track:Stop(0)
		end
	end

	humanoid.PlatformStand = true
	root.Anchored = true

	drills[player] = {
		root = root,
		humanoid = humanoid,
		base = Vector3.new(root.Position.X, floor, root.Position.Z),
		yaw = yaw,
		joints = joints,
		animate = if animate ~= nil and animate:IsA("BaseScript")
			then animate else nil,
	}
end

--[[
	Aplica a postura que o estado pede.

	Chamado por mudança de atributo e não por laço: `postura` é publicado pelo
	`Cultivation` a cada sincronização, então isto dispara no instante exato em
	que o jogador escolhe um caminho -- sem varrer ninguém.
]]
function Pose.apply(player: Player)
	local state = Cultivation.stateOf(player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if state == nil or humanoid == nil then
		return
	end

	if state.action == "cultivar" then
		sit(player)
		return
	end

	release(player)
	if state.action ~= "treinar" then
		stopDrill(player)
	end

	if state.action == "treinar" then
		Pose.drill(player)
		return
	end

	--: Solto. `Body` é quem sabe a velocidade deste cultivador, e restaurar um
	--: valor guardado aqui seria uma segunda opinião sobre o mesmo número --
	--: que fica errada assim que ele rompe um degrau de corpo.
	Body.apply(player)
end

--[[
	O movimento, num laço só para todos.

	`PreSimulation` e não `Heartbeat`: o tronco é ancorado e não precisaria de
	nada, mas as **juntas** precisam. Uma `AnimationConstraint` não move nada
	sozinha -- ela declara um alvo que o solucionador persegue, e um alvo
	escrito depois do solve é um alvo que aquele quadro ignora. `PreSimulation`
	é o passo imediatamente antes, e é o único lugar em que escrever numa
	constraint muda a pose do quadro para o qual foi escrita.
]]
local function pump()
	local now = os.clock()
	local spec = Content.pushup
	for player, drill in drills do
		if drill.root.Parent == nil or drill.humanoid.Health <= 0 then
			stopDrill(player)
			continue
		end

		--: `dip` vai de 0 (braço esticado, corpo no alto) a 1 (corpo no chão).
		--: `math.abs(math.sin)` dá o mesmo tempo na subida e na descida, que é
		--: como uma flexão de verdade se parece -- uma senoide comum passa
		--: rápido demais pelo fundo.
		local dip = math.abs(math.sin(now * spec.hertz * math.pi))

		drill.root.CFrame =
			CFrame.new(drill.base
				+ Vector3.new(0, spec.floor + (1 - dip) * spec.amplitude, 0))
			* CFrame.Angles(0, drill.yaw, 0)
			* CFrame.Angles(math.rad(spec.pitch), 0, 0)

		--[[
			Os braços abrem conforme descem, e é isso que faz a flexão ser vista.

			Os ângulos antigos mediam certo e não apareciam: com o corpo quase
			deitado e os braços colados ao tronco, ambos ficavam escondidos
			**debaixo** do personagem. A abertura joga os cotovelos para fora da
			silhueta, e o sinal é espelhado porque no mapa R15 o ombro direito e
			o esquerdo têm `spread` de sinais opostos -- somar o mesmo valor nos
			dois fecha um e abre o outro.
		]]
		local elbow = math.rad(spec.cotoveloAlto
			+ (spec.cotoveloFundo - spec.cotoveloAlto) * dip)
		local flare = math.rad(spec.abertura) * dip
		for name, joint in drill.joints do
			if name == "RightElbow" then
				joint.Transform = CFrame.Angles(elbow, 0, -flare)
			elseif name == "LeftElbow" then
				joint.Transform = CFrame.Angles(elbow, 0, flare)
			elseif name == "RightShoulder" then
				joint.Transform = CFrame.Angles(math.rad(spec.ombro), 0, -flare * 1.4)
			elseif name == "LeftShoulder" then
				joint.Transform = CFrame.Angles(math.rad(spec.ombro), 0, flare * 1.4)
			elseif name == "Neck" then
				--: A cabeça sobe quando o corpo sobe. É o detalhe que separa
				--: "alguém treinando" de "um boneco articulado".
				joint.Transform = CFrame.Angles(
					math.rad(spec.pescoco * (0.4 + dip * 0.9)), 0, 0)
			end
		end
	end
end

local function follow(player: Player)
	player:GetAttributeChangedSignal("postura"):Connect(function()
		Pose.apply(player)
	end)
	player.CharacterAdded:Connect(function()
		--: O assento e o tronco antigos morreram com o corpo antigo. Sem esta
		--: limpeza a tabela guarda instâncias destruídas, e o próximo
		--: `release` não acha mais nada para soltar.
		seats[player] = nil
		drills[player] = nil
		task.wait(0.5)
		Pose.apply(player)
	end)
	if player.Character ~= nil then
		task.spawn(Pose.apply, player)
	end
end

function Pose.start()
	Players.PlayerAdded:Connect(follow)
	--: O jogador local do Studio entra antes deste sistema existir.
	for _, player in Players:GetPlayers() do
		follow(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		release(player)
		stopDrill(player)
	end)

	RunService.PreSimulation:Connect(function()
		local ok, err = pcall(pump)
		if not ok then
			Debug.error("flexão falhou: " .. tostring(err))
		end
	end)

	Debug.probe("postura", function()
		local out = {}
		for _, player in Players:GetPlayers() do
			local state = Cultivation.stateOf(player)
			out[player.Name] = {
				acao = if state ~= nil then state.action else "?",
				sentado = seats[player] ~= nil,
				flexionando = drills[player] ~= nil,
			}
		end
		return out
	end)
	Debug.info("postura: quem cultiva senta, quem treina faz flexão")
end

return Pose
