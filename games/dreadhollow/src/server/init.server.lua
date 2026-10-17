--!strict
--- DREADHOLLOW — the sanatorium at the end of the road.
---
--- A survival-horror night built on the engine, not beside it: the figure is
--- `WorldKit.Threat`, the hunt is `GameKit.Pursuit`/`Motion` through
--- `Behaviours.Life`, the lantern/fear economy is player attributes, and every
--- pickup is `Behaviours.Play`. Nothing here trusts the client: pages,
--- lantern, shelter and the gate are all decided on the server.
---
--- The loop: find 6 of 8 pages, keep the lantern fed with batteries or the
--- chapel, and reach the north gate. The Hollow hunts by sight and sound and
--- gives up when it loses you; the chapel is the one room it never enters.
---
--- Validation: STATICALLY_VALIDATED (source reads; no Studio run yet).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")

local Core = require(ReplicatedStorage.Core)
local Behaviours = require(ReplicatedStorage.Behaviours)
local GameKit = require(ReplicatedStorage.GameKit)
local WorldKit = require(ReplicatedStorage.WorldKit)
local TokenData = require(ReplicatedStorage.Shared.TokenData)
local Config = require(ReplicatedStorage.Shared.GameConfig)

local Actions, Events, Timer, Curve = Core.Actions, Core.Events, Core.Timer, Core.Curve
local Spatial, Zone = Core.Spatial, Core.Zone
local Play, Life = Behaviours.Play, Behaviours.Life

local tokens = WorldKit.Tokens.define(TokenData)
local random = Random.new(Config.seed)

-- ------------------------------------------------- SYSTEMS wave: knobs+estado
-- Knobs novos com defaults seguros se GameConfig faltar (nunca indexe direto).
local CFG = (Config :: any)
local OFF_SIGHT_FACTOR: number = tonumber(CFG.lanternOffSightFactor) or 0.35 -- sight ×fator c/ lanterna apagada (~20st a sight 70)
local SANITY_DRAIN: number = tonumber(CFG.sanityDrain) or 4 -- /s com lanterna apagada
local SANITY_SLOW_AT: number = tonumber(CFG.sanitySlowAt) or 30 -- abaixo: WalkSpeed reduzido
local SANITY_REGEN: number = 3 -- /s com lanterna acesa (fora de Config: sem regen o lento seria permanente)
local STAM_MAX: number = tonumber(CFG.staminaMax) or 100
local STAM_DRAIN: number = tonumber(CFG.staminaDrain) or 18 -- /s em sprint
local STAM_REGEN: number = tonumber(CFG.staminaRegen) or 12 -- /s sem sprint
local EXHAUST_SECONDS: number = tonumber(CFG.exhaustSeconds) or 3 -- trava de sprint ao zerar
local HIDE_COOLDOWN: number = tonumber(CFG.hideCooldown) or 20 -- espera p/ esconder de novo
local HIDE_MAX: number = tonumber(CFG.hideMax) or 12 -- teto escondido, depois expulsa
local LOBBY_SECONDS: number = tonumber(CFG.lobbySeconds) or 30
local NIGHT_SECONDS: number = tonumber(CFG.nightSeconds) or 300
local MIN_READY: number = tonumber(CFG.minReady) or 2
local DAWN_SECONDS: number = 15 -- placar do amanhecer
local COUNTDOWN_SECONDS: number = 10 -- LOBBY final antes da noite (Phase segue LOBBY: contrato)
local SPEED_WALK: number = 16
local SPEED_SLOW: number = 12 -- sanidade baixa pesa o passo
local SPEED_SPRINT: number = 22 -- sprint é velocidade do servidor, nunca do cliente
local SPEED_EXHAUST: number = 10 -- trava de exaustão
local NOISE_RADIUS: number = 40 -- NoisePing: audível a 40st por 2s mesmo escondido/apagado
local PING_SECONDS: number = 2
local READ_RANGE: number = 12 -- proximidade p/ ler página / esconder / ready

local phase: string = "LOBBY" -- espelhado no attr Phase de cada jogador
local countdownActive = false
local lobbyElapsed = 0
local lobbyTick: any = nil
local nightHandle: any = nil
local dawnHandle: any = nil
local trickleHandle: any = nil

local sprintIntent: { [Player]: boolean? } = {} -- Shift espelhado (intenção; velocidade o servidor decide)
local pingUntil: { [Player]: number? } = {} -- NoisePing: audível mesmo escondido/apagado
local hideSince: { [Player]: number? } = {} -- dentro do armário desde
local hideNoiseAt: { [Player]: number? } = {} -- último farejo (rolagem 3s/30%)
local hideLocker: { [Player]: BasePart? } = {} -- onde está escondido (saída)
local lastLanternToggle: { [Player]: number? } = {} -- debounce F
local lastReadAt: { [Player]: number? } = {} -- debounce Ler
local exhaustUntil: { [Player]: number? } = {} -- trava de sprint
local chaseTarget: { [Model]: Player? } = {} -- quem cada Hollow persegue (espelho via onSpotted)
local suppressed: { [Model]: boolean? } = {} -- patrol forçado pelo filtro stealth

local LOBBY_CENTRE: Vector3 = Vector3.new(0, 0, 150) -- saguão fora da arena (plataforma própria)
local LOBBY_SPAWN_AT: Vector3 = Vector3.new(0, 1, 150)
local ENTRANCE_AT: Vector3 = Vector3.new(0, 1, 95)
local entranceSpawn: SpawnLocation? = nil -- o "Entrance" do file-scope (toggle por fase)
local lobbySpawn: SpawnLocation? = nil -- criado na seção do loop

local function hrpOf(player: Player): BasePart?
	local character = player.Character
	if character == nil then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root ~= nil and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function aliveChar(player: Player): (Model?, Humanoid?)
	local character = player.Character
	if character == nil then
		return nil, nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 then
		return nil, nil
	end
	return character, humanoid
end

local function noisePing(player: Player, seconds: number) -- ruído realerta guards próximos
	pingUntil[player] = math.max(pingUntil[player] or 0, os.clock() + seconds)
end

local function setPhaseAll(value: string) -- Phase global espelhada em attr (client-ux lê player.Phase)
	phase = value
	for _, other in ipairs(Players:GetPlayers()) do
		Actions.set(other, "Phase", value)
	end
end

-- Remotes (servidor cria; @client-ux: F→DreadLantern, Shift→DreadSprint(bool), Ready→DreadReady, DreadPage é s2c).
local function makeRemote(name: string): RemoteEvent
	local found = ReplicatedStorage:FindFirstChild(name)
	if found ~= nil and found:IsA("RemoteEvent") then
		return found
	end
	local event = Instance.new("RemoteEvent")
	event.Name = name
	event.Parent = ReplicatedStorage
	return event
end
local lanternRemote = makeRemote("DreadLantern")
local sprintRemote = makeRemote("DreadSprint")
local readyRemote = makeRemote("DreadReady")
local pageRemote = makeRemote("DreadPage")

local PageTexts: any = nil -- tabela [1..8] {title, body}; nil = fallback "(texto indisponível)"
do
	local found = ReplicatedStorage.Shared:FindFirstChild("PageTexts")
	if found ~= nil and found:IsA("ModuleScript") then
		local ok, mod: any = pcall(function()
			return require(found)
		end)
		if ok then
			PageTexts = mod
		end
	end
end

-- ------------------------------------------------------------------ the night
-- Fixed dead-of-night. No day cycle: a horror game that brightens up on a
-- timer is a horror game that negotiated with its own premise.
-- Runtime manda: o project.json não segura a noite sozinho, então tudo
-- abaixo é setado explícito (Fog SEM FogColor lava para cinza-claro).
-- pacote crítico-R10 (frame Play Solo real: torre invisível, leak interno
-- do Bell 200): Outdoor 55,62,82, Fog 60→400, Bell 80/2.0, sino + spire
-- Neon 255,190,120. Espelhado no default.project.json (preview Edit = runtime).

Lighting.ClockTime = 0
Lighting.Brightness = 2
Lighting.Ambient = Color3.fromRGB(50, 55, 75)
Lighting.OutdoorAmbient = Color3.fromRGB(55, 62, 82)
Lighting.FogColor = Color3.fromRGB(18, 22, 35)
Lighting.FogStart = 60
Lighting.FogEnd = 400
-- Technology vem do default.project.json (Future); setar em runtime exige
-- capability de plugin e aborta este Script top-level.
Lighting.GlobalShadows = true

local atmosphere = Instance.new("Atmosphere")
atmosphere.Name = "DreadAtmosphere"
atmosphere.Density = 0.25
atmosphere.Offset = 0.15
atmosphere.Color = Color3.fromRGB(12, 14, 24)
atmosphere.Decay = Color3.fromRGB(8, 10, 18)
atmosphere.Glare = 0.25
atmosphere.Haze = 0.6
atmosphere.Parent = Lighting

local bloom = Instance.new("BloomEffect")
bloom.Name = "DreadBloom"
bloom.Intensity = 0.6
bloom.Size = 32
bloom.Threshold = 0.85
bloom.Parent = Lighting

