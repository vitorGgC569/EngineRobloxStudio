--!strict
--[[
	Content — os dois caminhos, as raízes, as pílulas e cada número do jogo.

	Um módulo só, porque a regra da casa é que um número de balanceamento nunca
	mora em dois lugares. Um sistema que quer um preço pergunta aqui; nada mais
	escreve um valor à mão.

	O que este jogo é
	-----------------

	Um cultivo xianxia: você desperta uma raiz espiritual, medita para acumular
	Qi, rompe realms, e volta ao começo do laço mais rápido do que saiu.

	Duas escadas em paralelo, não uma
	---------------------------------

	`Qi` e `Corpo` sobem separados, cada realm com dez estágios. É de onde vem
	a sensação de imensidão: a mesma aritmética repetida em duas colunas dá
	centenas de degraus discretos por um custo de autoria quase nulo.

	    Qi     15 realms x 10 estágios = 150 degraus
	    Corpo  12 realms x 10 estágios = 120 degraus

	A ordem é o cânone do gênero, não invenção: Refinamento de Qi, Fundação,
	Núcleo, Alma Nascente, Formação de Alma. Um leitor de xianxia reconhece a
	escada antes de ler a segunda linha, e isso é metade da promessa do jogo.

	A gacha é sobre *quem você é*
	-----------------------------

	Raiz espiritual e constituição corporal são **rolados** e podem ser
	**travados**. Essa é a diferença que importa: uma gacha que entrega um item
	para uma lista satura, porque a lista sempre cresce. Uma gacha que rola um
	atributo permanente não satura, porque só existe um e sempre pode ser
	melhor -- e a trava existe porque a rolagem boa é rara o bastante para dar
	medo de perder.
]]

local Content = {}

-- ================================================================ moedas

Content.currencies = {
	--: A pedra espiritual: cai de mobs e chefes, gasta em pílulas e rolagens.
	--: Uma moeda, dois usos, e os dois no mesmo laço.
	pedras = { display = "Pedras Espirituais", start = 250, precision = 0 },
	--: Mérito: ganho por feitos, não por tempo. Compra o que pedra não compra.
	meritos = { display = "Méritos", start = 0, precision = 0 },
}

-- ========================================================== o caminho do Qi

--[[
	Os quinze realms do Qi, em ordem.

	`base` é o Qi necessário para o **primeiro estágio** do realm. Cada estágio
	seguinte multiplica por `step`, e romper para o realm seguinte multiplica
	de novo -- que é como um cultivo fica exponencial sem nenhuma tabela de
	trezentas linhas.
]]
export type Realm = {
	id: string,
	name: string,
	base: number,
	step: number,
	--[[
		O que este realm concede ao ser alcançado, permanentemente.

		Uma chave só: `rendimento`, que multiplica a entrada por tick e é
		cumulativa com a de todos os realms abaixo. Havia três outras aqui --
		`qiMax`, `saudeMax`, `poder` -- e nenhuma tinha leitor: eram números de
		balanceamento que ninguém consultava, o que é pior que não existirem,
		porque quem lê a tabela acredita que estão valendo.
	]]
	grants: { [string]: number }?,
	note: string?,
}

local qi: { Realm } = {
	{ id = "refino", name = "Refinamento de Qi", base = 60, step = 1.42,
	  note = "O primeiro fôlego. Todo imortal já foi alguém sentado no chão." },
	{ id = "fundacao", name = "Estabelecimento de Fundação", base = 900, step = 1.44,
	  grants = { rendimento = 1.20 },
	  note = "A base sobre a qual tudo o mais é empilhado. Apressá-la custa séculos." },
	{ id = "nucleo", name = "Formação do Núcleo", base = 14000, step = 1.46,
	  grants = { rendimento = 1.20 },
	  note = "O Qi deixa de ser algo que você junta e vira algo que você é." },
	{ id = "almanascente", name = "Alma Nascente", base = 210000, step = 1.48,
	  grants = { rendimento = 1.20 },
	  note = "Uma segunda você, pequena, sentada dentro da primeira." },
	{ id = "formacaoalma", name = "Formação de Alma", base = 3.2e6, step = 1.50,
	  grants = { rendimento = 1.20 },
	  note = "A alma endurece. Daqui em diante, morrer é mais difícil que viver." },
	{ id = "transformacao", name = "Transformação de Alma", base = 5.0e7, step = 1.52,
	  grants = { rendimento = 1.20 } },
	{ id = "vazio", name = "Vazio Iluminado", base = 8.0e8, step = 1.54,
	  grants = { rendimento = 1.20 },
	  note = "Você vê o vazio entre as coisas e entende que ele também é uma coisa." },
	{ id = "fusao", name = "Fusão", base = 1.3e10, step = 1.56,
	  grants = { rendimento = 1.20 } },
	{ id = "mahayana", name = "Mahayana", base = 2.2e11, step = 1.58,
	  grants = { rendimento = 1.20 } },
	{ id = "tribulacao", name = "Tribulação Celestial", base = 3.8e12, step = 1.62,
	  grants = { rendimento = 1.20 },
	  note = "O céu percebe você. Ele não gosta." },
	{ id = "terreno", name = "Imortal Terreno", base = 7.0e13, step = 1.66,
	  grants = { rendimento = 1.20 } },
	{ id = "verdadeiro", name = "Imortal Verdadeiro", base = 1.4e15, step = 1.70,
	  grants = { rendimento = 1.20 } },
	{ id = "dourado", name = "Imortal Dourado", base = 3.0e16, step = 1.74,
	  grants = { rendimento = 1.20 } },
	{ id = "ancestral", name = "Imortal Ancestral", base = 7.0e17, step = 1.78,
	  grants = { rendimento = 1.20 } },
	{ id = "soberano", name = "Soberano Imortal", base = 1.8e19, step = 1.82,
	  grants = { rendimento = 1.20 },
	  note = "Desobedecer aos céus faz de você um imortal." },
}
Content.qiRealms = qi

-- ======================================================= o caminho do corpo

--[[
	Os doze realms do corpo.

	Sobem com **treino**, não com meditação, e é por isso que existem: duas
	barras que enchem por ações diferentes dão ao jogador algo a fazer quando a
	outra está esperando. Um cultivo com uma barra só é um cronômetro.
]]
local body: { Realm } = {
	{ id = "corpo", name = "Treinamento de Corpo", base = 40, step = 1.40,
	  note = "Carregar água morro acima. Mil vezes." },
	{ id = "pele", name = "Pele de Ferro", base = 620, step = 1.42,
	  grants = { rendimento = 1.20 } },
	{ id = "ossos", name = "Ossos de Bronze", base = 9000, step = 1.44,
	  grants = { rendimento = 1.20 } },
	{ id = "musculo", name = "Músculo Sagrado", base = 130000, step = 1.46,
	  grants = { rendimento = 1.20 } },
	{ id = "sangue", name = "Sangue Dourado", base = 1.9e6, step = 1.48,
	  grants = { rendimento = 1.20 },
	  note = "O sangue passa a brilhar. É bonito e dói." },
	{ id = "jade", name = "Corpo de Jade", base = 2.9e7, step = 1.50,
	  grants = { rendimento = 1.20 } },
	{ id = "diamante", name = "Corpo Diamantino", base = 4.6e8, step = 1.54,
	  grants = { rendimento = 1.20 } },
	{ id = "imperecivel", name = "Corpo Imperecível", base = 7.5e9, step = 1.58,
	  grants = { rendimento = 1.20 } },
	{ id = "divino", name = "Corpo Divino", base = 1.3e11, step = 1.62,
	  grants = { rendimento = 1.20 } },
	{ id = "dragao", name = "Corpo de Dragão", base = 2.4e12, step = 1.66,
	  grants = { rendimento = 1.20 } },
	{ id = "caos", name = "Corpo do Caos", base = 4.8e13, step = 1.70,
	  grants = { rendimento = 1.20 } },
	{ id = "soberanocorpo", name = "Corpo Soberano", base = 1.1e15, step = 1.76,
	  grants = { rendimento = 1.20 } },
}
Content.bodyRealms = body

