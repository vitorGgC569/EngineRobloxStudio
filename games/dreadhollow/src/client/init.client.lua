--!strict
--- DREADHOLLOW HUD: projection only, zero authority.
---
--- Reads player attributes the server owns (Pages, Lantern, Notice/NoticeAt/
--- NoticeKind, Chased, Won) and draws them. It never computes economy, never
--- fires gameplay remotes, never moves the character, never synthesizes clicks.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local gui = Instance.new("ScreenGui")
gui.Name = "DreadHud"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 900
gui.Parent = player:WaitForChild("PlayerGui")

-- Tuning server-authoritative: fonte canônica são os atributos do jogador
-- publicados pelo servidor (PagesToWin/LanternMax). Fallback 6/100 existe
-- só para o HUD não quebrar antes da primeira replicação; nunca adivinhe.
local FALLBACK_PAGES_TO_WIN = 6
local FALLBACK_LANTERN_MAX = 100
-- NoticeAt é os.clock() do servidor (monotônico na sessão): TTL local de 4s é válido.
local TOAST_TTL_SECONDS = 4
local LANTERN_CRITICAL = 0.25
local LANTERN_LOW = 0.5

local function getPagesToWin(): number
	local v = tonumber(player:GetAttribute("PagesToWin"))
	if v ~= nil and v > 0 then
		return math.floor(v)
	end
	return FALLBACK_PAGES_TO_WIN
end

local function getLanternMax(): number
	local v = tonumber(player:GetAttribute("LanternMax"))
	if v ~= nil and v > 0 then
		return v
	end
	return FALLBACK_LANTERN_MAX
end

local function addStroke(inst: Instance, thickness: number)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = thickness
	stroke.Color = Color3.fromRGB(0, 0, 0)
	stroke.Transparency = 0.25
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.Parent = inst
end

-- Vignette FIRST so later siblings draw above it. Direct transparency sets
-- only: never Tween a meter or vignette (tweens stall in edit mode).
local vignette = Instance.new("Frame")
vignette.Name = "Vignette"
vignette.AnchorPoint = Vector2.new(0, 0)
vignette.Position = UDim2.new(0, 0, 0, 0)
vignette.Size = UDim2.new(1, 0, 1, 0)
vignette.BorderSizePixel = 0
vignette.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
vignette.BackgroundTransparency = 0.72
vignette.Active = false
vignette.ZIndex = 1
vignette.Parent = gui

-- Vinheta real: mesmo Frame, só desenho (lógica de refresh intocada).
-- Gradiente centro ~transparente / bordas escuras; com centro 0.5 sobre
-- BackgroundTransparency 0.72 o centro efetivo fica ~0.86. Sem Tween.
local vignetteGradient = Instance.new("UIGradient")
vignetteGradient.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0),
	NumberSequenceKeypoint.new(0.5, 0.5),
	NumberSequenceKeypoint.new(1, 0),
})
vignetteGradient.Rotation = 90
vignetteGradient.Parent = vignette

-- Objective, top centre: the only number that matters.
local objective = Instance.new("TextLabel")
objective.Name = "Objective"
objective.AnchorPoint = Vector2.new(0.5, 0)
objective.Position = UDim2.new(0.5, 0, 0, 18)
objective.Size = UDim2.new(0, 480, 0, 38)
objective.BackgroundTransparency = 0.55
objective.BackgroundColor3 = Color3.fromRGB(8, 8, 12)
objective.TextColor3 = Color3.fromRGB(205, 195, 170)
objective.Font = Enum.Font.GothamBold
objective.TextSize = 20
objective.TextWrapped = true
objective.ZIndex = 5
objective.Text = "PÁGINAS … — ANDE ATÉ A PÁGINA"
objective.Parent = gui
addStroke(objective, 1)

-- Chased warning, stacked directly under the objective.
local chasedLabel = Instance.new("TextLabel")
chasedLabel.Name = "Chased"
chasedLabel.AnchorPoint = Vector2.new(0.5, 0)
chasedLabel.Position = UDim2.new(0.5, 0, 0, 60)
chasedLabel.Size = UDim2.new(0, 420, 0, 30)
chasedLabel.BackgroundTransparency = 1
chasedLabel.TextColor3 = Color3.fromRGB(255, 70, 60)
chasedLabel.Font = Enum.Font.GothamBold
-- R14: Chased hierarquia sobre toast danger via tamanho (20→24), sem Tween/pisca.
chasedLabel.TextSize = 24
chasedLabel.TextWrapped = true
chasedLabel.ZIndex = 5
chasedLabel.Visible = false
chasedLabel.Text = "ELE ESTÁ ATRÁS DE VOCÊ — CORRA"
chasedLabel.Parent = gui
addStroke(chasedLabel, 2)

-- Lantern stack, bottom left: label anchored above the bar, both explicit.
local lanternLabel = Instance.new("TextLabel")
lanternLabel.Name = "LanternLabel"
lanternLabel.AnchorPoint = Vector2.new(0, 1)
lanternLabel.Position = UDim2.new(0, 24, 1, -88)
lanternLabel.Size = UDim2.new(0, 300, 0, 20)
lanternLabel.BackgroundTransparency = 1
lanternLabel.TextColor3 = Color3.fromRGB(205, 195, 170)
lanternLabel.Font = Enum.Font.GothamBold
lanternLabel.TextSize = 14
lanternLabel.TextXAlignment = Enum.TextXAlignment.Left
lanternLabel.TextTruncate = Enum.TextTruncate.AtEnd
lanternLabel.ZIndex = 5
lanternLabel.Text = "LANTERNA"
lanternLabel.Parent = gui
addStroke(lanternLabel, 1)

