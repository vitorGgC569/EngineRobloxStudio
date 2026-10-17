--!strict
--[[
	daocultivo — bootstrap do servidor.

	Este arquivo liga a engine e mais nada. Toda decisão sobre o que o jogo é
	mora em `systems/`; aqui só existe a ordem em que as coisas sobem, e essa
	ordem importa em três pontos:

	    Wire antes de tudo      os canais têm de existir antes do primeiro
	                            handler, nos dois lados
	    Save antes dos sistemas `Cultivation` restaura de `Save.get` ao dar as
	                            boas-vindas, e um perfil que ainda não carregou
	                            devolve um cultivador zerado por cima de um
	                            salvo -- que é como se apaga a conta de alguém
	                            sem nenhum erro aparecer
	    Debug.ready por último  é o que diz a quem fotografa e mede que o jogo
	                            terminou de começar
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

-- O contrato de engine contra o qual este projeto foi escrito. Mantenha: uma
-- engine que se move debaixo de um jogo falha longe da linha que causou.
Forge.require("0.2.0")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

--: O contrato de rede, definido nesta VM. O cliente dá require no mesmo
--: módulo; não existe arranjo em que um lado tenha canais e o outro não.
require(Shared:WaitForChild("Wire"))

local Rng = Forge.Core.Rng
local Save = Forge.Save
local Debug = Forge.Debug
local Telemetry = Forge.Telemetry

local startedAt = os.clock()

-- 1. Determinismo onde ele pertence: uma semente, fluxos nomeados adiante.
Rng.seed(Config.seed)

-- 2. Contêineres de runtime. Tudo que o jogo cria mora num deles, para que um
--    validador possa contar e uma limpeza possa encontrar.
for _, name in Config.containers do
	if not Workspace:FindFirstChild(name) then
		local folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = Workspace
	end
end

-- 3. Persistência. O template é a forma do save de um cultivador novo, e ele
--    vem de `Cultivation` em vez de ser escrito aqui: dois lugares descrevendo
--    a mesma tabela é como um campo novo deixa de ser preenchido para quem já
--    jogava.
local Cultivation = require(script:WaitForChild("systems"):WaitForChild("Cultivation"))

Save.configure({
	store = Config.saveStore,
	version = 1,
	template = Cultivation.template(),
})
Save.start()

-- 4. Os sistemas. Cada um é um módulo com `start()`.
--
--    A ordem de `GetChildren` não é garantida, então nenhum sistema aqui pode
--    depender de outro já ter startado -- só de conseguir dar `require` nele,
--    o que o cache de módulos garante.
local systems = script:FindFirstChild("systems")
if systems then
	for _, module in systems:GetChildren() do
		if not module:IsA("ModuleScript") then
			continue
		end
		local ok, system = pcall(require, module)
		if not ok then
			Debug.error(string.format("sistema '%s' não carregou: %s",
				module.Name, tostring(system)))
			continue
		end
		if type(system) == "table" and type(system.start) == "function" then
			local started, err = pcall(system.start)
			if not started then
				Debug.error(string.format("sistema '%s' não subiu: %s",
					module.Name, tostring(err)))
			end
		end
	end
end

--[[
	5. A telemetria, e o dreno que ela precisa ter.

	`Telemetry.event` sem nenhum sink registrado enfileira e joga fora. Não dá
	erro, não avisa, e o jogo publicado passa meses "medindo" nada -- que é a
	forma mais cara de não ter dado, porque parece que se tem.

	Em Studio o dreno é a saída: quem está escrevendo o jogo quer ver o evento
	no momento em que ele acontece. Publicado, é o DataStore, que é o único
	destino que este repositório consegue ler de volta sem serviço externo.
]]
Telemetry.start()
if Config.selfTest then
	Telemetry.printSink()
elseif not Telemetry.dataStoreSink() then
	Debug.error("telemetria sem dreno: os eventos estão sendo descartados")
end

--[[
	6. A suíte viva.

	Roda depois de tudo estar de pé, porque uma suíte que começa primeiro
	testa um jogo que ainda não existe. Só em Studio: os cenários criam e
	destroem instâncias de verdade, o que não pertence a uma sessão em que
	alguém está jogando.

	`forge gametest` lê o relatório que isto publica. É a única coisa neste
	projeto capaz de responder "o jogo ainda funciona" sem uma pessoa olhando
	a tela, e precisa desta linha para ter o que ler.
]]
if Config.selfTest then
	task.defer(function()
		local report = Forge.Testing.runAndPublish(
			script:FindFirstChild("tests"), nil, Config.name)
		Debug.info(string.format("suíte: %d passaram, %d falharam, %d travaram",
			report.passed or 0, report.failed or 0, report.timedOut or 0))
	end)
end

-- 7. A costura. É o que deixa o Quality Engine medir significado e não só
--    geometria. Tirar não quebra o jogo; cega o validador, que é pior.
Debug.expose()

Debug.probe("sessao", function()
	return {
		uptime = os.clock() - startedAt,
		jogadores = #Players:GetPlayers(),
		semente = Rng.masterSeed(),
	}
end)

Debug.info(string.format("%s no ar em %.2fs", Config.name, os.clock() - startedAt))
print(string.format("[%s] servidor pronto em %.2fs (semente %d)",
	Config.name, os.clock() - startedAt, Config.seed))

--[[
	8. A última linha, e ela tem de continuar sendo a última.

	Tudo que fotografa, mede ou testa este jogo precisa saber quando ele
	subiu, e sem esta linha cada um adivinha. As adivinhações são todas
	variações de esperar a tela parar de mudar, e erram todas do mesmo jeito:
	um HUD monta os rótulos no primeiro quadro e os preenche conforme as
	respostas chegam, então o observador se dá por satisfeito enquanto o jogo
	ainda está começando.
]]
Debug.ready(Config.name)