--: Dez estágios por realm, como o gênero manda. Um número, não uma tabela.
Content.stagesPerRealm = 10

--[[
	Quanto custa o estágio `stage` do realm `index` de uma escada.

	Cumulativo dentro do estágio: o jogador enche uma barra por estágio, e a
	barra do estágio seguinte é maior. Não é limiar acumulado -- é o custo
	daquele degrau, que é o que a barra na tela mostra.
]]
function Content.stageCost(ladder: { Realm }, index: number, stage: number): number
	local realm = ladder[index]
	if realm == nil then
		return math.huge
	end
	return realm.base * realm.step ^ (stage - 1)
end

--: O nome que aparece sobre a cabeça: "Formação de Alma V".
local ROMAN = { "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X" }

function Content.realmTitle(ladder: { Realm }, index: number, stage: number): string
	local realm = ladder[index]
	if realm == nil then
		return "?"
	end
	return realm.name .. " " .. (ROMAN[stage] or tostring(stage))
end

-- ========================================================== raiz espiritual

--[[
	A raiz espiritual: o que você é, rolado uma vez e re-rolável para sempre.

	O cânone do gênero está invertido de propósito e é assim no material de
	origem: **menos elementos é melhor**. Uma raiz quíntupla dispersa o Qi por
	cinco caminhos e não avança em nenhum; uma raiz única concentra tudo. Um
	leitor do gênero sabe disso antes de ler a tabela, e um jogador novo
	aprende na primeira rolagem ruim.

	`weight` é a chance relativa. `mult` multiplica o ganho de Qi por tick, que
	é o número que o HUD mostra como *Multiplicador*.
]]
export type Root = {
	id: string, name: string, tier: number, mult: number, weight: number,
	note: string,
}

local roots: { Root } = {
	{ id = "quintupla", name = "Raiz Quíntupla", tier = 1, mult = 0.75, weight = 300,
	  note = "Cinco elementos, nenhum caminho. Os anciões sentem muito." },
	{ id = "quadrupla", name = "Raiz Quádrupla", tier = 2, mult = 0.95, weight = 240,
	  note = "Quatro. Melhor que cinco, e isso é tudo o que se pode dizer." },
	{ id = "tripla", name = "Raiz Tripla", tier = 3, mult = 1.20, weight = 170,
	  note = "Passável. Uma seita pequena te aceita." },
	{ id = "dupla", name = "Raiz Dupla", tier = 4, mult = 1.65, weight = 95,
	  note = "Dois elementos em equilíbrio. Um bom começo." },
	{ id = "unica_fogo", name = "Raiz Única de Fogo", tier = 5, mult = 2.40, weight = 26,
	  note = "Um caminho, e ele queima." },
	{ id = "unica_agua", name = "Raiz Única de Água", tier = 5, mult = 2.40, weight = 26,
	  note = "Um caminho, e ele não tem pressa." },
	{ id = "unica_metal", name = "Raiz Única de Metal", tier = 5, mult = 2.45, weight = 22,
	  note = "Um caminho, e ele corta." },
	{ id = "trovao", name = "Raiz de Trovão", tier = 6, mult = 3.60, weight = 9,
	  note = "O céu já sabe seu nome. Isso raramente é bom." },
	{ id = "gelo_eterno", name = "Raiz de Gelo Eterno", tier = 6, mult = 3.80, weight = 7,
	  note = "Cultivar dói. Você para de sentir que dói, o que é pior." },
	{ id = "caos", name = "Raiz do Caos", tier = 7, mult = 6.00, weight = 2,
	  note = "Não é um elemento. É a ausência de acordo entre eles." },
	{ id = "celestial", name = "Raiz Celestial", tier = 8, mult = 10.00, weight = 1,
	  note = "Uma a cada era. As seitas guerreiam por você antes de te conhecer." },
}
Content.roots = roots

-- ====================================================== constituição corporal

export type Constitution = {
	id: string, name: string, tier: number, mult: number, weight: number,
	note: string,
}

local constitutions: { Constitution } = {
	{ id = "comum", name = "Constituição Comum", tier = 1, mult = 0.80, weight = 320,
	  note = "O corpo com que se nasce. Serve para carregar água." },
	{ id = "robusta", name = "Constituição Robusta", tier = 2, mult = 1.00, weight = 220,
	  note = "Aguenta o treino sem quebrar. É mais do que parece." },
	{ id = "veias", name = "Veias de Ferro", tier = 3, mult = 1.35, weight = 140,
	  note = "O sangue corre pesado e o cansaço chega tarde." },
	{ id = "medula", name = "Medula de Jade", tier = 4, mult = 1.90, weight = 70,
	  note = "Os ossos se recompõem enquanto você dorme." },
	{ id = "dragao", name = "Ossos de Dragão", tier = 5, mult = 2.90, weight = 20,
	  note = "Algo muito antigo passou pela sua linhagem e não pediu licença." },
	{ id = "sagrada", name = "Constituição Sagrada", tier = 6, mult = 4.50, weight = 6,
	  note = "Os monges se levantam quando você entra. Não sabem por quê." },
	{ id = "imortal", name = "Corpo Imortal Ancestral", tier = 7, mult = 8.00, weight = 1,
	  note = "O corpo já era imortal. Faltava alguém morar nele." },
}
Content.constitutions = constitutions

--: Cor por tier, para o HUD e para a animação de rolagem. Uma tabela, para
--: que a roleta, o inventário e o texto sobre a cabeça não discordem.
Content.tierColour = {
	[1] = Color3.fromRGB(158, 160, 168),
	[2] = Color3.fromRGB(126, 196, 140),
	[3] = Color3.fromRGB(92, 164, 232),
	[4] = Color3.fromRGB(150, 122, 232),
	[5] = Color3.fromRGB(226, 158, 70),
	[6] = Color3.fromRGB(232, 96, 112),
	[7] = Color3.fromRGB(246, 214, 96),
	[8] = Color3.fromRGB(250, 250, 250),
}

-- ================================================================= pílulas

--[[
	Pílulas: o sink que fecha o laço.

	Chefes dão pedras, pedras viram pílulas, pílulas multiplicam a meditação.
	Sem isso o combate e o cultivo são dois jogos na mesma tela.

	`seconds` é a duração; `mult` multiplica o ganho enquanto durar. São os
	dois relógios que a tela de origem mostra no canto -- *Qi Verdadeiro* e
	*Treinamento Celestial*, contando para trás.
]]
export type Pill = {
	id: string, name: string, cost: number, seconds: number,
	track: string,       -- "qi" | "corpo" | "ambos"
	mult: number, note: string,
}

Content.pills = {
	{ id = "qi_verdadeiro", name = "Pílula do Qi Verdadeiro", cost = 40,
	  seconds = 300, track = "qi", mult = 2.0,
	  note = "Cinco minutos em que o Qi entra como se você fosse oco." },
	{ id = "treino_celestial", name = "Pílula do Treino Celestial", cost = 40,
	  seconds = 300, track = "corpo", mult = 2.0,
	  note = "O corpo aceita o dobro de castigo e agradece depois." },
	{ id = "nove_giros", name = "Pílula dos Nove Giros", cost = 220,
	  seconds = 420, track = "ambos", mult = 3.0,
	  note = "Nove voltas no caldeirão. Uma a menos e é veneno." },
	{ id = "dissolucao", name = "Pílula da Dissolução", cost = 800,
	  seconds = 600, track = "ambos", mult = 5.5,
	  note = "Dissolve o gargalo. Também dissolve um pouco de você." },
} :: { Pill }

function Content.pill(id: string): Pill?
	for _, pill in Content.pills do
		if pill.id == id then
			return pill
		end
	end
	return nil
end

-- =============================================================== rolagens