local grade = Instance.new("ColorCorrectionEffect")
grade.Name = "DreadGrade"
grade.Brightness = 0
grade.Contrast = 0.08
grade.Saturation = -0.15
grade.TintColor = Color3.fromRGB(200, 210, 230)
grade.Parent = Lighting

-- ------------------------------------------------------------------ builders

local DREAD = Instance.new("Folder")
DREAD.Name = "Dreadhollow"
DREAD.Parent = workspace

local function part(name: string, size: Vector3, position: Vector3, role: string): Part
	local swatch = tokens:swatch(role)
	local built = Instance.new("Part")
	built.Name = name
	built.Size = size
	built.Position = position
	built.Anchored = true
	built.TopSurface = Enum.SurfaceType.Smooth
	built.BottomSurface = Enum.SurfaceType.Smooth
	built.Color = swatch.color
	built.Material = swatch.material
	built.Parent = DREAD
	return built
end

--- A wall run with one door gap. Openings are 8 studs wide (grammar
--- doorWidth) so the navmesh reads them as passages, not walls.
local function wallRun(name: string, from: Vector3, to: Vector3, height: number, gapAt: number?, role: string)
	local direction = (to - from)
	local length = direction.Magnitude
	local unit = if length > 0 then direction / length else Vector3.xAxis
	local centre = (from + to) / 2
	local gapWidth = tokens:grammar("doorWidth")
	if gapAt == nil then
		part(name, Vector3.new(2, height, length), centre + Vector3.new(0, height / 2, 0), role).Rotation =
			Vector3.new(0, math.deg(math.atan2(-unit.X, -unit.Z)), 0)
		return
	end
	local gapCentre = from + unit * (gapAt :: number)
	local firstLength = (gapAt :: number) - gapWidth / 2
	local secondStart = (gapAt :: number) + gapWidth / 2
	local secondLength = length - secondStart
	local yaw = math.deg(math.atan2(-unit.X, -unit.Z))
	if firstLength > 0.5 then
		local first = part(name .. "A", Vector3.new(2, height, firstLength), from + unit * (firstLength / 2) + Vector3.new(0, height / 2, 0), role)
		first.Rotation = Vector3.new(0, yaw, 0)
	end
	if secondLength > 0.5 then
		local second = part(name .. "B", Vector3.new(2, height, secondLength), from + unit * (secondStart + secondLength / 2) + Vector3.new(0, height / 2, 0), role)
		second.Rotation = Vector3.new(0, yaw, 0)
	end
	-- Lintel above the doorway: reads as a door, keeps the silhouette whole.
	local lintel = part(name .. "Lintel", Vector3.new(2, height - tokens:grammar("doorHeight"), gapWidth), gapCentre + Vector3.new(0, (height + tokens:grammar("doorHeight")) / 2, 0), role)
	lintel.Rotation = Vector3.new(0, yaw, 0)
	_ = centre
end

-- ------------------------------------------------------------------ the grounds

local HALF = Config.arenaSize / 2 -- 110

local ground = part("Ground", Vector3.new(Config.arenaSize, 4, Config.arenaSize), Vector3.new(0, -2, 0), "ground")
-- NOTE: sem override de Material — o Slate do token `ground` segura a noite;
-- Grass lavava o chão para lavanda sob o Fog.
_ = ground

-- Perimeter: three solid sides, gate gap in the north wall.
wallRun("WallSouth", Vector3.new(-HALF, 0, HALF), Vector3.new(HALF, 0, HALF), 16, nil, "stone")
wallRun("WallWest", Vector3.new(-HALF, 0, -HALF), Vector3.new(-HALF, 0, HALF), 16, nil, "stone")
wallRun("WallEast", Vector3.new(HALF, 0, -HALF), Vector3.new(HALF, 0, HALF), 16, nil, "stone")
wallRun("WallNorth", Vector3.new(-HALF, 0, -HALF), Vector3.new(HALF, 0, -HALF), 16, HALF, "stone")

-- Bell tower: the landmark. A player must be able to navigate by looking.
local tower = part("BellTower", Vector3.new(10, 34, 10), Vector3.new(0, 17, -20), "stone")
tower:SetAttribute("WorldKitRole", "landmark")
-- Belfry aberto: 4 pilares escuros + vão livre + sino ink + spire piramidal
-- escura. O vão fica aberto de propósito — o escuro da noite é o fundo, não
-- uma tampa sólida (a antiga caixa sólida lia como "tampa azul").
for _, ox in ipairs({ -4.5, 4.5 }) do
	for _, oz in ipairs({ -4.5, 4.5 }) do
		local pillar = part("BelfryPillar", Vector3.new(2, 6, 2), Vector3.new(ox, 37, -20 + oz), "slate")
		pillar.CanCollide = false
	end
end
local bell = part("Bell", Vector3.new(3, 3, 3), Vector3.new(0, 36.5, -20), "ink")
bell.CanCollide = false
bell.Material = Enum.Material.Neon
bell.Color = Color3.fromRGB(255, 190, 120)
local spire = part("Spire", Vector3.new(13, 6, 13), Vector3.new(0, 43, -20), "slate")
spire.CanCollide = false
spire.Material = Enum.Material.Neon
spire.Color = Color3.fromRGB(255, 190, 120)
local spireMesh = Instance.new("SpecialMesh")
spireMesh.Name = "Pyramid"
spireMesh.MeshType = Enum.MeshType.Pyramid
spireMesh.Parent = spire
local bellLight = Instance.new("PointLight")
bellLight.Name = "BellLight"
bellLight.Range = 80
bellLight.Brightness = 2.0
bellLight.Shadows = false -- halo ancora, não projeta (R7)
bellLight.Color = Color3.fromRGB(255, 190, 120)
bellLight.Parent = bell

-- Dead trees: troncos 4.5 + 2 galhos simples cada, seedados para o mapa não
-- derivar entre runs (14 galhos no total).
for index = 1, 7 do
	local angle = random:NextNumber(0, math.pi * 2)
	local radius = random:NextNumber(45, 95)
	local at = Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius - 10)
	local height = random:NextNumber(10, 16)
	local trunk = part(("DeadTree%d"):format(index), Vector3.new(4.5, height, 4.5), at + Vector3.new(0, height / 2, 0), "wood")
	trunk.CanCollide = false
	for branch = 1, 2 do
		local side = if branch == 1 then 1 else -1
		local limb = part(("DeadBranch%d_%d"):format(index, branch), Vector3.new(3.5, 1, 1), at + Vector3.new(side * 2.5, height - random:NextNumber(2, 4), 0), "wood")
		limb.CanCollide = false
		limb.Rotation = Vector3.new(0, random:NextNumber(0, 180), side * 30)
	end
end

-- Pátio: escombros/lápides/cercas seedados fora de rotas e portas (|x| 12..28,
-- z -50..10: fora do eixo x≈0, da torre, da capela e do hall). Orçamento:
-- 6 lápides + 8 cerca = 14 parts; com os galhos, 28 novas no total (<40).
for index = 1, 6 do
	local side = if random:NextInteger(0, 1) == 0 then -1 else 1
	local spot = Vector3.new(side * random:NextNumber(12, 28), 0, random:NextNumber(-50, 10))
	local role = if index % 2 == 0 then "slate" else "stone"
	local slab = part(("Rubble%d"):format(index), Vector3.new(2, random:NextNumber(1.5, 3), 1), spot + Vector3.new(0, 1, 0), role)
	slab.CanCollide = false
	slab.Rotation = Vector3.new(random:NextNumber(-8, 8), random:NextNumber(0, 180), random:NextNumber(-8, 8))
end
for _, side in ipairs({ -1, 1 }) do
	for _, z in ipairs({ -30, -20, -10 }) do
		local post = part(("Fence%d_%d"):format(side, z), Vector3.new(1, 3, 1), Vector3.new(side * 18, 1.5, z), "wood")
		post.CanCollide = false
	end
	local rail = part(("FenceRail%d"):format(side), Vector3.new(1, 1, 22), Vector3.new(side * 18, 2.2, -20), "wood")
	rail.CanCollide = false
end

-- Breadcrumbs do pátio (R8/R14): 2 lampiões FRIIOS via role mosslight, fora de
-- rotas/portas (|x|=22 fora do eixo x≈0; z -38/+2 fora de torre/capela/hall/
-- wards). Orçamento: 4 parts + 2 lights (teto 6+2). R14 (frame real):
-- âmbar-triplo Bell/HallLamp/Lamp se canibalizava; seguro-âmbar é SÓ
-- capela/portão/sino. HallLamp interno segue âmbar quente por intenção
-- (feature R11) — só o pátio vai p/ frio. Sem luz nova, sem retune.
local lampHeadRole = if tokens:hasRole("mosslight") then "mosslight" else "bone"
for _, spot in ipairs({ Vector3.new(-22, 0, -38), Vector3.new(12, 0, 20) }) do
	local post = part(("LampPost_%d_%d"):format(spot.X, spot.Z), Vector3.new(1, 7, 1), spot + Vector3.new(0, 3.5, 0), "wood")
	post.CanCollide = false
	local head = part(("LampHead_%d_%d"):format(spot.X, spot.Z), Vector3.new(1.5, 1, 1.5), spot + Vector3.new(0, 7.2, 0), lampHeadRole)
	head.CanCollide = false
	head.Material = Enum.Material.Neon
	local lamp = Instance.new("PointLight")
	lamp.Name = ("Lamp_%d_%d"):format(spot.X, spot.Z)
	lamp.Range = 22
	lamp.Brightness = 1.0
	lamp.Shadows = false
	lamp.Color = Color3.fromRGB(170, 200, 160)
	lamp.Parent = head
