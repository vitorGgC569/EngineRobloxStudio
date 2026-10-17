local RS=game:GetService("ReplicatedStorage")
local Players=game:GetService("Players")
local RunService=game:GetService("RunService")
local UIS=game:GetService("UserInputService")
local Tween=game:GetService("TweenService")
local Debris=game:GetService("Debris")
local MarketplaceService=game:GetService("MarketplaceService")
local Forge=require(RS.Forge)
local C=require(RS.Shared.Config)
local Art=require(RS.Shared.Art)
local Net,UI=Forge.Net,Forge.UI
local player=Players.LocalPlayer
local P=C.colors
Net.define(C.net)
game:GetService("StarterGui"):SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList,false)
Forge.Audio.defineMany(Forge.Audio.Bank.specs())
local state=nil
local gui=UI.mount("SnackRollHUD",{ignoreInset=true})
local canvas=Instance.new("Frame");canvas.Name="Canvas";canvas.Size=UDim2.fromOffset(1280,800);canvas.AnchorPoint=Vector2.new(.5,.5);canvas.Position=UDim2.fromScale(.5,.5);canvas.BackgroundTransparency=1;canvas.Parent=gui
local scale=Instance.new("UIScale");scale.Parent=canvas
local function fit() local v=workspace.CurrentCamera.ViewportSize;scale.Scale=math.min(v.X/1280,v.Y/800) end
fit();workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
local function box(parent,name,x,y,w,h,color,radius)
	local f=Instance.new("Frame");f.Name=name;f.Position=UDim2.fromOffset(x,y);f.Size=UDim2.fromOffset(w,h);f.BackgroundColor3=color or P.cream;f.BorderSizePixel=0;f.Parent=parent;UI.corner(f,radius or 16);return f
end
local function label(parent,name,text,x,y,w,h,size,color)
	local t=Instance.new("TextLabel");t.Name=name;t.Position=UDim2.fromOffset(x,y);t.Size=UDim2.fromOffset(w,h);t.BackgroundTransparency=1;t.Text=text;t.TextColor3=color or P.ink;t.TextSize=size or 20;t.Font=Enum.Font.FredokaOne;t.TextWrapped=true;t.Parent=parent;return t
end
local function button(parent,name,text,x,y,w,h,color,fn)
	local b=Instance.new("TextButton");b.Name=name;b.Text=text;b.Position=UDim2.fromOffset(x,y);b.Size=UDim2.fromOffset(w,h);b.BackgroundColor3=color or P.blue;b.TextColor3=P.ink;b.TextSize=19;b.Font=Enum.Font.FredokaOne;b.TextWrapped=true;b.AutoButtonColor=true;b.BorderSizePixel=0;b.Parent=parent;UI.corner(b,14);UI.stroke(b,P.ink,2)
	for _,stroke in b:GetChildren() do if stroke:IsA("UIStroke") then stroke.ApplyStrokeMode=Enum.ApplyStrokeMode.Border end end
	b.Activated:Connect(function() Forge.Audio.play("ui.click",{volume=.2});fn() end);return b
end
local function viewport(parent,model,x,y,w,h)
	local v=Instance.new("ViewportFrame");v.Name="Preview";v.Position=UDim2.fromOffset(x,y);v.Size=UDim2.fromOffset(w,h);v.BackgroundTransparency=1;v.Ambient=Color3.fromRGB(190,190,190);v.LightColor=Color3.new(1,1,1);v.LightDirection=Vector3.new(-1,-2,-3);v.Parent=parent
	model.Parent=v;model:PivotTo(CFrame.new())
	local camera=Instance.new("Camera");camera.FieldOfView=37;camera.CFrame=CFrame.lookAt(Vector3.new(4,3.2,-6.5),Vector3.new(0,.3,0));camera.Parent=v;v.CurrentCamera=camera;return v