local lanternBack = Instance.new("Frame")
lanternBack.Name = "LanternBack"
lanternBack.AnchorPoint = Vector2.new(0, 1)
lanternBack.Position = UDim2.new(0, 24, 1, -64)
lanternBack.Size = UDim2.new(0, 260, 0, 18)
-- R14: fundo 0.45→0.2 + borda (invisível no preto), sem Tween.
lanternBack.BackgroundTransparency = 0.2
lanternBack.BackgroundColor3 = Color3.fromRGB(8, 8, 12)
lanternBack.BorderSizePixel = 1
lanternBack.BorderColor3 = Color3.fromRGB(205, 195, 170)
lanternBack.ZIndex = 5
lanternBack.Parent = gui

local lanternFill = Instance.new("Frame")
lanternFill.Name = "LanternFill"
lanternFill.AnchorPoint = Vector2.new(0, 0.5)
lanternFill.Position = UDim2.new(0, 0, 0.5, 0)
lanternFill.Size = UDim2.new(1, 0, 1, 0)
lanternFill.BorderSizePixel = 0
lanternFill.BackgroundColor3 = Color3.fromRGB(255, 190, 120)
lanternFill.ZIndex = 6
lanternFill.Parent = lanternBack

-- Toast line, bottom centre, with per-kind color and local expiry.
local toast = Instance.new("TextLabel")
toast.Name = "Toast"
toast.AnchorPoint = Vector2.new(0.5, 1)
toast.Position = UDim2.new(0.5, 0, 1, -130)
toast.Size = UDim2.new(0, 600, 0, 30)
toast.BackgroundTransparency = 1
toast.TextColor3 = Color3.fromRGB(230, 220, 200)
toast.Font = Enum.Font.GothamBold
toast.TextSize = 18
toast.TextWrapped = true
toast.ZIndex = 5
toast.Text = ""
toast.Parent = gui
addStroke(toast, 2)

local wonBanner = Instance.new("TextLabel")
wonBanner.Name = "Won"
wonBanner.AnchorPoint = Vector2.new(0.5, 0.5)
wonBanner.Position = UDim2.new(0.5, 0, 0.4, 0)
wonBanner.Size = UDim2.new(0, 560, 0, 64)
wonBanner.BackgroundTransparency = 0.35
wonBanner.BackgroundColor3 = Color3.fromRGB(8, 8, 12)
wonBanner.TextColor3 = Color3.fromRGB(255, 214, 140)
wonBanner.Font = Enum.Font.GothamBold
wonBanner.TextSize = 36
wonBanner.TextWrapped = true
wonBanner.ZIndex = 10
wonBanner.Text = ""
wonBanner.Visible = false
wonBanner.Parent = gui
addStroke(wonBanner, 2)

-- First-screen help: client-local overlay only, dismissed by a real user
-- click. Never auto-clicks, never touches gameplay state.
local help = Instance.new("Frame")
help.Name = "Help"
help.AnchorPoint = Vector2.new(0.5, 0.5)
help.Position = UDim2.new(0.5, 0, 0.38, 0)
help.Size = UDim2.new(0, 480, 0, 250)
help.BackgroundTransparency = 0.25
help.BackgroundColor3 = Color3.fromRGB(8, 8, 12)
help.ZIndex = 20
help.Parent = gui

local helpTitle = Instance.new("TextLabel")
helpTitle.Name = "Title"
helpTitle.AnchorPoint = Vector2.new(0.5, 0)
helpTitle.Position = UDim2.new(0.5, 0, 0, 12)
helpTitle.Size = UDim2.new(1, -24, 0, 30)
helpTitle.BackgroundTransparency = 1
helpTitle.TextColor3 = Color3.fromRGB(255, 214, 140)
helpTitle.Font = Enum.Font.GothamBold
helpTitle.TextSize = 20
helpTitle.ZIndex = 21
helpTitle.Text = "SOBREVIVA A DREADHOLLOW"
helpTitle.Parent = help
addStroke(helpTitle, 1)

local helpBody = Instance.new("TextLabel")
helpBody.Name = "Body"
helpBody.AnchorPoint = Vector2.new(0.5, 0)
helpBody.Position = UDim2.new(0.5, 0, 0, 48)
helpBody.Size = UDim2.new(1, -24, 0, 140)
helpBody.BackgroundTransparency = 1
helpBody.TextColor3 = Color3.fromRGB(230, 220, 200)
helpBody.Font = Enum.Font.Gotham
helpBody.TextSize = 16
helpBody.TextWrapped = true
helpBody.TextYAlignment = Enum.TextYAlignment.Top
helpBody.ZIndex = 21
helpBody.Text = "Encontre as páginas e escape.\nWASD — mover | Mouse — olhar | Shift — correr\nAnde até a página para coletar (proximidade, sem tecla).\nLanterna fraca = mais perigo. Corra quando ELE chegar perto."
helpBody.Parent = help
addStroke(helpBody, 1)

local helpButton = Instance.new("TextButton")
helpButton.Name = "Dismiss"
helpButton.AnchorPoint = Vector2.new(0.5, 1)
helpButton.Position = UDim2.new(0.5, 0, 1, -12)
helpButton.Size = UDim2.new(0, 220, 0, 36)
helpButton.BackgroundColor3 = Color3.fromRGB(40, 32, 24)
helpButton.TextColor3 = Color3.fromRGB(255, 214, 140)
helpButton.Font = Enum.Font.GothamBold
helpButton.TextSize = 16
helpButton.ZIndex = 22
helpButton.Text = "ENTENDI"
helpButton.Parent = help

