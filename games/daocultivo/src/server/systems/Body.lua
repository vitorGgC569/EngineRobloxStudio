--!strict
--[[
	Body — o caminho do corpo, aplicado ao corpo.

	Sem este arquivo o Corpo é uma segunda barra decorativa: enche, muda um
	título, e o personagem continua com cem de vida andando a dezesseis. Em
	qualquer manhwa é o contrário -- quem treina o corpo **aguenta mais, corre
	mais e salta mais alto**, e é a única razão de existirem dois caminhos em
	vez de um.

	O que muda, e por que só isto
	-----------------------------

	    MaxHealth   exponencial, e é o número grande que a tela mostra
	    WalkSpeed   aditivo, com teto
	    JumpPower   aditivo, com teto

	Os tetos não são timidez. Um cultivador a trezentos studs por segundo
	atravessa a montanha antes de ela carregar -- com `StreamingEnabled`
	ligado, ele corre para dentro de um mundo que ainda não existe e cai. E um
	salto sem teto entrega, de graça, o voo que a Formação do Núcleo deveria
	conceder, que é o momento mais bem guardado do jogo.

	Quando aplica
	-------------

	No nascimento do personagem e a cada mudança de degrau do corpo. Aplicar
	só no nascimento faz o jogador romper, ver o título mudar e continuar
	morrendo com a mesma vida até morrer -- o que lê como o rompimento não ter
	valido nada.

	A ordem de `MaxHealth` e `Health`
	---------------------------------

	`Health` é preso ao `MaxHealth` corrente. Escrever a vida antes do máximo
	faz o Roblox aparar o valor no máximo **antigo**, e o cultivador que
	acabou de dobrar a resistência aparece com a barra pela metade.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Content = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Content"))

local Cultivation = require(script.Parent:WaitForChild("Cultivation"))

local Debug = Forge.Debug

local Body = {}

local function constitutionMult(id: string): number
	for _, entry in Content.constitutions do
		if entry.id == id then
			return entry.mult
		end
	end
	return 1.0
end

--: Quantos degraus de corpo já foram subidos. Mesma conta que a curva de
--: rendimento usa, e por isso mesma unidade: degrau, não realm.
local function bodyStages(state: any): number
	return (state.bodyRealm - 1) * Content.stagesPerRealm + state.bodyStage
end

function Body.apply(player: Player)
	local state = Cultivation.stateOf(player)
	local character = player.Character
	if state == nil or character == nil then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return
	end

	local stages = bodyStages(state)
	--: As técnicas entram aqui, e não numa segunda conta em outro sistema. Um
	--: `saudeMult` aplicado no HUD e não no `Humanoid` seria uma barra que
	--: mente sobre quanto dano o jogador aguenta.
	local wanted = Content.maxHealth(stages, constitutionMult(state.constitution))
		* Cultivation.techniqueMultiplier(state, "saudeMult")
	local before = humanoid.MaxHealth
	local ratio = if before > 0 then humanoid.Health / before else 1

	humanoid.MaxHealth = wanted
	--: A vida sobe na mesma proporção em que estava. Encher a barra a cada
	--: avanço faria do rompimento uma cura, e romper no meio de uma luta
	--: viraria a jogada em vez de ser a recompensa dela.
	humanoid.Health = math.clamp(wanted * ratio, 1, wanted)

	--[[
		Um cultivador em postura não anda.

		`Pose` prende o movimento quando a postura começa, e este sistema
		reaplica velocidade a cada degrau de corpo rompido -- então sem esta
		checagem um avanço no meio de uma meditação devolveria a caminhada e o
		jogador sairia andando sentado. Os dois sistemas escrevem no mesmo
		`WalkSpeed`, e este é o que roda por último.
	]]
	--: A velocidade da técnica é aplicada **antes** do teto, não depois: o teto
	--: existe porque um cultivador rápido demais corre para dentro de um mundo
	--: que o `StreamingEnabled` ainda não carregou, e uma técnica não é motivo
	--: para suspender essa regra.
	local speed = math.min(Content.body.maxSpeed,
		Content.walkSpeed(stages)
			* Cultivation.techniqueMultiplier(state, "velocidade"))
	--[[
		Correr multiplica a caminhada, que já vem do caminho do corpo e das
		técnicas.

		Uma segunda escada de velocidade seria mais um número para manter e
		para o jogador aprender; um multiplicador sobre a primeira faz o treino
		de corpo pagar duas vezes -- anda mais rápido, e corre mais rápido
		ainda -- sem nada novo para explicar.
	]]
	local pinned = state.action == "cultivar" or state.action == "treinar"
	humanoid.WalkSpeed = if pinned then 0
		elseif state.sprinting then Content.sprintSpeed(speed)
		else speed
	humanoid.JumpPower = if pinned then 0 else Content.jumpPower(stages)
	--: `UseJumpPower` existe porque o padrão do Roblox migrou para
	--: `JumpHeight`, e num lugar com esse padrão escrever `JumpPower` é
	--: escrever numa propriedade que ninguém lê. Protegido, porque a
	--: propriedade não existe em toda versão -- e uma que falta deve custar o
	--: salto, não o sistema inteiro.
	pcall(function()
		humanoid.UseJumpPower = true
	end)

	--: Publicado para a tela e para a placa. A saúde é o segundo número
	--: grande da interface e ela não recebe `StateSync` de outros jogadores.
	player:SetAttribute("saudeMax", wanted)
end

local function follow(player: Player)
	player.CharacterAdded:Connect(function()
		--: Um quadro depois. O `Humanoid` existe no instante do evento, mas o
		--: script padrão do Roblox ainda escreve `WalkSpeed` depois dele, e
		--: quem escreve por último ganha.
		task.wait(0.2)
		Body.apply(player)
	end)
	--: O degrau do corpo é publicado como atributo pelo `Cultivation`, então
	--: este é o sinal exato de "o jogador rompeu" -- sem laço, sem polling, e
	--: sem o sistema do corpo precisar saber como o rompimento funciona.
	player:GetAttributeChangedSignal("corpoEstagio"):Connect(function()
		Body.apply(player)
	end)
	player:GetAttributeChangedSignal("corpoRealm"):Connect(function()
		Body.apply(player)
	end)
	--: A corrida é publicada como atributo pelo `Cultivation`, então este é o
	--: sinal exato de "apertou ou soltou Shift" -- sem laço, e sem `Body`
	--: precisar saber que existe uma tecla.
	player:GetAttributeChangedSignal("correndo"):Connect(function()
		Body.apply(player)
	end)
	--: A corrida é publicada como atributo pelo `Cultivation`, então este é o
	--: sinal exato de "apertou ou soltou Shift" -- sem laço, e sem `Body`
	--: precisar saber que existe uma tecla.
	player:GetAttributeChangedSignal("correndo"):Connect(function()
		Body.apply(player)
	end)
	if player.Character ~= nil then
		task.spawn(Body.apply, player)
	end
end

--[[
	A regeneração, num laço só para todos os jogadores.

	Um `task.spawn` por jogador é o mesmo trabalho dividido em N agendamentos
	que o Roblox tem de acordar separados, e este laço roda para sempre.

	A pausa depois de apanhar é o que separa "curo entre as brigas" de "curo
	durante a briga". Sem ela toda luta perdida vira empate, e a decisão de
	quando entrar no bosque -- que é o interesse inteiro da caça -- deixa de
	existir.
]]
local hurtAt: { [Player]: number } = {}

function Body.hurt(player: Player)
	hurtAt[player] = os.clock()
end

local function regenerate()
	local now = os.clock()
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid == nil or humanoid.Health <= 0 then
			continue
		end
		if humanoid.Health >= humanoid.MaxHealth then
			continue
		end
		if now - (hurtAt[player] or 0) < Content.body.regenDelay then
			continue
		end
		humanoid.Health = math.min(humanoid.MaxHealth,
			humanoid.Health + humanoid.MaxHealth * Content.body.regenPercent)
	end
end

function Body.start()
	Players.PlayerAdded:Connect(follow)
	Players.PlayerRemoving:Connect(function(player)
		hurtAt[player] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(1)
			local ok, err = pcall(regenerate)
			if not ok then
				Debug.error("regeneração falhou: " .. tostring(err))
			end
		end
	end)
	--: O jogador local do Studio entra antes deste sistema existir, então
	--: `PlayerAdded` já passou para ele -- e ele é o único jogador da sessão
	--: em que o jogo é testado.
	for _, player in Players:GetPlayers() do
		follow(player)
	end

	Debug.probe("corpo", function()
		local out = {}
		for _, player in Players:GetPlayers() do
			local state = Cultivation.stateOf(player)
			if state ~= nil then
				local stages = bodyStages(state)
				out[player.Name] = {
					degraus = stages,
					saudeMax = Content.maxHealth(stages,
						constitutionMult(state.constitution))
						* Cultivation.techniqueMultiplier(state, "saudeMult"),
					velocidade = Content.walkSpeed(stages),
					salto = Content.jumpPower(stages),
					tecnicaSaude = Cultivation.techniqueMultiplier(state, "saudeMult"),
				}
			end
		end
		return out
	end)
	Debug.info("corpo: saúde, velocidade e salto seguem o caminho do corpo")
end

return Body
