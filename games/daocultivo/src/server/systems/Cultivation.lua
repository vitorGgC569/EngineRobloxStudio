--!strict
--[[
	Cultivation — o laço inteiro do jogo, do lado que decide.

	Um cultivador tem duas poças que crescem por ações diferentes, uma
	exigência que o próximo degrau cobra, e uma identidade rolada que
	multiplica tudo. Esse é o jogo; o resto é apresentação.

	    sentar    Qi entra por tick, sem teto: a poça só cresce
	    exigência o que o degrau seguinte custa
	    avanço    gasta **a exigência**, não a poça, e sobe um estágio
	    estágio X realm seguinte, e o avanço de realm pode falhar
	    pedras    caem do avanço e das veias, compram pílulas e rolagens
	    pílulas   multiplicam a entrada por alguns minutos
	    rolagem   troca quem você é; a trava é o que impede de perder

	Por que a poça não tem teto
	---------------------------

	Tinha, e estava errado. Com teto, o Qi parava de entrar assim que a barra
	enchia: quem saísse da frente da tela voltava para uma poça exatamente onde
	a deixou, e cultivar virava uma fila de cliques obrigatórios em vez de um
	acúmulo. Um jogo de cultivo em que **parar de olhar interrompe o cultivo**
	contradiz a única coisa que o gênero promete.

	Agora a poça só cresce. O que o degrau seguinte custa é uma *exigência*, e
	o avanço debita exatamente ela -- então quem fica meia hora fora volta com
	Qi para cinco avanços guardados e escolhe quando gastá-los. A decisão que o
	teto tentava criar continua existindo, e melhor: rompo agora, ou junto mais
	e tomo uma pílula antes de encarar a tribulação de realm?

	Por que o avanço de realm pode falhar
	-------------------------------------

	Cânone do gênero, e mecanicamente é o único ponto do laço em que o jogador
	pode perder algo. Sem risco em algum lugar, pedra espiritual não tem para
	que servir e a economia inteira vira decoração. A falha é generosa de
	propósito: custa metade de uma exigência, nunca a poça, e cada tentativa
	frustrada deixa uma percepção que soma na próxima -- então uma sequência
	ruim termina, sempre.

	A forma das funções, e por que ela não é `(player, ...)`
	--------------------------------------------------------

	Toda regra aqui é `(state, subject, ...)`. Nenhuma toca um `Player`.

	Isso não é purismo: é a única forma que um cenário consegue exercitar. A
	versão anterior deste arquivo era `(player, ...)`, e a consequência foi que
	nenhum teste conseguia rodar a regra -- só o handler de rede, que é a
	metade que sempre funciona. Os `Net.on` no fim do arquivo são invólucros de
	três linhas justamente para que não haja nada dentro deles que um teste não
	alcance.

	O que o servidor guarda e o cliente não
	---------------------------------------

	Tudo. O cliente não mantém cópia de Qi, de pedras nem de estágio: um
	cliente que mantém discorda do livro no instante em que algo é gasto, e
	discorda sempre a favor de quem está olhando.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Content = require(Shared:WaitForChild("Content"))

require(Shared:WaitForChild("Wire"))

local Net = Forge.Net
local Rng = Forge.Core.Rng
local Save = Forge.Save
local Debug = Forge.Debug
local Telemetry = Forge.Telemetry
local Hatch = Forge.Loop.Hatch

local Cultivation = {}

--: Um fluxo nomeado, não `math.random`. Uma rolagem de raiz é a coisa mais
--: cara que este jogo faz e precisa ser reproduzível a partir da semente,
--: senão um cenário que testa "o giro paga" testa uma moeda diferente a cada
--: execução.
local stream = Rng.stream("daocultivo.destino")
local function roll(): number
	return stream:number()
end

export type State = {
	qiRealm: number, qiStage: number, qi: number, qiInsight: number,
	bodyRealm: number, bodyStage: number, body: number, bodyInsight: number,
	root: string, rootLocked: boolean,
	constitution: string, constitutionLocked: boolean,
	pedras: number, meritos: number,
	--: id da pílula -> `os.time` em que o efeito acaba.
	buffs: { [string]: number },
	--: técnicas compradas. Mora no estado e não num atributo do `Player`
	--: porque é a única forma de o save levá-las junto.
	owned: { [string]: boolean },
	--: manuais lidos. Permanentes e cumulativos: é o único multiplicador que
	--: não se compra, e por isso o único que faz caçar valer a pena.
	manuals: { [string]: number },
	techniques: { [number]: string },
	action: string,
	flying: boolean,
	--: Correndo. Vive no estado e não só no cliente porque a velocidade é do
	--: servidor: um cliente que decide a própria velocidade decide a própria
	--: velocidade.
	sprinting: boolean,
	--: Quantos cultivadores este jogador matou. A aura escurece com isto, e é
	--: a única estatística do jogo que ele pode querer esconder.
	kills: number,
	--: Onde o cultivador está sentado. Vem da posição no mundo, não de um
	--: pedido do cliente: uma zona escolhida por mensagem é uma zona que
	--: qualquer um escolhe sem sair do lugar.
	zone: string,
	spins: number, breaks: number,
}

local states: { [Player]: State } = {}

-- ============================================================= a identidade

--: Os drops das duas roletas, no formato que `CrateRoll` quer. Derivados das
--: tabelas de `Content` e nunca escritos duas vezes: uma raiz nova aparece na
--: roleta por existir, não porque alguém lembrou de acrescentá-la aqui.
local function dropsFrom(list: { any }): { any }
	local drops = {}
	for _, entry in list do
		table.insert(drops, { id = entry.id, weight = entry.weight, rarity = entry.tier })
	end
	return drops
end

local function techniqueById(id: string): any
	for _, entry in Content.techniques do
		if entry.id == id then
			return entry
		end
	end
	return nil
end

local function byId(list: { any }, id: string): any
	for _, entry in list do
		if entry.id == id then
			return entry
		end
	end
	return list[1]
end

--[[
	As duas roletas, cada uma com seu funil e sua pena.

	`Loop.Hatch` faz três coisas que valem a composição: declara o funil por
	existir (o jogo anterior daqui não sabia dizer se alguém ficou, porque
	declarar era tarefa de quem escrevia o jogo), mantém a pena **por jogador**
	e não por servidor, e sabe que o primeiro giro é de graça.

	O primeiro giro grátis não é generosidade. É a resposta ao único registro
	real de retenção deste repositório: a maior parte dos jogadores novos saiu
	antes de receber qualquer coisa.
]]
local wheels = {}

local function wheel(kind: string): any
	local found = wheels[kind]
	if found ~= nil then
		return found
	end
	local list = if kind == "raiz" then Content.roots else Content.constitutions
	found = Hatch.new({
		theme = {
			noun = if kind == "raiz" then "raiz espiritual" else "constituição",
			verb = "despertar",
		},
		drops = dropsFrom(list),
		--: O segundo degrau: a primeira rolagem de tier 4 ou mais. É onde o
		--: jogador para de rolar por curiosidade e passa a rolar com medo de
		--: perder, e é o número que decide se ele volta amanhã.
		tier2At = 4,
		pityThreshold = 12,
		minRarityForPity = 4,
		funnel = "daocultivo." .. kind,
	})
	wheels[kind] = found
	return found
end

-- ================================================================= o estado

--: Um cultivador novo. Público, porque é por aqui que um cenário começa: um
--: teste que precisa de um `Player` para exercitar uma regra é um teste que
--: nunca vai ser escrito.
function Cultivation.newState(): State
	return {
		qiRealm = 1, qiStage = 1, qi = 0, qiInsight = 0,
		bodyRealm = 1, bodyStage = 1, body = 0, bodyInsight = 0,
		root = "quintupla", rootLocked = false,
		constitution = "comum", constitutionLocked = false,
		pedras = Content.currencies.pedras.start,
		meritos = Content.currencies.meritos.start,
		buffs = {},
		owned = {},
		manuals = {},
		techniques = {},
		action = "nenhum",
		flying = false,
		sprinting = false,
		kills = 0,
		zone = "patio",
		spins = 0, breaks = 0,
	}
end

function Cultivation.stateOf(player: Player): State?
	return states[player]
end

-- ================================================================ os números

--: A exigência do degrau atual: o que o próximo avanço custa. É o denominador
--: da barra e o débito do avanço, e por isso mora numa função só -- três
--: lugares lendo três fórmulas é como uma barra chega a 103%.
function Cultivation.required(state: State, track: string): number
	if track == "qi" then
		return Content.stageCost(Content.qiRealms, state.qiRealm, state.qiStage)
	end
	return Content.stageCost(Content.bodyRealms, state.bodyRealm, state.bodyStage)
end

--: Quantos degraus já foram subidos num caminho. Um degrau, não um realm: é
--: a unidade em que o custo cresce, então tem de ser a unidade em que o ganho
--: cresce também.
local function stagesOf(state: State, track: string): number
	if track == "qi" then
		return (state.qiRealm - 1) * Content.stagesPerRealm + state.qiStage
	end
	return (state.bodyRealm - 1) * Content.stagesPerRealm + state.bodyStage
end

--: O multiplicador das pílulas ativas para uma trilha. Multiplicativo entre
--: si de propósito: duas pílulas caras ao mesmo tempo é a jogada que o
--: jogador descobre sozinho, e descobrir uma jogada vale mais que ler uma.
function Cultivation.pillMultiplier(state: State, track: string): number
	local now = os.time()
	local total = 1.0
	for id, expiry in state.buffs do
		if expiry > now then
			local pill = Content.pill(id)
			if pill ~= nil and (pill.track == track or pill.track == "ambos") then
				total *= pill.mult
			end
		end
	end
	return total
end

--[[
	O que a zona rende para este cultivador.

	Abaixo do rank a zona não rende nada extra -- e essa é a porta. Uma parede
	física que recusa a entrada ensina a mesma regra e custa um jogador
	empacado numa borda invisível sem entender por quê; um lugar em que se
	pode entrar e no qual o Qi simplesmente não responde ensina a regra
	andando, e deixa o discípulo externo ver o Pico de perto -- que é
	exatamente a propaganda que faz ele voltar.
]]
function Cultivation.zoneMultiplier(state: State): number
	local zone = Content.zone(state.zone)
	if zone == nil then
		return 1.0
	end
	if state.qiRealm < zone.rank then
		return 1.0
	end
	return zone.mult
end

--[[
	O que os manuais lidos rendem, para sempre.

	Cumulativo e não "o melhor conta": uma coleção que só usa o topo
	transforma tudo abaixo dele em lixo no instante em que o topo cai, e o
	jogador para de comemorar um Grau Terrestre porque já tem um Celestial.
	Cumulativo, cada página nova soma -- que é o comportamento que faz alguém
	voltar ao bosque depois de já ter o melhor manual do jogo.

	Um manual conta uma vez por cópia lida, e a contagem mora no estado: uma
	segunda cópia do mesmo manual soma a metade, para que o oitavo Lobo das
	Neblinas ainda pague alguma coisa sem que farmar o mais fácil vire a
	estratégia dominante.
]]
function Cultivation.manualMultiplier(state: State, track: string): number
	local total = 1.0
	for id, copies in state.manuals do
		local manual = Content.manual(id)
		if manual == nil or copies <= 0 then
			continue
		end
		if manual.track ~= track and manual.track ~= "ambos" then
			continue
		end
		--: A primeira cópia inteira, as seguintes pela metade e com retorno
		--: decrescente. Sem o teto, farmar a besta mais fraca por uma noite
		--: passa por cima de toda a escada de raridade.
		local gain = (manual.mult - 1)
		total *= 1 + gain * (1 + math.min(copies - 1, 20) * 0.5)
	end
	return total
end

--[[
	O que as técnicas equipadas multiplicam.

	`field` é um dos de `Content.techniqueEffects`. Multiplicativo entre os
	quatro slots, como tudo o mais neste jogo -- e é a peça que faltava: até
	agora equipar uma técnica gastava pedras, acendia um losango e não mexia em
	número nenhum. Os campos `poder`, `velocidade`, `qiMult` e `saudeMult`
	estavam na tabela desde o primeiro dia sem um único leitor.

	Só conta o que está **equipado**, não o que foi comprado. Os quatro slots
	são a decisão que a compra abre; sem isso, comprar tudo seria a única
	jogada e os losangos seriam enfeite.
]]
function Cultivation.techniqueMultiplier(state: State, field: string): number
	local total = 1.0
	for slot = 1, Content.techniqueSlots do
		local id = state.techniques[slot]
		if id == nil or id == "" then
			continue
		end
		local technique = techniqueById(id)
		if technique ~= nil and technique[field] ~= nil then
			total *= technique[field]
		end
	end
	return total
end

--: O que o HUD chama de *Multiplicador*: quem você é, o que tomou, onde está
--: sentado, o que já leu e o que está equipado.
function Cultivation.multiplier(state: State, track: string): number
	local identity = if track == "qi"
		then byId(Content.roots, state.root).mult
		else byId(Content.constitutions, state.constitution).mult
	local technique = if track == "qi"
		then Cultivation.techniqueMultiplier(state, "qiMult")
		else 1.0
	return identity
		* Cultivation.pillMultiplier(state, track)
		* Cultivation.zoneMultiplier(state)
		* Cultivation.manualMultiplier(state, track)
		* technique
end

--: Quantos degraus um caminho já subiu. O golpe do cultivador sai daqui, e
--: `Hunt` lê a mesma função -- duas contagens de degrau seriam duas ideias
--: diferentes de quão forte alguém está.
function Cultivation.stages(state: State, track: string): number
	if track == "qi" then
		return (state.qiRealm - 1) * Content.stagesPerRealm + state.qiStage
	end
	return (state.bodyRealm - 1) * Content.stagesPerRealm + state.bodyStage
end

--: O dano de um golpe. Pesa mais o corpo, porque é o caminho que não tem
--: outro uso: quem só meditou tem Qi enorme e apanha do primeiro javali, o
--: que é exatamente a lição que faz as duas barras existirem.
function Cultivation.strike(state: State): number
	return Content.strike(
		Cultivation.stages(state, "corpo"),
		Cultivation.stages(state, "qi"),
		Cultivation.manualMultiplier(state, "corpo"))
		* Cultivation.techniqueMultiplier(state, "poder")
end

--[[
	Quanto entra por tick. A curva inteira está descrita em `Content`.

	Aqui só há a montagem: exponencial no próprio caminho, exponencial menor no
	outro, e o acumulado dos realms alcançados. Nenhum número neste corpo --
	todos vêm de `Content`, porque um valor de balanceamento escrito num
	sistema é um valor que ninguém encontra quando quer mudar.
]]
function Cultivation.perTick(state: State, track: string): number
	local base = if track == "qi" then Content.baseQiPerTick else Content.baseBodyPerTick
	local other = if track == "qi" then "corpo" else "qi"
	local ladder = if track == "qi" then Content.qiRealms else Content.bodyRealms
	local realm = if track == "qi" then state.qiRealm else state.bodyRealm

	return base
		* Cultivation.multiplier(state, track)
		* Content.yieldPerStage ^ (stagesOf(state, track) - 1)
		* Content.crossYieldPerStage ^ (stagesOf(state, other) - 1)
		* Content.realmYield(ladder, realm)
end

--: Se dá para romper agora. Uma comparação, num lugar só: o cliente acende o
--: botão a partir dela e o servidor aceita o avanço a partir dela, e as duas
--: não podem discordar.
function Cultivation.canBreak(state: State, track: string): boolean
	local pool = if track == "qi" then state.qi else state.body
	return pool >= Cultivation.required(state, track) - 1e-6
end

--: Quantos avanços já estão pagos dentro da poça. É o número que diz ao
--: jogador que valeu a pena ter saído do jogo, e sem ele o acúmulo fica
--: invisível assim que a barra passa de cem por cento.
function Cultivation.banked(state: State, track: string): number
	local pool = if track == "qi" then state.qi else state.body
	local need = Cultivation.required(state, track)
	if need <= 0 then
		return 0
	end
	return math.floor(pool / need)
end

-- ============================================================= o rompimento

--[[
	A chance do avanço.

	Estágio comum nunca falha: cobrar risco nove vezes por realm transforma o
	jogo numa moeda. Só a passagem de realm -- do décimo estágio para o
	seguinte -- é apostada, uma vez a cada dez avanços, que é raro o bastante
	para ser um evento e frequente o bastante para a pílula ter comprador.
]]
function Cultivation.chance(state: State, track: string): number
	local stage = if track == "qi" then state.qiStage else state.bodyStage
	if stage < Content.stagesPerRealm then
		return 1.0
	end
	local identity = if track == "qi"
		then byId(Content.roots, state.root).tier
		else byId(Content.constitutions, state.constitution).tier
	local insight = if track == "qi" then state.qiInsight else state.bodyInsight
	local pills = Cultivation.pillMultiplier(state, track)
	local base = 0.42
		+ identity * 0.045
		+ insight * 0.10
		--: A pílula ajuda a romper, mas com retorno decrescente: uma pílula de
		--: 5.5x que garantisse o avanço tornaria o risco comprável, e risco
		--: comprável não é risco.
		+ math.min(0.18, (pills - 1) * 0.06)
	return math.clamp(base, 0.05, 0.95)
end

--: O que um avanço paga em pedras. Cresce com o realm porque os preços das
--: pílulas são fixos: sem isso a economia inteira congela no realm quatro.
local function payout(realmIndex: number, stage: number): number
	return math.floor(6 * realmIndex * (1 + stage * 0.35))
end

local function ladderFor(track: string): { any }
	return if track == "qi" then Content.qiRealms else Content.bodyRealms
end

--[[
	Rompe, ou não.

	Devolve um relatório -- o cliente precisa saber se falhou, quanto sobrou e
	para onde subiu, e inferir isso de um `StateSync` que chegou depois é como
	se perde o momento que faz alguém tentar de novo.
]]
function Cultivation.breakthrough(state: State, subject: string,
                                   track: string): { [string]: any }
	if track ~= "qi" and track ~= "corpo" then
		return { ok = false, reason = "caminho desconhecido" }
	end
	if not Cultivation.canBreak(state, track) then
		return { ok = false, reason = "ainda falta Qi para este degrau" }
	end

	local ladder = ladderFor(track)
	local realmIndex = if track == "qi" then state.qiRealm else state.bodyRealm
	local stage = if track == "qi" then state.qiStage else state.bodyStage
	local isRealmBreak = stage >= Content.stagesPerRealm
	local chance = Cultivation.chance(state, track)
	local won = not isRealmBreak or stream:number() <= chance

	local need = Cultivation.required(state, track)

	if not won then
		--[[
			A falha custa **metade da exigência**, não metade da poça.

			Metade da poça punia justamente quem tinha acumulado: um jogador
			que voltasse com cinco avanços guardados perdia dois e meio numa
			rolagem, e a lição disso é "não acumule" -- o oposto do jogo. Meia
			exigência dói e não apaga o que a paciência juntou.

			A percepção soma, então uma sequência ruim tem fim, que é a
			diferença entre tensão e castigo.
		]]
		if track == "qi" then
			state.qi = math.max(0, state.qi - need * 0.5)
			state.qiInsight += 1
		else
			state.body = math.max(0, state.body - need * 0.5)
			state.bodyInsight += 1
		end
		Telemetry.event("daocultivo.avanco", {
			track = track, realm = realmIndex, stage = stage, ok = false,
		})
		return {
			ok = false, failed = true, track = track, chance = chance,
			insight = if track == "qi" then state.qiInsight else state.bodyInsight,
			reason = "a tribulação te rejeitou",
		}
	end

	--: Debita a exigência e deixa o resto na poça. O excedente é o que faz
	--: "voltei depois de uma hora" render uma sequência de avanços em vez de
	--: um só.
	local nextRealm, nextStage = realmIndex, stage + 1
	if isRealmBreak then
		nextRealm = math.min(realmIndex + 1, #ladder)
		nextStage = 1
	end

	local gained = payout(realmIndex, stage)
	if track == "qi" then
		state.qi = math.max(0, state.qi - need)
		state.qiRealm, state.qiStage = nextRealm, nextStage
		if isRealmBreak then
			state.qiInsight = 0
		end
	else
		state.body = math.max(0, state.body - need)
		state.bodyRealm, state.bodyStage = nextRealm, nextStage
		if isRealmBreak then
			state.bodyInsight = 0
		end
	end
	state.pedras += gained
	state.breaks += 1
	if isRealmBreak then
		state.meritos += realmIndex * 5
	end

	--: O funil sabe que este jogador chegou ao segundo degrau. Na roleta o
	--: degrau é o tier 4; aqui é o segundo realm, e é o mesmo evento: a
	--: primeira vez que o jogo devolveu algo grande.
	if isRealmBreak and nextRealm == 2 then
		wheel("raiz"):reachedTierTwo(subject)
	end

	Telemetry.event("daocultivo.avanco", {
		track = track, realm = nextRealm, stage = nextStage, ok = true,
	})

	return {
		ok = true, track = track,
		realm = nextRealm, stage = nextStage,
		realmBreak = isRealmBreak,
		title = Content.realmTitle(ladder, nextRealm, nextStage),
		pedras = gained,
		note = ladder[nextRealm] and ladder[nextRealm].note or nil,
	}
end

-- ================================================================= a roleta

function Cultivation.spin(state: State, subject: string, kind: string): { [string]: any }
	if kind ~= "raiz" and kind ~= "constituicao" then
		return { ok = false, reason = "roleta desconhecida" }
	end
	local locked = if kind == "raiz" then state.rootLocked else state.constitutionLocked
	if locked then
		return { ok = false, reason = "está selada; quebre o selo primeiro" }
	end

	local loop = wheel(kind)
	local price = Content.spins[kind].cost
	local free = loop:isFree(subject)
	if not free and state.pedras < price then
		return { ok = false, reason = string.format("faltam %d pedras", price - state.pedras) }
	end
	if not free then
		state.pedras -= price
	end

	local drop = loop:open(subject, roll)
	state.spins += 1

	local list = if kind == "raiz" then Content.roots else Content.constitutions
	local entry = byId(list, drop.id)
	local previous = if kind == "raiz" then state.root else state.constitution
	if kind == "raiz" then
		state.root = drop.id
	else
		state.constitution = drop.id
	end

	return {
		ok = true, kind = kind, id = drop.id, name = entry.name,
		tier = entry.tier, mult = entry.mult, note = entry.note,
		previous = previous, free = free,
	}
end

function Cultivation.lock(state: State, kind: string, on: boolean): { [string]: any }
	if kind ~= "raiz" and kind ~= "constituicao" then
		return { ok = false, reason = "selo desconhecido" }
	end
	if not on then
		--: Quebrar o selo é de graça. Cobrar dos dois lados faria o jogador
		--: evitar selar, que é o oposto do que o selo existe para provocar.
		if kind == "raiz" then
			state.rootLocked = false
		else
			state.constitutionLocked = false
		end
		return { ok = true, kind = kind, on = false }
	end
	local price = Content.locks[kind].cost
	if state.pedras < price then
		return { ok = false, reason = string.format("faltam %d pedras", price - state.pedras) }
	end
	state.pedras -= price
	if kind == "raiz" then
		state.rootLocked = true
	else
		state.constitutionLocked = true
	end
	return { ok = true, kind = kind, on = true }
end

-- ================================================================ as pílulas

function Cultivation.consume(state: State, subject: string,
                              pillId: string): { [string]: any }
	local pill = Content.pill(pillId)
	if pill == nil then
		return { ok = false, reason = "essa pílula não existe" }
	end
	if state.pedras < pill.cost then
		return { ok = false, reason = string.format("faltam %d pedras", pill.cost - state.pedras) }
	end
	state.pedras -= pill.cost
	--: Empilha o tempo em vez de reiniciar. Um jogador que toma a segunda
	--: pílula faltando dez segundos e perde os dez aprende a esperar olhando
	--: o relógio, e olhar relógio não é jogar.
	local now = os.time()
	local from = math.max(state.buffs[pillId] or now, now)
	state.buffs[pillId] = from + pill.seconds
	wheel("raiz"):kept(subject)
	return { ok = true, pill = pillId, name = pill.name, expiry = state.buffs[pillId] }
end

-- ================================================================ os manuais

--[[
	Ler um manual: permanente, imediato e sem custo.

	Sem custo porque o preço já foi pago no bosque. Cobrar de novo para "abrir"
	o que caiu de uma besta é a mecânica que ensina o jogador a não caçar.
]]
function Cultivation.learn(state: State, manualId: string): { [string]: any }
	local manual = Content.manual(manualId)
	if manual == nil then
		return { ok = false, reason = "esse manual não existe" }
	end
	local copies = (state.manuals[manualId] or 0) + 1
	state.manuals[manualId] = copies
	return {
		ok = true, id = manualId, name = manual.name,
		grade = manual.grade, tier = manual.tier,
		track = manual.track, mult = manual.mult,
		copies = copies, note = manual.note,
	}
end

-- ==================================================================== a loja

--[[
	Comprar e usar um item, que é a mesma operação.

	Um inventário entre a compra e o uso seria uma tela a mais para atravessar
	e nenhuma decisão nova: um ginseng guardado não faz nada que um ginseng
	comprado na hora não faça. Se algum dia houver troca entre jogadores, aí
	sim existe uma razão para ele existir.
]]
function Cultivation.buy(state: State, itemId: string): { [string]: any }
	local item = Content.item(itemId)
	if item == nil then
		return { ok = false, reason = "esse item não existe na loja" }
	end
	if state.pedras < item.cost then
		return { ok = false, reason = string.format("faltam %d pedras",
			item.cost - state.pedras) }
	end
	state.pedras -= item.cost

	if item.kind == "instante" then
		--: Em múltiplos da **exigência do degrau atual**, e não num valor
		--: absoluto. Um ginseng que dá "5000 de Qi" é um item que resolve o
		--: primeiro realm e não significa nada no quinto; em múltiplos ele
		--: continua valendo três degraus a vida inteira do save.
		local track = item.track
		local gained = Cultivation.required(state, track) * item.amount
		if track == "qi" then
			state.qi += gained
		else
			state.body += gained
		end
		return { ok = true, id = itemId, name = item.name, kind = item.kind,
			track = track, gained = gained, note = item.note }
	end

	if item.kind == "purificar" then
		if state.kills <= 0 then
			--: Devolve a pedra. Vender absolvição a quem não pecou é o tipo de
			--: compra que o jogador só descobre que foi inútil depois.
			state.pedras += item.cost
			return { ok = false, reason = "suas mãos já estão limpas" }
		end
		state.kills = math.max(0, state.kills - item.amount)
		return { ok = true, id = itemId, name = item.name, kind = item.kind,
			kills = state.kills, note = item.note }
	end

	if item.kind == "percep" then
		if item.track == "qi" or item.track == "ambos" then
			state.qiInsight += item.amount
		end
		if item.track == "corpo" or item.track == "ambos" then
			state.bodyInsight += item.amount
		end
		return { ok = true, id = itemId, name = item.name, kind = item.kind,
			note = item.note }
	end

	return { ok = false, reason = "esse item não sabe o que fazer" }
end

-- =============================================================== as técnicas

function Cultivation.equip(state: State, subject: string, slot: number,
                            techniqueId: string): { [string]: any }
	if slot < 1 or slot > Content.techniqueSlots or slot % 1 ~= 0 then
		return { ok = false, reason = "slot inválido" }
	end
	if techniqueId == "" then
		state.techniques[slot] = nil
		return { ok = true, slot = slot }
	end
	local technique = techniqueById(techniqueId)
	if technique == nil then
		return { ok = false, reason = "essa técnica não existe" }
	end
	if state.qiRealm < technique.realm then
		return { ok = false, reason = string.format("exige %s",
			Content.qiRealms[technique.realm].name) }
	end
	--: Comprada uma vez, equipável para sempre. O custo é do aprendizado, não
	--: de trocar de slot -- cobrar a troca faz o jogador nunca experimentar.
	if state.owned[techniqueId] ~= true then
		if state.pedras < technique.cost then
			return { ok = false, reason = string.format("faltam %d pedras",
				technique.cost - state.pedras) }
		end
		state.pedras -= technique.cost
		state.owned[techniqueId] = true
	end
	state.techniques[slot] = techniqueId
	wheel("raiz"):kept(subject)
	return { ok = true, slot = slot, technique = techniqueId, name = technique.name }
end

-- ==================================================================== o voo

function Cultivation.fly(state: State, on: boolean): { [string]: any }
	if on and state.qiRealm < Content.flightRealm then
		return { ok = false, reason = string.format("voar exige %s",
			Content.qiRealms[Content.flightRealm].name) }
	end
	--: Voar e cultivar não se acumulam. Um cultivador sentado no ar ganhando
	--: Qi é uma postura que o jogo não tem, e sair voando de um assento deixa
	--: o `Seat` órfão com alguém preso nele.
	if on then
		state.action = "nenhum"
		state.sprinting = false
	end
	state.flying = on
	return {
		ok = true, on = on,
		speed = Content.flySpeed(state.qiRealm),
		ceiling = Content.flyCeiling(state.qiRealm),
	}
end

--[[
	Correr.

	Não custa Qi e não tem barra. Um recurso a mais para vigiar numa tela que
	já tem duas poças, sete terraços e uma bolsa é um recurso que o jogador
	ignora -- e correr é locomoção, não uma decisão. O que a torna interessante
	é que a velocidade base **vem do caminho do corpo**: quem treinou corre
	mais rápido do que quem não treinou, sem uma segunda escada para manter.
]]
function Cultivation.sprint(state: State, on: boolean): { [string]: any }
	--: Ninguém corre sentado nem meditando. Sem isto, apertar Shift durante a
	--: meditação devolveria velocidade a um personagem preso num assento.
	if on and (state.action ~= "nenhum" or state.flying) then
		return { ok = false, reason = "não dá para correr agora" }
	end
	state.sprinting = on
	return { ok = true, on = on }
end

-- ==================================================================== o laço

--: Um segundo de cultivo. `dt` em segundos reais, escalado pelo tick, para
--: que mudar `Content.tickSeconds` mude a cadência da tela e não o
--: balanceamento.
function Cultivation.tick(state: State, dt: number)
	--: Sem `math.min`. O Qi entra enquanto a ação durar, e passar da exigência
	--: do degrau é o objetivo -- não um estouro a ser aparado.
	local scale = dt / Content.tickSeconds
	if state.action == "cultivar" then
		state.qi += Cultivation.perTick(state, "qi") * scale
	elseif state.action == "treinar" then
		state.body += Cultivation.perTick(state, "corpo") * scale
	end
end

--: O toque manual, que é o "Toque - Impulso" da tela. Uma fração do tick, de
--: modo que martelar rende mais do que esperar sem substituir a pílula: um
--: toque que rende demais transforma um jogo de paciência num jogo de dedo, e
--: ninguém volta no dia seguinte para um jogo de dedo.
function Cultivation.tap(state: State, track: string): number
	local wanted = if track == "qi" then "cultivar" else "treinar"
	if state.action ~= wanted then
		return 0
	end
	local gain = Cultivation.perTick(state, track) * Content.tapGain
	if track == "qi" then
		state.qi += gain
	else
		state.body += gain
	end
	return gain
end

-- ============================================================== a publicação

--[[
	O estado, empacotado para a tela.

	Números já resolvidos, não ingredientes. Se o cliente calculasse o teto ou
	o multiplicador, a tela e o servidor teriam duas fórmulas para a mesma
	coisa e uma delas ficaria para trás na primeira mudança de balanceamento.
]]
function Cultivation.pack(state: State): { [string]: any }
	local now = os.time()
	local buffs = {}
	for id, expiry in state.buffs do
		if expiry > now then
			local pill = Content.pill(id)
			table.insert(buffs, {
				id = id,
				name = pill and pill.name or id,
				remaining = expiry - now,
				track = pill and pill.track or "ambos",
			})
		end
	end

	local root = byId(Content.roots, state.root)
	local const = byId(Content.constitutions, state.constitution)
	local zone = Content.zone(state.zone)

	local techniques = {}
	for slot = 1, Content.techniqueSlots do
		local id = state.techniques[slot]
		local technique = if id ~= nil then techniqueById(id) else nil
		techniques[slot] = {
			id = id or "",
			name = if technique ~= nil then technique.name else "Nenhum",
		}
	end

	return {
		qi = {
			pool = state.qi,
			required = Cultivation.required(state, "qi"),
			banked = Cultivation.banked(state, "qi"),
			perTick = Cultivation.perTick(state, "qi"),
			multiplier = Cultivation.multiplier(state, "qi"),
			title = Content.realmTitle(Content.qiRealms, state.qiRealm, state.qiStage),
			realm = state.qiRealm, stage = state.qiStage,
			ready = Cultivation.canBreak(state, "qi"),
			chance = Cultivation.chance(state, "qi"),
			insight = state.qiInsight,
		},
		corpo = {
			pool = state.body,
			required = Cultivation.required(state, "corpo"),
			banked = Cultivation.banked(state, "corpo"),
			perTick = Cultivation.perTick(state, "corpo"),
			multiplier = Cultivation.multiplier(state, "corpo"),
			title = Content.realmTitle(Content.bodyRealms, state.bodyRealm, state.bodyStage),
			realm = state.bodyRealm, stage = state.bodyStage,
			ready = Cultivation.canBreak(state, "corpo"),
			chance = Cultivation.chance(state, "corpo"),
			insight = state.bodyInsight,
		},
		--: Os manuais vão inteiros para a tela: nome, grau e cópias. É a
		--: coleção do jogo, e uma coleção que o jogador não consegue olhar é
		--: uma coleção que ele não persegue.
		manuals = (function()
			local list = {}
			for id, copies in state.manuals do
				local manual = Content.manual(id)
				if manual ~= nil then
					table.insert(list, {
						id = id, name = manual.name, grade = manual.grade,
						tier = manual.tier, track = manual.track,
						mult = manual.mult, copies = copies, note = manual.note,
					})
				end
			end
			table.sort(list, function(a, b)
				if a.tier == b.tier then
					return a.name < b.name
				end
				return a.tier > b.tier
			end)
			return list
		end)(),
		manualQi = Cultivation.manualMultiplier(state, "qi"),
		manualCorpo = Cultivation.manualMultiplier(state, "corpo"),
		--: Os multiplicadores das técnicas, um por efeito. A tela mostra o que
		--: os quatro slots estão de fato rendendo -- sem isso, equipar
		--: continua sendo um ato de fé.
		tecnicaQi = Cultivation.techniqueMultiplier(state, "qiMult"),
		tecnicaPoder = Cultivation.techniqueMultiplier(state, "poder"),
		tecnicaSaude = Cultivation.techniqueMultiplier(state, "saudeMult"),
		tecnicaVelocidade = Cultivation.techniqueMultiplier(state, "velocidade"),
		golpe = Cultivation.strike(state),
		root = { id = root.id, name = root.name, tier = root.tier,
			mult = root.mult, locked = state.rootLocked },
		constitution = { id = const.id, name = const.name, tier = const.tier,
			mult = const.mult, locked = state.constitutionLocked },
		pedras = state.pedras,
		meritos = state.meritos,
		buffs = buffs,
		techniques = techniques,
		action = state.action,
		flying = state.flying,
		sprinting = state.sprinting,
		canFly = state.qiRealm >= Content.flightRealm,
		flySpeed = Content.flySpeed(state.qiRealm),
		flyCeiling = Content.flyCeiling(state.qiRealm),
		zone = {
			id = state.zone,
			name = if zone ~= nil then zone.name else "—",
			rank = if zone ~= nil then zone.rank else 1,
			--: O que a zona *promete* e o que ela **está dando**. Os dois, e
			--: não só o segundo: um discípulo externo sentado no Pico precisa
			--: ver o 19x que não está recebendo, senão a zona é só um lugar
			--: bonito onde o número não mudou.
			mult = if zone ~= nil then zone.mult else 1.0,
			active = Cultivation.zoneMultiplier(state),
			allowed = zone == nil or state.qiRealm >= zone.rank,
			note = if zone ~= nil then zone.note else nil,
		},
		spins = state.spins,
		breaks = state.breaks,
		karma = {
			kills = state.kills,
			name = Content.karmaFor(state.kills).name,
			note = Content.karmaFor(state.kills).note,
			darkness = Content.karmaFor(state.kills).darkness,
		},
	}
end

--[[
	Os atributos, que são a outra metade da publicação.

	O HUD lê os números do `StateSync`, mas o nome sobre a cabeça é desenhado
	pelo **mundo**, num `BillboardGui` que todos os jogadores veem -- e o mundo
	não recebe o `StateSync` de ninguém. Um atributo no `Player` replica para
	todo mundo e sobrevive a respawn, que é exatamente o que uma placa de nome
	precisa.
]]
local function publish(player: Player, state: State)
	player:SetAttribute("tituloQi",
		Content.realmTitle(Content.qiRealms, state.qiRealm, state.qiStage))
	player:SetAttribute("tituloCorpo",
		Content.realmTitle(Content.bodyRealms, state.bodyRealm, state.bodyStage))
	player:SetAttribute("pedras", state.pedras)
	player:SetAttribute("qiRealm", state.qiRealm)
	player:SetAttribute("qiEstagio", state.qiStage)
	player:SetAttribute("corpoRealm", state.bodyRealm)
	--: O estágio, e não só o realm. É o sinal que `Body` escuta para
	--: reaplicar saúde e velocidade: um avanço dentro do mesmo realm muda o
	--: corpo tanto quanto um que troca de realm, e escutar só o realm faria
	--: nove avanços em cada dez não mudarem nada que o jogador sinta.
	player:SetAttribute("corpoEstagio", state.bodyStage)
	player:SetAttribute("raizTier", byId(Content.roots, state.root).tier)
	--: O karma é atributo e não só `StateSync` porque a aura de **todo mundo**
	--: precisa dele: quem chega perto de um cultivador do Dao Demoníaco tem de
	--: ver a aura preta sem precisar do estado dele.
	player:SetAttribute("karma", state.kills)
	player:SetAttribute("constTier", byId(Content.constitutions, state.constitution).tier)
	player:SetAttribute("voando", state.flying)
	player:SetAttribute("correndo", state.sprinting)
	player:SetAttribute("velocidadeVoo", Content.flySpeed(state.qiRealm))
	player:SetAttribute("tetoVoo", Content.flyCeiling(state.qiRealm))
	player:SetAttribute("zona", state.zone)
	--: A postura, que é o que `Pose` escuta para sentar o cultivador e o que a
	--: aura lê para se enrolar em volta dele. Atributo e não mensagem: os dois
	--: precisam saber a postura de **todo** jogador, e um `StateSync` só chega
	--: ao dono.
	player:SetAttribute("postura", state.action)
end

local function sync(player: Player)
	local state = states[player]
	if state == nil then
		return
	end
	publish(player, state)
	Net.fire(player, "StateSync", Cultivation.pack(state))
end

--[[
	Mudar de zona, dito pelo mundo e não pelo cliente.

	`Zones` observa a posição e chama isto quando alguém cruza uma borda. A
	notificação é o que faz a zona existir para o jogador: sem ela o
	multiplicador muda em silêncio e o jogador nunca liga uma coisa à outra --
	que é como um sistema inteiro passa despercebido por estar funcionando.
]]
function Cultivation.setZone(player: Player, zoneId: string): boolean
	local state = states[player]
	if state == nil or state.zone == zoneId then
		return false
	end
	local zone = Content.zone(zoneId)
	if zone == nil then
		return false
	end
	state.zone = zoneId
	local allowed = state.qiRealm >= zone.rank
	Net.fire(player, "Notify", {
		text = if allowed
			then string.format("%s  ·  x%.1f", zone.name, zone.mult)
			else string.format("%s  ·  o Qi daqui exige %s",
				zone.name, Content.qiRealms[zone.rank].name),
	})
	sync(player)
	return true
end

--[[
	Entregar um manual, que é o que uma besta morta paga.

	Vive aqui e não em `Hunt` porque o estado é daqui: um sistema de caça que
	escrevesse direto na tabela de manuais seria um segundo dono do save, e a
	primeira coisa que dois donos fazem é discordar.
]]
function Cultivation.award(player: Player, manualId: string): { [string]: any }?
	local state = states[player]
	if state == nil then
		return nil
	end
	local report = Cultivation.learn(state, manualId)
	if report.ok then
		Net.fire(player, "Learned", report)
		sync(player)
	end
	return report
end

--[[
	Registrar que este jogador matou outro cultivador.

	Vive aqui e não em `Hunt` pelo mesmo motivo dos manuais: o estado é daqui,
	e um segundo dono do save é a primeira coisa que discorda.
]]
function Cultivation.markKill(killer: Player, victim: Player)
	local state = states[killer]
	if state == nil or killer == victim then
		return
	end
	state.kills += 1
	local step = Content.karmaFor(state.kills)
	Net.fire(killer, "Notify", {
		text = string.format("%s morreu pela sua mão — %s", victim.DisplayName, step.name),
	})
	Net.fire(victim, "Notify", {
		text = string.format("%s te matou.", killer.DisplayName),
	})
	Telemetry.event("daocultivo.pk", { kills = state.kills })
	sync(killer)
end

--: Dar pedras de fora do laço: é assim que as veias espirituais e as bestas
--: pagam, e é o único caminho pelo qual pedra entra sem um avanço.
function Cultivation.grant(player: Player, pedras: number, why: string?)
	local state = states[player]
	if state == nil then
		return
	end
	state.pedras += pedras
	wheel("raiz"):kept(tostring(player.UserId))
	Net.fire(player, "Notify", {
		text = string.format("+%d pedras espirituais%s", pedras,
			if why ~= nil then " — " .. why else ""),
	})
	sync(player)
end

-- =========================================================== a persistência

local SAVE_FIELDS = {
	"qiRealm", "qiStage", "qi", "qiInsight",
	"bodyRealm", "bodyStage", "body", "bodyInsight",
	"root", "rootLocked", "constitution", "constitutionLocked",
	"pedras", "meritos", "spins", "breaks", "kills",
}

--: O que vai para o DataStore. Explícito, e não `state` inteiro: `buffs` é um
--: relógio de parede que não sobrevive a um logout, e gravar `action` faz o
--: jogador voltar sentado numa sessão em que ele nunca sentou.
function Cultivation.template(): { [string]: any }
	local fresh = Cultivation.newState()
	local out = {}
	for _, field in SAVE_FIELDS do
		out[field] = (fresh :: any)[field]
	end
	--: Técnicas viram uma lista por slot; um dicionário com buracos não
	--: sobrevive a uma ida e volta por JSON.
	out.techniques = {}
	out.owned = {}
	out.manuals = {}
	return out
end

--[[
	O estado, virado tabela de save -- e de volta.

	Estas duas são **puras**: recebem um `State` e uma tabela, e não tocam num
	`Player`. É a única forma de um cenário exercitar a persistência, e a
	persistência é o lugar onde um defeito não dá erro nenhum: um campo que
	existe no estado e não na lista simplesmente não volta, e o jogador perde
	exatamente o que mais custou.

	Em Studio sem "Enable Studio Access to API Services" o `DataStore` não
	existe e o `Save` entra em modo memória -- o que significa que **nada disso
	é exercitado numa sessão de teste**. Por isso as duas são públicas e há um
	cenário que faz a ida e a volta numa tabela comum: prova a metade que é
	nossa, sem depender da metade que é configuração do Studio.
]]
function Cultivation.save(state: State): { [string]: any }
	local profile = {}
	for _, field in SAVE_FIELDS do
		profile[field] = (state :: any)[field]
	end
	--: Técnicas viram lista por slot; um dicionário com buracos não sobrevive
	--: a uma ida e volta por JSON.
	local list = {}
	for slot = 1, Content.techniqueSlots do
		list[slot] = state.techniques[slot] or ""
	end
	profile.techniques = list
	profile.owned = table.clone(state.owned)
	profile.manuals = table.clone(state.manuals)
	return profile
end

function Cultivation.load(state: State, profile: any)
	if type(profile) ~= "table" then
		return
	end
	for _, field in SAVE_FIELDS do
		local value = profile[field]
		if value ~= nil then
			(state :: any)[field] = value
		end
	end
	if type(profile.manuals) == "table" then
		for id, copies in profile.manuals do
			local count = tonumber(copies)
			if count ~= nil and count > 0 then
				state.manuals[tostring(id)] = count
			end
		end
	end
	if type(profile.owned) == "table" then
		for id, has in profile.owned do
			if has == true then
				state.owned[tostring(id)] = true
			end
		end
	end
	if type(profile.techniques) == "table" then
		for slot = 1, Content.techniqueSlots do
			local id = profile.techniques[slot] or profile.techniques[tostring(slot)]
			if type(id) == "string" and id ~= "" then
				state.techniques[slot] = id
			end
		end
	end
end

--: O invólucro com `Player`. Três linhas, e nenhuma regra dentro: a regra
--: está em `Cultivation.save`, onde um cenário alcança.
local function persist(player: Player)
	local state = states[player]
	local profile = Save.get(player)
	if state == nil or type(profile) ~= "table" then
		return
	end
	for key, value in Cultivation.save(state) do
		profile[key] = value
	end
end

-- ================================================================= a partida

--[[
	A chegada, e a corrida que ela esconde.

	`welcome` **tem** de rodar com o perfil já carregado. Chamado antes, ele
	monta um cultivador zerado, e a gravação periódica quarenta e cinco
	segundos depois escreve esse zero por cima do save de verdade. Ninguém vê
	erro nenhum: o jogador simplesmente perde tudo e não tem como provar.

	Por isso a porta normal é `Save.observe`, que liga **e** repassa quem já
	carregou -- e a porta de emergência é o laço em `start`, para o caso em que
	o DataStore não responde. Em Studio sem serviços de API ligados esse é o
	caso *comum*, não a exceção, e um jogo que só abre com persistência viva é
	um jogo que não abre na máquina de quem o escreve.
]]
local function welcome(player: Player, profile: any?)
	if states[player] ~= nil then
		return
	end
	local state = Cultivation.newState()
	states[player] = state
	Cultivation.load(state, profile or Save.get(player))
	Telemetry.seen(tostring(player.UserId))
	sync(player)
	Net.fire(player, "Notify", {
		text = "Você acorda ao pé da montanha. O primeiro despertar é de graça.",
	})
end

--: O invólucro que todo handler usa: pega o estado, roda a regra, publica.
--: Três linhas em cada `Net.on` e nenhuma regra dentro deles, porque regra
--: dentro de handler é regra que nenhum cenário alcança.
local function withState(player: Player, fn: (State) -> ())
	local state = states[player]
	if state == nil then
		return
	end
	fn(state)
	persist(player)
	sync(player)
end

function Cultivation.start()
	local function subjectOf(player: Player): string
		return tostring(player.UserId)
	end

	Net.on("SetAction", function(player: Player, payload: any)
		withState(player, function(state)
			--: Validado contra `Content.stances`, não contra a barra de ações:
			--: a barra tem botões que são efeitos instantâneos, e aceitá-los
			--: como postura deixa um cliente modificado parar o cultivo -- ou
			--: sentar-se num estado em que nada entra.
			local action = tostring(payload.action)
			local known = false
			for _, stance in Content.stances do
				if stance == action then
					known = true
				end
			end
			if known then
				state.action = action
			end
		end)
	end)

	Net.on("Tap", function(player: Player, payload: any)
		local state = states[player]
		if state ~= nil then
			Cultivation.tap(state, tostring(payload.track))
		end
	end)

	--: Carregado por `require` e não por parâmetro: `Ascension` é enfeite, e um
	--: enfeite que o laço principal precise receber para funcionar deixa de ser
	--: enfeite.
	local Ascension = require(script.Parent:WaitForChild("Ascension"))

	Net.on("Breakthrough", function(player: Player, payload: any)
		withState(player, function(state)
			local report = Cultivation.breakthrough(state, subjectOf(player),
				tostring(payload.track))
			Net.fire(player, "Broke", report)
			--: O mundo só vê o avanço que deu certo. Uma tribulação falhada
			--: já tem o próprio cartão, e um clarão de vitória para uma
			--: derrota é a pior mensagem possível.
			if report.ok then
				local fine, err = pcall(Ascension.burst, player, report)
				if not fine then
					Debug.error("o avanço não estourou: " .. tostring(err))
				end
			end
		end)
	end)

	Net.on("Spin", function(player: Player, payload: any)
		withState(player, function(state)
			local report = Cultivation.spin(state, subjectOf(player),
				tostring(payload.kind))
			Net.fire(player, "Spun", report)
		end)
	end)

	Net.on("Lock", function(player: Player, payload: any)
		withState(player, function(state)
			local report = Cultivation.lock(state, tostring(payload.kind),
				payload.on == true)
			if not report.ok and report.reason ~= nil then
				Net.fire(player, "Notify", { text = tostring(report.reason) })
			end
		end)
	end)

	Net.on("Consume", function(player: Player, payload: any)
		withState(player, function(state)
			local report = Cultivation.consume(state, subjectOf(player),
				tostring(payload.pill))
			Net.fire(player, "Notify", {
				text = if report.ok
					then string.format("%s — o efeito começou", tostring(report.name))
					else tostring(report.reason),
			})
		end)
	end)

	Net.on("Equip", function(player: Player, payload: any)
		withState(player, function(state)
			local report = Cultivation.equip(state, subjectOf(player),
				math.floor(payload.slot), tostring(payload.technique))
			if not report.ok then
				Net.fire(player, "Notify", { text = tostring(report.reason) })
			end
		end)
	end)

	Net.on("Buy", function(player: Player, payload: any)
		withState(player, function(state)
			local report = Cultivation.buy(state, tostring(payload.item))
			Net.fire(player, "Notify", {
				text = if report.ok
					then string.format("%s — usado", tostring(report.name))
					else tostring(report.reason),
			})
		end)
	end)

	Net.on("Sprint", function(player: Player, payload: any)
		withState(player, function(state)
			Cultivation.sprint(state, payload.on == true)
		end)
	end)

	Net.on("Fly", function(player: Player, payload: any)
		withState(player, function(state)
			local report = Cultivation.fly(state, payload.on == true)
			if not report.ok then
				Net.fire(player, "Notify", { text = tostring(report.reason) })
			end
		end)
	end)

	--: A porta normal. `Save.observe` liga e repassa: um `onLoaded:Connect`
	--: simples perderia o jogador local do Studio, que entra antes deste
	--: sistema existir e é o único jogador da sessão em que o jogo é testado.
	Save.observe(function(player: Player, profile: any)
		welcome(player, profile)
	end)

	--: A porta de emergência. Sem serviços de API ligados o `Save` entra em
	--: modo degradado e pode nunca anunciar um perfil; sem isto o jogo abre,
	--: o HUD desenha zeros e nada responde. Oito segundos é depois de qualquer
	--: carga honesta e antes de qualquer paciência.
	task.spawn(function()
		local waiting: { [Player]: number } = {}
		while true do
			task.wait(2)
			for _, player in Players:GetPlayers() do
				if states[player] ~= nil then
					continue
				end
				local since = waiting[player]
				if since == nil then
					waiting[player] = os.clock()
				elseif os.clock() - since > 8 then
					Debug.error(string.format(
						"perfil de %s não chegou em %.0fs; começando sem save",
						player.Name, os.clock() - since))
					welcome(player, nil)
				end
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		persist(player)
		states[player] = nil
	end)

	--: O relógio. Um só, para todos os jogadores: um `task.spawn` por jogador
	--: é o mesmo trabalho dividido em N agendamentos que o Roblox tem de
	--: acordar separados.
	task.spawn(function()
		local last = os.clock()
		while true do
			task.wait(Content.tickSeconds)
			local now = os.clock()
			local dt = now - last
			last = now
			for player, state in states do
				Cultivation.tick(state, dt)
				publish(player, state)
				Net.fire(player, "StateSync", Cultivation.pack(state))
			end
		end
	end)

	--: A gravação periódica. Sem ela, um servidor que cai leva junto tudo o
	--: que aconteceu desde o último avanço -- e o avanço é raro por
	--: construção, então "desde o último" pode ser a sessão inteira.
	task.spawn(function()
		while true do
			task.wait(45)
			for player in states do
				persist(player)
				Save.write(player)
			end
		end
	end)

	--: O que está indo mal para *este* jogador, agora. Mandado à tela em vez
	--: de guardado num relatório: fechar o buraco na sessão em que ele abriu
	--: vale mais do que encontrá-lo num gráfico no mês seguinte.
	task.spawn(function()
		while true do
			task.wait(10)
			for player in states do
				Net.fire(player, "Findings", {
					findings = wheel("raiz"):check(tostring(player.UserId)),
				})
			end
		end
	end)

	Debug.probe("cultivo", function()
		local out = {}
		for player, state in states do
			out[player.Name] = {
				qi = state.qi,
				qiExigencia = Cultivation.required(state, "qi"),
				qiGuardados = Cultivation.banked(state, "qi"),
				qiTitulo = Content.realmTitle(Content.qiRealms, state.qiRealm, state.qiStage),
				corpoTitulo = Content.realmTitle(Content.bodyRealms, state.bodyRealm, state.bodyStage),
				raiz = state.root,
				pedras = state.pedras,
				acao = state.action,
				porTick = Cultivation.perTick(state, "qi"),
				--: Os manuais na sonda, porque são a única recompensa do jogo
				--: que não aparece em nenhum atributo -- e portanto a única
				--: que um teste externo não conseguia ver cair.
				manuais = (function()
					local out = {}
					for id, copies in state.manuals do
						out[id] = copies
					end
					return out
				end)(),
				multManualQi = Cultivation.manualMultiplier(state, "qi"),
			}
		end
		return out
	end)

	Debug.info(string.format("cultivo: %d degraus de Qi, %d de corpo",
		#Content.qiRealms * Content.stagesPerRealm,
		#Content.bodyRealms * Content.stagesPerRealm))
end

return Cultivation