-- R9: dismiss local SOMENTE por movimento PROVADO no frame (delta de HRP) ou
-- ENTENDI. Key press sozinho não dispensa: prova = |pos - origem| >= limiar.
-- Fallback 12s com Pages>0 mantido (página coletada prova deslocamento).
-- Tudo local: só lê HRP, sem remote, sem gameplay, sem mover character.
local PROVEN_MOVE_STUDS = 0.25
local helpHeartConn: RBXScriptConnection? = nil
local moveOrigin: Vector3? = nil
local function disconnectHelpMove()
	if helpHeartConn ~= nil then
		helpHeartConn:Disconnect()
		helpHeartConn = nil
	end
end

helpButton.Activated:Connect(function()
	help.Visible = false
	disconnectHelpMove()
end)
local function getHRP(): BasePart?
	local char = player.Character
	if char == nil then
		return nil
	end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if hrp ~= nil and hrp:IsA("BasePart") then
		return hrp
	end
	return nil
end
local function captureOrigin()
	local hrp = getHRP()
	if hrp ~= nil then
		moveOrigin = hrp.Position
	end
end
captureOrigin()
player.CharacterAdded:Connect(function()
	if not help.Visible then
		return
	end
	moveOrigin = nil
	task.defer(captureOrigin)
end)
helpHeartConn = RunService.Heartbeat:Connect(function()
	if not help.Visible then
		disconnectHelpMove()
		return
	end
	local hrp = getHRP()
	if hrp == nil then
		return
	end
	if moveOrigin == nil then
		moveOrigin = hrp.Position
		return
	end
	if (hrp.Position - moveOrigin).Magnitude >= PROVEN_MOVE_STUDS then
		help.Visible = false
		disconnectHelpMove()
	end
end)
task.delay(12, function()
	if not help.Visible then
		return
	end
	local pages = tonumber(player:GetAttribute("Pages")) or 0
	if pages > 0 then
		help.Visible = false
		disconnectHelpMove()
	end
end)

local lastNoticeAt = 0
local toastToken = 0

local function toastColorForKind(kind: string?): Color3
	if kind == "danger" then
		return Color3.fromRGB(255, 80, 70)
	elseif kind == "page" then
		return Color3.fromRGB(255, 214, 140)
	elseif kind == "escape" then
		return Color3.fromRGB(140, 255, 170)
	elseif kind == "locked" then
		return Color3.fromRGB(255, 150, 60)
	else
		-- Kind ausente ou desconhecido: cor neutra, sem erro.
		return Color3.fromRGB(230, 220, 200)
	end
end

local function showToast(text: string, kind: string?)
	toastToken += 1
	local token = toastToken
	toast.Text = text
	toast.TextColor3 = toastColorForKind(kind)
	-- R14: TTL 6s só p/ kind==danger; demais 4s. Sem Tween.
	local ttl = TOAST_TTL_SECONDS
	if kind == "danger" then
		ttl = 6
	end
	task.delay(ttl, function()
		if token == toastToken then
			toast.Text = ""
		end
	end)
end

local function refresh()
	local pagesToWin = getPagesToWin()
	local lanternMax = getLanternMax()
	local pages = tonumber(player:GetAttribute("Pages")) or 0
	local lantern = tonumber(player:GetAttribute("Lantern")) or lanternMax
	local chased = player:GetAttribute("Chased") == true
	local won = player:GetAttribute("Won") == true
	local notice = tostring(player:GetAttribute("Notice") or "")
	local noticeAt = tonumber(player:GetAttribute("NoticeAt")) or 0
	-- NoticeKind canônico: "escape"|"locked"|"page"|"danger"|ausente (nil).
	-- Só canônicos passam; resto cai em nil → cor neutra, sem erro.
	local rawKind = player:GetAttribute("NoticeKind")
	local noticeKind: string? = nil
	if rawKind == "escape" or rawKind == "locked" or rawKind == "page" or rawKind == "danger" then
		noticeKind = (rawKind :: string)
	end

	objective.Text = ("PÁGINAS %d/%d — ANDE ATÉ A PÁGINA"):format(math.min(pages, pagesToWin), pagesToWin)

	local fraction = math.clamp(lantern / lanternMax, 0, 1)
	lanternFill.Size = UDim2.new(fraction, 0, 1, 0)
	if fraction < LANTERN_CRITICAL then
		lanternFill.BackgroundColor3 = Color3.fromRGB(150, 30, 30)
		lanternLabel.Text = "LANTERNA FRACA — VOLTE À LUZ"
		lanternLabel.TextColor3 = Color3.fromRGB(255, 80, 70)
	elseif fraction < LANTERN_LOW then
		lanternFill.BackgroundColor3 = Color3.fromRGB(255, 150, 60)
		lanternLabel.Text = ("LANTERNA %d%%"):format(math.floor(fraction * 100))
		lanternLabel.TextColor3 = Color3.fromRGB(255, 190, 120)
	else
		lanternFill.BackgroundColor3 = Color3.fromRGB(255, 190, 120)
		lanternLabel.Text = ("LANTERNA %d%%"):format(math.floor(fraction * 100))
		lanternLabel.TextColor3 = Color3.fromRGB(205, 195, 170)
	end

	if noticeAt > lastNoticeAt then
		lastNoticeAt = noticeAt
		if notice ~= "" then
			showToast(notice, noticeKind)
		end
	end

	-- The dark breathes: baseline dread, worse when hunted or almost out.
	-- Direct assignment only, so edit-mode and runtime agree.
	-- R15: caçada vs sufoco por TINTA (sem Tween): chase = vermelho-escuro,
	-- crítico/baseline = preto. Toast danger mantém vermelho; chased já é maior.
	local target = 0.72
	if chased then
		target = 0.45
	end
	if fraction < LANTERN_CRITICAL then
		-- R14: crítico 0.35 vs chase 0.45 — sufoco ≠ caçada. Sem Tween.
		target = math.min(target, 0.35)
	end
	vignette.BackgroundTransparency = target
	if chased then
		vignette.BackgroundColor3 = Color3.fromRGB(80, 5, 5)
	else
		vignette.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	end
	chasedLabel.Visible = chased and not won

	wonBanner.Visible = won
	if won then
		wonBanner.Text = "VOCÊ ESCAPOU"
		help.Visible = false
	end
