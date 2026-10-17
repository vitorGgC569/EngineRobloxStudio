--!strict
--[[
	Wire — o contrato de rede, declarado uma vez e exigido pelos dois lados.

	`Net.define` monta sua tabela de canais **por VM de Lua**. Se só o servidor
	chamar, no cliente todo canal é indefinido: `Net.send` não tem por onde
	mandar e `Net.on` liga um handler a um canal que não existe. Nada disso dá
	erro. O jogo compila, tipa, passa no `forge doctor`, passa nos cenários --
	e nenhum botão faz nada, para ninguém.

	Isso aconteceu no jogo anterior deste repositório e sobreviveu a todos os
	portões automáticos, porque nenhum teste daqui já clicou num botão: todos
	disparavam o RemoteEvent direto, que é exatamente a metade que funcionava.

	Então os canais moram aqui, em `Shared`, e os dois lados dão require. Não
	existe arranjo em que um tenha e o outro não.

	`dir` é do ponto de vista do servidor: `s2c` é o servidor contando ao
	cliente, `c2s` é o cliente pedindo. Todo `c2s` leva `rate` e `shape` --
	não por estilo, mas porque é a diferença entre um jogo e uma superfície de
	exploit.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Net = Forge.Net

local Wire = {}

Wire.channels = {
	-- ------------------------------------------------ servidor -> cliente
	--: O estado inteiro do cultivador. Barato o bastante para mandar por
	--: tick, e ter uma só fonte de verdade vale mais que os bytes.
	StateSync = { dir = "s2c" },
	Notify = { dir = "s2c" },
	--: O avanço é canal próprio, não um campo do estado. Um rompimento
	--: dobrado dentro de uma sincronização chega junto com tudo e vira "um
	--: número mudou" -- e número mudando não é por que alguém medita de novo.
	Broke = { dir = "s2c" },
	--: A rolagem também. A roleta precisa saber quando começar a girar, e
	--: isso é um evento, não um estado.
	Spun = { dir = "s2c" },
	--: O que `Loop.Hatch` está achando errado com *este* jogador agora.
	Findings = { dir = "s2c" },
	--: Um manual caído. Canal próprio pelo mesmo motivo do avanço: é o único
	--: multiplicador permanente do jogo e chega uma vez a cada muitas bestas.
	--: Dobrado num `StateSync` ele passaria como uma linha a mais numa lista.
	Learned = { dir = "s2c" },
	--: A besta acertou. Existe para a tela tremer e piscar de vermelho -- sem
	--: isso o jogador perde vida sem saber de onde, o que lê como bug.
	Struck = { dir = "s2c" },

	-- ------------------------------------------------ cliente -> servidor
	--: Não há `Ping` aqui. O scaffold traz um, e ele fica declarado sem
	--: chamador em todo jogo que nasce dele -- um canal aberto que ninguém
	--: usa é superfície de ataque sem contrapartida, e "é só o exemplo" é como
	--: ela sobrevive até a publicação.

	--: Sentar, treinar ou levantar. O cliente diz qual; o servidor decide se
	--: pode e quanto rende.
	SetAction = { dir = "c2s", rate = 6, shape = { action = "string" } },

	--: O toque manual. Taxa alta de propósito -- é o "Toque - Impulso", e um
	--: limite baixo aqui vira um botão que engasga. O ganho por toque é do
	--: servidor, então spam só gasta a cota, não gera Qi.
	Tap = { dir = "c2s", rate = 12, shape = { track = "string" } },

	--: Romper. Manual, sempre: o avanço é o momento do jogo e um avanço
	--: automático rouba do jogador a única decisão que ele toma no laço.
	Breakthrough = { dir = "c2s", rate = 3, shape = { track = "string" } },

	--: A gacha do que você é.
	Spin = { dir = "c2s", rate = 3, shape = { kind = "string" } },
	Lock = { dir = "c2s", rate = 2, shape = { kind = "string", on = "boolean" } },

	--: Pílulas e técnicas.
	Consume = { dir = "c2s", rate = 3, shape = { pill = "string" } },
	Equip = { dir = "c2s", rate = 4,
		shape = { slot = "number", technique = "string" } },

	--: A loja. Comprar e usar são a mesma mensagem: um inventário entre as
	--: duas seria mais uma tela e nenhuma decisão nova.
	Buy = { dir = "c2s", rate = 4, shape = { item = "string" } },

	--: O golpe. Sem alvo no payload: quem decide o que foi atingido é o
	--: servidor, a partir da posição do personagem. Um alvo escolhido pelo
	--: cliente é um alvo do outro lado do mapa.
	Swing = { dir = "c2s", rate = 6, shape = {} },

	--: Voar é permissão do servidor, não uma flag do cliente. O cliente pede;
	--: o servidor confere o realm e responde no estado.
	Fly = { dir = "c2s", rate = 4, shape = { on = "boolean" } },

	--: Correr. A tecla é do cliente, a velocidade é do servidor -- um cliente
	--: que decide a própria velocidade decide a própria velocidade. A taxa é
	--: alta porque é uma tecla que se segura e se solta o tempo todo.
	Sprint = { dir = "c2s", rate = 10, shape = { on = "boolean" } },
}

--[[
	Define os canais na VM que estiver perguntando.

	Idempotente porque tanto um bootstrap quanto um require tardio podem
	chamar, e `Net.define` sobre um canal já definido não pode virar um
	segundo canal.
]]
local defined = false

function Wire.install()
	if defined then
		return
	end
	defined = true
	Net.define(Wire.channels)
end

Wire.install()

return Wire
