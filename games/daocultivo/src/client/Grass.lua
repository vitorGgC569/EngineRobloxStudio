--!strict
--[[
	Grass — o vento, do lado que desenha.

	A grama nativa do Roblox -- `Terrain.Decoration` -- **não existe nesta
	versão do Studio**, e isso foi conferido propriedade por propriedade
	(`Decoration`, `GrassLength`, `Grass`, `DecorationEnabled`: todas ausentes)
	em vez de suposto. Adivinhar o nome novo teria sido escrever numa
	propriedade inexistente, que nesta engine não dá erro: apenas não faz nada,
	que é o modo de falha mais caro que existe.

	Então o vento é feito à mão. `Mountain.meadow` planta as folhas e guarda em
	cada uma a própria base, o próprio giro e a própria fase; aqui elas são
	lidas uma vez e balançadas.

	Por que isto é do cliente
	-------------------------

	Vento é enfeite puro e precisa de sessenta quadros. Feito no servidor, cada
	folha vira replicação de CFrame por quadro -- quatrocentas folhas contra a
	rede, para produzir exatamente o mesmo pixel que cada cliente desenha de
	graça sozinho. As folhas são ancoradas, então uma escrita local nem sequer
	briga com o servidor: ele não manda CFrame de parte ancorada que não mexe.

	Por que uma rajada e não um seno
	--------------------------------

	Um seno puro faz o campo inteiro ondular junto, o que lê como gelatina. A
	fase por folha quebra isso, e uma segunda onda **lenta e larga**, calculada
	a partir da posição no mundo, faz a rajada atravessar o campo -- que é o que
	vento faz e o que o olho procura sem saber.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Grass = {}

type Leaf = {
	part: BasePart,
	base: Vector3,
	yaw: number,
	half: number,
	phase: number,
}

local leaves: { Leaf } = {}

--: O quanto uma folha se inclina, em radianos, e a velocidade da rajada. Aqui
--: e não em `Content` porque nada além deste arquivo lê: é o único número do
--: jogo que descreve um pixel e mais nada.
local SWAY = 0.30
local SPEED = 1.7
local GUST = 0.014

local function collect(folder: Instance)
	table.clear(leaves)
	for _, part in folder:GetChildren() do
		if not part:IsA("BasePart") then
			continue
		end
		local x = tonumber(part:GetAttribute("baseX"))
		local y = tonumber(part:GetAttribute("baseY"))
		local z = tonumber(part:GetAttribute("baseZ"))
		local yaw = tonumber(part:GetAttribute("giro"))
		local height = tonumber(part:GetAttribute("altura"))
		local phase = tonumber(part:GetAttribute("fase"))
		--: Uma folha sem os atributos é uma folha que o servidor plantou de
		--: outro jeito. Ignorada em vez de adivinhada: o pior resultado
		--: possível aqui é uma folha parada, e o segundo pior é uma folha
		--: girando em torno de um ponto errado no meio do campo.
		if x == nil or y == nil or z == nil or yaw == nil
			or height == nil or phase == nil then
			continue
		end
		table.insert(leaves, {
			part = part,
			base = Vector3.new(x, y, z),
			yaw = yaw,
			half = height / 2,
			phase = phase,
		})
	end
end

function Grass.start()
	local sect = Workspace:WaitForChild("Seita", 30)
	local folder = if sect ~= nil then sect:WaitForChild("Grama", 30) else nil
	if folder == nil then
		--: Sem campo, sem vento. Silencioso de propósito: um cliente que
		--: reclama de cenário ausente enche o console do jogador com um
		--: problema que só o servidor pode resolver.
		return
	end

	collect(folder)
	folder.ChildAdded:Connect(function()
		--: `StreamingEnabled` está ligado, então as folhas chegam e vão embora
		--: conforme o jogador anda. Recolher de novo é mais barato do que
		--: manter um índice correto durante o streaming.
		task.defer(collect, folder)
	end)
	folder.ChildRemoved:Connect(function()
		task.defer(collect, folder)
	end)

	RunService.RenderStepped:Connect(function()
		local now = os.clock()
		for _, leaf in leaves do
			if leaf.part.Parent == nil then
				continue
			end
			--: A rajada: uma onda longa que atravessa o campo em diagonal. É o
			--: termo que faz o vento parecer vir de algum lugar.
			local gust = math.sin((leaf.base.X + leaf.base.Z) * GUST + now * 0.6)
			local tilt = math.sin(now * SPEED + leaf.phase) * SWAY
				+ gust * SWAY * 0.7
			leaf.part.CFrame = CFrame.new(leaf.base)
				* CFrame.Angles(0, leaf.yaw, 0)
				* CFrame.Angles(tilt, 0, tilt * 0.4)
				* CFrame.new(0, leaf.half, 0)
		end
	end)
end

return Grass