end

-- ------------------------------------------------------------------ the hall
-- Main hall 60x40 at (0,0,40): doors south (entrance) and north (courtyard).

local function room(name: string, centre: Vector3, width: number, depth: number, height: number, doorSides: { string })
	local x0, x1 = centre.X - width / 2, centre.X + width / 2
	local z0, z1 = centre.Z - depth / 2, centre.Z + depth / 2
	local southGap: number? = if table.find(doorSides, "south") ~= nil then width / 2 else nil
	local northGap: number? = if table.find(doorSides, "north") ~= nil then width / 2 else nil
	local westGap: number? = if table.find(doorSides, "west") ~= nil then depth / 2 else nil
	local eastGap: number? = if table.find(doorSides, "east") ~= nil then depth / 2 else nil
	wallRun(name .. "South", Vector3.new(x0, 0, z1), Vector3.new(x1, 0, z1), height, southGap, "stone")
	wallRun(name .. "North", Vector3.new(x0, 0, z0), Vector3.new(x1, 0, z0), height, northGap, "stone")
	wallRun(name .. "West", Vector3.new(x0, 0, z0), Vector3.new(x0, 0, z1), height, westGap, "stone")
	wallRun(name .. "East", Vector3.new(x1, 0, z0), Vector3.new(x1, 0, z1), height, eastGap, "stone")
	local roof = part(name .. "Roof", Vector3.new(width + 4, 1, depth + 4), centre + Vector3.new(0, height + 0.5, 0), "slate")
	roof.CanCollide = false
	part(name .. "Floor", Vector3.new(width, 0.4, depth), centre + Vector3.new(0, 0.2, 0), "ground")
end

room("Hall", Vector3.new(0, 0, 40), 60, 40, 12, { "south", "north" })
-- R11 (frame real): vão do Hall quente aceso sem PointLight declarada no Hall
-- — leak de luz sem sombra através de parede: BellLight (0,36.5,-20, Range 80,
-- Shadows=false) alcança o Hall (porta norte a 40st) e LampHead (12,7.2,20)
-- está embutido no plano de HallNorth (z=20, x 4..30). Eliminar exigiria
-- retune de Bell/Lighting (proibido) ou Shadows=true num Range 80 (caro).
-- DECISÃO: ASSUMIR como feature — 1 PointLight âmbar fraca Range<=26 DENTRO
-- do Hall equaliza o vão por intenção, não por acidente.
local hallLampHead = part("HallLamp", Vector3.new(1.5, 1, 1.5), Vector3.new(6, 9, 40), "bone")
hallLampHead.CanCollide = false
hallLampHead.Material = Enum.Material.Neon
local hallLamp = Instance.new("PointLight")
hallLamp.Name = "HallLamp"
hallLamp.Range = 22
hallLamp.Brightness = 1.0
hallLamp.Shadows = false
hallLamp.Color = Color3.fromRGB(255, 190, 120)
hallLamp.Parent = hallLampHead
room("WardA", Vector3.new(-60, 0, 0), 40, 30, 12, { "east" })
room("WardB", Vector3.new(60, 0, 0), 40, 30, 12, { "west" })

-- Chapel 30x24 at (0,0,-70): the one safe room. Pale stone reads as safety.
room("Chapel", Vector3.new(0, 0, -70), 30, 24, 12, { "south" })
local altar = part("Altar", Vector3.new(8, 3, 4), Vector3.new(0, 1.5, -78), "bone")
altar.CanCollide = false
for index = 1, 2 do
	local candle = part(("Candle%d"):format(index), Vector3.new(0.6, 1.5, 0.6), Vector3.new(-2 + index * 4 - 2, 3.75, -78), "bone")
	candle.CanCollide = false
	local flame = Instance.new("PointLight")
	flame.Name = ("Flame%d"):format(index)
	flame.Range = 26
	flame.Brightness = 1.4
	flame.Color = Color3.fromRGB(255, 190, 120)
	flame.Parent = candle
end

-- Candle flicker: the only animated light besides the lantern. Cheap on
-- purpose — two lights on a shared beat, not a script per flame.
local flickerSeed = 0
Timer.every(0.12, function()
	flickerSeed += 1
	bellLight.Brightness = 2.0 + 0.4 * math.sin(flickerSeed * 0.9)
	for _, item in ipairs(DREAD:GetChildren()) do
		if item:IsA("Part") and string.sub(item.Name, 1, 6) == "Candle" then
			local flame = item:FindFirstChildOfClass("PointLight")
			if flame ~= nil then
				flame.Brightness = 1.3 + 0.25 * math.sin(flickerSeed * 1.7 + item.Position.X)
			end
		end
	end
end, "candle-flicker")

-- The gate: barrier plus seal in the north wall, landing beyond it.
local barrier = part("GateBarrier", Vector3.new(8, 10, 1.5), Vector3.new(0, 5, -HALF), "wood")
local seal = part("GateSeal", Vector3.new(2, 2, 0.4), Vector3.new(0, 7, -HALF + 1), "accentDanger")
seal.CanCollide = false
seal.Material = Enum.Material.Neon
local landing = part("Landing", Vector3.new(24, 4, 20), Vector3.new(0, -2, -HALF - 10), "ground")
landing.CanCollide = true
local winPad = part("EscapePad", Vector3.new(10, 1, 8), Vector3.new(0, 0.5, -HALF - 10), "bone")
winPad.CanCollide = false
winPad.Transparency = 0.4
local gateLight = Instance.new("PointLight")
gateLight.Name = "GateLight"
gateLight.Range = 40
gateLight.Brightness = 2.0
gateLight.Color = Color3.fromRGB(255, 190, 120)
gateLight.Parent = winPad

-- Entrance spawn.
local spawn = Instance.new("SpawnLocation")
spawn.Name = "Entrance"
spawn.Size = Vector3.new(6, 1, 6)
spawn.Position = Vector3.new(0, 1, 95)
spawn.Anchored = true
spawn.Neutral = true
spawn.Duration = 0
-- R7: spawn olha o norte — personagem nasce encarando a torre (0,4,-20),
-- sem yaw chutado; CFrame.lookAt deriva a orientação do alvo.
spawn.CFrame = CFrame.lookAt(spawn.Position, Vector3.new(0, 4, -20))
spawn.Parent = DREAD

-- ------------------------------------------------------------------ pages
-- Eight pages, six needed: no single page can soft-lock the run. Pages are
-- small and pale, and they sit where the lantern beam actually reaches.

local pageSpots = {
	Vector3.new(-20, 2, 45), Vector3.new(20, 2, 32), -- hall
	Vector3.new(-68, 2, 6), Vector3.new(-52, 2, -6), -- ward A
	Vector3.new(68, 2, 6), Vector3.new(52, 2, -6), -- ward B
	Vector3.new(8, 2, -70), -- chapel: safety, but only one page
	Vector3.new(12, 2, -20), -- courtyard, by the tower
}

local collectedTotal = 0

local function remainingPages(): number
	return #pageSpots - collectedTotal
end

-- Late-join guard (ledger R2→R3.1): pages are singleton (8 world, 6 to win),
-- so a pre-escape late-joiner with 0 pages can face <6 remaining and never
-- win alone. Chosen fix: direct (this notify), NOT a hall respawn — minting
-- pages inflates the workspace and contradicts the singleton economy, while
-- the seal-break below already opens the gate for everyone once one player
-- escapes. AdvisedFollow fires once per player so this never spams.
local function adviseLateJoiner(player: Player)
	if Actions.get(player, "Pages", 0) ~= 0 then
		return
	end
	if Actions.get(player, "AdvisedFollow", false) == true then
		return
	end
	if remainingPages() < Config.pagesToWin then
		Actions.set(player, "AdvisedFollow", true)
		Actions.notify(player, "Siga quem tem páginas — o selo abre para todos.", { kind = "page" })
	end
end