end

player:GetAttributeChangedSignal("Pages"):Connect(refresh)
player:GetAttributeChangedSignal("PagesToWin"):Connect(refresh)
player:GetAttributeChangedSignal("Lantern"):Connect(refresh)
player:GetAttributeChangedSignal("LanternMax"):Connect(refresh)
player:GetAttributeChangedSignal("Notice"):Connect(refresh)
player:GetAttributeChangedSignal("NoticeAt"):Connect(refresh)
player:GetAttributeChangedSignal("NoticeKind"):Connect(refresh)
player:GetAttributeChangedSignal("Chased"):Connect(refresh)
player:GetAttributeChangedSignal("Won"):Connect(refresh)
refresh()

-- ============================================================
-- R2 PROJECTION (servidor R2 ausente nesta rodada): zero autoridade.
-- Lê SOMENTE attrs: LanternOn, Sanity, Stamina, Exhausted, Hidden,
-- HideCooldown, Phase, Escapes, Deaths, Ready (+Pages/PagesToWin p/ placar).
-- NENHUM Remote é referenciado por nome: botões F/Shift/Esconder/Ler/Ready
-- existem mas são inativos (Activated → toast "aguardando servidor R2").
-- F local via UserInputService só exibe o tooltip; nunca envia nada.
-- Sem Tween. ZIndex: HUD 5/6, lobby 25/26, dawn 26/27, nota 30-32.
-- Ajuda existente intocada.
-- ============================================================

local UserInputService = game:GetService("UserInputService")

local R2_WAIT_TOOLTIP = "aguardando servidor R2"

local function getNumAttr(name: string): number?
	local v = player:GetAttribute(name)
	if typeof(v) == "number" then
		return (v :: number)
	end
	if typeof(v) == "string" then
		return tonumber((v :: string))
	end
	return nil
end

local function getStrAttr(name: string): string?
	local v = player:GetAttribute(name)
	if typeof(v) == "string" then
		return (v :: string)
	end
	return nil
end

local function getBoolAttr(name: string): boolean?
	local v = player:GetAttribute(name)
	if typeof(v) == "boolean" then
		return (v :: boolean)
	end
	return nil
end

-- Sanity (acima do stamina; mesma linguagem da lanterna).
local sanityLabel = Instance.new("TextLabel")
sanityLabel.Name = "SanityLabel"
sanityLabel.AnchorPoint = Vector2.new(0, 1)
sanityLabel.Position = UDim2.new(0, 24, 1, -160)
sanityLabel.Size = UDim2.new(0, 300, 0, 20)
sanityLabel.BackgroundTransparency = 1
sanityLabel.TextColor3 = Color3.fromRGB(205, 195, 170)
sanityLabel.Font = Enum.Font.GothamBold
sanityLabel.TextSize = 14
sanityLabel.TextXAlignment = Enum.TextXAlignment.Left
sanityLabel.TextTruncate = Enum.TextTruncate.AtEnd
sanityLabel.ZIndex = 5
sanityLabel.Text = "SANIDADE —"
sanityLabel.Parent = gui
addStroke(sanityLabel, 1)

local sanityBack = Instance.new("Frame")
sanityBack.Name = "SanityBack"
sanityBack.AnchorPoint = Vector2.new(0, 1)
sanityBack.Position = UDim2.new(0, 24, 1, -140)
sanityBack.Size = UDim2.new(0, 260, 0, 14)
sanityBack.BackgroundTransparency = 0.2
sanityBack.BackgroundColor3 = Color3.fromRGB(8, 8, 12)
sanityBack.BorderSizePixel = 1
sanityBack.BorderColor3 = Color3.fromRGB(205, 195, 170)
sanityBack.ZIndex = 5
sanityBack.Parent = gui

local sanityFill = Instance.new("Frame")
sanityFill.Name = "SanityFill"
sanityFill.AnchorPoint = Vector2.new(0, 0.5)
sanityFill.Position = UDim2.new(0, 0, 0.5, 0)
sanityFill.Size = UDim2.new(1, 0, 1, 0)
sanityFill.BorderSizePixel = 0
sanityFill.BackgroundColor3 = Color3.fromRGB(150, 180, 255)
sanityFill.ZIndex = 6
sanityFill.Parent = sanityBack