--[[
	Preços das rolagens e das travas.

	A trava custa mais que a rolagem de propósito: rolar é esperança, travar é
	uma decisão. Se travar fosse barato ninguém rolaria uma segunda vez.
]]
Content.spins = {
	raiz = { cost = 25, currency = "pedras", name = "Giro de Raiz Espiritual" },
	constituicao = { cost = 25, currency = "pedras", name = "Giro de Constituição" },
}
Content.locks = {
	raiz = { cost = 90, currency = "pedras", name = "Selo de Raiz" },
	constituicao = { cost = 90, currency = "pedras", name = "Selo de Constituição" },
}

-- ================================================================ técnicas

--[[
	Quatro slots, como a tela de origem mostra -- e todos começam em `Nenhum`.

	Vazios de propósito no início: um slot vazio com um número ao lado é a
	pergunta "o que vai aqui", e essa pergunta é o que faz alguém procurar.
]]
Content.techniqueSlots = 4

--[[
	O que cada campo de uma técnica faz, e quem o lê.

	Esta tabela existe porque os campos existiam sem leitor nenhum: equipar
	uma técnica gastava pedras, ocupava um losango e **não mudava um único
	número do jogo**. É exatamente o defeito que apaguei dos `grants` de realm
	-- valor de balanceamento que ninguém consulta é pior que valor ausente,
	porque quem lê a tabela acredita que está valendo.

	Declarar os efeitos aqui, em vez de espalhar quatro `if` pelos sistemas,
	também resolve o próximo: uma técnica nova com um campo novo precisa de uma
	linha nesta tabela e de nada mais.
]]
Content.techniqueEffects = {
	{ field = "qiMult", label = "Qi por tick" },
	{ field = "poder", label = "Dano do golpe" },
	{ field = "saudeMult", label = "Vida máxima" },
	{ field = "velocidade", label = "Velocidade" },
}

--: Como uma técnica se descreve para o jogador. Derivado da mesma tabela, para
--: que uma técnica nunca prometa na tela algo diferente do que aplica.
function Content.techniqueBlurb(technique: any): string
	local parts = {}
	for _, effect in Content.techniqueEffects do
		local value = technique[effect.field]
		if value ~= nil and value ~= 1 then
			table.insert(parts, string.format("%s ×%.2f", effect.label, value))
		end
	end
	if #parts == 0 then
		return "sem efeito"
	end
	return table.concat(parts, "  ·  ")
end

Content.techniques = {
	{ id = "palma_ferro", name = "Palma de Ferro", realm = 1, cost = 60,
	  poder = 1.2, note = "A primeira coisa que qualquer seita ensina." },
	{ id = "passo_vento", name = "Passo do Vento", realm = 2, cost = 240,
	  velocidade = 1.35, note = "Chegar antes é metade de vencer." },
	{ id = "respiracao_abismo", name = "Respiração do Abismo", realm = 3, cost = 1200,
	  qiMult = 1.30, note = "Puxa Qi do que não deveria ter Qi." },
	{ id = "corpo_montanha", name = "Corpo de Montanha", realm = 4, cost = 5000,
	  saudeMult = 1.6, note = "Não desviar também é uma técnica." },
	{ id = "espada_solitaria", name = "Espada Solitária", realm = 5, cost = 22000,
	  poder = 2.4, note = "Um golpe. Se não bastar, não havia segundo." },
	{ id = "renascer_cinzas", name = "Renascer das Cinzas", realm = 7, cost = 260000,
	  saudeMult = 2.2, poder = 1.8, note = "Morrer passa a ser reversível. Uma vez." },
}

-- ========================================================= zonas de treino

--[[
	As zonas, que são o motivo de a montanha ter altura.

	Um cultivo em que só se senta é um protetor de tela. O que o gênero faz --
	em toda manhwa, sem exceção -- é dividir a seita por **rank**: discípulo
	externo treina no pátio, interno no salão, nuclear na caverna, e o ancião
	sobe ao pico. Cada degrau é um lugar melhor para respirar, e é o lugar que
	rende, não o personagem.

	Mecanicamente isso resolve três coisas de uma vez:

	    dá destino    a poça enchendo deixa de ser espera e vira caminhada
	    dá alívio     cada realm rompido abre um lugar que rende mais
	    dá inveja     as zonas são públicas, e ver alguém sentado no Pico é
	                  a única propaganda que este jogo precisa

	`rank` é o realm de Qi exigido. A porta não é uma parede: um discípulo
	externo consegue *entrar* no Salão dos Ancestrais e o Qi denso demais
	simplesmente não entra nele -- a zona não rende nada abaixo do rank, o que
	ensina a regra sem trancar nada.
]]
export type Zone = {
	id: string, name: string, rank: number, mult: number,
	--: Distância do centro e altura. A montanha sobe junto com o rank, e é de
	--: propósito: a zona melhor tem de ser mais longe de tudo.
	radius: number, angle: number, height: number,
	colour: Color3, note: string,
}

Content.zones = {
	{ id = "patio", name = "Pátio dos Discípulos Externos", rank = 1, mult = 1.0,
	  radius = 0, angle = 0, height = 0,
	  colour = Color3.fromRGB(176, 172, 186),
	  note = "O taiji. Onde todo mundo começa e ninguém fica." },
	{ id = "salao", name = "Salão dos Discípulos Internos", rank = 2, mult = 1.9,
	  radius = 205, angle = 0.35, height = 16,
	  colour = Color3.fromRGB(124, 176, 232),
	  note = "Telhado, incenso e silêncio. O primeiro lugar em que te deixam entrar." },
	{ id = "caverna", name = "Caverna do Qi Denso", rank = 3, mult = 3.4,
	  radius = 250, angle = 1.35, height = 34,
	  colour = Color3.fromRGB(132, 226, 196),
	  note = "O ar aqui é grosso. Respirar dói e vale a pena." },
	{ id = "lago", name = "Lago do Espírito Congelado", rank = 4, mult = 6.0,
	  radius = 295, angle = 2.45, height = 52,
	  colour = Color3.fromRGB(158, 214, 246),
	  note = "A água não congela por frio. Congela por concentração." },
	{ id = "poco", name = "Poço do Dragão Adormecido", rank = 5, mult = 10.5,
	  radius = 340, angle = 3.55, height = 74,
	  colour = Color3.fromRGB(226, 158, 70),
	  note = "Algo enorme dorme embaixo. O Qi que sobe é o que ele exala." },
	{ id = "pico", name = "Pico da Tribulação", rank = 7, mult = 19.0,
	  radius = 385, angle = 4.65, height = 104,
	  colour = Color3.fromRGB(232, 110, 118),
	  note = "O raio cai aqui todo dia. Quem senta, senta sabendo." },
	{ id = "ancestral", name = "Salão dos Ancestrais", rank = 9, mult = 34.0,
	  radius = 430, angle = 5.65, height = 142,
	  colour = Color3.fromRGB(246, 214, 96),
	  note = "Nove nomes na parede. O décimo lugar está vago há oitocentos anos." },
} :: { Zone }

function Content.zone(id: string): Zone?
	for _, zone in Content.zones do
		if zone.id == id then
			return zone
		end
	end
	return nil
end

--: O raio em que a zona conta. Um número só, para que a plataforma desenhada
--: e a região testada não possam discordar -- um jogador em cima da pedra e
--: fora da zona é o bug que ninguém consegue descrever.
Content.zoneRadius = 26

-- ======================================================= o corpo, de verdade