end
local function send(name,args) Net.send(name,args or {}) end
local brand=label(canvas,"Logo","SNACK\nROLL",22,82,140,82,36,P.cream);brand.TextStrokeColor3=P.ink;brand.TextStrokeTransparency=0
local weightBox=box(canvas,"WeightCard",382,28,235,60,P.cream);UI.stroke(weightBox,P.ink,3)
label(weightBox,"Icon","🍗",8,5,51,46,34)
local weightText=label(weightBox,"Weight","0",57,8,165,43,32)
local coinBox=box(canvas,"CoinsCard",633,28,235,60,P.gold);UI.stroke(coinBox,P.ink,3)
label(coinBox,"Icon","●",10,5,43,46,37,Color3.fromRGB(217,144,22))
local coinText=label(coinBox,"Coins","0",53,8,170,43,32)
local tutorial=box(canvas,"Hint",379,102,492,40,P.ink)
local hint=label(tutorial,"Text","Coma para crescer. Depois, quebre as fitas!",10,2,472,35,18,P.cream)
local nav={}
local openMenu
for i,def in {{"Foods","🍔  COMIDAS  [F]",P.orange,"foods"},{"Pets","🐾  PETS  [P]",P.blue,"pets"},{"Rebirths","♻  RENASCER",P.pink,"rebirth"},{"Gifts","🎁  PRESENTES",P.gold,"gifts"},{"Trails","✦  RASTROS",P.cream,"trails"}} do
	nav[def[1]]=button(canvas,def[1],def[2],20,176+(i-1)*59,167,49,def[3],function() openMenu(def[4]) end)
end
nav.Premium=button(canvas,"Premium","✨  LOJA ROBUX",20,435,167,49,P.gold,function() openMenu("premium") end)
local autoEat=button(canvas,"AutoEat","AUTO COMER\nLibera na comida 3",20,495,167,52,P.green,function() send("Auto",{kind="eat"}) end)
local autoRoll=button(canvas,"AutoRoll","AUTO ROLAR\nLibera no rebirth 1",20,557,167,52,P.blue,function() send("Auto",{kind="roll"}) end)
button(canvas,"Ranking","🏆  RANKING  [L]",20,619,167,44,P.gold,function() openMenu("ranking") end)
local daily=button(canvas,"Daily","🎁 PRESENTE\nDIÁRIO",1115,107,143,70,P.gold,function() openMenu("gifts") end)
local record=box(canvas,"Record",1107,197,150,105,P.ink)
local recordText=label(record,"Text","SEU RECORDE\n0 / 36 fitas",8,9,134,85,20,P.cream)
local podium=box(canvas,"ServerPodium",1015,315,181,137,P.ink)
label(podium,"Title","🏆  MAIOR PESO",8,4,165,25,16,P.gold)
local podiumRows={}
for i=1,3 do local row=label(podium,"Rank_"..i,"",8,30+(i-1)*32,165,29,15,P.cream);row.TextXAlignment=Enum.TextXAlignment.Left;podiumRows[i]=row end
local course=box(canvas,"Course",1211,337,42,277,P.cream)
local courseFill=box(course,"Fill",5,5,32,0,P.pink,12)
local courseText=label(canvas,"Distance","0 m",1100,625,157,33,23,P.cream);courseText.TextStrokeTransparency=.15;courseText.TextStrokeColor3=P.ink
local levelBox=box(canvas,"Level",390,626,500,42,P.ink)
local levelFill=box(levelBox,"Fill",4,4,0,34,P.orange,12)
local levelText=label(levelBox,"Caption","NÍVEL 1",8,0,484,42,21,P.cream)
local foodHolder=box(canvas,"FoodButton",520,683,123,96,P.green);UI.stroke(foodHolder,P.ink,3)
local heldViewport=viewport(foodHolder,Art.food("cookie"),7,0,109,70)
local eatButton=button(foodHolder,"Eat","COMER  [E]",3,64,117,29,P.green,function() send("Eat") end);eatButton.TextSize=16
local eatPicture=Instance.new("ImageButton");eatPicture.Name="EatPicture";eatPicture.BackgroundTransparency=1;eatPicture.Image="";eatPicture.Size=UDim2.fromOffset(123,64);eatPicture.ZIndex=2;eatPicture.Parent=foodHolder;eatPicture.Activated:Connect(function() send("Eat") end)
local rollButton=button(canvas,"Roll","ROLAR!  [R]",660,689,227,79,P.orange,function() if state and state.run then send("Return") else send("Roll") end end)
local gainText=label(canvas,"Gain","+4 por mordida",326,696,178,35,19,P.cream);gainText.TextStrokeTransparency=.15;gainText.TextStrokeColor3=P.ink
local mode=label(canvas,"SaveMode","Carregando progresso…",22,751,290,24,13,P.cream);mode.TextXAlignment=Enum.TextXAlignment.Left;mode.TextStrokeTransparency=.25
local resultBox=box(canvas,"Result",425,171,430,79,P.gold);resultBox.Visible=false
local resultText=label(resultBox,"Text","",12,5,406,69,24)
local toast=box(canvas,"Toast",350,561,580,43,P.ink);toast.Visible=false
local toastText=label(toast,"Text","",10,1,560,41,19,P.cream)
local toastSerial=0
local function message(text,kind)
	Forge.Audio.play(if kind=="error" then "ui.error" elseif kind=="reward" then "ui.success" else "ui.click",{volume=.25})
	toastSerial+=1;local serial=toastSerial;toast.Visible=true;toastText.Text=text;toast.BackgroundColor3=if kind=="error" then Color3.fromRGB(175,64,66) else P.ink
	task.delay(3,function() if serial==toastSerial then toast.Visible=false end end)