-- Stamina (entre sanity e lanterna).
local staminaLabel = Instance.new("TextLabel")
staminaLabel.Name = "StaminaLabel"
staminaLabel.AnchorPoint = Vector2.new(0, 1)
staminaLabel.Position = UDim2.new(0, 24, 1, -124)
staminaLabel.Size = UDim2.new(0, 300, 0, 20)
staminaLabel.BackgroundTransparency = 1
staminaLabel.TextColor3 = Color3.fromRGB(205, 195, 170)
staminaLabel.Font = Enum.Font.GothamBold
staminaLabel.TextSize = 14
staminaLabel.TextXAlignment = Enum.TextXAlignment.Left
staminaLabel.TextTruncate = Enum.TextTruncate.AtEnd
staminaLabel.ZIndex = 5
staminaLabel.Text = "FÔLEGO —"
staminaLabel.Parent = gui
addStroke(staminaLabel, 1)

local staminaBack = Instance.new("Frame")
staminaBack.Name = "StaminaBack"
staminaBack.AnchorPoint = Vector2.new(0, 1)
staminaBack.Position = UDim2.new(0, 24, 1, -104)
staminaBack.Size = UDim2.new(0, 260, 0, 14)
staminaBack.BackgroundTransparency = 0.2
staminaBack.BackgroundColor3 = Color3.fromRGB(8, 8, 12)
staminaBack.BorderSizePixel = 1
staminaBack.BorderColor3 = Color3.fromRGB(205, 195, 170)
staminaBack.ZIndex = 5
staminaBack.Parent = gui

local staminaFill = Instance.new("Frame")
staminaFill.Name = "StaminaFill"
staminaFill.AnchorPoint = Vector2.new(0, 0.5)
staminaFill.Position = UDim2.new(0, 0, 0.5, 0)
staminaFill.Size = UDim2.new(1, 0, 1, 0)
staminaFill.BorderSizePixel = 0
staminaFill.BackgroundColor3 = Color3.fromRGB(140, 255, 170)
staminaFill.ZIndex = 6
staminaFill.Parent = staminaBack

-- Ícone LanternOn, topo direita: projeção do attr, fallback "—".
local lanternOnIcon = Instance.new("TextLabel")
lanternOnIcon.Name = "LanternOn"
lanternOnIcon.AnchorPoint = Vector2.new(1, 0)
lanternOnIcon.Position = UDim2.new(1, -24, 0, 18)
lanternOnIcon.Size = UDim2.new(0, 200, 0, 30)
lanternOnIcon.BackgroundTransparency = 0.55
lanternOnIcon.BackgroundColor3 = Color3.fromRGB(8, 8, 12)
lanternOnIcon.TextColor3 = Color3.fromRGB(205, 195, 170)
lanternOnIcon.Font = Enum.Font.GothamBold
lanternOnIcon.TextSize = 16
lanternOnIcon.ZIndex = 5
lanternOnIcon.Text = "LANTERNA —"
lanternOnIcon.Parent = gui
addStroke(lanternOnIcon, 1)

-- Estado Hidden, centro inferior: visível só quando há o que projetar.
local hiddenLabel = Instance.new("TextLabel")
hiddenLabel.Name = "Hidden"
hiddenLabel.AnchorPoint = Vector2.new(0.5, 1)
hiddenLabel.Position = UDim2.new(0.5, 0, 1, -170)
hiddenLabel.Size = UDim2.new(0, 300, 0, 26)
hiddenLabel.BackgroundTransparency = 0.55
hiddenLabel.BackgroundColor3 = Color3.fromRGB(8, 8, 12)
hiddenLabel.TextColor3 = Color3.fromRGB(150, 180, 255)
hiddenLabel.Font = Enum.Font.GothamBold
hiddenLabel.TextSize = 16
hiddenLabel.ZIndex = 5
hiddenLabel.Visible = false
hiddenLabel.Text = "ESCONDIDO"
hiddenLabel.Parent = gui
addStroke(hiddenLabel, 1)

-- Fileira de ações PRONTA mas INATIVA: nenhum Remote por nome, nenhum envio.
-- Cada botão só mostra o tooltip; abre caminho p/ o servidor R2 ligar.
local actionRow = Instance.new("Frame")
actionRow.Name = "Actions"
actionRow.AnchorPoint = Vector2.new(1, 1)
actionRow.Position = UDim2.new(1, -24, 1, -64)
actionRow.Size = UDim2.new(0, 348, 0, 36)
actionRow.BackgroundTransparency = 1
actionRow.ZIndex = 5
actionRow.Parent = gui

local actionLayout = Instance.new("UIListLayout")
actionLayout.FillDirection = Enum.FillDirection.Horizontal
actionLayout.Padding = UDim.new(0, 6)
actionLayout.Parent = actionRow

local actionSpecs = {
	{ key = "F", text = "F LANTERNA" },
	{ key = "Shift", text = "SHIFT CORRER" },
	{ key = "Hide", text = "ESCONDER" },
	{ key = "Read", text = "LER NOTA" },
	{ key = "Ready", text = "READY" },
}
for _, spec in actionSpecs do
	local btn = Instance.new("TextButton")
	btn.Name = "Action" .. (spec :: any).key
	btn.Size = UDim2.new(0, 64, 0, 36)
	btn.BackgroundTransparency = 0.2
	btn.BackgroundColor3 = Color3.fromRGB(8, 8, 12)
	btn.TextColor3 = Color3.fromRGB(120, 115, 105)
	btn.Font = Enum.Font.GothamBold
	btn.TextSize = 11
	btn.TextWrapped = true
	btn.AutoButtonColor = false
	btn.ZIndex = 6
	btn.Text = (spec :: any).text
	btn.Parent = actionRow
	btn.Activated:Connect(function()
		showToast(R2_WAIT_TOOLTIP)
	end)