-- Páginas 3x4 pálidas, SEM luz própria: 8 PointLights matariam a noite e o
-- orçamento — legibilidade vem do tamanho + Bloom 0.6, não de luz por página.
local function buildPages() -- noite nova, páginas novas (singleton por run; ler ≠ coletar)
	for _, old in ipairs(DREAD:GetChildren()) do
		if old:IsA("BasePart") and string.sub(old.Name, 1, 4) == "Page" then
			old:Destroy()
		end
	end
	collectedTotal = 0
	for index, at in ipairs(pageSpots) do
	local page = part(("Page%d"):format(index), Vector3.new(3, 4, 0.2), at, "paper")
	page.CanCollide = false
	if index <= 2 then
		page.Orientation = Vector3.new(0, 0, 0)
	end
	local handle = Play.pickup(page, { currency = "Pages", amount = 1, spin = index > 2 })
	handle.collected:connect(function(player)
		collectedTotal += 1
		local have = Actions.get(player, "Pages", 0)
		Actions.notify(player, ("Página %d de %d — o portão quer %d"):format(have, Config.pagesToWin, Config.pagesToWin), { kind = "page" })
		if have >= Config.pagesToWin then
			Actions.notify(player, "O selo quebrou. CORRA ao portão norte.", { kind = "escape" })
		end
		if remainingPages() < Config.pagesToWin then
			for _, other in ipairs(Players:GetPlayers()) do
				if other ~= player then
					adviseLateJoiner(other)
				end
			end
		end
	end)
		-- Ler: prompt curto devolve PageTexts[i] SÓ p/ quem leu (FireClient); coletar segue onTouch.
		-- Handler não captura `page` (só index/pos): página destruída = conexão coletável, sem leak por noite.
		Events.onPrompt(page, function(reader, _prompt)
			if reader == nil then
				return
			end
			local now = os.clock()
			if now - (lastReadAt[reader] or -10) < 1 then
				return -- debounce Ler
			end
			lastReadAt[reader] = now
			if Actions.get(reader, "Hidden", false) == true then
				return -- escondido não lê
			end
			local root = hrpOf(reader)
			if root == nil or (root.Position - at).Magnitude > READ_RANGE + 2 then
				return -- proximidade validada no servidor
			end
			local entry = if PageTexts ~= nil then PageTexts[index] else nil
			local title = if entry ~= nil and entry.title ~= nil then tostring(entry.title) else ("Página %d"):format(index)
			local body = if entry ~= nil and entry.body ~= nil then tostring(entry.body) else "(texto indisponível)"
			pageRemote:FireClient(reader, index, title, body)
		end, { label = "Página", action = "Ler", holdTime = 0.5, range = READ_RANGE })
	end
end

-- ------------------------------------------------------------------ batteries
-- Economy (GameConfig, do not retune here): 5 cells, +40 Lantern each,
-- LanternMax 100, drain 1.4/s unsheltered, respawn 30s.
-- Ring formula holds for any N: angle steps of 2*pi/N on radius 55 around
-- (0,-10) stay inside the 220 arena with ~69 studs of spacing at N=5.
-- Intentionally raw Events.onTouch, NOT Play.pickup: pickup adds with no max
-- clamp, but the lantern needs { min = 0, max = lanternMax } plus a
-- full-lantern refuse; cooldown is `available` + Transparency/CanTouch while
-- invisible so a farmed cell can never be touched on cooldown.
-- Pulso da bateria adiado p/ depois: exigiria Timer/luz extra por célula;
-- legibilidade vem do Neon + Bloom 0.6 por enquanto.

-- R8: baterias fora do âmbar via role "mosslight" (@world-art); fallback
-- cobre ordem de edição — mosslight ainda não está no disco, então
-- hasRole devolve false e segura lanternGlow. Tokens.define FALHA em role
-- desconhecido, por isso o branch é obrigatório, não opcional.
local cellRole = if tokens:hasRole("mosslight") then "mosslight" else "lanternGlow"
local function buildBatteries() -- noite nova, células recarregadas (respawn de 30s segue valendo)
	for _, old in ipairs(DREAD:GetChildren()) do
		if old:IsA("BasePart") and string.sub(old.Name, 1, 7) == "Battery" then
			old:Destroy()
		end
	end
	for index = 1, Config.batteryCount do
	local angle = (index / Config.batteryCount) * math.pi * 2 + 0.4
	local at = Vector3.new(math.cos(angle) * 55, 2, math.sin(angle) * 55 - 10)
	local cell = part(("Battery%d"):format(index), Vector3.new(1.2, 2.0, 1.2), at, cellRole)
	cell.CanCollide = false
	cell.Material = Enum.Material.Neon
	cell.Transparency = 0.15
	local available = true
	Events.onTouch(cell, function(_, player)
		if player == nil then
			return
		end
		if not available then
			return
		end
		if cell.CanTouch == false then
			return
		end
		if Actions.get(player, "Lantern", 0) >= Config.lanternMax then
			Actions.notify(player, "Lanterna cheia — guarde a bateria para o escuro.")
			return
		end
		Actions.add(player, "Lantern", Config.batteryGives, { min = 0, max = Config.lanternMax })
		Actions.notify(player, "Bateria: lanterna recarregada.")
		available = false
		cell.Transparency = 1
		cell.CanTouch = false
		Timer.after(Config.batteryRespawn, function()
			cell.Transparency = 0.15
			cell.CanTouch = true
			available = true
		end)
	end, { debounce = 1 })
	end
end

buildBatteries()

-- ------------------------------------------------------------------ chapel
-- The one safe room: the lantern recovers here and fear cannot touch you.

local chapelZone = Zone.new(Vector3.new(0, 6, -70), Vector3.new(34, 14, 28), {})
chapelZone.entered:connect(function(_, player)
	if player ~= nil then
		Actions.set(player, "Sheltered", true)
		Actions.notify(player, "A capela. Ele não entra aqui.")
	end
end)
chapelZone.left:connect(function(_, player)
	if player ~= nil then
		Actions.set(player, "Sheltered", false)
	end
end)

-- ------------------------------------------------------------------ the gate
-- sealBroken is the multiplayer anti-softlock: pages are world-singleton
-- pickups, so two players can never each hold 6 of 8. Once the first
-- player breaks the seal, everyone else can run through freely.

local sealBroken = false

Events.onTouch(winPad, function(_, player)
	if player == nil then
		return
	end
	if Actions.get(player, "Won", false) == true then
		return
	end
	if sealBroken then
		Actions.set(player, "Won", true)
		Actions.add(player, "Escapes", 1)
		Actions.notify(player, "VOCÊ ESCAPOU DE DREADHOLLOW.", { kind = "escape" })
		return
	end
	local have = Actions.get(player, "Pages", 0)
	if have < Config.pagesToWin then
		Actions.notify(player, ("O portão exige %d páginas. Você tem %d."):format(Config.pagesToWin, have), { kind = "locked" })
		return
	end
	Actions.set(player, "Won", true)
	Actions.add(player, "Escapes", 1) -- Escapes++ no escape (placar do DAWN)
	Actions.add(player, "Lantern", Config.lanternMax, { min = 0, max = Config.lanternMax })
	Actions.notify(player, "VOCÊ ESCAPOU DE DREADHOLLOW.", { kind = "escape" })
	sealBroken = true
	if barrier.Parent ~= nil then
		barrier.CanCollide = false
		barrier.Transparency = 0.7
		seal:Destroy()
		for _, other in ipairs(Players:GetPlayers()) do
			if other ~= player and Actions.get(other, "Won", false) ~= true then
				Actions.notify(other, "O selo do portão quebrou. Fujam — o portão está aberto!", { kind = "escape" })
			end
		end
	end
end, { debounce = 2 })

-- ------------------------------------------------------------------ players