--[[
	O que o caminho do corpo faz com o corpo.

	Sem isto o Corpo é uma segunda barra decorativa: sobe, muda um título e não
	muda nada que o jogador sinta. Em qualquer manhwa é o contrário -- quem
	treina o corpo **aguenta mais, corre mais e cai de mais alto**, e é a razão
	de existir um segundo caminho.

	    saúde       exponencial, como o custo. É o número grande da tela.
	    velocidade  aditiva e com teto: um cultivador a 300 studs/s atravessa
	                a montanha antes de ela carregar, e o mundo deixa de
	                existir para ele.
	    salto       idem. O teto aqui é o que separa "pula alto" de "voa sem
	                ter rompido a Formação do Núcleo".

	A constituição multiplica a saúde, não a velocidade: uma constituição rara
	tem de fazer o corpo aguentar, não fazer dele um foguete.
]]
Content.body = {
	baseHealth = 100,
	--: 1.16 por degrau contra um custo de 1.40-1.76: a saúde cresce mais devagar
	--: que o preço do degrau, de propósito. Um corpo que dobra a cada estágio
	--: torna todo dano do jogo irrelevante em dez minutos.
	healthPerStage = 1.16,
	baseSpeed = 16,
	speedPerStage = 0.24,
	maxSpeed = 68,
	baseJump = 50,
	jumpPerStage = 1.0,
	maxJump = 180,

	--[[
		Regeneração, em fração da vida máxima por segundo.

		O script `Health` do Roblox devolve 1% a cada segundo, e com oitenta
		pontos de vida isso é 0,8 por segundo -- um minuto e meio parado depois
		de cada caçada. Dois por cento é o suficiente para o jogador voltar ao
		bosque sem esperar, e continua longe de salvá-lo dentro de uma luta:
		três javalis fazem dezenove por segundo.

		É também um prêmio do caminho do corpo que ninguém precisa explicar --
		quem treinou tem mais vida máxima, logo regenera mais em números
		absolutos, exatamente como o gênero promete.
	]]
	regenPercent = 0.02,
	--: Depois de apanhar, a regeneração espera. Sem essa pausa, curar durante
	--: a briga transforma toda luta perdida numa luta empatada.
	regenDelay = 4.5,
}

--[[
	A flexão: ritmo e amplitude do treino de corpo.

	`hertz` é quantas por segundo. Duas é o ritmo de alguém treinando de
	verdade -- mais rápido lê como um erro de animação, mais lento lê como
	alguém cansado.
]]
Content.pushup = {
	--[[
		Devagar. A 1.9 Hz a flexão era rápida demais para o olho separar a
		descida da subida: virava vibração. Uma flexão de verdade leva perto de
		um segundo e meio, e é nesse ritmo que ela **lê** como flexão.
	]]
	hertz = 0.72,
	--[[
		Quanto o tronco sobe e desce, em studs.

		Dobrado. O que faz alguém reconhecer uma flexão à distância não é o
		cotovelo -- é o **vão entre o peito e o chão** aparecendo e sumindo. A
		0.8 studs esse vão era menor que a espessura do próprio tronco e não
		havia o que ver.
	]]
	amplitude = 1.7,
	--: A altura do tronco no fundo do movimento, acima do chão.
	floor = 1.45,
	--[[
		A inclinação do corpo. Oitenta e dois graus: quase uma prancha.

		A 74 o corpo ficava numa diagonal de dezesseis graus, e uma diagonal lê
		como alguém caindo. Prancha lê como alguém se sustentando -- que é a
		posição inteira.
	]]
	pitch = -82,

	--[[
		Os ângulos das juntas, em graus, do topo ao fundo do movimento.

		Sem eles a "flexão" era um corpo rígido na diagonal subindo e descendo
		-- e a primeira pessoa que olhou disse exatamente isso: ele não está
		usando os braços.

		Os nomes são de `AnimationConstraint` de um rig R15, lidos de um
		personagem vivo e não lembrados: `RightShoulder`, `LeftShoulder`,
		`RightElbow`, `LeftElbow`. O que faz isso funcionar do servidor é que
		escrever `Transform` **replica** -- conferido com foto, porque a
		documentação da casa dizia que não daria.

		`ombro` é fixo: o braço aponta para o chão o tempo todo. Quem se move é
		o **cotovelo**, de quase esticado a bem dobrado, que é onde a flexão
		acontece de verdade.
	]]
	ombro = -74,
	cotoveloAlto = -6,
	cotoveloFundo = -96,
	--[[
		A abertura dos cotovelos, em graus, no fundo do movimento.

		É a correção que faltava. Os ângulos anteriores estavam **certos** e
		mediam certo -- o cotovelo ia de -83° a -88° entre duas leituras a meio
		segundo -- e mesmo assim ninguém via braço nenhum se mexendo: com o
		corpo quase deitado e os braços colados ao tronco, os dois ficavam
		**embaixo** do personagem, escondidos de qualquer câmera normal.

		Abrir os cotovelos para fora põe os braços na silhueta. A leitura de uma
		pose não é o ângulo que ela tem: é o que sobra dela vista de trás.
	]]
	abertura = 26,
	--: O pescoço olha um pouco para a frente em vez de para o chão. É o que
	--: separa alguém treinando de alguém desmaiado.
	pescoco = 26,
}

--: A saúde máxima de um corpo com `stages` degraus e uma dada constituição.
function Content.maxHealth(stages: number, constitutionMult: number): number
	local b = Content.body
	return b.baseHealth * b.healthPerStage ^ (stages - 1) * constitutionMult
end

function Content.walkSpeed(stages: number): number
	local b = Content.body
	return math.min(b.maxSpeed, b.baseSpeed + (stages - 1) * b.speedPerStage)
end

function Content.jumpPower(stages: number): number
	local b = Content.body
	return math.min(b.maxJump, b.baseJump + (stages - 1) * b.jumpPerStage)
end

-- ==================================================================== a aura

--[[
	A aura, que é como o rank se lê de longe.

	Num jogo de cultivo a progressão de outra pessoa tem de ser visível do
	outro lado do pátio, senão o servidor compartilhado não serve para nada. É
	também a única propaganda que o jogo faz de si mesmo: alguém que acabou de
	entrar vê um cultivador de Alma Nascente sentado no Pico com três anéis
	girando e passa a querer aquilo.

	Cada degrau é maior **e mais chamativo** que o anterior -- mais partículas,
	mais luz, mais anéis, e a cor migra de branco para dourado passando por
	azul, jade e rubro. A escada é declarada aqui e não no cliente porque o
	servidor também a lê para decidir o que vale a pena replicar.
]]
export type Aura = {
	from: number, name: string,
	rate: number, size: number, speed: number,
	light: number, range: number,
	rings: number, ringSpeed: number,
	sparks: boolean, pillar: boolean,
	--: A coluna de luz que sobe até o céu. É o que se vê do outro lado da
	--: montanha, e é onde a escada deixa de ser sutil de propósito.
	beam: number,
	--: Pedras orbitando, como as que flutuam em volta de um cultivador de
	--: realm alto em qualquer capítulo do gênero.
	shards: number,
	--: Marca no chão. Um cultivador de rank alto sentado deixa um selo
	--: desenhado embaixo dele, e é o detalhe que faz um pátio parecer ocupado
	--: por alguém importante.
	sigil: number,
	--[[
		As duas trocas de **silhueta**, e não de intensidade.

		Crescer não é trocar. Um patamar que só emite mais partículas que o
		anterior lê como o mesmo cultivador mais perto; o que faz alguém dizer
		"aquele ali é outra coisa" é a forma mudar de lugar no corpo.

		`halo` põe um anel **na cabeça** em vez de só nos pés -- é a leitura
		mais antiga de santidade que existe e não se confunde com nada.
		`crown` levanta os fragmentos para cima da cabeça, em coroa, em vez de
		orbitarem na cintura.
	]]
	halo: boolean,
	crown: boolean,
	colour: Color3,
}