end

-- Painel de leitura de nota: oculto até o servidor R2 fornecer conteúdo.
-- Fecha em X ou ao andar (delta HRP provado). Tudo local, sem remote.
local notePanel = Instance.new("Frame")
notePanel.Name = "NotePanel"
notePanel.AnchorPoint = Vector2.new(0.5, 0.5)
notePanel.Position = UDim2.new(0.5, 0, 0.5, 0)
notePanel.Size = UDim2.new(0, 420, 0, 280)
notePanel.BackgroundTransparency = 0.2
notePanel.BackgroundColor3 = Color3.fromRGB(8, 8, 12)
notePanel.ZIndex = 30
notePanel.Visible = false
notePanel.Parent = gui

local noteTitle = Instance.new("TextLabel")
noteTitle.Name = "NoteTitle"
noteTitle.AnchorPoint = Vector2.new(0.5, 0)
noteTitle.Position = UDim2.new(0.5, 0, 0, 12)
noteTitle.Size = UDim2.new(1, -64, 0, 28)
noteTitle.BackgroundTransparency = 1
noteTitle.TextColor3 = Color3.fromRGB(255, 214, 140)
noteTitle.Font = Enum.Font.GothamBold
noteTitle.TextSize = 18
noteTitle.TextTruncate = Enum.TextTruncate.AtEnd
noteTitle.ZIndex = 31
noteTitle.Text = ""
noteTitle.Parent = notePanel
addStroke(noteTitle, 1)

local noteBody = Instance.new("TextLabel")
noteBody.Name = "NoteBody"
noteBody.AnchorPoint = Vector2.new(0.5, 0)
noteBody.Position = UDim2.new(0.5, 0, 0, 48)
noteBody.Size = UDim2.new(1, -32, 1, -64)
noteBody.BackgroundTransparency = 1
noteBody.TextColor3 = Color3.fromRGB(230, 220, 200)
noteBody.Font = Enum.Font.Gotham
noteBody.TextSize = 15
noteBody.TextWrapped = true
noteBody.TextYAlignment = Enum.TextYAlignment.Top
noteBody.ZIndex = 31
noteBody.Text = ""
noteBody.Parent = notePanel

local noteClose = Instance.new("TextButton")
noteClose.Name = "NoteClose"
noteClose.AnchorPoint = Vector2.new(1, 0)
noteClose.Position = UDim2.new(1, -8, 0, 8)
noteClose.Size = UDim2.new(0, 32, 0, 32)
noteClose.BackgroundColor3 = Color3.fromRGB(40, 32, 24)
noteClose.TextColor3 = Color3.fromRGB(255, 214, 140)
noteClose.Font = Enum.Font.GothamBold
noteClose.TextSize = 16
noteClose.ZIndex = 32
noteClose.Text = "X"
noteClose.Parent = notePanel
noteClose.Activated:Connect(function()
	notePanel.Visible = false
end)

-- @systems R2: publicar como abrir (attrs NoteTitle/NoteBody ou remote de
-- leitura). showNote existe só como projeção; nada neste cliente a chama.
local noteOrigin: Vector3? = nil
local function showNote(title: string, body: string)
	noteTitle.Text = title
	noteBody.Text = body
	local hrp = getHRP()
	if hrp ~= nil then
		noteOrigin = hrp.Position
	else
		noteOrigin = nil
	end
	notePanel.Visible = true
end
RunService.Heartbeat:Connect(function()
	if not notePanel.Visible then
		return
	end
	local hrp = getHRP()
	if hrp == nil then
		return
	end
	if noteOrigin == nil then
		noteOrigin = hrp.Position
		return
	end
	if (hrp.Position - noteOrigin).Magnitude >= PROVEN_MOVE_STUDS then
		notePanel.Visible = false
	end
end)

-- Tela LOBBY: visível só quando Phase projeta lobby. Ready/score são leitura.
local lobbyPanel = Instance.new("Frame")
lobbyPanel.Name = "LobbyPanel"
lobbyPanel.AnchorPoint = Vector2.new(0.5, 0.5)
lobbyPanel.Position = UDim2.new(0.5, 0, 0.5, 0)
lobbyPanel.Size = UDim2.new(0, 440, 0, 300)
lobbyPanel.BackgroundTransparency = 0.2
lobbyPanel.BackgroundColor3 = Color3.fromRGB(8, 8, 12)
lobbyPanel.ZIndex = 25
lobbyPanel.Visible = false
lobbyPanel.Parent = gui

local lobbyPhase = Instance.new("TextLabel")
lobbyPhase.Name = "LobbyPhase"
lobbyPhase.AnchorPoint = Vector2.new(0.5, 0)
lobbyPhase.Position = UDim2.new(0.5, 0, 0, 12)
lobbyPhase.Size = UDim2.new(1, -24, 0, 30)
lobbyPhase.BackgroundTransparency = 1
lobbyPhase.TextColor3 = Color3.fromRGB(255, 214, 140)
lobbyPhase.Font = Enum.Font.GothamBold
lobbyPhase.TextSize = 20
lobbyPhase.ZIndex = 26
lobbyPhase.Text = "FASE: LOBBY"
lobbyPhase.Parent = lobbyPanel
addStroke(lobbyPhase, 1)