end
local shade=box(canvas,"ModalShade",0,0,1280,800,P.ink,1);shade.BackgroundTransparency=.45;shade.Visible=false;shade.ZIndex=20
local panel=box(shade,"Panel",295,155,690,470,P.cream,24)
local menuTitle=label(panel,"Title","",23,11,585,50,29);menuTitle.TextXAlignment=Enum.TextXAlignment.Left
button(panel,"Close","×",628,12,43,43,P.pink,function() shade.Visible=false end)
local content=Instance.new("ScrollingFrame");content.Name="Contents";content.Position=UDim2.fromOffset(20,79);content.Size=UDim2.fromOffset(650,373);content.CanvasSize=UDim2.fromOffset(0,0);content.BackgroundTransparency=1;content.BorderSizePixel=0;content.ScrollBarThickness=5;content.ScrollBarImageColor3=P.blue;content.Parent=panel
local function playerWeight(p)
	if p==player and state then return state.weight end
	return p:GetAttribute("Weight") or 0
end
local function orderedPlayers()
	local roster=Players:GetPlayers()
	table.sort(roster,function(a,b)
		local wa,wb=playerWeight(a),playerWeight(b)
		if wa==wb then return a.UserId<b.UserId end
		return wa>wb
	end)
	return roster
end
local function updatePodium()
	local roster=orderedPlayers()
	for i,row in podiumRows do
		local p=roster[i]
		row.Visible=p~=nil
		if p then
			row.Text=string.format("%d. %s  •  %s",i,p.DisplayName,C.format(playerWeight(p)))
			row.TextColor3=if i==1 then P.gold else P.cream
		end
	end
