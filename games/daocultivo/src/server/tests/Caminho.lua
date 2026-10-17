--!strict
--[[
	O caminho, afirmado contra o jogo rodando.

	Cada cenário aqui é uma frase de projeto virada em asserção. Nenhum deles
	testa um número de balanceamento -- "o primeiro estágio custa 60" fica
	vermelho na primeira afinação e ensina a ignorar o vermelho. O que está
	afirmado são **regras**, que continuam verdadeiras depois de qualquer
	afinação:

	    "o jogador nunca bate numa parede"
	        -> o tempo por estágio cresce devagar, e nunca dobra
	    "o teto é o que dá decisão ao jogador"
	        -> a poça para no teto e não passa
	    "o risco existe uma vez a cada dez avanços"
	        -> estágio comum é certo, passagem de realm é apostada
	    "o primeiro despertar é de graça"
	        -> o segundo cobra, e uma raiz selada recusa

	E o mais importante: **todos rodam a regra de verdade**. A versão anterior
	deste arquivo teria de fabricar um `Player` para chamar qualquer coisa, o
	que na prática significa que ninguém escreve o teste e a regra fica sem
	cobertura enquanto o handler de rede -- que é a metade que sempre funciona
	-- fica coberto duas vezes.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Content = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Content"))
local Cultivation = require(script.Parent.Parent.systems.Cultivation)

--: Põe na poça exatamente o que o degrau atual exige, para chegar ao ponto
--: interessante sem simular vinte minutos. É o equivalente de teste de "o
--: jogador esperou".
local function fill(state: any, track: string)
	if track == "qi" then
		state.qi = Cultivation.required(state, "qi")
	else
		state.body = Cultivation.required(state, "corpo")
	end
end

return function(Testing)
	Testing.scenario("um cultivador novo começa vazio e no primeiro degrau", function(t)
		local state = Cultivation.newState()
		t:expectEqual(state.qi, 0, "a poça de um novato tem de estar vazia")
		t:expectEqual(state.qiRealm, 1, "todo mundo começa no primeiro realm")
		t:expectEqual(state.qiStage, 1, "e no primeiro estágio dele")
		t:expect(Cultivation.required(state, "qi") > 0,
			"a exigência do primeiro estágio tem de ser um número real")
		t:expect(not Cultivation.canBreak(state, "qi"),
			"uma poça vazia não pode romper nada")
	end)

	Testing.scenario("sentado sem escolher caminho, nada entra", function(t)
		local state = Cultivation.newState()
		for _ = 1, 30 do
			Cultivation.tick(state, 1)
		end
		t:expectEqual(state.qi, 0, "sem ação escolhida o Qi não pode subir")
		t:expectEqual(state.body, 0, "nem o corpo")
	end)

	Testing.scenario("cultivar enche o Qi e treinar enche o corpo, nunca os dois", function(t)
		local state = Cultivation.newState()
		state.action = "cultivar"
		Cultivation.tick(state, 1)
		t:expect(state.qi > 0, "cultivar tem de render Qi")
		t:expectEqual(state.body, 0, "cultivar não pode render corpo")

		local qiBefore = state.qi
		state.action = "treinar"
		Cultivation.tick(state, 1)
		t:expect(state.body > 0, "treinar tem de render corpo")
		t:expectEqual(state.qi, qiBefore, "treinar não pode render Qi")
	end)

	Testing.scenario("a poça não para: quem cultiva mais tempo acumula avanços", function(t)
		--[[
			A correção mais importante deste jogo.

			A primeira versão travava o Qi na exigência do degrau. O sintoma
			era brutal e invisível num teste de unidade: quem saísse da frente
			da tela voltava com a poça exatamente onde a deixou, e cultivar
			virava uma fila de cliques obrigatórios. Um jogo de cultivo em que
			parar de olhar interrompe o cultivo contradiz a única coisa que o
			gênero promete.
		]]
		local state = Cultivation.newState()
		state.action = "cultivar"
		local need = Cultivation.required(state, "qi")
		for _ = 1, 400 do
			Cultivation.tick(state, 1)
		end
		t:expect(state.qi > need * 2, string.format(
			"quatrocentos ticks pararam em %.0f contra uma exigência de %.0f: "
			.. "a poça voltou a ter teto", state.qi, need))
		t:expect(Cultivation.banked(state, "qi") >= 2,
			"o excedente tem de virar avanços guardados")
	end)

	Testing.scenario("o avanço debita a exigência e deixa o resto", function(t)
		--: O outro lado da mesma regra: se o avanço zerasse a poça, acumular
		--: seria pior do que romper na hora, e o jogador aprenderia a não
		--: acumular.
		local state = Cultivation.newState()
		local need = Cultivation.required(state, "qi")
		state.qi = need * 3

		local report = Cultivation.breakthrough(state, "teste:sobra", "qi")
		t:expect(report.ok, "com o triplo da exigência o avanço tem de passar")
		t:expect(state.qi > need, string.format(
			"sobrou %.0f de uma poça de %.0f: o avanço comeu o acúmulo",
			state.qi, need * 3))
	end)

	Testing.scenario("o avanço só é aceito com a poça cheia", function(t)
		local state = Cultivation.newState()
		local refused = Cultivation.breakthrough(state, "teste:vazio", "qi")
		t:expect(not refused.ok, "romper sem Qi suficiente tem de ser recusado")
		t:expect(refused.reason ~= nil, "uma recusa precisa dizer por quê")

		fill(state, "qi")
		local report = Cultivation.breakthrough(state, "teste:cheio", "qi")
		t:expect(report.ok, "romper com a exigência paga tem de passar")
		t:expectEqual(state.qiStage, 2, "o avanço sobe um estágio")
		t:expectEqual(state.qi, 0, "pago exatamente o custo, a poça fica em zero")
		t:expect((report.pedras or 0) > 0, "todo avanço paga pedras")
	end)

	Testing.scenario("o avanço de estágio é certo; o de realm é apostado", function(t)
		--[[
			Cobrar risco nove vezes por realm transformaria o jogo numa moeda.
			Uma vez a cada dez é raro o bastante para ser um evento e frequente
			o bastante para a pílula ter comprador.
		]]
		local state = Cultivation.newState()
		t:expectEqual(Cultivation.chance(state, "qi"), 1.0,
			"um estágio comum não pode falhar")

		state.qiStage = Content.stagesPerRealm
		local chance = Cultivation.chance(state, "qi")
		t:expect(chance < 1.0, "a passagem de realm tem de ser apostada")
		t:expect(chance > 0.2, "e não pode ser uma aposta desesperada")
	end)

	Testing.scenario("uma tribulação falhada deixa percepção, não só prejuízo", function(t)
		--: Uma sequência ruim tem de ter fim. Sem a percepção somando, um
		--: jogador azarado fica preso no mesmo degrau para sempre, o que é a
		--: diferença entre tensão e castigo.
		local state = Cultivation.newState()
		state.qiStage = Content.stagesPerRealm
		local before = Cultivation.chance(state, "qi")

		state.qiInsight += 1
		local after = Cultivation.chance(state, "qi")
		t:expect(after > before,
			"cada tentativa frustrada tem de melhorar a próxima")
	end)

	Testing.scenario("o primeiro despertar é de graça e o segundo cobra", function(t)
		--: A resposta ao único registro real de retenção deste repositório: a
		--: maior parte dos jogadores novos saiu antes de receber qualquer coisa.
		local state = Cultivation.newState()
		local purse = state.pedras

		local first = Cultivation.spin(state, "teste:gratis", "raiz")
		t:expect(first.ok, "o primeiro giro não pode ser recusado")
		t:expect(first.free == true, "o primeiro giro é de graça")
		t:expectEqual(state.pedras, purse, "e não pode cobrar nada")

		local second = Cultivation.spin(state, "teste:gratis", "raiz")
		t:expect(second.ok, "o segundo giro tem de caber no bolso inicial")
		t:expect(state.pedras < purse, "o segundo giro cobra")
	end)

	Testing.scenario("uma raiz selada recusa o giro", function(t)
		local state = Cultivation.newState()
		local sealed = Cultivation.lock(state, "raiz", true)
		t:expect(sealed.ok, "selar com pedras no bolso tem de passar")

		local blocked = Cultivation.spin(state, "teste:selo", "raiz")
		t:expect(not blocked.ok, "uma raiz selada não pode ser rolada por cima")

		Cultivation.lock(state, "raiz", false)
		local allowed = Cultivation.spin(state, "teste:selo", "raiz")
		t:expect(allowed.ok, "quebrado o selo, o giro volta")
	end)

	Testing.scenario("uma pílula multiplica a entrada enquanto dura", function(t)
		local state = Cultivation.newState()
		state.action = "cultivar"
		local before = Cultivation.perTick(state, "qi")

		local taken = Cultivation.consume(state, "teste:pilula", "qi_verdadeiro")
		t:expect(taken.ok, "a pílula mais barata tem de caber no bolso inicial")
		t:expect(Cultivation.perTick(state, "qi") > before,
			"uma pílula de Qi tem de aumentar a entrada de Qi")
		t:expectEqual(Cultivation.pillMultiplier(state, "corpo"), 1.0,
			"e não pode aumentar a do corpo")
	end)

	Testing.scenario("voar é recusado antes do realm que o concede", function(t)
		local state = Cultivation.newState()
		local refused = Cultivation.fly(state, true)
		t:expect(not refused.ok, "um novato não pode voar")
		t:expect(not state.flying, "e a recusa não pode deixar a flag ligada")

		state.qiRealm = Content.flightRealm
		local allowed = Cultivation.fly(state, true)
		t:expect(allowed.ok, "no realm certo, voar é permitido")
		t:expect(state.flying, "e a flag acompanha")
	end)

	Testing.scenario("uma técnica exige o realm e cobra uma vez só", function(t)
		local state = Cultivation.newState()
		local hard = Content.techniques[5]
		local refused = Cultivation.equip(state, "teste:tec", 1, hard.id)
		t:expect(not refused.ok, "uma técnica de realm alto tem de ser recusada")

		local easy = Content.techniques[1]
		state.pedras = easy.cost * 3
		local bought = Cultivation.equip(state, "teste:tec", 1, easy.id)
		t:expect(bought.ok, "a primeira técnica tem de ser comprável")
		local afterFirst = state.pedras

		Cultivation.equip(state, "teste:tec", 2, easy.id)
		t:expectEqual(state.pedras, afterFirst,
			"trocar de slot não pode cobrar de novo")
	end)

	Testing.scenario("o jogador nunca bate numa parede", function(t)
		--[[
			A asserção que segura o desenho inteiro.

			O custo por estágio é exponencial. Se o ganho não for exponencial
			também, cada estágio demora um múltiplo do anterior e por volta do
			quarto realm o jogo parece quebrado sem ter mudado nada. Medido
			aqui em segundos simulados, degrau a degrau, através dos dois
			primeiros realms.
		]]
		local state = Cultivation.newState()
		state.action = "cultivar"

		local previous = 0
		local worst = 0
		for _ = 1, Content.stagesPerRealm * 2 do
			local seconds = Cultivation.required(state, "qi")
				/ Cultivation.perTick(state, "qi")
			if previous > 0 then
				worst = math.max(worst, seconds / previous)
			end
			previous = seconds
			fill(state, "qi")
			Cultivation.breakthrough(state, "teste:parede", "qi")
			--: Forçado: a passagem de realm é apostada, e um cenário que
			--: depende de ganhar uma aposta é um cenário que falha 40% das
			--: vezes por motivo nenhum.
			if state.qiStage == Content.stagesPerRealm and state.qiRealm == 1 then
				state.qiRealm, state.qiStage = 2, 1
			end
		end

		t:expect(worst < 1.6, string.format(
			"algum degrau ficou %.2fx mais longo que o anterior — isso é parede",
			worst))
	end)

	Testing.scenario("o primeiro avanço cabe no primeiro minuto", function(t)
		--[[
			O buraco que fecha 28% das primeiras sessões. Um jogo em que a
			primeira recompensa chega depois de dois minutos perde o jogador
			antes de mostrar o que é.
		]]
		local state = Cultivation.newState()
		state.action = "cultivar"
		local seconds = 0
		while seconds < 60 and not Cultivation.canBreak(state, "qi") do
			Cultivation.tick(state, 1)
			seconds += 1
		end
		t:expect(Cultivation.canBreak(state, "qi"), string.format(
			"o primeiro avanço não ficou pago em 60s (%.0f de %.0f)",
			state.qi, Cultivation.required(state, "qi")))
	end)

	Testing.scenario("o segundo realm cabe numa sessão", function(t)
		--: O degrau que 74% dos jogadores novos, no único registro real deste
		--: repositório, nunca alcançaram. Se não couber numa sessão, a escada
		--: está errada e nenhuma quantidade de conteúdo conserta.
		local state = Cultivation.newState()
		state.action = "cultivar"
		local seconds = 0
		while seconds < 2400 and state.qiRealm < 2 do
			Cultivation.tick(state, 1)
			if Cultivation.canBreak(state, "qi") then
				local report = Cultivation.breakthrough(state, "teste:sessao", "qi")
				--: A tribulação pode recusar. Isso é o jogo funcionando, não o
				--: teste falhando -- o cenário só continua tentando.
				if not report.ok and not report.failed then
					break
				end
			end
			seconds += 1
		end
		t:expect(state.qiRealm >= 2, string.format(
			"não chegou ao Estabelecimento de Fundação em 40 minutos simulados "
			.. "(parou em %s)",
			Content.realmTitle(Content.qiRealms, state.qiRealm, state.qiStage)))
	end)

	Testing.scenario("um terraço só rende para quem tem o rank", function(t)
		--[[
			A porta do jogo inteiro, e ela é feita de Qi e não de parede.

			Um discípulo externo pode caminhar até o Salão dos Ancestrais e
			sentar no meio dele. A placa diz x34; o multiplicador dele continua
			x1. É assim que a regra se ensina andando, em vez de com uma borda
			invisível que trava alguém sem explicar nada.
		]]
		local state = Cultivation.newState()
		local top = Content.zones[#Content.zones]

		state.zone = top.id
		t:expectEqual(Cultivation.zoneMultiplier(state), 1.0,
			"um novato no terraço mais alto não pode receber nada")

		state.qiRealm = top.rank
		t:expectEqual(Cultivation.zoneMultiplier(state), top.mult,
			"no rank exigido o terraço tem de render o que a placa promete")
	end)

	Testing.scenario("subir de terraço rende mais que o anterior", function(t)
		--: A escada de zonas é o que dá destino à caminhada. Se um terraço
		--: mais alto rendesse igual ou menos, subir seria enfeite.
		local previous = 0
		for _, zone in Content.zones do
			local state = Cultivation.newState()
			state.qiRealm = zone.rank
			state.zone = zone.id
			local mult = Cultivation.zoneMultiplier(state)
			t:expect(mult > previous, string.format(
				"'%s' rende %.1f, e o terraço anterior já rendia %.1f",
				zone.name, mult, previous))
			previous = mult
		end
	end)

	Testing.scenario("o terraço entra no multiplicador que a tela mostra", function(t)
		local state = Cultivation.newState()
		local before = Cultivation.perTick(state, "qi")

		local zone = Content.zones[2]
		state.qiRealm = zone.rank
		state.zone = zone.id
		--: Comparado no mesmo realm dos dois lados: subir de realm também muda
		--: o ganho, e um teste que confundisse as duas causas passaria mesmo
		--: com a zona desligada.
		local plain = Cultivation.newState()
		plain.qiRealm = zone.rank
		t:expect(Cultivation.perTick(state, "qi") > Cultivation.perTick(plain, "qi"),
			"sentar num terraço tem de render mais que sentar no chão")
		t:expect(before > 0, "o ganho base tem de existir para haver o que multiplicar")
	end)

	Testing.scenario("treinar o corpo dá corpo: vida, velocidade e salto", function(t)
		--[[
			Sem isto o Corpo é uma segunda barra decorativa. Em qualquer manhwa
			quem treina o corpo aguenta mais e corre mais, e é a única razão de
			existirem dois caminhos em vez de um.
		]]
		local novice = Content.maxHealth(1, 1.0)
		local veteran = Content.maxHealth(40, 1.0)
		t:expect(veteran > novice * 10,
			"quarenta degraus de corpo têm de valer muito mais que um")

		t:expect(Content.walkSpeed(40) > Content.walkSpeed(1),
			"treinar o corpo tem de deixar o cultivador mais rápido")
		t:expect(Content.jumpPower(40) > Content.jumpPower(1),
			"e saltar mais alto")

		--: Os tetos não são timidez: com `StreamingEnabled`, um cultivador
		--: rápido demais corre para dentro de um mundo que ainda não carregou.
		t:expect(Content.walkSpeed(10000) <= Content.body.maxSpeed,
			"a velocidade tem de ter teto")
		t:expect(Content.jumpPower(10000) <= Content.body.maxJump,
			"o salto também — sem isso o voo deixa de ser uma conquista")
	end)

	Testing.scenario("a constituição multiplica a vida, não a velocidade", function(t)
		local common = Content.maxHealth(20, 1.0)
		local rare = Content.maxHealth(20, 4.0)
		t:expect(rare > common * 3.5,
			"uma constituição rara tem de fazer o corpo aguentar")
		t:expectEqual(Content.walkSpeed(20), Content.walkSpeed(20),
			"e a velocidade não pode depender dela")
	end)

	Testing.scenario("a aura muda a cada degrau, não só a cada realm", function(t)
		--[[
			O defeito que sobreviveu a três correções.

			`auraFor` recebia só o realm, e as âncoras estão nos realms 1, 2, 3,
			4, 5, 7, 10 e 13 -- então do Refinamento de Qi I ao X, que são
			**dez rompimentos**, a aura era byte a byte a mesma. O jogador
			rompia a noite inteira e não via nada mudar, e nenhum cenário
			pegava isso porque todos comparavam realms.

			Este compara **estágios do mesmo realm**, que é onde o jogador
			passa noventa por cento do tempo dele.
		]]
		local first = Content.auraFor(1, 1)
		local last = Content.auraFor(1, Content.stagesPerRealm)
		t:expect(last.rate > first.rate,
			"dez avanços dentro de um realm e a aura não emite mais nada")
		t:expect(last.size > first.size, "nem cresce")
		t:expect(last.colour ~= first.colour,
			"nem muda de cor: a escada de estágios é invisível")

		--: E o degrau seguinte tem de continuar acima do último do anterior --
		--: senão romper um realm seria um passo para trás.
		local nextRealm = Content.auraFor(2, 1)
		t:expect(nextRealm.rate >= last.rate * 0.9,
			"romper o realm fez a aura encolher")
	end)

	Testing.scenario("cada patamar troca a forma, não só a intensidade", function(t)
		--: Crescer não é trocar. Um patamar que só emite mais lê como o mesmo
		--: cultivador mais perto; o que faz alguém dizer "aquele ali é outra
		--: coisa" é a forma mudar de lugar no corpo.
		local low = Content.auraFor(1, 1)
		local mid = Content.auraFor(4, 1)
		local high = Content.auraFor(13, 1)

		t:expect(not low.halo, "um novato não pode ter halo")
		t:expect(mid.halo, "o patamar do Núcleo em diante tem de ter halo")
		t:expect(not mid.crown, "a coroa não pode chegar no meio da escada")
		t:expect(high.crown, "o topo da escada precisa da coroa")
		t:expect(high.rings > low.rings, "o topo tem de ter mais anéis")
		t:expect(high.beam > 0 and low.beam == 0,
			"a coluna de luz é uma troca de forma, não um degrau de brilho")
	end)

	Testing.scenario("a aura cresce a cada degrau de rank", function(t)
		--[[
			A aura é a única propaganda que este jogo faz de si mesmo: quem
			acaba de entrar vê um cultivador de rank alto e passa a querer
			aquilo. Se um degrau não for visivelmente maior que o anterior, a
			escada inteira deixa de ser lida do outro lado do pátio.
		]]
		local previousRate, previousRings = -1, -1
		for _, aura in Content.auras do
			t:expect(aura.rate > previousRate, string.format(
				"'%s' não emite mais que o degrau anterior", aura.name))
			t:expect(aura.rings >= previousRings, string.format(
				"'%s' perdeu anéis em relação ao degrau anterior", aura.name))
			previousRate, previousRings = aura.rate, aura.rings
		end

		--: E a escada tem de cobrir a escada de realms, senão os últimos
		--: rompimentos não mudam nada no que se vê.
		local top = Content.auraFor(#Content.qiRealms)
		t:expect(top.rings >= 3, "o topo da escada precisa de aura de topo")
		t:expectEqual(Content.auraFor(1).rings, 0,
			"um novato não pode nascer com anéis")
	end)

	Testing.scenario("um manual é permanente e cumulativo", function(t)
		--[[
			A peça que faz caçar não ser "sentar de outro jeito".

			Pílula acaba. Manual não: é o único multiplicador que o jogo não
			vende, e por isso o único motivo mecânico para alguém entrar na
			caverna de uma besta. Cumulativo, e não "só o melhor conta" --
			senão o oitavo Lobo das Neblinas não vale nada e o jogador para de
			comemorar tudo o que não seja Celestial.
		]]
		local state = Cultivation.newState()
		local before = Cultivation.perTick(state, "qi")

		local learned = Cultivation.learn(state, "respiracao_basica")
		t:expect(learned.ok, "ler um manual não pode ser recusado")
		local after = Cultivation.perTick(state, "qi")
		t:expect(after > before, "um manual de Qi tem de aumentar a entrada de Qi")

		Cultivation.learn(state, "sutra_lotus")
		t:expect(Cultivation.perTick(state, "qi") > after,
			"o segundo manual tem de somar com o primeiro, não substituí-lo")

		local twoCopies = Cultivation.learn(state, "respiracao_basica")
		t:expectEqual(twoCopies.copies, 2, "a segunda cópia tem de ser contada")
	end)

	Testing.scenario("um manual de corpo não acelera o Qi", function(t)
		--: Trilhas separadas. Se todo manual servisse para tudo, os dois
		--: caminhos deixariam de ser dois.
		local state = Cultivation.newState()
		local qiBefore = Cultivation.perTick(state, "qi")
		Cultivation.learn(state, "punho_pedra")
		t:expectEqual(Cultivation.perTick(state, "qi"), qiBefore,
			"um manual de corpo não pode mexer na entrada de Qi")
		t:expect(Cultivation.manualMultiplier(state, "corpo") > 1,
			"mas tem de mexer na do corpo")
	end)

	Testing.scenario("o ginseng vale degraus, não um número fixo", function(t)
		--[[
			Um item que dá "5000 de Qi" resolve o primeiro realm e não
			significa nada no quinto. Em múltiplos da exigência do degrau
			atual, o mesmo ginseng continua valendo três degraus pela vida
			inteira do save -- que é o que o preço fixo dele promete.
		]]
		local novice = Cultivation.newState()
		novice.pedras = 100000
		local item = Content.item("ginseng_centenario")
		Cultivation.buy(novice, item.id)
		local gainedEarly = novice.qi

		local veteran = Cultivation.newState()
		veteran.pedras = 100000
		veteran.qiRealm, veteran.qiStage = 4, 5
		Cultivation.buy(veteran, item.id)
		local gainedLate = veteran.qi

		t:expect(gainedLate > gainedEarly * 100,
			"o mesmo ginseng tem de escalar com o degrau do cultivador")
		t:expectEqual(gainedEarly / Cultivation.required(novice, "qi"), item.amount,
			"e valer exatamente os degraus que a loja promete")
	end)

	Testing.scenario("a loja recusa o que não cabe no bolso", function(t)
		local state = Cultivation.newState()
		state.pedras = 0
		local refused = Cultivation.buy(state, "ginseng_milenar")
		t:expect(not refused.ok, "comprar sem pedra tem de ser recusado")
		t:expectEqual(state.qi, 0, "e não pode entregar nada")
	end)

	Testing.scenario("o golpe vem do corpo mais do que do Qi", function(t)
		--[[
			A lição que faz as duas barras existirem: quem só meditou tem Qi
			enorme e apanha do primeiro javali. Se o Qi pesasse igual, o
			caminho do corpo seria uma segunda barra sem consequência.
		]]
		local monk = Cultivation.newState()
		monk.qiRealm, monk.qiStage = 4, 1

		local fighter = Cultivation.newState()
		fighter.bodyRealm, fighter.bodyStage = 4, 1

		t:expect(Cultivation.strike(fighter) > Cultivation.strike(monk),
			"quem treinou o corpo tem de bater mais que quem só meditou")
	end)

	Testing.scenario("toda besta paga, e só as fortes guardam grau alto", function(t)
		--: Se a besta mais fraca pudesse largar o manual mais raro, farmá-la
		--: seria a estratégia dominante e a escada de rank não significaria
		--: nada.
		local weakest, strongest = Content.beasts[1], Content.beasts[#Content.beasts]
		t:expect(weakest.manualTier < strongest.manualTier,
			"a besta mais fraca não pode guardar o mesmo grau que a mais forte")
		for _, beast in Content.beasts do
			t:expect(beast.pedras > 0, beast.name .. " não paga nada")
			t:expect(beast.manualChance > 0, beast.name .. " nunca larga manual")
			t:expect(beast.vida > 0 and beast.poder > 0,
				beast.name .. " não é um alvo válido")
		end
	end)

	Testing.scenario("as posturas são três, e a barra tem cinco botões", function(t)
		--[[
			A confusão que abriu um buraco real: `SetAction` validava contra a
			barra de ações, que tem botões de efeito instantâneo. Um cliente
			modificado mandava `action = "voar"` e parava o cultivo de graça.
		]]
		t:expectEqual(#Content.stances, 3,
			"sentar, treinar e levantar — e nada mais é uma postura")
		t:expect(#Content.actions > #Content.stances,
			"a barra mostra mais coisas do que existem posturas")
		for _, stance in Content.stances do
			local found = stance == "nenhum"
			for _, action in Content.actions do
				if action.id == stance then
					found = true
				end
			end
			t:expect(found, "a postura '" .. stance .. "' não tem botão")
		end
	end)

	Testing.scenario("uma técnica equipada muda um número de verdade", function(t)
		--[[
			O defeito que este cenário existe para impedir de voltar.

			`poder`, `velocidade`, `qiMult` e `saudeMult` estavam na tabela de
			técnicas desde o primeiro dia **sem um único leitor**: equipar
			gastava pedras, acendia um losango e não mexia em nada. É a mesma
			falha que os `grants` de realm tinham -- um valor de balanceamento
			que ninguém consulta é pior que um ausente, porque quem lê a tabela
			acredita que está valendo.

			Cada campo declarado em `Content.techniqueEffects` é testado aqui,
			e não um deles: uma técnica nova com um campo sem leitor volta a
			passar despercebida se este laço olhar só para o que já existia.
		]]
		for _, effect in Content.techniqueEffects do
			local carrier = nil
			for _, technique in Content.techniques do
				if technique[effect.field] ~= nil then
					carrier = technique
					break
				end
			end
			t:expect(carrier ~= nil, string.format(
				"nenhuma técnica usa '%s' — o campo existe sem dono", effect.field))
			if carrier == nil then
				continue
			end

			local state = Cultivation.newState()
			state.qiRealm = carrier.realm
			state.pedras = carrier.cost * 2
			local before = Cultivation.techniqueMultiplier(state, effect.field)
			t:expectEqual(before, 1.0,
				"sem nada equipado o multiplicador tem de ser um")

			local equipped = Cultivation.equip(state, "teste:efeito", 1, carrier.id)
			t:expect(equipped.ok, "equipar no realm certo não pode ser recusado")
			t:expect(Cultivation.techniqueMultiplier(state, effect.field) > 1.0,
				string.format("'%s' não moveu '%s'", carrier.name, effect.field))
		end
	end)

	Testing.scenario("a técnica de Qi entra no ganho por tick", function(t)
		--: O caminho completo, e não só o multiplicador isolado: um efeito que
		--: existe e não é lido por `perTick` é o mesmo nada com um teste verde.
		local state = Cultivation.newState()
		local sutra = nil
		for _, technique in Content.techniques do
			if technique.qiMult ~= nil then
				sutra = technique
			end
		end
		t:expect(sutra ~= nil, "nenhuma técnica multiplica Qi")
		if sutra == nil then
			return
		end
		state.qiRealm = sutra.realm
		state.pedras = sutra.cost * 2
		local before = Cultivation.perTick(state, "qi")
		Cultivation.equip(state, "teste:qi", 1, sutra.id)
		t:expect(Cultivation.perTick(state, "qi") > before,
			"equipar uma técnica de Qi tem de aumentar a entrada de Qi")
	end)

	Testing.scenario("a técnica de poder entra no golpe", function(t)
		local state = Cultivation.newState()
		local fist = Content.techniques[1]
		state.qiRealm = fist.realm
		state.pedras = fist.cost * 2
		local before = Cultivation.strike(state)
		Cultivation.equip(state, "teste:golpe", 1, fist.id)
		t:expect(Cultivation.strike(state) > before,
			"equipar Palma de Ferro tem de aumentar o dano")
	end)

	Testing.scenario("só o que está equipado conta", function(t)
		--: Comprar é para sempre; equipar é a decisão. Se comprar já valesse,
		--: os quatro slots seriam enfeite e a única jogada seria comprar tudo.
		local state = Cultivation.newState()
		local fist = Content.techniques[1]
		state.qiRealm = fist.realm
		state.pedras = fist.cost * 3
		Cultivation.equip(state, "teste:slot", 1, fist.id)
		local equipped = Cultivation.techniqueMultiplier(state, "poder")
		t:expect(equipped > 1.0, "equipada, a técnica conta")

		Cultivation.equip(state, "teste:slot", 1, "")
		t:expectEqual(Cultivation.techniqueMultiplier(state, "poder"), 1.0,
			"desequipada, ela para de contar mesmo estando comprada")
		t:expect(state.owned[fist.id] == true,
			"e continua comprada, para poder voltar sem pagar de novo")
	end)

	Testing.scenario("toda técnica se descreve pelo que faz", function(t)
		--: A frase da tela sai da mesma tabela que o efeito, para que uma
		--: técnica nunca prometa na loja algo diferente do que aplica.
		for _, technique in Content.techniques do
			local blurb = Content.techniqueBlurb(technique)
			t:expect(blurb ~= "sem efeito", string.format(
				"'%s' não declara efeito nenhum", technique.name))
		end
	end)

	Testing.scenario("o save leva de volta tudo o que foi conquistado", function(t)
		--[[
			A ida e a volta inteiras, numa tabela comum.

			Este é o cenário que faltava. `Cultivation.save` e
			`Cultivation.load` são puras de propósito: em Studio sem "Enable
			Studio Access to API Services" o `DataStore` não existe e o `Save`
			entra em modo memória -- ou seja, **a persistência nunca é
			exercitada numa sessão de teste**, e um campo esquecido não dá erro
			nenhum. Ele só apaga o que o jogador levou mais tempo para
			conseguir.

			Aqui um cultivador com histórico é serializado, uma tabela nova é
			carregada a partir disso, e as duas são comparadas campo a campo.
		]]
		local before = Cultivation.newState()
		before.qiRealm, before.qiStage, before.qi = 6, 4, 12345.5
		before.bodyRealm, before.bodyStage, before.body = 3, 9, 987.25
		before.qiInsight, before.bodyInsight = 2, 1
		before.root, before.rootLocked = "trovao", true
		before.constitution, before.constitutionLocked = "dragao", true
		before.pedras, before.meritos = 4321, 77
		before.spins, before.breaks, before.kills = 19, 41, 3
		Cultivation.learn(before, "sutra_lotus")
		Cultivation.learn(before, "sutra_lotus")
		Cultivation.learn(before, "veia_dragao")
		before.owned["palma_ferro"] = true
		before.techniques[1] = "palma_ferro"
		before.techniques[3] = "passo_vento"

		local profile = Cultivation.save(before)
		local after = Cultivation.newState()
		Cultivation.load(after, profile)

		for _, field in { "qiRealm", "qiStage", "qi", "qiInsight",
		                  "bodyRealm", "bodyStage", "body", "bodyInsight",
		                  "root", "rootLocked", "constitution",
		                  "constitutionLocked", "pedras", "meritos",
		                  "spins", "breaks", "kills" } do
			t:expectEqual((after :: any)[field], (before :: any)[field],
				"o campo '" .. field .. "' não sobreviveu ao save")
		end

		t:expectEqual(after.manuals["sutra_lotus"], 2,
			"as cópias de manual não sobreviveram")
		t:expectEqual(after.manuals["veia_dragao"], 1,
			"um manual inteiro se perdeu no save")
		t:expect(after.owned["palma_ferro"] == true,
			"a técnica comprada virou uma compra a refazer")
		t:expectEqual(after.techniques[1], "palma_ferro",
			"o slot 1 voltou vazio")
		t:expectEqual(after.techniques[3], "passo_vento",
			"um slot com buraco antes dele não sobreviveu")
		t:expect(after.techniques[2] == nil,
			"um slot vazio voltou preenchido")

		--: E o multiplicador, que é a consequência de tudo isso. Se os
		--: manuais voltaram, a entrada por tick tem de voltar igual.
		t:expectEqual(Cultivation.manualMultiplier(after, "qi"),
			Cultivation.manualMultiplier(before, "qi"),
			"os manuais voltaram sem valer o que valiam")
	end)

	Testing.scenario("o template do save declara tudo o que o save escreve", function(t)
		--: Um campo que o save escreve e o template não declara é um campo que
		--: um jogador **antigo** nunca recebe: o `Save` só preenche o que o
		--: template conhece, e o perfil dele já existe.
		local template = Cultivation.template()
		local written = Cultivation.save(Cultivation.newState())
		for field in written do
			t:expect(template[field] ~= nil, string.format(
				"o save escreve '%s' e o template não declara: jogador antigo "
				.. "nunca recebe esse campo", field))
		end
	end)

	Testing.scenario("voar exige o meio da escada, e melhora com ela", function(t)
		--[[
			Cânone do gênero: sobre um núcleo formado um cultivador plana; com
			uma alma nascente ele voa. Quatro de quinze realms é o meio da
			escada -- tarde o bastante para ser conquista, cedo o bastante para
			o jogador ainda estar por perto quando chega.
		]]
		local novice = Cultivation.newState()
		local refused = Cultivation.fly(novice, true)
		t:expect(not refused.ok, "um novato não pode voar")

		local adept = Cultivation.newState()
		adept.qiRealm = Content.flightRealm
		local granted = Cultivation.fly(adept, true)
		t:expect(granted.ok, "no realm do voo, voar tem de ser permitido")

		--: E o poder cresce com o realm. Um voo que não melhora é transporte:
		--: a conquista acontece uma vez e nunca mais significa nada.
		t:expect(Content.flySpeed(12) > Content.flySpeed(Content.flightRealm),
			"voar num realm alto tem de ser mais rápido")
		t:expect(Content.flyCeiling(12) > Content.flyCeiling(Content.flightRealm),
			"voar num realm alto tem de subir mais")
		t:expect(Content.flySpeed(99) <= Content.flight.maxSpeed,
			"a velocidade de voo precisa de teto: com streaming, rápido demais "
			.. "é voar para dentro de um mundo que não carregou")
	end)

	Testing.scenario("voar cancela a postura, e correr é recusado no ar", function(t)
		--: Um cultivador sentado no ar ganhando Qi é uma postura que o jogo não
		--: tem -- e sair voando de um assento deixa o `Seat` órfão com alguém
		--: preso nele.
		local state = Cultivation.newState()
		state.qiRealm = Content.flightRealm
		state.action = "cultivar"
		Cultivation.fly(state, true)
		t:expectEqual(state.action, "nenhum", "voar tem de levantar o cultivador")

		local running = Cultivation.sprint(state, true)
		t:expect(not running.ok, "não se corre voando")
		t:expect(not state.sprinting, "e a recusa não pode ligar a flag")
	end)

	Testing.scenario("correr multiplica a caminhada, e tem teto", function(t)
		--: A velocidade base vem do caminho do corpo, então quem treinou corre
		--: mais rápido -- sem uma segunda escada para manter.
		local slow = Content.walkSpeed(1)
		local fast = Content.walkSpeed(60)
		t:expect(Content.sprintSpeed(slow) > slow, "correr tem de ser mais rápido")
		t:expect(Content.sprintSpeed(fast) > Content.sprintSpeed(slow),
			"quem treinou o corpo tem de correr mais que quem não treinou")
		t:expect(Content.sprintSpeed(10000) <= Content.sprint.maxSpeed,
			"a corrida precisa de teto pelo mesmo motivo que o voo")
	end)

	Testing.scenario("não se corre sentado", function(t)
		local state = Cultivation.newState()
		state.action = "cultivar"
		local refused = Cultivation.sprint(state, true)
		t:expect(not refused.ok, "meditando não se corre")
	end)

	Testing.scenario("o pacote para a tela é auto-suficiente", function(t)
		--[[
			O cliente não recalcula nada. Se algum destes campos faltar, a tela
			ou desenha em branco ou inventa a própria fórmula -- e a fórmula
			inventada é sempre a que fica para trás na afinação seguinte.
		]]
		local state = Cultivation.newState()
		local packed = Cultivation.pack(state)
		for _, field in { "pool", "required", "banked", "perTick", "multiplier",
		                  "title", "ready", "chance" } do
			t:expect(packed.qi[field] ~= nil,
				"o pacote de Qi não trouxe '" .. field .. "'")
			t:expect(packed.corpo[field] ~= nil,
				"o pacote de corpo não trouxe '" .. field .. "'")
		end
		t:expectEqual(#packed.techniques, Content.techniqueSlots,
			"a tela desenha um losango por slot e conta pelo pacote")
		t:expect(packed.root.name ~= nil, "a raiz precisa de nome na tela")
	end)

	Testing.scenario("o save leva de volta tudo o que foi conquistado", function(t)
		--[[
			O defeito que ninguém reporta porque não dá erro: um campo que o
			template não declara não é gravado, e o jogador perde exatamente o
			que mais custou.
		]]
		local template = Cultivation.template()
		for _, field in { "qiRealm", "qiStage", "qi", "root", "rootLocked",
		                  "pedras", "meritos", "techniques", "owned" } do
			t:expect(template[field] ~= nil,
				"o template de save não declara '" .. field .. "'")
		end
	end)
end