--[[
	A escada de auras.

	Foi refeita para cima, inteira. A primeira versão era discreta -- névoa,
	um halo, um anel -- e discreto é exatamente o oposto do que o gênero faz:
	num manhwa a diferença entre um discípulo externo e um ancião é que o
	segundo **distorce o ar em volta dele** e todo mundo na página para de
	falar. Uma aura que precisa de atenção para ser notada não comunica rank
	nenhum, e rank invisível é a mesma coisa que não ter rank.

	Cada degrau é maior que o anterior em todos os canais ao mesmo tempo:
	partículas, luz, anéis, coluna, pedras orbitando e selo no chão. Seis
	canais e não um, porque o pátio é olhado a trinta studs em luz forte, onde
	só a cor não separa nada.
]]
Content.auras = {
	--[[
		Cada degrau é uma coisa **diferente**, não mais da mesma.

		A primeira escada crescia só em quantidade: mais partículas, mais luz,
		mais um anel. Na tela, um cultivador de Estabelecimento de Fundação era
		indistinguível de um de Refinamento de Qi -- a mesma névoa esbranquiçada
		nos dois, e a foto provou. Rank invisível é a mesma coisa que não ter
		rank.

		Agora cada degrau muda **cor** e **forma**: a cor percorre a escada
		inteira (pálido, ciano, azul, jade, violeta, carmesim, âmbar, ouro) e a
		forma ganha peças que o degrau anterior não tinha -- selo, coluna,
		fragmentos em órbita, um segundo selo girando ao contrário. À distância
		de leitura, cor e silhueta separam; contagem de partículas, não.
	]]
	--: Ciano, não branco-azulado. A 196,220,236 sob material `Neon` o primeiro
	--: degrau saía branco puro na foto -- e branco puro é a cor de "estourou",
	--: não a cor de um rank. Toda a escada precisa começar já colorida para
	--: que o segundo degrau seja visivelmente **outra** cor.
	{ from = 1, name = "Sopro", rate = 16, size = 1.5, speed = 1.6,
	  light = 0.9, range = 14, rings = 0, ringSpeed = 0,
	  sparks = false, pillar = false, beam = 0, shards = 0, sigil = 0,
	  halo = false, crown = false,
	  colour = Color3.fromRGB(116, 194, 228) },
	{ from = 2, name = "Névoa de Qi", rate = 34, size = 2.1, speed = 2.3,
	  light = 1.7, range = 22, rings = 1, ringSpeed = 1.0,
	  sparks = false, pillar = false, beam = 0, shards = 0, sigil = 7,
	  halo = false, crown = false,
	  colour = Color3.fromRGB(88, 214, 238) },
	{ from = 3, name = "Halo do Núcleo", rate = 62, size = 2.8, speed = 3.2,
	  light = 2.6, range = 32, rings = 2, ringSpeed = 1.5,
	  sparks = true, pillar = false, beam = 0, shards = 3, sigil = 9,
	  halo = true, crown = false,
	  colour = Color3.fromRGB(78, 148, 252) },
	{ from = 4, name = "Pressão da Alma", rate = 100, size = 3.4, speed = 4.2,
	  light = 3.4, range = 42, rings = 2, ringSpeed = 2.0,
	  sparks = true, pillar = true, beam = 42, shards = 5, sigil = 11,
	  halo = true, crown = false,
	  colour = Color3.fromRGB(72, 228, 166) },
	{ from = 5, name = "Manto de Alma", rate = 150, size = 4.1, speed = 5.2,
	  light = 4.2, range = 54, rings = 3, ringSpeed = 2.5,
	  sparks = true, pillar = true, beam = 72, shards = 7, sigil = 13,
	  halo = true, crown = false,
	  colour = Color3.fromRGB(170, 116, 252) },
	{ from = 7, name = "Domínio do Vazio", rate = 214, size = 4.9, speed = 6.4,
	  light = 5.2, range = 68, rings = 4, ringSpeed = 3.1,
	  sparks = true, pillar = true, beam = 108, shards = 9, sigil = 15,
	  halo = true, crown = true,
	  colour = Color3.fromRGB(240, 82, 92) },
	{ from = 10, name = "Presságio de Tribulação", rate = 290, size = 5.8,
	  speed = 7.6, light = 6.4, range = 84, rings = 5, ringSpeed = 3.8,
	  sparks = true, pillar = true, beam = 160, shards = 12, sigil = 18,
	  halo = true, crown = true,
	  colour = Color3.fromRGB(252, 168, 54) },
	{ from = 13, name = "Coroa Imortal", rate = 380, size = 6.8, speed = 9.0,
	  light = 7.8, range = 104, rings = 6, ringSpeed = 4.5,
	  sparks = true, pillar = true, beam = 230, shards = 16, sigil = 22,
	  halo = true, crown = true,
	  colour = Color3.fromRGB(255, 230, 146) },
} :: { Aura }

--[[
	A aura de um **degrau**, não de um realm.

	Este é o defeito que sobreviveu a três tentativas de corrigi-lo, e a causa
	era simples e invisível: `auraFor` recebia só o realm. As âncoras estão nos
	realms 1, 2, 3, 4, 5, 7, 10 e 13 -- então do Refinamento de Qi I ao
	Refinamento de Qi X, que são **dez rompimentos**, a aura era byte a byte a
	mesma. O jogador rompia a noite inteira e via exatamente nada.

	Agora há duas escalas, e elas fazem coisas diferentes de propósito:

	    estágio   cresce e muda de cor, continuamente -- todo avanço aparece
	    realm     troca a **forma**: ganha anel, selo, fragmento, coluna

	A cor interpola entre a âncora atual e a próxima, então cada um dos dez
	estágios de um realm desloca o tom um pouco; ao romper o realm, a cor chega
	na âncora seguinte e a forma muda de uma vez. É a diferença entre "está
	subindo" e "virei outra coisa", e o jogo precisa das duas.

	As flags de forma vêm da âncora **atual**, sem interpolar: meio anel não
	existe, e um fragmento que aparece a 30% de opacidade lê como bug.
]]
local function anchorFor(qiRealm: number): (Aura, Aura, number)
	local current, following = Content.auras[1], Content.auras[1]
	for index, aura in Content.auras do
		if qiRealm >= aura.from then
			current = aura
			following = Content.auras[index + 1] or aura
		end
	end
	--: Onde este realm cai entre as duas âncoras. Serve para a cor: dois
	--: realms dentro da mesma faixa (5 e 6, por exemplo) não podem ter
	--: exatamente o mesmo tom, senão a faixa inteira lê como um degrau só.
	local span = math.max(1, following.from - current.from)
	local within = math.clamp((qiRealm - current.from) / span, 0, 1)
	return current, following, within
end

function Content.auraFor(qiRealm: number, qiStage: number?): Aura
	local current, following, within = anchorFor(qiRealm)
	local stage = math.clamp((qiStage or 1) - 1, 0, Content.stagesPerRealm - 1)
		/ (Content.stagesPerRealm - 1)

	--: A mistura da cor anda com o realm **e** com o estágio dentro dele. Um
	--: décimo de faixa por estágio é pouco em cada avanço e muito ao longo de
	--: um realm, que é exatamente o formato de uma progressão longa.
	local blend = math.clamp(within + stage / math.max(1, following.from - current.from), 0, 1)

	--: Os números crescem com o estágio dentro do realm, e chegam ao valor da
	--: próxima âncora no décimo. Assim o último estágio de um realm já é quase
	--: o primeiro do seguinte, e romper é um alívio em vez de um salto.
	local function grow(a: number, b: number): number
		return a + (b - a) * stage
	end

	local aura: Aura = {
		from = current.from,
		--: O nome é o da âncora: é um rótulo de patamar, e mudar de nome a cada
		--: estágio faria dele ruído em vez de identidade.
		name = current.name,
		rate = grow(current.rate, following.rate),
		size = grow(current.size, following.size),
		speed = grow(current.speed, following.speed),
		light = grow(current.light, following.light),
		range = grow(current.range, following.range),
		ringSpeed = grow(current.ringSpeed, following.ringSpeed),
		--: Forma: da âncora atual, sem interpolar. Meio anel não existe.
		rings = current.rings,
		sparks = current.sparks,
		pillar = current.pillar,
		beam = current.beam,
		shards = current.shards,
		sigil = current.sigil,
		halo = current.halo,
		crown = current.crown,
		colour = current.colour:Lerp(following.colour, blend),
	}
	return aura