local lobbyReady = Instance.new("TextLabel")
lobbyReady.Name = "LobbyReady"
lobbyReady.AnchorPoint = Vector2.new(0.5, 0)
lobbyReady.Position = UDim2.new(0.5, 0, 0, 50)
lobbyReady.Size = UDim2.new(1, -24, 0, 28)
lobbyReady.BackgroundTransparency = 1
lobbyReady.TextColor3 = Color3.fromRGB(205, 195, 170)
lobbyReady.Font = Enum.Font.GothamBold
lobbyReady.TextSize = 16
lobbyReady.ZIndex = 26
lobbyReady.Text = "PRONTO: —"
lobbyReady.Parent = lobbyPanel

local lobbyScore = Instance.new("TextLabel")
lobbyScore.Name = "LobbyScore"
lobbyScore.AnchorPoint = Vector2.new(0.5, 0)
lobbyScore.Position = UDim2.new(0.5, 0, 0, 84)
lobbyScore.Size = UDim2.new(1, -24, 0, 60)
lobbyScore.BackgroundTransparency = 1
lobbyScore.TextColor3 = Color3.fromRGB(230, 220, 200)
lobbyScore.Font = Enum.Font.Gotham
lobbyScore.TextSize = 16
lobbyScore.TextWrapped = true
lobbyScore.ZIndex = 26
lobbyScore.Text = "PÁGINAS — • FUGAS — • MORTES —"
lobbyScore.Parent = lobbyPanel

local lobbyReadyBtn = Instance.new("TextButton")
lobbyReadyBtn.Name = "LobbyReadyBtn"
lobbyReadyBtn.AnchorPoint = Vector2.new(0.5, 1)
lobbyReadyBtn.Position = UDim2.new(0.5, 0, 1, -52)
lobbyReadyBtn.Size = UDim2.new(0, 220, 0, 36)
lobbyReadyBtn.BackgroundColor3 = Color3.fromRGB(40, 32, 24)
lobbyReadyBtn.TextColor3 = Color3.fromRGB(120, 115, 105)
lobbyReadyBtn.Font = Enum.Font.GothamBold
lobbyReadyBtn.TextSize = 16
lobbyReadyBtn.AutoButtonColor = false
lobbyReadyBtn.ZIndex = 26
lobbyReadyBtn.Text = "MARCAR READY"
lobbyReadyBtn.Parent = lobbyPanel
lobbyReadyBtn.Activated:Connect(function()
	showToast(R2_WAIT_TOOLTIP)
end)

local lobbyHint = Instance.new("TextLabel")
lobbyHint.Name = "LobbyHint"
lobbyHint.AnchorPoint = Vector2.new(0.5, 1)
lobbyHint.Position = UDim2.new(0.5, 0, 1, -12)
lobbyHint.Size = UDim2.new(1, -24, 0, 28)
lobbyHint.BackgroundTransparency = 1
lobbyHint.TextColor3 = Color3.fromRGB(120, 115, 105)
lobbyHint.Font = Enum.Font.Gotham
lobbyHint.TextSize = 13
lobbyHint.ZIndex = 26
lobbyHint.Text = R2_WAIT_TOOLTIP
lobbyHint.Parent = lobbyPanel

-- Tela DAWN: resultados projetados dos attrs. Leitura pura.
local dawnPanel = Instance.new("Frame")
dawnPanel.Name = "DawnPanel"
dawnPanel.AnchorPoint = Vector2.new(0.5, 0.5)
dawnPanel.Position = UDim2.new(0.5, 0, 0.5, 0)
dawnPanel.Size = UDim2.new(0, 440, 0, 240)
dawnPanel.BackgroundTransparency = 0.2
dawnPanel.BackgroundColor3 = Color3.fromRGB(8, 8, 12)
dawnPanel.ZIndex = 26
dawnPanel.Visible = false
dawnPanel.Parent = gui

local dawnTitle = Instance.new("TextLabel")
dawnTitle.Name = "DawnTitle"
dawnTitle.AnchorPoint = Vector2.new(0.5, 0)
dawnTitle.Position = UDim2.new(0.5, 0, 0, 12)
dawnTitle.Size = UDim2.new(1, -24, 0, 36)
dawnTitle.BackgroundTransparency = 1
dawnTitle.TextColor3 = Color3.fromRGB(255, 214, 140)
dawnTitle.Font = Enum.Font.GothamBold
dawnTitle.TextSize = 28
dawnTitle.ZIndex = 27
dawnTitle.Text = "AMANHECEU"
dawnTitle.Parent = dawnPanel
addStroke(dawnTitle, 1)

local dawnResult = Instance.new("TextLabel")
dawnResult.Name = "DawnResult"
dawnResult.AnchorPoint = Vector2.new(0.5, 0)
dawnResult.Position = UDim2.new(0.5, 0, 0, 60)
dawnResult.Size = UDim2.new(1, -24, 0, 120)
dawnResult.BackgroundTransparency = 1
dawnResult.TextColor3 = Color3.fromRGB(230, 220, 200)
dawnResult.Font = Enum.Font.Gotham
dawnResult.TextSize = 17
dawnResult.TextWrapped = true
dawnResult.ZIndex = 27
dawnResult.Text = "FUGAS — • MORTES — • PÁGINAS —"
dawnResult.Parent = dawnPanel

local function fmtCount(v: number?): string
	if v == nil then
		return "—"
	end
	return tostring(math.max(0, math.floor(v)))
end