end
local menuRefresh={}
local menuType=nil
local function refreshMenu() for _,fn in menuRefresh do fn() end end
local function paragraph(text,y,h) local t=label(content,"Description",text,8,y,620,h,18);t.TextXAlignment=Enum.TextXAlignment.Left;return t end
openMenu=function(kind)
	if not state then return end
	if shade.Visible and menuType==kind then shade.Visible=false;return end
	menuType=kind;shade.Visible=true;content:ClearAllChildren();content.CanvasPosition=Vector2.zero;menuRefresh={}
	if kind=="premium" then
		menuTitle.Text="LOJA PREMIUM • ROBUX"
		paragraph("Itens permanentes e exclusivos. O passe é verificado pelo Roblox antes de liberar cada item.",0,58)
		for i,pass in C.premiumPasses do
			local row=box(content,"Pass_"..pass.id,2,66+(i-1)*164,631,152,Color3.fromRGB(232,224,251),15)
			local petDef;for _,pet in C.pets do if pet.pass==pass.id then petDef=pet;break end end
			if petDef then viewport(row,Art.pet(petDef),4,3,112,140) end
			local title=label(row,"Name",pass.name,122,10,344,31,24);title.TextXAlignment=Enum.TextXAlignment.Left
			local description=label(row,"Description",pass.description,122,45,354,60,16);description.TextXAlignment=Enum.TextXAlignment.Left
			local purchase=button(row,"Purchase","",474,48,145,59,P.gold,function() send("Premium",{id=pass.id}) end)
			if pass.gamePassId<1 then purchase.Text="ID DO PASSE\nPENDENTE";purchase.BackgroundColor3=Color3.fromRGB(193,191,205);purchase.AutoButtonColor=false end
			table.insert(menuRefresh,function()
				if pass.gamePassId>0 then
					purchase.Text=if state.premium[pass.id] then "ADQUIRIDO ✓" else "ADQUIRIR\nPELO ROBUX"
					purchase.BackgroundColor3=if state.premium[pass.id] then P.green else P.gold
				end
			end)
		end
		content.CanvasSize=UDim2.fromOffset(0,66+#C.premiumPasses*164)
	elseif kind=="foods" then
		menuTitle.Text="O CARDÁPIO • COMIDAS"
		for i,f in C.foods do
			local row=box(content,"Food_"..i,2,(i-1)*93,631,85,Color3.fromRGB(246,226,195),15)
			viewport(row,Art.food(f.id),4,1,89,79)
			local title=label(row,"Name",f.name,99,11,315,27,22);title.TextXAlignment=Enum.TextXAlignment.Left
			local sub=label(row,"Gain","+"..C.format(f.gain).." de peso base por mordida",99,43,310,26,15);sub.TextXAlignment=Enum.TextXAlignment.Left
			local buy=button(row,"BuyFood_"..i,"",435,19,178,49,P.green,function() send("BuyFood",{index=i}) end)
			table.insert(menuRefresh,function()
				buy.Text=if state.food==i then "EQUIPADO ✓" elseif state.food>i then "CONCLUÍDO" elseif state.food+1==i then C.format(f.cost).." MOEDAS" else "COMPRE A ANTERIOR"
				buy.BackgroundColor3=if i==state.food+1 then P.green else P.cream
			end)
		end
		local startY=#C.foods*93+8
		for i,f in C.premiumFoods do
			local y=startY+(i-1)*93;local row=box(content,"PremiumFood_"..f.id,2,y,631,85,Color3.fromRGB(233,224,250),15)
			viewport(row,Art.food(f.id),4,1,89,79)
			local title=label(row,"Name",f.name.."  ✨",99,11,315,27,22);title.TextXAlignment=Enum.TextXAlignment.Left
			local sub=label(row,"Gain","+"..C.format(f.gain).." de peso base • passe permanente",99,43,320,26,15);sub.TextXAlignment=Enum.TextXAlignment.Left
			local buy=button(row,"PremiumFoodAction_"..f.id,"",435,19,178,49,P.gold,function() if state.premium[f.pass] then send("PremiumFood",{id=f.id}) else send("Premium",{id=f.pass}) end end)
			table.insert(menuRefresh,function()
				buy.Text=if not state.premium[f.pass] then "EXCLUSIVO ROBUX" elseif state.premiumFood==f.id then "EQUIPADO ✓" else "EQUIPAR"
				buy.BackgroundColor3=if state.premium[f.pass] then P.green else P.gold
			end)
		end
		content.CanvasSize=UDim2.fromOffset(0,startY+#C.premiumFoods*93)
	elseif kind=="pets" then
		menuTitle.Text="SEUS COMPANHEIROS"
		local summary=paragraph("",0,40);table.insert(menuRefresh,function() summary.Text=#state.equipped.." / "..state.capacity.." equipados • Os bônus se somam e continuam após renascer." end)
		for i,p in C.pets do
			local row=box(content,"Pet_"..i,2,48+(i-1)*97,631,89,Color3.fromRGB(227,236,243))
			viewport(row,Art.pet(p),1,2,93,84)
			local n=label(row,"Name",p.name,101,11,294,30,23);n.TextXAlignment=Enum.TextXAlignment.Left
			local b=label(row,"Bonus","+"..math.floor(p.bonus*100).."% de peso por mordida",101,44,314,25,16);b.TextXAlignment=Enum.TextXAlignment.Left
			local action=button(row,"PetAction_"..i,"",435,21,178,47,P.blue,function() if p.pass and not state.premium[p.pass] then send("Premium",{id=p.pass}) else send("Pet",{index=i}) end end)
			table.insert(menuRefresh,function()
				action.Text=if p.pass and not state.premium[p.pass] then "EXCLUSIVO ROBUX" elseif not state.pets[p.id] then C.format(p.cost).." MOEDAS" elseif table.find(state.equipped,p.id) then "GUARDAR ✓" else "EQUIPAR"
				action.BackgroundColor3=if p.pass and not state.premium[p.pass] then P.gold else P.blue
			end)
		end
		content.CanvasSize=UDim2.fromOffset(0,48+#C.pets*97)
	elseif kind=="rebirth" then
		menuTitle.Text="UM NOVO APETITE"
		paragraph("Renascer reinicia seu peso, moedas e comidas. Você mantém pets, recordes, vitórias e recompensas já recebidas.",2,68)
		paragraph("Cada renascimento: +50% de ganho base de peso e +15% de moedas nas corridas. A cada 2 renascimentos, +1 pet equipado (até 5).",84,73)
		paragraph("O primeiro libera rolar automaticamente e mantém o auto comer disponível. Novos rastros desbloqueiam nos renascimentos 1, 2 e 3.",170,67)
		local needed=paragraph("",247,35);table.insert(menuRefresh,function() needed.Text="Requisito: "..C.format(state.rebirthCost).." de peso + recorde de 5 fitas." end)
		local confirm=false
		local b=button(content,"DoRebirth","RENASCER",105,298,419,51,P.pink,function()
			if not confirm then confirm=true;message("Confirme no botão: peso, moedas e comidas serão reiniciados.");refreshMenu() else confirm=false;send("Rebirth");shade.Visible=false end
		end)
		table.insert(menuRefresh,function() b.Text=if confirm then "CONFIRMAR RENASCIMENTO" else "RENASCER • "..state.rebirths.." ATUAIS" end)
		content.CanvasSize=UDim2.fromOffset(0,360)
	elseif kind=="gifts" then
		menuTitle.Text="UMA PAUSA PARA PRESENTES"
		paragraph("Um presente por dia e bônus pelo tempo ativo. A sequência diária cresce até 7 dias; os presentes de tempo renovam a cada dia (UTC).",0,58)
		local dailyButton=button(content,"ClaimDaily","",4,73,625,60,P.gold,function() send("Reward",{index=0}) end)
		table.insert(menuRefresh,function() dailyButton.Text=if state.dailyReady then "RESGATAR PRESENTE DIÁRIO" else "DIÁRIO RESGATADO • SEQUÊNCIA "..state.streak end)
		for i,gift in C.rewards do
			local b=button(content,"ClaimTime_"..i,"",4,150+(i-1)*63,625,53,P.blue,function() send("Reward",{index=i}) end)
			table.insert(menuRefresh,function()
				local left=math.max(0,gift.seconds-state.playSeconds)
				b.Text=if state.claims[tostring(i)] then "PRESENTE RESGATADO ✓" elseif left==0 then "RESGATAR "..C.format(gift.coins*(1+state.rebirths)).." MOEDAS" else string.format("%d MIN JOGADOS • FALTAM %d:%02d",gift.seconds/60,math.floor(left/60),left%60)
				b.BackgroundColor3=if left==0 and not state.claims[tostring(i)] then P.green else P.blue
			end)
		end
		content.CanvasSize=UDim2.fromOffset(0,410)
	elseif kind=="trails" then
		menuTitle.Text="DEIXE SUA MARCA"
		for i,trail in C.trails do
			local b=button(content,"Trail_"..i,"",4,(i-1)*78,625,63,trail.color,function() if trail.pass and not state.premium[trail.pass] then send("Premium",{id=trail.pass}) else send("Trail",{index=i}) end end)
			table.insert(menuRefresh,function() b.Text=trail.name..(if trail.pass and not state.premium[trail.pass] then " • EXCLUSIVO ROBUX" elseif state.trail==i then " • EQUIPADO" elseif state.rebirths<trail.rebirth then " • RENASCIMENTO "..trail.rebirth else " • EQUIPAR") end)
		end
		content.CanvasSize=UDim2.fromOffset(0,325)
	elseif kind=="ranking" then
		menuTitle.Text="MAIORES DO SERVIDOR"
		paragraph("Placar ao vivo ordenado pelo peso atual. O peso de todos é atualizado durante a partida.",0,58)
		local rankRows={}
		for i=1,50 do
			local row=box(content,"Rank_"..i,3,70+(i-1)*64,626,56,Color3.fromRGB(224,234,244));row.Visible=false
			local text=label(row,"Text","",15,2,596,50,21);text.TextXAlignment=Enum.TextXAlignment.Left;rankRows[i]={row=row,text=text}
		end
		table.insert(menuRefresh,function()
			local roster=orderedPlayers();content.CanvasSize=UDim2.fromOffset(0,70+#roster*64)
			for i,entry in rankRows do
				local p=roster[i];entry.row.Visible=p~=nil
				if p then entry.row.BackgroundColor3=if p==player then P.gold else Color3.fromRGB(224,234,244);entry.text.Text=string.format("%d. %s  •  %s peso  •  %d vitórias",i,p.DisplayName,C.format(playerWeight(p)),(p:FindFirstChild("leaderstats") and p.leaderstats["Vitórias"].Value or 0)) end
			end
		end)
	end
	refreshMenu()
end
local pets={}
local petKey=""
local shownFood=0
local function updatePets()
	local key=table.concat(state.equipped,",")
	if key==petKey then return end;petKey=key
	for _,m in pets do m:Destroy() end;pets={}
	for _,id in state.equipped do for _,def in C.pets do if id==def.id then local m=Art.pet(def);m.Parent=workspace;m:ScaleTo(.8);table.insert(pets,m) end end end
end
Net.on("State",function(data)
	state=data;weightText.Text=C.format(data.weight);coinText.Text=C.format(data.coins)
	gainText.Text="+"..C.format(data.gain).." por mordida"
	local low,high=C.levelBounds(data.weight);local alpha=math.clamp((data.weight-low)/math.max(1,high-low),0,1)
	levelFill.Size=UDim2.fromOffset(492*alpha,34);levelText.Text="NÍVEL "..C.level(data.weight).."  •  "..C.format(data.weight).." / "..C.format(high)
	recordText.Text="SEU RECORDE\n"..data.best.." / 36 fitas\n"..data.wins.." vitórias"
	local progress=if data.run then math.clamp(data.run.distance/984,0,1) else 0
	courseFill.Size=UDim2.fromOffset(32,267*progress);courseFill.Position=UDim2.fromOffset(5,272-267*progress)
	courseText.Text=if data.run then math.floor(data.run.distance).." m" else "0 m"
	rollButton.Text=if data.run then "VOLTAR" else "ROLAR!  [R]"
	hint.Text=if data.run then data.run.broken.." FITAS • "..C.format(data.run.energy).." PESO RESTANTE" elseif data.food==1 and data.coins>=50 then "Já pode comprar o donut! Abra COMIDAS [F]." elseif data.weight<8 then "Coma 2 vezes para começar sua primeira corrida." else "Entre na pista ou aperte R para rolar!"
	autoEat.Text="AUTO COMER\n"..(if data.autoEat then "LIGADO ✓" elseif data.food>=3 or data.rebirths>0 then "DESLIGADO" else "Libera na comida 3")
	autoRoll.Text="AUTO ROLAR\n"..(if data.autoRoll then "LIGADO ✓" elseif data.rebirths>0 then "DESLIGADO" else "Libera no rebirth 1")
	daily.Text=if data.dailyReady then "🎁 PRESENTE\nDISPONÍVEL!" else "🎁 PRESENTES\nPOR TEMPO"
	mode.Text=if data.persistent then "PROGRESSO SALVO AUTOMATICAMENTE" else "STUDIO • SESSÃO SEM SALVAMENTO"
	resultBox.Visible=data.result~=nil and data.run==nil and not shade.Visible
	if data.result then resultText.Text=(if data.result.win then "🏆 CAMPEÃO!" else "BOA CORRIDA!").."  +"..C.format(data.result.coins).." moedas\n"..data.result.broken.." fitas • "..data.result.distance.." m" end
	local activeFood=C.foods[data.food].id
	if data.premiumFood and data.premiumFood~="" then for _,food in C.premiumFoods do if food.id==data.premiumFood and data.premium and data.premium[food.pass] then activeFood=food.id;break end end end
	if activeFood~=shownFood then heldViewport:Destroy();heldViewport=viewport(foodHolder,Art.food(activeFood),7,0,109,64);shownFood=activeFood end
	refreshMenu();updatePets();updatePodium()
end)
Net.on("Feedback",function(data) message(data.text,data.kind) end)
local function resetTapes()
	local world=workspace:FindFirstChild("SnackRollWorld");local folder=world and world:FindFirstChild("Tapes")
	if folder then for _,p in folder:GetDescendants() do if p:IsA("BasePart") then p.LocalTransparencyModifier=0 elseif p:IsA("SurfaceGui") then p.Enabled=true end end end
end
local function pop(text)
	local t=label(canvas,"BitePopup",text,525+math.random(-50,50),500,230,55,32,P.gold);t.TextStrokeColor3=P.ink;t.TextStrokeTransparency=0
	Tween:Create(t,TweenInfo.new(.8),{Position=t.Position-UDim2.fromOffset(0,90),TextTransparency=1,TextStrokeTransparency=1}):Play();Debris:AddItem(t,.85)
end
local snackRests=setmetatable({}, {__mode="k"})
local biteTween
local biteSerial=0
local function animateBite()
	local char=player.Character;local weld=char and char:FindFirstChild("HeldSnackWeld",true)
	local head=char and char:FindFirstChild("Head")
	if not weld or not weld:IsA("Weld") or not weld.Part0 or not head then return end
	local hand=weld.Part0;local rest=snackRests[weld] or weld.C0;snackRests[weld]=rest;biteSerial+=1
	local serial=biteSerial;if biteTween then biteTween:Cancel() end
	local target=hand.CFrame:ToObjectSpace(head.CFrame*CFrame.new(0,-.13,-.72))*CFrame.Angles(math.rad(-16),0,math.rad(8))
	biteTween=Tween:Create(weld,TweenInfo.new(.17,Enum.EasingStyle.Back,Enum.EasingDirection.Out),{C0=target});biteTween:Play()
	task.delay(.19,function()
		if serial~=biteSerial or not weld.Parent then return end
		local origin=head.CFrame*CFrame.new(math.random(-12,12)/100,-.2,-.85)
		for i=1,4 do
			local crumb=Art.part(workspace,"BiteCrumb",Vector3.new(.16,.13,.15),origin,C.colors.gold,Enum.PartType.Ball)
			local destination=origin*CFrame.new(math.random(-15,15)/10,math.random(4,15)/10,math.random(-8,8)/10)
			Tween:Create(crumb,TweenInfo.new(.52,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{CFrame=destination,Size=Vector3.new(.025,.025,.025),Transparency=1}):Play();Debris:AddItem(crumb,.55)
		end
		biteTween=Tween:Create(weld,TweenInfo.new(.16,Enum.EasingStyle.Sine,Enum.EasingDirection.InOut),{C0=rest});biteTween:Play()
	end)
end
local function promptPass(id)
	for _,pass in C.premiumPasses do if pass.id==id then
		if pass.gamePassId<1 then message("O passe Robux de "..pass.name.." ainda não tem ID cadastrado para esta experiência.","error")
		else MarketplaceService:PromptGamePassPurchase(player,pass.gamePassId) end
		return
	end end
end
Players.PlayerAdded:Connect(function() task.defer(updatePodium);if menuType=="ranking" and shade.Visible then refreshMenu() end end)
Players.PlayerRemoving:Connect(function() task.defer(updatePodium);if menuType=="ranking" and shade.Visible then refreshMenu() end end)
local runningCamera=false
Net.on("Effect",function(data)
	if data.kind=="menu" then openMenu(data.menu)
	elseif data.kind=="eat" then pop("+"..C.format(data.gain).." 🍗");animateBite()
	elseif data.kind=="promptPass" then promptPass(data.id)
	elseif data.kind=="start" then runningCamera=true;shade.Visible=false;resetTapes()
	elseif data.kind=="reset" then runningCamera=false;workspace.CurrentCamera.CameraType=Enum.CameraType.Custom;resetTapes()
	elseif data.kind=="break" then
		Forge.Audio.play("combat.hit",{volume=.2,pitch=1.3})
		local world=workspace:FindFirstChild("SnackRollWorld");local gate=world and world.Tapes:FindFirstChild("Gate_"..data.index)
		if gate then for _,p in gate:GetDescendants() do if p:IsA("BasePart") and p.Name=="Tape" then p.LocalTransparencyModifier=1 elseif p:IsA("SurfaceGui") then p.Enabled=false end end end
		pop("+"..C.format(data.reward).." ●")
		for i=1,12 do
			local p=Art.part(workspace,"TapeConfetti",Vector3.new(.5,.18,1.4),CFrame.new(data.position+Vector3.new(math.random(-4,4),1,0)),C.zones[math.ceil(data.index/12)].color)
			Tween:Create(p,TweenInfo.new(.7),{CFrame=p.CFrame*CFrame.new(math.random(-10,10),math.random(3,9),math.random(-8,8))*CFrame.Angles(i,i,0),Transparency=1}):Play();Debris:AddItem(p,.75)
		end
	end
end)
UIS.InputBegan:Connect(function(input,processed)
	if processed or UIS:GetFocusedTextBox() then return end
	if input.KeyCode==Enum.KeyCode.E then if not shade.Visible then send("Eat") end
	elseif input.KeyCode==Enum.KeyCode.R then if not shade.Visible then if state and state.run then send("Return") else send("Roll") end end
	elseif input.KeyCode==Enum.KeyCode.F then openMenu("foods")
	elseif input.KeyCode==Enum.KeyCode.P then openMenu("pets")
	elseif input.KeyCode==Enum.KeyCode.L then openMenu("ranking")
	elseif input.KeyCode==Enum.KeyCode.B then openMenu("premium")
	elseif input.KeyCode==Enum.KeyCode.Escape then shade.Visible=false end
end)
RunService.RenderStepped:Connect(function(dt)
	local char=player.Character;local root=char and char:FindFirstChild("HumanoidRootPart");if not root then return end
	if runningCamera then
		local camera=workspace.CurrentCamera;camera.CameraType=Enum.CameraType.Scriptable
		local target=CFrame.lookAt(root.Position+Vector3.new(20,15,26),root.Position+Vector3.new(0,0,-16))
		camera.CFrame=camera.CFrame:Lerp(target,1-math.exp(-dt*7))
	end
	for i,m in pets do
		local phase=os.clock()*2.6+i*1.8
		local pos=if runningCamera then root.Position+Vector3.new((i-(#pets+1)/2)*3,1.6+math.sin(phase)*.19,7) else (root.CFrame*CFrame.new((i-(#pets+1)/2)*3,1.2+math.sin(phase)*.22,5)).Position
		local camera=workspace.CurrentCamera
		local target=CFrame.lookAt(pos,camera.CFrame.Position)*CFrame.Angles(0,0,math.sin(phase)*.045)
		m:PivotTo(m:GetPivot():Lerp(target,1-math.exp(-dt*6)))
	end
end)
player.CharacterAdded:Connect(function() runningCamera=false;workspace.CurrentCamera.CameraType=Enum.CameraType.Custom;resetTapes() end)
send("Ready")
task.spawn(function() for _=1,10 do if state then break end;task.wait(1);send("Ready") end end)