end

--: O nome do patamar, para a tela. Separado de `auraFor` porque quem quer o
--: rótulo quase nunca quer os vinte números junto.
function Content.auraName(qiRealm: number): string
	local current = anchorFor(qiRealm)
	return current.name
end

--: O corpo tem a própria assinatura: vapor quente em vez de névoa fria. Some
--: com a do Qi em vez de substituí-la, porque quem treina os dois tem de
--: parecer alguém que treinou os dois.
Content.bodyAuraFrom = 3
Content.bodyAuraColour = Color3.fromRGB(244, 136, 74)

-- ================================================================= manuais

--[[
	Manuais de cultivo, que caem de bestas e nunca de uma loja.

	É a peça que fecha o laço do gênero. Pílula é consumo -- acaba, e o que
	sobra é a lembrança de ter gastado. **Manual é permanente**: uma técnica
	arrancada da caverna de uma besta demoníaca multiplica a respiração de quem
	a lê para sempre, e é por isso que em toda manhwa alguém entra na caverna.

	Mecanicamente resolve o problema que este jogo teria sem combate: sem
	manual, matar uma besta paga pedras, e pedra é a mesma coisa que sentar
	mais tempo. Com manual, caçar dá algo que sentar **não dá**, e as duas
	metades do jogo param de competir uma com a outra.

	Os graus são a escada de raridade das manhwas, na ordem canônica:

	    Amarelo    o que qualquer seita externa distribui
	    Misterioso o que uma seita guarda
	    Terrestre  o que um clã esconde
	    Celestial  o que se rouba de um túmulo

	`mult` multiplica a entrada da trilha, para sempre e cumulativamente com
	todos os outros manuais lidos. Cumulativo de propósito: uma coleção que só
	conta o melhor item transforma tudo abaixo do topo em lixo no instante em
	que o topo cai.
]]
export type Manual = {
	id: string, name: string, grade: string, tier: number,
	track: string, mult: number, weight: number, note: string,
}

Content.manualGrades = {
	{ id = "amarelo", name = "Grau Amarelo", colour = Color3.fromRGB(214, 196, 118) },
	{ id = "misterioso", name = "Grau Misterioso", colour = Color3.fromRGB(140, 176, 236) },
	{ id = "terrestre", name = "Grau Terrestre", colour = Color3.fromRGB(198, 134, 88) },
	{ id = "celestial", name = "Grau Celestial", colour = Color3.fromRGB(248, 220, 130) },
}

Content.manuals = {
	{ id = "respiracao_basica", name = "Respiração da Montanha Fria",
	  grade = "amarelo", tier = 1, track = "qi", mult = 1.10, weight = 300,
	  note = "Trinta páginas, e vinte delas ensinam a sentar direito." },
	{ id = "punho_pedra", name = "Punho de Pedra Bruta",
	  grade = "amarelo", tier = 1, track = "corpo", mult = 1.10, weight = 300,
	  note = "Bater numa pedra até a pedra ceder. Funciona." },
	{ id = "sutra_lotus", name = "Sutra do Lótus Silencioso",
	  grade = "misterioso", tier = 2, track = "qi", mult = 1.28, weight = 150,
	  note = "Escrito por um monge que não falou durante quarenta anos." },
	{ id = "forja_sangue", name = "Forja de Sangue e Ferro",
	  grade = "misterioso", tier = 2, track = "corpo", mult = 1.28, weight = 150,
	  note = "Metade do manual é a lista do que fazer quando doer demais." },
	{ id = "nove_ceus", name = "Escritura dos Nove Céus",
	  grade = "terrestre", tier = 3, track = "ambos", mult = 1.42, weight = 52,
	  note = "Nove camadas. Ninguém que a leu inteira voltou para contar." },
	{ id = "veia_dragao", name = "Manual da Veia de Dragão",
	  grade = "terrestre", tier = 3, track = "corpo", mult = 1.60, weight = 38,
	  note = "Ensina a respirar como algo que tem quilômetros de comprimento." },
	{ id = "vazio_absoluto", name = "Cânone do Vazio Absoluto",
	  grade = "celestial", tier = 4, track = "qi", mult = 2.10, weight = 9,
	  note = "As páginas estão em branco. Esse é o cânone." },
	{ id = "corpo_imortal", name = "Registro do Corpo Imortal",
	  grade = "celestial", tier = 4, track = "ambos", mult = 2.40, weight = 4,
	  note = "Arrancado de um caixão que já estava aberto quando chegaram." },
} :: { Manual }

function Content.manual(id: string): Manual?
	for _, manual in Content.manuals do
		if manual.id == id then
			return manual
		end
	end
	return nil
end

function Content.gradeColour(grade: string): Color3
	for _, entry in Content.manualGrades do
		if entry.id == grade then
			return entry.colour
		end
	end
	return Color3.fromRGB(200, 200, 200)
end

-- ================================================================== o karma

--[[
	O Dao Demoníaco: o que matar cultivadores faz com a sua aura.

	É a divisão mais antiga do gênero -- caminho ortodoxo contra caminho
	demoníaco -- e a manhwa nunca a explica com um número. Ela mostra: o
	sujeito entra na sala e a aura dele é **preta**. Todo mundo entende, e
	ninguém precisou ler nada.

	Aqui é literal. A aura de rank escurece a cada jogador morto, e a escada é
	curta de propósito: a diferença entre zero e uma morte tem de ser visível,
	senão a primeira não custa nada. `darkness` é quanto a cor do rank é puxada
	para o quase-preto de `karmaTint`.

	Não é preto puro. Preto puro em `Neon` some contra o chão à noite, e uma
	aura invisível não é uma marca -- é a ausência de uma. O tom é sangue muito
	escuro, que lê como preto e continua tendo silhueta.
]]
Content.karma = {
	{ from = 0, name = "Discípulo Ortodoxo", darkness = 0.0,
	  note = "Suas mãos estão limpas." },
	{ from = 1, name = "Mãos Manchadas", darkness = 0.26,
	  note = "Um cultivador morreu por você. A aura lembra." },
	{ from = 3, name = "Caminho Sombrio", darkness = 0.5,
	  note = "As seitas ortodoxas já sabem o seu nome." },
	{ from = 7, name = "Dao Demoníaco", darkness = 0.74,
	  note = "Você deixou de ser um problema e virou uma categoria." },
	{ from = 15, name = "Soberano do Sangue", darkness = 0.92,
	  note = "Nada em você reflete luz. É assim que se reconhece um." },
}

Content.karmaTint = Color3.fromRGB(26, 4, 10)

--: O degrau de karma para um número de mortes. O maior `from` já alcançado --
--: não um índice, para que inserir um degrau no meio não reescreva os outros.
function Content.karmaFor(kills: number): { [string]: any }
	local chosen = Content.karma[1]
	for _, step in Content.karma do
		if kills >= step.from then
			chosen = step
		end
	end
	return chosen
end

--[[
	Onde não se mata ninguém.

	O pátio da seita é chão sagrado, o que é canônico e também a única coisa
	que impede o jogo de virar um campo de camping em cima do ponto de
	nascimento. Fora dele -- bosque, trilhas, terraços -- todo mundo é
	alcançável.
]]
Content.safeRadius = 150

-- ================================================================== bestas

--[[
	As bestas demoníacas do bosque, e o que elas devem ao jogo.

	Uma besta existe para três coisas, nessa ordem de importância:

	    o manual   o único jeito de ganhar um multiplicador permanente
	    a pedra    o que paga pílula e giro sem obrigar a sentar
	    o motivo   um lugar para gastar o que o caminho do corpo construiu

	`rank` é o realm de Qi a partir do qual ela aparece perto do jogador --
	uma besta de rank alto num pátio de novatos é uma morte que ele não
	entende. `poder` é o dano por golpe e `vida` a resistência; os dois crescem
	junto com a saúde do caminho do corpo, então um cultivador que só meditou
	descobre na primeira mordida por que existem duas barras.
]]
export type Beast = {
	id: string, name: string, rank: number,
	vida: number, poder: number, velocidade: number,
	pedras: number, manualChance: number, manualTier: number,
	colour: Color3, scale: number, shape: string, weapon: string?,
	note: string,
}