local function refreshR2()
	local sanity = getNumAttr("Sanity")
	if sanity == nil then
		sanityLabel.Text = "SANIDADE —"
		sanityLabel.TextColor3 = Color3.fromRGB(120, 115, 105)
		sanityFill.Size = UDim2.new(1, 0, 1, 0)
		sanityFill.BackgroundColor3 = Color3.fromRGB(90, 90, 100)
	else
		local f = math.clamp(sanity / 100, 0, 1)
		sanityFill.Size = UDim2.new(f, 0, 1, 0)
		sanityLabel.Text = ("SANIDADE %d%%"):format(math.floor(f * 100))
		if f < LANTERN_CRITICAL then
			sanityFill.BackgroundColor3 = Color3.fromRGB(150, 30, 30)
			sanityLabel.TextColor3 = Color3.fromRGB(255, 80, 70)
		else
			sanityFill.BackgroundColor3 = Color3.fromRGB(150, 180, 255)
			sanityLabel.TextColor3 = Color3.fromRGB(205, 195, 170)
		end
	end

	local stamina = getNumAttr("Stamina")
	local exhausted = getBoolAttr("Exhausted")
	if stamina == nil then
		staminaLabel.Text = "FÔLEGO —"
		staminaLabel.TextColor3 = Color3.fromRGB(120, 115, 105)
		staminaFill.Size = UDim2.new(1, 0, 1, 0)
		staminaFill.BackgroundColor3 = Color3.fromRGB(90, 90, 100)
	else
		local f = math.clamp(stamina / 100, 0, 1)
		staminaFill.Size = UDim2.new(f, 0, 1, 0)
		if exhausted == true then
			staminaLabel.Text = "FÔLEGO — EXAUSTO"
			staminaLabel.TextColor3 = Color3.fromRGB(255, 80, 70)
			staminaFill.BackgroundColor3 = Color3.fromRGB(150, 30, 30)
		else
			staminaLabel.Text = ("FÔLEGO %d%%"):format(math.floor(f * 100))
			staminaLabel.TextColor3 = Color3.fromRGB(205, 195, 170)
			staminaFill.BackgroundColor3 = Color3.fromRGB(140, 255, 170)
		end
	end

	local lanternOn = getBoolAttr("LanternOn")
	if lanternOn == nil then
		lanternOnIcon.Text = "LANTERNA —"
		lanternOnIcon.TextColor3 = Color3.fromRGB(120, 115, 105)
	elseif lanternOn then
		lanternOnIcon.Text = "LANTERNA ACESA"
		lanternOnIcon.TextColor3 = Color3.fromRGB(255, 190, 120)
	else
		lanternOnIcon.Text = "LANTERNA APAGADA"
		lanternOnIcon.TextColor3 = Color3.fromRGB(120, 115, 105)
	end

	local hidden = getBoolAttr("Hidden")
	local hideCd = getNumAttr("HideCooldown") or 0
	if hidden == true then
		hiddenLabel.Visible = true
		if hideCd > 0 then
			hiddenLabel.Text = ("ESCONDIDO (%.0fs)"):format(hideCd)
		else
			hiddenLabel.Text = "ESCONDIDO"
		end
		hiddenLabel.TextColor3 = Color3.fromRGB(150, 180, 255)
	elseif hideCd > 0 then
		hiddenLabel.Visible = true
		hiddenLabel.Text = ("SAINDO… (%.0fs)"):format(hideCd)
		hiddenLabel.TextColor3 = Color3.fromRGB(120, 115, 105)
	else
		hiddenLabel.Visible = false
	end

	local rawPhase = getStrAttr("Phase")
	local phaseUpper = if rawPhase ~= nil then string.upper(rawPhase) else ""
	local pages = getNumAttr("Pages")
	local escapes = getNumAttr("Escapes")
	local deaths = getNumAttr("Deaths")
	local pagesToWin = getPagesToWin()
	local scoreLine = ("PÁGINAS %s/%d • FUGAS %s • MORTES %s"):format(
		fmtCount(pages), pagesToWin, fmtCount(escapes), fmtCount(deaths))

	local ready = getBoolAttr("Ready")
	if ready == nil then
		lobbyReady.Text = "PRONTO: —"
		lobbyReady.TextColor3 = Color3.fromRGB(120, 115, 105)
	elseif ready then
		lobbyReady.Text = "PRONTO ✓"
		lobbyReady.TextColor3 = Color3.fromRGB(140, 255, 170)
	else
		lobbyReady.Text = "NÃO PRONTO"
		lobbyReady.TextColor3 = Color3.fromRGB(205, 195, 170)
	end
	lobbyScore.Text = scoreLine

	lobbyPanel.Visible = phaseUpper == "LOBBY"
	dawnPanel.Visible = phaseUpper == "DAWN"
	if dawnPanel.Visible then
		dawnResult.Text = ("FUGAS %s • MORTES %s • %s"):format(
			fmtCount(escapes), fmtCount(deaths), scoreLine)
		help.Visible = false
	end
	if lobbyPanel.Visible then
		help.Visible = false
	end
end

for _, attrName in
	{ "LanternOn", "Sanity", "Stamina", "Exhausted", "Hidden", "HideCooldown", "Phase", "Escapes", "Deaths", "Ready", "Pages", "PagesToWin" }
do
	player:GetAttributeChangedSignal((attrName :: string)):Connect(refreshR2)
end
refreshR2()

-- F local: só tooltip enquanto o servidor R2 não existe. Nunca envia nada,
-- nunca referencia Remote por nome. Shift não toasta (evita spam ao correr).
local lastFToastAt = 0
UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	if input.KeyCode == Enum.KeyCode.F and notePanel.Visible == false then
		local now = os.clock()
		if now - lastFToastAt >= 1 then
			lastFToastAt = now
			showToast(R2_WAIT_TOOLTIP)
		end
	end
end)