-- Client contract (@client-ux): PagesToWin/LanternMax are published here so
-- the HUD never hardcodes them. Fallback if absent: PagesToWin=6, LanternMax=100.
-- Notice kinds canon: "escape" | "locked" | "page" | "danger" | absent.
Events.onPlayer(function(player)
	Actions.set(player, "Lantern", Config.lanternMax)
	Actions.set(player, "Pages", 0)
	Actions.set(player, "Sheltered", false)
	Actions.set(player, "Chased", false)
	Actions.set(player, "Won", false)
	Actions.set(player, "PagesToWin", Config.pagesToWin)
	Actions.set(player, "LanternMax", Config.lanternMax)
	Actions.set(player, "AdvisedFollow", false)
	-- Contrato SYSTEMS (@client-ux lê exatamente estes nomes): defaults no join.
	Actions.set(player, "LanternOn", true)
	Actions.set(player, "Sanity", 100)
	Actions.set(player, "Stamina", STAM_MAX)
	Actions.set(player, "Exhausted", false)
	Actions.set(player, "Hidden", false)
	Actions.set(player, "HideCooldown", 0)
	Actions.set(player, "Phase", phase)
	Actions.set(player, "Escapes", 0)
	Actions.set(player, "Deaths", 0)
	Actions.set(player, "Ready", false)
	Actions.set(player, "Spectate", false)
	if phase == "NIGHT" then -- late-join na noite: espectador no saguão, sem Pages
		Actions.set(player, "Spectate", true)
		Actions.notify(player, "Você chegou no meio da noite — observe do saguão.", { kind = "page" })
	else
		Actions.notify(player, ("Encontre %d das %d páginas, alimente a lanterna e fuja pelo portão NORTE. A capela (sul da torre) é segura."):format(Config.pagesToWin, #pageSpots))
	end
	if sealBroken then
		Actions.notify(player, "O selo já quebrou — corra ao portão norte.", { kind = "escape" })
	else
		adviseLateJoiner(player)
	end
end)

-- A fresh life means a full lantern. Pages survive death: the pages are
-- progress, the lantern is the run. Sheltered resets because respawn is at
-- the entrance, never inside the chapel.
Events.onCharacter(function(character, player, humanoid)
	Actions.set(player, "Lantern", Config.lanternMax)
	Actions.set(player, "Sheltered", false)
	Actions.set(player, "Chased", false)
	-- Morte zera fôlego/mente/tática; Pages/Deaths/Escapes sobrevivem (progresso).
	Actions.set(player, "LanternOn", true)
	Actions.set(player, "Sanity", 100)
	Actions.set(player, "Stamina", STAM_MAX)
	Actions.set(player, "Exhausted", false)
	Actions.set(player, "Hidden", false)
	humanoid.WalkSpeed = SPEED_WALK
	sprintIntent[player] = nil
	pingUntil[player] = nil
	hideSince[player] = nil
	hideNoiseAt[player] = nil
	hideLocker[player] = nil
	exhaustUntil[player] = nil
	task.defer(function() -- corretivo de spawn por fase (spawn duplo: lobby x entrada)
		local live = player.Character
		if live == nil then
			return
		end
		local dest: Vector3? = nil
		if phase == "LOBBY" then
			dest = LOBBY_SPAWN_AT
		elseif Actions.get(player, "Spectate", false) == true then
			dest = LOBBY_SPAWN_AT -- espectador fica no saguão
		end
		if dest ~= nil then
			pcall(function()
				live:PivotTo(CFrame.new(dest :: Vector3))
			end)
		end
	end)
	_ = character
end)

-- ------------------------------------------------------------------ lantern + fear

local threats = Instance.new("Folder")
threats.Name = "Threats"
threats.Parent = DREAD

local function nearestThreatDistance(from: Vector3): number
	local best = math.huge
	for _, model in ipairs(threats:GetChildren()) do
		if model:IsA("Model") then
			local ok, pivot = pcall(function()
				return model:GetPivot().Position
			end)
			if ok then
				local distance = (pivot - from).Magnitude
				if distance < best then
					best = distance
				end
			end
		end
	end
	return best
end

-- Chased vs fear (fonte p/ README/@lore-docs): `chasedRadius` (60) só marca
-- Chased p/ flicker da lanterna; `fearRadius` (Config, 16) drena de verdade
-- via fearDrain. Sheltered zera ambos — é o que torna a capela real.
-- Canônico em GameConfig (`chasedRadius=60`, @world-art); fallback 60 aqui
-- cobre qualquer ordem de edição.
local CHASED_RADIUS: number = (Config :: any).chasedRadius or 60

Timer.every(1, function()
	for _, player in ipairs(Players:GetPlayers()) do
		if Actions.get(player, "Won", false) == true then
			Actions.set(player, "Chased", false)
			continue
		end
		if phase ~= "NIGHT" then -- fora da noite a economia dorme (sem drain, sem dano, sem caçada)
			Actions.set(player, "Chased", false)
			continue
		end
		local character = player.Character
		if character == nil then
			continue
		end
		local sheltered = Actions.get(player, "Sheltered", false) == true
		local lanternOn = Actions.get(player, "LanternOn", true) == true -- default true
		local delta = if sheltered then Config.lanternRecover elseif not lanternOn then 0 else -Config.lanternDrain

		-- Fear: proximity to the Hollow burns the lantern faster. Sheltered
		-- players feel nothing and never read as chased — that is what
		-- makes the chapel safety real.
		local chased = false
		local root = character:FindFirstChild("HumanoidRootPart")
		if root ~= nil and root:IsA("BasePart") and not sheltered then
			local distance = nearestThreatDistance(root.Position)
			if distance < CHASED_RADIUS then
				chased = true
			end
			if not sheltered and distance < Config.fearRadius then
				delta -= Config.fearDrain
			end
		end
		Actions.set(player, "Chased", chased)

		if not lanternOn then -- apagado corrói a mente (capela poupa); aceso recupera devagar
			if not sheltered then
				Actions.add(player, "Sanity", -SANITY_DRAIN, { min = 0, max = 100 })
			end
		else
			Actions.add(player, "Sanity", SANITY_REGEN, { min = 0, max = 100 })
		end

		local left = Actions.add(player, "Lantern", delta, { min = 0, max = Config.lanternMax })

		-- The lantern is the light. Range and brightness follow the charge,
		-- and the beam stutters when the Hollow is near.
		-- LanternGlow vive no HumanoidRootPart, nunca na Head: PointLight na
		-- Head estoura a câmera colada (blowout em Play Solo).
		local head = character:FindFirstChild("Head")
		if head ~= nil then
			local legacy = head:FindFirstChild("LanternGlow")
			if legacy ~= nil then
				legacy:Destroy()
			end
		end
		if root ~= nil and root:IsA("BasePart") then
			local glow = root:FindFirstChild("LanternGlow") :: PointLight?
			if glow == nil then
				glow = Instance.new("PointLight")
				glow.Name = "LanternGlow"
				glow.Color = Color3.fromRGB(255, 200, 140)
				glow.Shadows = false
				glow.Parent = root
			end
			glow.Enabled = lanternOn -- apagado = glow apagado (tick de 1s + toggle imediato no Remote)
			local flicker = 0
			if chased and left > 0 then
				flicker = random:NextNumber(-0.35, 0.1)
			end
			glow.Range = Curve.remap(left, 0, Config.lanternMax, 4, 34)
			glow.Brightness = math.max(Curve.remap(left, 0, Config.lanternMax, 0.2, 1.6) + flicker, 0)
		end
		if left <= 0 and not sheltered then
			Actions.damage(character, Config.darkDamage)
		end
	end
end, "lantern")

-- ------------------------------------------------------------------ the Hollow

local guards: { any } = {}

-- Fixed ambush points on open ground, seeded-picked per spawn. The old ring
-- (radius 80) could land inside the Hall, the Wards, the chapel or the
-- tower footprint and soft-lock a wave behind a wall. Every point below was
-- checked against the room footprints: Hall x±30/z20..60, Wards x±40..80 /
-- z±15, Chapel x±15/z-82..-58, tower x±5/z-25..-15.
local HOLLOW_SPAWNS = {
	Vector3.new(0, 4, -40),
	Vector3.new(-40, 4, -30),
	Vector3.new(40, 4, -30),
	Vector3.new(-40, 4, 70),
	Vector3.new(40, 4, 70),
	Vector3.new(-90, 4, -40),
	Vector3.new(90, 4, -40),
	Vector3.new(-20, 4, -50),
}

local function makeHollow(wave: number): Instance?
	-- Prune dead entries so the table cannot grow without bound.
	for index = #guards, 1, -1 do
		local entry = guards[index]
		local model = if type(entry) == "table" then entry.model else entry
		if model == nil or (model :: Instance).Parent == nil then
			table.remove(guards, index)
		end
	end
	local at = HOLLOW_SPAWNS[random:NextInteger(1, #HOLLOW_SPAWNS)]
	local ok, model = pcall(function()
		return WorldKit.Threat.build(threats, tokens, {
			id = ("Hollow%d"):format(random:NextInteger(1, 99999)),
			cframe = CFrame.new(at),
			maxHealth = 60 + wave * 15,
			health = 60 + wave * 15,
			scale = 1.1,
			seed = random:NextInteger(1, 9999),
			bodyRole = "ink",
			mantleRole = "slate",
			faceRole = "neutralLight",
			accentRole = "accentDanger",
			showName = false,
			showHealth = false,
		})
	end)
	if not ok or model == nil then
		return nil
	end
	-- olhos-par R15: par simétrico Neon na face (Threat.build só dá 1 Relic +
	-- Face neutra; olho único invertido não prova leitura R15). Parentadas ao
	-- modelo em posição relativa ao Hood/PrimaryPart (Anchored como as parts
	-- do Threat, logo PivotTo carrega o conjunto) + WeldConstraint p/ solda
	-- explícita; CanCollide/CanTouch=false p/ nunca snagar nav/player.
	do
		local hollow = model :: Model
		local hood = hollow:FindFirstChild("Hood")
		local anchor = if hood ~= nil and hood:IsA("BasePart") then (hood :: BasePart).CFrame else hollow:GetPivot()
		local anchorSize = if hood ~= nil and hood:IsA("BasePart") then (hood :: BasePart).Size else Vector3.new(1.9, 1.9, 1.9)
		local eyeSwatch = tokens:swatch("accentDanger")
		local eyeD = math.clamp(anchorSize.X * 0.22, 0.25, 0.5)
		local xOff = anchorSize.X * 0.18
		local yOff = anchorSize.Y * 0.08
		local zOff = anchorSize.Z * 0.5 + eyeD * 0.4
		for _, side in ipairs({ -1, 1 }) do
			local eye = Instance.new("Part")
			eye.Name = if side < 0 then "EyeL" else "EyeR"
			eye.Shape = Enum.PartType.Ball
			eye.Size = Vector3.new(eyeD, eyeD, eyeD)
			eye.CFrame = anchor * CFrame.new(side * xOff, yOff, -zOff)
			eye.Anchored = true
			eye.CanCollide = false
			eye.CanTouch = false
			eye.CanQuery = false
			eye.CastShadow = false
			eye.TopSurface = Enum.SurfaceType.Smooth
			eye.BottomSurface = Enum.SurfaceType.Smooth
			eye.Color = eyeSwatch.color
			eye.Material = Enum.Material.Neon
			eye:SetAttribute("WorldKitRole", "accentDanger")
			eye.Parent = hollow
			if hood ~= nil and hood:IsA("BasePart") then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = hood :: BasePart
				weld.Part1 = eye
				weld.Parent = eye
			end
		end
		-- Rim/silhueta barato: 1 manto slate atrás do capuz.
		local rimSwatch = tokens:swatch("slate")
		local rim = Instance.new("Part")
		rim.Name = "CowlRim"
		rim.Size = Vector3.new(anchorSize.X * 1.6, anchorSize.Y * 0.28, anchorSize.Z * 1.1)
		rim.CFrame = anchor * CFrame.new(0, anchorSize.Y * 0.42, anchorSize.Z * 0.15)
		rim.Anchored = true
		rim.CanCollide = false
		rim.CanTouch = false
		rim.CanQuery = false
		rim.TopSurface = Enum.SurfaceType.Smooth
		rim.BottomSurface = Enum.SurfaceType.Smooth
		rim.Color = rimSwatch.color
		rim.Material = rimSwatch.material
		rim:SetAttribute("WorldKitRole", "slate")
		rim.Parent = hollow
	end
	-- Faceless on purpose: no nameplate, no health bar. You see the eyes
	-- first, and by then it has already seen you. Wave scaling caps at
	-- chase+6 (=17 > walkSpeed 16) desde ~wave 8: ondas tardias superam o
	-- jogador em campo aberto por escalada intencional (economia intacta);
	-- a defesa segue quebrar visão por giveUp 5s / alcançar a capela.
	local sightNow = math.min(Config.sight + wave * 4, 90)
	local chaseNow = math.min(Config.chaseSpeed + wave * 0.8, Config.chaseSpeed + 6)
	local nextAt = HOLLOW_SPAWNS[(table.find(HOLLOW_SPAWNS, at) % #HOLLOW_SPAWNS) + 1]
	local hollowModel: Model? = nil
	local guard = Life.guard(model, {
		sight = sightNow,
		chaseSpeed = chaseNow,
		giveUp = Config.giveUp,
		gait = "menace",
		-- Patrulha anti-estátua: sem post o Hollow nasce parado até ver
		-- alguém. Pontos seedados de HOLLOW_SPAWNS (fora de salas/torre).
		post = at,
		route = { at, nextAt },
		patrolSpeed = 8,
		onSpotted = function(target) -- espelho p/ filtro stealth: quem este Hollow persegue
			local spotted = if target ~= nil then Players:GetPlayerFromCharacter(target) else nil
			if hollowModel ~= nil and spotted ~= nil then
				chaseTarget[hollowModel :: Model] = spotted
			end
		end,
		onLost = function() -- motor desistiu sozinho: limpa o espelho
			if hollowModel ~= nil then
				chaseTarget[hollowModel :: Model] = nil
				suppressed[hollowModel :: Model] = nil
			end
		end,
	})
	table.insert(guards, { guard = guard, model = model, chaseSpeed = chaseNow, sight = sightNow, route = { at, nextAt }, post = at })
	hollowModel = model
	return model
end

-- Life.spawner APOSENTADO aqui: ele só abre a próxima onda com gate
-- made/#alive==0 (wave-clear). O Hollow é imortal/parado → a onda nunca
-- zera → 1 entidade para sempre. Horror imortal pede trickle por timer.
local trickleWave = 0

local function aliveHollows(): number
	local count = 0
	for index = #guards, 1, -1 do
		local entry = guards[index]
		local model = if type(entry) == "table" then entry.model else entry
		if model == nil or (model :: Instance).Parent == nil then
			table.remove(guards, index)
		else
			count += 1
		end
	end
	return count
end

local function trickleHollow()
	if aliveHollows() >= Config.waveCap then
		return -- cap anti-acúmulo: a onda espera, nunca ignora o teto
	end
	trickleWave += 1
	if makeHollow(trickleWave) == nil then
		return
	end
	for _, player in ipairs(Players:GetPlayers()) do
		Actions.notify(player, ("Onda %d — ele volta a caçar. Apague-se."):format(trickleWave), { kind = "danger" })
	end
end

Events.on("dreadhollow.escaped", function()
	for _, model in ipairs(threats:GetChildren()) do
		model:Destroy()
	end
	table.clear(guards)
end)

-- ------------------------------------------------------------------ o loop
-- LOBBY (saguão físico + ready) → COUNTDOWN 10s → NIGHT (trickle) → DAWN (placar 15s) → LOBBY.
-- Phase global espelhada em attr; COUNTDOWN roda com Phase=LOBBY (contrato imutável).

entranceSpawn = spawn
part("LobbyFloor", Vector3.new(36, 1, 26), LOBBY_CENTRE + Vector3.new(0, -0.5, 0), "ground")
part("LobbyWallN", Vector3.new(36, 10, 2), LOBBY_CENTRE + Vector3.new(0, 5, -13), "stone")
part("LobbyWallS", Vector3.new(36, 10, 2), LOBBY_CENTRE + Vector3.new(0, 5, 13), "stone")
part("LobbyWallW", Vector3.new(2, 10, 26), LOBBY_CENTRE + Vector3.new(-18, 5, 0), "stone")
part("LobbyWallE", Vector3.new(2, 10, 26), LOBBY_CENTRE + Vector3.new(18, 5, 0), "stone")
do -- SpawnLocation do saguão (toggle com Entrance por fase: sem sorteio de spawn)
	local ls = Instance.new("SpawnLocation")
	ls.Name = "LobbySpawn"
	ls.Size = Vector3.new(6, 1, 6)
	ls.Position = LOBBY_SPAWN_AT
	ls.Anchored = true
	ls.Neutral = true
	ls.Duration = 0
	ls.Enabled = true
	ls.CFrame = CFrame.lookAt(ls.Position, Vector3.new(0, 1, 95))
	ls.Parent = DREAD
	lobbySpawn = ls
end

local function clearThreats() -- hygiene entre fases: sem Hollow fora da noite
	for _, model in ipairs(threats:GetChildren()) do
		model:Destroy()
	end
	table.clear(guards)
	table.clear(chaseTarget)
	table.clear(suppressed)
end

local function resetRunner(player: Player, dest: Vector3) -- zera Pages/Lantern/Won + tática
	Actions.set(player, "Pages", 0)
	Actions.set(player, "Lantern", Config.lanternMax)
	Actions.set(player, "LanternOn", true)
	Actions.set(player, "Sanity", 100)
	Actions.set(player, "Stamina", STAM_MAX)
	Actions.set(player, "Exhausted", false)
	Actions.set(player, "Hidden", false)
	Actions.set(player, "Won", false)
	Actions.set(player, "Chased", false)
	Actions.set(player, "Ready", false)
	sprintIntent[player] = nil
	pingUntil[player] = nil
	hideSince[player] = nil
	hideNoiseAt[player] = nil
	hideLocker[player] = nil
	exhaustUntil[player] = nil
	local character = player.Character
	if character ~= nil then
		pcall(function()
			character:PivotTo(CFrame.new(dest))
		end)
	end
end

-- ------------------------------------------------- stealth (filtro prévio no tick)
-- O motor (Life.guard) enxerga por física; o filtro decide quem ele PODE caçar:
-- Hidden/espectador nunca; apagado só dentro de sight×fator (~20st); NoisePing fura tudo a 40st/2s.
local function guardSeesPlayer(gpos: Vector3, sight: number, watcher: Model, player: Player): boolean
	if phase ~= "NIGHT" then
		return false -- fora da noite ninguém é caçado
	end
	if Actions.get(player, "Won", false) == true then
		return false -- escapou, fora da caçada
	end
	if Actions.get(player, "Spectate", false) == true then
		return false -- espectador nunca entra na mira
	end
	local character, _hum = aliveChar(player)
	if character == nil then
		return false
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return false
	end
	local dist = (root.Position - gpos).Magnitude
	if (pingUntil[player] or 0) > os.clock() and dist <= NOISE_RADIUS then
		return true -- NoisePing: ouvido a 40st por 2s
	end
	if Actions.get(player, "Hidden", false) == true then
		return false -- armário quebra a mira
	end
	local range = sight
	if Actions.get(player, "LanternOn", true) ~= true then
		range = sight * OFF_SIGHT_FACTOR -- apagado encolhe a mira
	end
	if dist > range then
		return false -- filtro prévio: apagado além de ~20st é ignorado
	end
	return Spatial.sees(gpos, root.Position, { caster = watcher, target = character })
end

local function patrolOf(entry: any) -- devolve o guard p/ patrol (giveUp imediato)
	GameKit.Pursuit.start(entry.model, { mode = "patrol", speed = 8, points = entry.route })
end

local function suppressGuard(entry: any)
	if entry == nil or entry.model == nil or entry.model.Parent == nil then
		return
	end
	chaseTarget[entry.model] = nil
	if suppressed[entry.model] ~= true then
		suppressed[entry.model] = true
		patrolOf(entry)
	end
end

local function chasePlayer(entry: any, player: Player) -- reengaja mira válida
	local character, _hum = aliveChar(player)
	if character == nil then
		return
	end
	suppressed[entry.model] = false
	chaseTarget[entry.model] = player
	GameKit.Pursuit.start(entry.model, { mode = "chase", speed = entry.chaseSpeed }, function()
		local live = player.Character -- fecha sobre o alvo válido; nil = perdeu
		if live == nil then
			return nil
		end
		local hum = live:FindFirstChildOfClass("Humanoid")
		if hum == nil or hum.Health <= 0 then
			return nil
		end
		return live
	end)
	GameKit.Motion.play(entry.model, { gait = "menace", rate = 1.8 })
end

Timer.every(0.5, function() -- filtro prévio: mira efetiva por guard
	if phase ~= "NIGHT" then
		return
	end
	for _, entry in ipairs(guards) do
		local model = entry.model
		local handle = entry.guard
		if model == nil or model.Parent == nil or handle == nil then
			continue
		end
		local ok, gpos = pcall(function()
			return model:GetPivot().Position
		end)
		if not ok then
			continue
		end
		local function valid(p: Player): boolean
			return guardSeesPlayer(gpos, entry.sight or 70, model, p)
		end
		local current = chaseTarget[model]
		if handle.isChasing() then
			if current ~= nil and valid(current) then
				suppressed[model] = false -- caça válida, não toca
			else
				local best: Player? = nil -- procura outra mira válida antes de largar
				for _, other in ipairs(Players:GetPlayers()) do
					if other ~= current and valid(other) then
						best = other
						break
					end
				end
				if best ~= nil then
					chasePlayer(entry, best)
				else
					suppressGuard(entry)
				end
			end
		else
			chaseTarget[model] = nil
			suppressed[model] = nil -- patrulha: o motor adquire sozinho no próximo beat
		end
	end
end, "stealth-filter")

-- ------------------------------------------------- lockers
local function exitLocker(player: Player, silent: boolean?) -- reposiciona na frente e solta
	local locker = hideLocker[player]
	hideLocker[player] = nil
	hideSince[player] = nil
	hideNoiseAt[player] = nil
	Actions.set(player, "Hidden", false)
	if locker ~= nil then
		local pr = locker:FindFirstChildOfClass("ProximityPrompt")
		if pr ~= nil then
			pr.ActionText = "Esconder"
		end
		local outPos = Vector3.new(locker.Position.X, 1, locker.Position.Z + 3.5)
		pcall(function()
			(player.Character :: Model):PivotTo(CFrame.new(outPos))
		end)
	end
	if silent ~= true then
		Actions.notify(player, "Você saiu do esconderijo.")
	end
end

local function enterLocker(player: Player, locker: BasePart, prompt: ProximityPrompt)
	if phase ~= "NIGHT" then
		Actions.notify(player, "A noite ainda não caiu.")
		return
	end
	if Actions.get(player, "Spectate", false) == true or Actions.get(player, "Won", false) == true then
		return
	end
	local character, _hum = aliveChar(player)
	if character == nil then
		return
	end
	if os.clock() < (tonumber(Actions.get(player, "HideCooldown", 0)) or 0) then
		Actions.notify(player, "O esconderijo ainda range — espere.", { kind = "locked" })
		return
	end
	hideLocker[player] = locker
	hideSince[player] = os.clock()
	hideNoiseAt[player] = os.clock()
	Actions.set(player, "Hidden", true) -- escondido não anda (WalkSpeed 0) nem é visto
	Actions.set(player, "HideCooldown", os.clock() + HIDE_COOLDOWN) -- relógio p/ próxima
	pcall(function()
		character:PivotTo(CFrame.new(Vector3.new(locker.Position.X, 1.2, locker.Position.Z)))
	end)
	for _, entry in ipairs(guards) do -- giveUp imediato SÓ do perseguidor deste jogador
		if chaseTarget[entry.model] == player then
			suppressGuard(entry)
		end
	end
	Actions.notify(player, "Escondido. Saia antes que ele fareje.", { kind = "page" })
	prompt.ActionText = "Sair"
end

for index, at in ipairs({
	Vector3.new(-26, 3, 56), Vector3.new(26, 3, 56), -- hall
	Vector3.new(-76, 3, 10), Vector3.new(-76, 3, -10), -- ward A
	Vector3.new(76, 3, 10), Vector3.new(76, 3, -10), -- ward B
}) do
	local locker = part(("Locker%d"):format(index), Vector3.new(3, 6, 3), at, "wood")
	locker.CanCollide = false -- escondido não anda, não é a parede que prende
	Events.onPrompt(locker, function(player, prompt)
		if player == nil then
			return
		end
		if Actions.get(player, "Hidden", false) == true then
			if hideLocker[player] ~= locker then
				return -- cada um no seu armário
			end
			exitLocker(player)
			return
		end
		local root = hrpOf(player)
		if root == nil or (root.Position - locker.Position).Magnitude > READ_RANGE + 2 then
			return -- proximidade validada no servidor
		end
		enterLocker(player, locker, prompt)
	end, { label = "Armário", action = "Esconder", range = 10 })
end

Timer.every(1, function() -- HideTime máx + farejo
	if phase ~= "NIGHT" then
		return
	end
	local now = os.clock()
	for _, player in ipairs(Players:GetPlayers()) do
		if Actions.get(player, "Hidden", false) ~= true then
			continue
		end
		if aliveChar(player) == nil then
			hideSince[player] = nil
			hideLocker[player] = nil
			hideNoiseAt[player] = nil
			Actions.set(player, "Hidden", false)
			continue
		end
		local since = hideSince[player] or now
		if now - since >= HIDE_MAX then -- HideTime máx: expulsão + notify danger
			exitLocker(player)
			Actions.notify(player, "Ele farejou o armário — CORRA!", { kind = "danger" })
		elseif (now - (hideNoiseAt[player] or since)) >= 3 then -- a cada 3s: 30% de NoisePing realerta guards próximos
			hideNoiseAt[player] = now
			if math.random() < 0.30 then
				noisePing(player, PING_SECONDS)
			end
		end
	end
end, "hide-watch")

-- ------------------------------------------------- remotes (intenção; servidor decide)
lanternRemote.OnServerEvent:Connect(function(player) -- F: toggle c/ debounce
	local now = os.clock()
	if now - (lastLanternToggle[player] or -10) < 0.5 then
		return
	end
	lastLanternToggle[player] = now
	local character, _hum = aliveChar(player)
	if character == nil then
		return
	end
	local on = Actions.get(player, "LanternOn", true) ~= true
	Actions.set(player, "LanternOn", on)
	local root = hrpOf(player) -- glow apaga junto (tick de 1s reforça)
	if root ~= nil then
		local glow = root:FindFirstChild("LanternGlow")
		if glow ~= nil and glow:IsA("PointLight") then
			glow.Enabled = on
		end
	end
	Actions.notify(player, if on then "Lanterna acesa." else "Lanterna apagada — a mente corrói.")
end)

sprintRemote.OnServerEvent:Connect(function(player, want) -- Shift espelhado: só intenção bool
	if type(want) ~= "boolean" then
		return
	end
	local character, _hum = aliveChar(player)
	if character == nil then
		return
	end
	sprintIntent[player] = if want == true then true else nil
end)

readyRemote.OnServerEvent:Connect(function(player) -- Ready/Unready + proximidade do saguão
	if phase ~= "LOBBY" then
		return
	end
	local character, _hum = aliveChar(player)
	if character == nil then
		return
	end
	local root = hrpOf(player)
	if root == nil then
		return
	end
	local lp = root.Position
	if math.abs(lp.X - LOBBY_CENTRE.X) > 18 or math.abs(lp.Z - LOBBY_CENTRE.Z) > 13 then
		Actions.notify(player, "Volte ao saguão para se declarar pronto.", { kind = "locked" })
		return
	end
	local ready = Actions.get(player, "Ready", false) ~= true
	Actions.set(player, "Ready", ready)
	Actions.notify(player, if ready then "Pronto! A noite cai com 2 prontos." else "Você recuou — sem pressa.")
end)

-- ------------------------------------------------- stamina + passo (servidor decide cada WalkSpeed)
Timer.every(0.25, function()
	local dt = 0.25
	local night = phase == "NIGHT"
	for _, player in ipairs(Players:GetPlayers()) do
		local _character, humanoid = aliveChar(player)
		if humanoid == nil then
			continue
		end
		if not night then
			if Actions.get(player, "Exhausted", false) == true then
				Actions.set(player, "Exhausted", false)
			end
			continue -- fora da noite o passo é livre
		end
		if Actions.get(player, "Won", false) == true then
			continue
		end
		local now = os.clock()
		if (exhaustUntil[player] or 0) > now then
			Actions.set(player, "Exhausted", true) -- trava: WalkSpeed 10
			humanoid.WalkSpeed = SPEED_EXHAUST
			continue -- exausto não drena nem regenera
		elseif Actions.get(player, "Exhausted", false) == true then
			Actions.set(player, "Exhausted", false)
		end
		local moving = humanoid.MoveDirection.Magnitude > 0.1
		local hidden = Actions.get(player, "Hidden", false) == true
		local wantsSprint = sprintIntent[player] == true and not hidden
		local overdriven = humanoid.WalkSpeed > SPEED_WALK -- redundância: passo alto em movimento cobra
		if (wantsSprint and moving) or (overdriven and moving) then -- sprint cobra; parado paga de volta
			local left = Actions.add(player, "Stamina", -STAM_DRAIN * dt, { min = 0, max = STAM_MAX })
			if left <= 0 then -- zerou: trava 3s (WalkSpeed 10) + NoisePing (40st/2s)
				exhaustUntil[player] = now + EXHAUST_SECONDS
				Actions.set(player, "Exhausted", true)
				humanoid.WalkSpeed = SPEED_EXHAUST
				noisePing(player, PING_SECONDS)
				sprintIntent[player] = nil
				Actions.notify(player, "Exausto! Ele ouviu você.", { kind = "danger" })
			end
		else
			Actions.add(player, "Stamina", STAM_REGEN * dt, { min = 0, max = STAM_MAX })
		end
		-- Escritor único de WalkSpeed: escondido 0 > exausto 10 > sprint 22 > mente 12 > base 16.
		local staminaNow = tonumber(Actions.get(player, "Stamina", STAM_MAX)) or STAM_MAX
		local sanityNow = tonumber(Actions.get(player, "Sanity", 100)) or 100
		if hidden then
			humanoid.WalkSpeed = 0
		elseif Actions.get(player, "Exhausted", false) == true then
			humanoid.WalkSpeed = SPEED_EXHAUST
		elseif wantsSprint and staminaNow > 0 and moving then
			humanoid.WalkSpeed = SPEED_SPRINT
		elseif sanityNow < SANITY_SLOW_AT then
			humanoid.WalkSpeed = SPEED_SLOW
		else
			humanoid.WalkSpeed = SPEED_WALK
		end
	end
end, "stamina")

Events.onDeath(function(_, player) -- Deaths++ na morte (progresso sobrevive ao respawn)
	Actions.add(player, "Deaths", 1)
	sprintIntent[player] = nil
	pingUntil[player] = nil
	hideSince[player] = nil
	hideNoiseAt[player] = nil
	hideLocker[player] = nil
	exhaustUntil[player] = nil
	for model, target in pairs(chaseTarget) do
		if target == player then
			chaseTarget[model] = nil
		end
	end
end)

Events.onPlayerLeft(function(player) -- hygiene de tabelas por jogador
	sprintIntent[player] = nil
	pingUntil[player] = nil
	hideSince[player] = nil
	hideNoiseAt[player] = nil
	hideLocker[player] = nil
	lastLanternToggle[player] = nil
	lastReadAt[player] = nil
	exhaustUntil[player] = nil
	for model, target in pairs(chaseTarget) do
		if target == player then
			chaseTarget[model] = nil
			suppressed[model] = nil
		end
	end
end)

-- ------------------------------------------------- fases
local function readyCount(): number
	local n = 0
	for _, other in ipairs(Players:GetPlayers()) do
		if Actions.get(other, "Ready", false) == true then
			n += 1
		end
	end
	return n
end

local beginDawn: (() -> ())? = nil -- forward (beginNight agenda; definição abaixo)
local beginLobbyFn: (() -> ())? = nil -- forward (beginDawn agenda; definição abaixo)

local function beginNight() -- teleport p/ Entrance, zera Pages/Lantern/Won, inicia trickle
	if phase == "NIGHT" then
		return
	end
	if lobbyTick ~= nil then
		lobbyTick:cancel()
		lobbyTick = nil
	end
	countdownActive = false
	setPhaseAll("NIGHT")
	sealBroken = false -- selo refeito p/ a nova noite
	barrier.CanCollide = true
	barrier.Transparency = 0
	if seal.Parent == nil then
		local fresh = part("GateSeal", Vector3.new(2, 2, 0.4), Vector3.new(0, 7, -HALF + 1), "accentDanger")
		fresh.CanCollide = false
		fresh.Material = Enum.Material.Neon
		seal = fresh
	end
	buildPages() -- mundo refeito: 8 páginas, coleta zerada
	buildBatteries()
	clearThreats()
	for _, other in ipairs(Players:GetPlayers()) do
		Actions.set(other, "Spectate", false) -- noite nova: todo presente joga
		resetRunner(other, ENTRANCE_AT)
	end
	(lobbySpawn :: SpawnLocation).Enabled = false
	(entranceSpawn :: SpawnLocation).Enabled = true
	trickleWave = 0 -- escalada recomeça a cada noite
	Timer.after(Config.firstWaveDelay, function() -- trickle vive SÓ na noite
		if phase ~= "NIGHT" then
			return
		end
		trickleHollow()
		trickleHandle = Timer.every(Config.waveBetween, function()
			if phase ~= "NIGHT" then
				if trickleHandle ~= nil then
					trickleHandle:cancel()
				end
				return
			end
			trickleHollow()
		end, "hollow-trickle")
	end, "hollow-first")
	nightHandle = Timer.after(NIGHT_SECONDS, function()
		local go = beginDawn
		if phase == "NIGHT" and go ~= nil then
			go()
		end
	end, "night-end")
	for _, other in ipairs(Players:GetPlayers()) do
		Actions.notify(other, "A NOITE CAIU. Apague a lanterna (F), esconda-se (armários), leia antes de coletar.", { kind = "danger" })
	end
end

beginDawn = function() -- placar 15s: Pages/Escapes/Deaths
	if phase == "DAWN" then
		return
	end
	if nightHandle ~= nil then
		nightHandle:cancel()
		nightHandle = nil
	end
	if trickleHandle ~= nil then
		trickleHandle:cancel()
		trickleHandle = nil
	end
	setPhaseAll("DAWN")
	clearThreats()
	for _, other in ipairs(Players:GetPlayers()) do
		Actions.set(other, "Chased", false)
		if hideLocker[other] ~= nil then
			exitLocker(other, true) -- expulsa do armário sem susto
		end
		local pages = tonumber(Actions.get(other, "Pages", 0)) or 0
		local escapes = tonumber(Actions.get(other, "Escapes", 0)) or 0
		local deaths = tonumber(Actions.get(other, "Deaths", 0)) or 0
		Actions.notify(other, ("Amanheceu. Páginas %d • Fugas %d • Mortes %d."):format(pages, escapes, deaths), { kind = "escape" })
	end
	(lobbySpawn :: SpawnLocation).Enabled = true
	dawnHandle = Timer.after(DAWN_SECONDS, function()
		local go = beginLobbyFn
		if phase == "DAWN" and go ~= nil then
			go()
		end
	end, "dawn-end")
end

local function startCountdown() -- 10s finais ainda em LOBBY (Phase segue LOBBY: contrato)
	if countdownActive or phase ~= "LOBBY" then
		return
	end
	countdownActive = true
	for _, other in ipairs(Players:GetPlayers()) do
		Actions.notify(other, "A noite cai em 10 segundos. Posições!", { kind = "danger" })
	end
	Timer.repeated(COUNTDOWN_SECONDS, 1, function(tick)
		if phase ~= "LOBBY" then
			return
		end
		local left = COUNTDOWN_SECONDS - tick + 1
		if left <= 5 and left > 0 then
			for _, other in ipairs(Players:GetPlayers()) do
				Actions.notify(other, ("A NOITE CAI EM %d"):format(left), { kind = "danger" })
			end
		end
		if tick >= COUNTDOWN_SECONDS then
			beginNight()
		end
	end, "lobby-countdown")
end

beginLobbyFn = function() -- sala de espera física: reagrupa, reseta, rearma o lobby
	if dawnHandle ~= nil then
		dawnHandle:cancel()
		dawnHandle = nil
	end
	if nightHandle ~= nil then
		nightHandle:cancel()
		nightHandle = nil
	end
	if trickleHandle ~= nil then
		trickleHandle:cancel()
		trickleHandle = nil
	end
	setPhaseAll("LOBBY")
	countdownActive = false
	lobbyElapsed = 0
	clearThreats()
	;(lobbySpawn :: SpawnLocation).Enabled = true
	;(entranceSpawn :: SpawnLocation).Enabled = false
	for _, other in ipairs(Players:GetPlayers()) do
		Actions.set(other, "Spectate", false)
		resetRunner(other, LOBBY_SPAWN_AT)
		Actions.notify(other, ("Saguão. Declare pronto no saguão — %d prontos ou %ds começam a contagem."):format(MIN_READY, LOBBY_SECONDS))
	end
	lobbyTick = Timer.every(1, function()
		if phase ~= "LOBBY" then
			if lobbyTick ~= nil then
				lobbyTick:cancel()
				lobbyTick = nil
			end
			return
		end
		lobbyElapsed += 1
		if not countdownActive and (lobbyElapsed >= LOBBY_SECONDS or readyCount() >= MIN_READY) then
			startCountdown()
		end
	end, "lobby-watch")
end

local lobbyZone = Zone.new(LOBBY_CENTRE + Vector3.new(0, 5, 0), Vector3.new(36, 12, 26), {})
lobbyZone.entered:connect(function(_, player) -- em NIGHT o saguão devolve p/ Entrance (trava de saída)
	if player ~= nil and phase == "NIGHT" and Actions.get(player, "Spectate", false) ~= true then
		local character = player.Character
		if character ~= nil then
			pcall(function()
				character:PivotTo(CFrame.new(ENTRANCE_AT))
			end)
		end
	end
end)

local beginLobby = beginLobbyFn :: () -> ()
beginLobby()
print("[dreadhollow] loop lobby→night→dawn armado —", Config.pagesToWin, "páginas até o portão")