Content.beasts = {
	{ id = "lobo_cinza", name = "Lobo das Neblinas", rank = 1,
	  vida = 60, poder = 6, velocidade = 15,
	  pedras = 6, manualChance = 0.16, manualTier = 1,
	  colour = Color3.fromRGB(122, 126, 136), scale = 0.9, shape = "quadruped",
	  note = "Caça em bando e foge sozinho." },
	{ id = "javali_ferro", name = "Javali de Casco de Ferro", rank = 1,
	  vida = 130, poder = 9, velocidade = 12,
	  pedras = 11, manualChance = 0.2, manualTier = 1,
	  colour = Color3.fromRGB(96, 76, 64), scale = 1.1, shape = "quadruped",
	  note = "Não desvia. Nunca desviou de nada." },
	{ id = "macaco_pedra", name = "Macaco de Pedra Antiga", rank = 2,
	  vida = 320, poder = 16, velocidade = 18,
	  pedras = 22, manualChance = 0.24, manualTier = 2,
	  colour = Color3.fromRGB(148, 142, 130), scale = 1.15, shape = "biped",
	  weapon = "staff",
	  note = "Aprendeu a segurar um bastão vendo alguém morrer com um." },
	{ id = "serpente_jade", name = "Serpente de Jade Venenosa", rank = 3,
	  vida = 760, poder = 30, velocidade = 21,
	  pedras = 44, manualChance = 0.28, manualTier = 2,
	  colour = Color3.fromRGB(96, 198, 148), scale = 1.0, shape = "quadruped",
	  note = "O veneno não mata. O que mata é o que ele faz com o Qi." },
	{ id = "tigre_trovao", name = "Tigre do Trovão Branco", rank = 4,
	  vida = 2100, poder = 62, velocidade = 24,
	  pedras = 90, manualChance = 0.3, manualTier = 3,
	  colour = Color3.fromRGB(226, 232, 244), scale = 1.35, shape = "quadruped",
	  note = "O trovão vem antes dele, não depois." },
	{ id = "general_ossos", name = "General de Ossos Amaldiçoado", rank = 5,
	  vida = 7400, poder = 120, velocidade = 17,
	  pedras = 190, manualChance = 0.34, manualTier = 3,
	  colour = Color3.fromRGB(212, 206, 186), scale = 1.5, shape = "biped",
	  weapon = "greatsword",
	  note = "Comandou um exército. Ainda dá ordens para ninguém." },
	{ id = "dragao_carmesim", name = "Dragão Carmesim Ancestral", rank = 7,
	  vida = 42000, poder = 340, velocidade = 26,
	  pedras = 620, manualChance = 0.45, manualTier = 4,
	  colour = Color3.fromRGB(214, 58, 62), scale = 2.1, shape = "hulk",
	  note = "Dorme há mil anos e sabe exatamente quem o acordou." },
} :: { Beast }

function Content.beast(id: string): Beast?
	for _, beast in Content.beasts do
		if beast.id == id then
			return beast
		end
	end
	return nil
end

--: O bosque de caça: onde as bestas nascem, quantas cabem e de quanto em
--: quanto tempo voltam. Números da caça num lugar só, para que o sistema não
--: os invente.
Content.hunt = {
	radius = 250,
	spread = 130,
	angle = 5.1,
	population = 14,
	respawnSeconds = 22,
	--: Alcance do golpe do jogador. Curto de propósito: um alcance generoso
	--: transforma a caça em cliques à distância, e a saúde do caminho do corpo
	--: deixa de significar alguma coisa.
	reach = 16,
	swingSeconds = 0.55,

	--[[
		O raio em que uma besta acorda, e o problema que ele resolve.

		Sem ele, `spread` (130) era o raio de perseguição: **todas as catorze
		bestas da clareira** convergiam no jogador mais próximo assim que ele
		pisava lá dentro. Medido na sessão viva: onze javalis a nove de dano
		cada, contra os oitenta pontos de vida de um cultivador de rank 1. Ele
		morreu antes de dar o primeiro golpe, reapareceu a 354 studs, e os dez
		golpes seguintes acertaram o vazio.

		A trinta e quatro studs você puxa duas ou três, que é o combate que
		esta caça quer ter: entrar, escolher o que pode aguentar, sair.
	]]
	aggro = 34,
	--: A distância que uma besta aceita se afastar de casa antes de voltar.
	--: Sem coleira, uma perseguição atravessa a clareira, o bosque e termina
	--: com um javali no meio da meditação de outro jogador.
	leash = 70,
	--: Quantas podem bater ao mesmo tempo no mesmo alvo. As outras continuam
	--: chegando -- o cerco existe e é assustador -- mas o dano por segundo
	--: para de escalar com o tamanho do bando.
	maxEngaged = 3,
}

--[[
	Quanto o cultivador bate.

	Vem dos dois caminhos, e a proporção é a decisão de projeto: o corpo pesa
	mais porque é o caminho que não tem outro uso. Quem só meditou tem Qi
	enorme e apanha do primeiro javali, o que é exatamente a lição.
]]
Content.strikeFromBody = 1.6
Content.strikeFromQi = 0.7
Content.strikeBase = 9

function Content.strike(bodyStages: number, qiStages: number,
                        manualMult: number): number
	return Content.strikeBase
		* (1 + bodyStages * Content.strikeFromBody + qiStages * Content.strikeFromQi)
		* manualMult
end

-- ================================================================== a loja

--[[
	A loja do pavilhão, e a regra que a mantém honesta.

	**Nada que a loja vende é permanente.** Pílulas, ginsengs, selos: tudo
	consumo. O permanente -- manual, raiz, constituição -- só vem de caçar ou
	de rolar, e é o que impede que ficar sentado juntando pedra compre o jogo
	inteiro.

	`kind` diz o que o item faz quando usado:

	    buff     multiplica a entrada por um tempo
	    instante entrega Qi ou corpo de uma vez, em múltiplos da exigência
	    percep   soma percepção, que melhora a chance da tribulação
]]
export type Item = {
	id: string, name: string, kind: string, cost: number,
	track: string, amount: number, seconds: number?, note: string,
}

Content.items = {
	{ id = "ginseng_centenario", name = "Ginseng Centenário", kind = "instante",
	  cost = 55, track = "qi", amount = 3,
	  note = "Cem anos de montanha numa raiz. Vale três degraus, de uma vez." },
	{ id = "ginseng_milenar", name = "Ginseng Milenar", kind = "instante",
	  cost = 320, track = "qi", amount = 14,
	  note = "Mil anos. Os clãs matam por um e escondem o segundo." },
	{ id = "fruto_sangue", name = "Fruto de Sangue Espiritual", kind = "instante",
	  cost = 70, track = "corpo", amount = 3,
	  note = "Amargo, e o corpo aceita antes da boca." },
	{ id = "medula_dragao", name = "Medula de Dragão", kind = "instante",
	  cost = 380, track = "corpo", amount = 14,
	  note = "Não se come. Se absorve, e leva uma noite inteira." },
	{ id = "incenso_claridade", name = "Incenso da Claridade", kind = "percep",
	  cost = 140, track = "ambos", amount = 1,
	  note = "Não dá Qi. Dá a percepção que faltava para atravessar." },
	--: A saída do caminho demoníaco, e ela é cara. Uma marca que se apaga
	--: barato não é uma marca; uma que não se apaga nunca faz o jogador
	--: abandonar o save em vez de voltar.
	{ id = "purificacao", name = "Pílula da Purificação", kind = "purificar",
	  cost = 900, track = "ambos", amount = 1,
	  note = "Nove dias de jejum comprimidos numa. Apaga uma morte da sua aura." },
} :: { Item }

function Content.item(id: string): Item?
	for _, item in Content.items do
		if item.id == id then
			return item
		end
	end
	return nil
end

-- ================================================================== ícones

--[[
	Os símbolos, e por que não são caracteres Unicode.

	A primeira versão desenhava as ações com `☯ ✧ ◉ ☁`. Num teclado isso lê
	como um jogo de cultivo; numa tela de 1100 pixels lê como um formulário. O
	gênero é ilustrado -- pergaminho, caldeirão, garra, espada -- e um glifo de
	fonte não carrega nada disso.

	`Forge.UI.ItchIcons` traz 77 ícones CC0 **já publicados nesta conta**, o
	que é o detalhe que importa: são os únicos que carregam em runtime. A
	tabela é aqui e não no cliente para que qualquer tela que venha a
	precisar do ícone de uma ação leia o mesmo token.
]]
Content.icons = {
	cultivar = "status.mana",
	treinar = "combat.armor",
	senso = "action.search",
	voar = "combat.speed",
	inventario = "nav.inventory",
	alquimia = "combat.potion",
	destino = "economy.gift",
	tecnicas = "status.medal",
	tabuas = "nav.quest",
	zonas = "nav.map",
	titulo = "status.trophy",
	loja = "nav.shop",
	manuais = "economy.chest",
	pedras = "economy.gem",
	--: A chave é o **id da ação**, `golpe`. Estava escrita `caca`, e o
	--: resultado foi o único botão da barra inferior sem desenho: a busca por
	--: `Content.icons["golpe"]` devolvia nil, o token virava string vazia e o
	--: ícone falhava em silêncio. Um dicionário de ícones cuja chave não é a
	--: chave de quem pergunta é um dicionário vazio com passos extras.
	golpe = "combat.sword",
}

-- ================================================================= ações

--[[
	As quatro ações da barra inferior, com o que cada uma faz.

	Declaradas aqui e não espalhadas pelo cliente, para que o botão, o servidor
	e a dica escrita não possam discordar sobre o que a ação é.
]]
Content.actions = {
	{ id = "cultivar", name = "Cultivar", track = "qi",
	  hint = "Sente-se e respire. O Qi entra por tick." },
	{ id = "treinar", name = "Treinar", track = "corpo",
	  hint = "O corpo sobe com castigo, não com calma." },
	{ id = "golpe", name = "Golpear", track = "nenhum",
	  hint = "Abre a guarda de tudo o que estiver ao alcance." },
	{ id = "senso", name = "Senso de Qi", track = "nenhum",
	  hint = "Revela o que há de espiritual por perto." },
	{ id = "voar", name = "Voar", track = "nenhum",
	  hint = "Concedido na Formação do Núcleo. Antes disso você cai." },
}

--[[
	As **posturas**: as únicas coisas que `SetAction` aceita.

	`Content.actions` é a barra da tela e tem cinco entradas, mas só três delas
	são um estado em que o cultivador fica. Validar `SetAction` contra a barra
	deixava um cliente modificado mandar `action = "voar"` e parar o cultivo de
	graça -- e "senso", que é um efeito instantâneo, virava uma postura em que
	nada entra. Duas listas porque são duas coisas, e confundir as duas foi o
	que abriu o buraco.
]]
Content.stances = { "cultivar", "treinar", "nenhum" }

--[[
	O voo, e por que ele começa na Alma Nascente.

	Cânone do gênero: sobre um núcleo formado um cultivador *plana* com uma
	espada; com uma alma nascente ele **voa**. É também o degrau certo em
	termos de jogo -- quatro de quinze é o meio da escada, tarde o bastante
	para ser uma conquista e cedo o bastante para o jogador ainda estar por
	perto quando ela chega.

	Velocidade e teto crescem com o realm, então voar aos catorze não é voar
	aos quatro. Sem isso a conquista acontece uma vez e nunca mais melhora, e
	um poder que não cresce vira transporte.
]]
Content.flightRealm = 4

Content.flight = {
	baseSpeed = 72,
	speedPerRealm = 16,
	--: Teto de velocidade. Com `StreamingEnabled` ligado, um cultivador rápido
	--: demais voa para dentro de um mundo que ainda não carregou -- e cai
	--: dentro dele.
	maxSpeed = 260,
	--: Altura máxima acima do pátio, também por realm. Voar até o infinito é
	--: como se descobre que o céu é uma textura.
	baseCeiling = 90,
	ceilingPerRealm = 34,
	maxCeiling = 520,
}

function Content.flySpeed(qiRealm: number): number
	local f = Content.flight
	return math.min(f.maxSpeed,
		f.baseSpeed + math.max(0, qiRealm - Content.flightRealm) * f.speedPerRealm)
end

function Content.flyCeiling(qiRealm: number): number
	local f = Content.flight
	return math.min(f.maxCeiling,
		f.baseCeiling + math.max(0, qiRealm - Content.flightRealm) * f.ceilingPerRealm)
end

--[[
	A corrida.

	Um multiplicador sobre a velocidade de caminhada, que já vem do caminho do
	corpo -- então quem treinou corre mais rápido do que quem não treinou, sem
	uma segunda escada para manter. O teto é o mesmo motivo do voo: o mundo
	precisa carregar antes de o jogador chegar nele.
]]
Content.sprint = {
	multiplier = 1.9,
	maxSpeed = 96,
}

function Content.sprintSpeed(walk: number): number
	return math.min(Content.sprint.maxSpeed, walk * Content.sprint.multiplier)
end

-- ================================================================= ganhos

--[[
	A curva, que é a única coisa aqui que decide se o jogo é longo ou chato.

	    ganho = base
	          * multiplicador (raiz/constituição x pílulas)
	          * rendimentoDoCaminho ^ (estágios do próprio caminho - 1)
	          * rendimentoCruzado  ^ (estágios do outro caminho - 1)
	          * rendimentoDeRealm  (acumulado de todos os realms alcançados)

	Por que expoente e não `1 + n * passo`
	--------------------------------------

	O custo **é** exponencial: cada estágio multiplica por `step`, entre 1.42 e
	1.82. Um ganho linear contra um custo exponencial é a parede clássica do
	gênero -- por volta do quarto realm cada estágio passa a demorar o dobro do
	anterior, e o jogo, que não mudou, começa a parecer quebrado.

	Com os dois exponenciais o que importa é a razão entre eles:

	    custo por estágio    x1.42 .. x1.82
	    ganho por estágio    x1.22

	ou seja, cada estágio demora ~16% mais que o anterior, e cada realm
	alcançado devolve 20% de graça no rompimento. Um realm inteiro fica ~1.7x
	mais longo que o anterior: o primeiro sai em minutos, o décimo em horas, e
	nenhum deles em "nunca". É devagar de propósito e nunca é parede.

	O termo cruzado
	---------------

	Treinar o corpo acelera o Qi, e vice-versa, mas a 5% por estágio em vez de
	22%. É o que impede que as duas barras sejam dois jogos na mesma tela sem
	transformar a segunda num atalho para a primeira.
]]
Content.tickSeconds = 1.0
Content.baseQiPerTick = 6
Content.baseBodyPerTick = 4
Content.yieldPerStage = 1.22
Content.crossYieldPerStage = 1.05

--: O rendimento acumulado de todos os realms até `index`, inclusive. Uma
--: função e não um campo por realm, para que acrescentar um realm no meio da
--: escada não exija recalcular a mão os dez que vêm depois.
function Content.realmYield(ladder: { Realm }, index: number): number
	local total = 1.0
	for step = 1, math.min(index, #ladder) do
		local grants = ladder[step].grants
		if grants ~= nil and grants.rendimento ~= nil then
			total *= grants.rendimento
		end
	end
	return total
end

--: O burst manual. Existe para que a meditação tenha algo a fazer com as mãos.
Content.tapGain = 0.55
Content.tapCooldown = 0.12

return Content
