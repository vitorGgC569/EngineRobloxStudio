local RS=game:GetService("ReplicatedStorage")
local Players=game:GetService("Players")
local RunService=game:GetService("RunService")
local MarketplaceService=game:GetService("MarketplaceService")
local Forge=require(RS.Forge)
local C=require(RS.Shared.Config)
local Art=require(RS.Shared.Art)
local World=require(script.World)
local Appearance=require(script.Appearance)
local Net,Save=Forge.Net,Forge.Save
local BarrierRun=Forge.Progression.BarrierRun
local states={}
Players.CharacterAutoLoads=false
Net.define(C.net);World.build(function(player,kind) Net.fire(player,"Effect",{kind="menu",menu=kind}) end)
local function notify(player,text,kind) Net.fire(player,"Feedback",{text=text,kind=kind or "info"}) end
local function state(player)
	local s=states[player]
	return if s and Save.get(player)==s.p then s else nil
end
local function alive(player)
	local char=player.Character;local root=char and char:FindFirstChild("HumanoidRootPart");local hum=char and char:FindFirstChildOfClass("Humanoid")
	return root,hum,hum and hum.Health>0 and root~=nil
end
local function credit(p,n) p.coins=math.min(1e12,p.coins+n) end
local function resetDay(p)
	local day=math.floor(os.time()/86400)
	if p.day~=day then p.day=day;p.playSeconds=0;p.claims={} end
end
local function sync(player)
	local s=state(player);if not s then return end
	local p=s.p;local r=s.run
	Net.fire(player,"State",{coins=p.coins,weight=p.weight,food=p.food,premiumFood=p.premiumFood,premium=p.premium,rebirths=p.rebirths,pets=p.pets,equipped=p.equipped,best=p.best,runs=p.runs,wins=p.wins,trail=p.trail,
		gain=C.gain(p),multiplier=C.multiplier(p),capacity=C.petCapacity(p),rebirthCost=C.rebirthCost(p),playSeconds=math.floor(p.playSeconds),claims=p.claims,dailyReady=p.lastDaily~=math.floor(os.time()/86400),streak=p.streak,
		autoEat=s.autoEat,autoRoll=s.autoRoll,persistent=Save.status(player).persistent,result=s.result,
		run=if r then {distance=r.distance,energy=r.energy,total=r.initialEnergy,broken=r.broken,reward=r.reward,finished=r.finished} else nil})
	for k,v in {Coins=p.coins,Weight=p.weight,Food=p.food,Rebirths=p.rebirths,Best=p.best,Runs=p.runs,PetCount=#p.equipped,Rolling=r~=nil,RunGates=if r then r.broken else 0} do player:SetAttribute(k,v) end
	local stats=player:FindFirstChild("leaderstats")
	if stats then stats.Fitas.Value=p.best;stats["Vitórias"].Value=p.wins;stats.Renascimentos.Value=p.rebirths end
end
local function passDefinition(id)
	for _,pass in C.premiumPasses do if pass.id==id then return pass end end
	return nil
end
local function grantPass(player,id)
	local s=state(player);local pass=passDefinition(id)
	if not s or not pass then return end
	s.p.premium=s.p.premium or {};s.p.pets=s.p.pets or {};s.p.premium[id]=true
	for _,pet in C.pets do if pet.pass==id then s.p.pets[pet.id]=true end end
	sync(player);notify(player,"Passe "..pass.name.." ativado! Seus itens exclusivos estão liberados.","reward")
end
local function appearance(player)
	local s=state(player);local root,hum,ok=alive(player);if not s or not ok or s.run then return end
	local char=player.Character
	Appearance.update(char,s.p.weight)
	local foodDef=C.foods[s.p.food]
	local foodId=foodDef.id
	if s.p.premiumFood and s.p.premiumFood~="" then
		for _,premiumFood in C.premiumFoods do if premiumFood.id==s.p.premiumFood and s.p.premium[premiumFood.pass] then foodId=premiumFood.id;break end end
	end
	if s.shownFood~=foodId then
		local old=char:FindFirstChild("HeldSnack");if old then old:Destroy() end
		local food=Art.food(foodId);food.Name="HeldSnack";food.Parent=char;food:ScaleTo(.45)
		local hand=char:FindFirstChild("RightHand") or char:FindFirstChild("Right Arm") or root
		local primary=food.PrimaryPart or food:FindFirstChildWhichIsA("BasePart");food.PrimaryPart=primary
		food:PivotTo(hand.CFrame*CFrame.new(0,-.36,-.55)*CFrame.Angles(-.32,0,0))
		for _,part in food:GetDescendants() do if part:IsA("BasePart") then
			part.Anchored=false;part.Massless=true
			if part==primary then
				local weld=Instance.new("Weld");weld.Name="HeldSnackWeld";weld.Part0=hand;weld.Part1=part;weld.C0=hand.CFrame:ToObjectSpace(part.CFrame);weld.Parent=part
			else local w=Instance.new("WeldConstraint");w.Part0=primary;w.Part1=part;w.Parent=part end
		end end
		s.shownFood=foodId
	end
	local trail=char:FindFirstChild("SnackTrail")
	if not trail then
		local a=Instance.new("Attachment");a.Position=Vector3.new(-1,0,1);a.Parent=root
		local b=Instance.new("Attachment");b.Position=Vector3.new(1,0,1);b.Parent=root
		trail=Instance.new("Trail");trail.Name="SnackTrail";trail.Attachment0=a;trail.Attachment1=b;trail.Lifetime=.5;trail.FaceCamera=true;trail.Parent=char
	end
	trail.Color=ColorSequence.new(C.trails[s.p.trail].color);trail.Enabled=s.p.trail>1
	local special=char:FindFirstChild("ExclusiveTrailFX",true)
	if s.p.trail>=5 then
		if not special then
			local attachment=Instance.new("Attachment");attachment.Name="ExclusiveTrailAttachment";attachment.Position=Vector3.new(0,-2.15,0);attachment.Parent=root
			special=Instance.new("ParticleEmitter");special.Name="ExclusiveTrailFX";special.Rate=8;special.Lifetime=NumberRange.new(.25,.55);special.Speed=NumberRange.new(.4,1.4);special.SpreadAngle=Vector2.new(180,180);special.LightEmission=.65;special.Size=NumberSequence.new({NumberSequenceKeypoint.new(0,.25),NumberSequenceKeypoint.new(1,.02)});special.Parent=attachment
		end
		special.Texture=if s.p.trail==5 then "rbxasset://textures/particles/sparkles_main.dds" else "rbxasset://textures/particles/fire_main.dds"
		special.Color=ColorSequence.new(C.trails[s.p.trail].color);special.Enabled=true
	elseif special then special:Destroy() end
end
local function returnToDiner(player)
	local s=state(player);if not s then return end
	local root,hum,ok=alive(player)
	if root then root.Anchored=false;root.AssemblyLinearVelocity=Vector3.zero;root.AssemblyAngularVelocity=Vector3.zero end
	if hum then hum.PlatformStand=false;hum.AutoRotate=true;hum.WalkSpeed=20;hum.JumpPower=45 end
	if ok then player.Character:PivotTo(CFrame.new(s.lane,4,21)) end
	s.run=nil;s.nextRoll=os.clock()+2;appearance(player);Net.fire(player,"Effect",{kind="reset"});sync(player)
end
local function finish(player,cancelled)
	local s=state(player);if not s or not s.run or s.paid then return end
	s.paid=true
	local r=s.run;if cancelled then r:cancel() end
	local p=s.p;local bonus=1+p.rebirths*.15;local reward=math.floor(r.reward*bonus)
	credit(p,reward);p.runs+=1;p.best=math.max(p.best,r.broken)
	if r.reason=="complete" then p.wins+=1;credit(p,math.floor(reward*.25));reward+=math.floor(reward*.25) end
	s.result={coins=reward,broken=r.broken,distance=math.floor(r.distance),win=r.reason=="complete"}
	Forge.Telemetry.event("snackroll.run_completed",{player=player.UserId,gates=r.broken,coins=reward})
	notify(player,if r.reason=="complete" then "PISTA COMPLETA! +"..C.format(reward).." moedas" else r.broken.." fitas rompidas! +"..C.format(reward).." moedas","reward")
	sync(player)
	task.delay(1.6,function() if state(player)==s and s.run==r then returnToDiner(player) end end)
end
local function eat(player)
	local s=state(player);local _,_,ok=alive(player);if not s or not ok or s.run then return end
	local now=os.clock();if now-(s.lastEat or 0)<.27 then return end;s.lastEat=now
	local gain=C.gain(s.p);s.p.weight=math.min(1e12,s.p.weight+gain);s.p.eaten+=1
	appearance(player);Net.fire(player,"Effect",{kind="eat",gain=gain});sync(player)
	if s.p.eaten==1 then Forge.Telemetry.event("snackroll.first_bite",{player=player.UserId}) end
end
local function startRoll(player)
	local s=state(player);local root,hum,ok=alive(player)
	if not s or not ok or s.run or os.clock()<(s.nextRoll or 0) then return end
	if s.p.weight<C.course.gates[1].cost then notify(player,"Coma até ter 8 de peso para romper a primeira fita.","error");return end
	s.run=BarrierRun.new(C.course,s.p.weight);s.paid=false;s.result=nil
	root.Anchored=true;hum.PlatformStand=true;hum.AutoRotate=false
	player.Character:PivotTo(CFrame.new(s.lane,3,-46))
	Net.fire(player,"Effect",{kind="start"});sync(player)
end
local function touch(player) local s=state(player);if s then s.lastActive=os.clock() end end
Net.on("Ready",function(player) sync(player) end)
Net.on("Eat",function(player) touch(player);eat(player) end)
Net.on("Roll",function(player) touch(player);startRoll(player) end)
Net.on("Return",function(player) touch(player);local s=state(player);if s and s.run then finish(player,true) end end)
Net.on("BuyFood",function(player,args)
	local s=state(player);if not s or s.run then return end;touch(player)
	local i=args.index;if i%1~=0 or i~=s.p.food+1 or not C.foods[i] then return end
	local f=C.foods[i];if s.p.coins<f.cost then notify(player,"Faltam "..C.format(f.cost-s.p.coins).." moedas.","error");return end
	s.p.coins-=f.cost;s.p.food=i;s.p.premiumFood="";appearance(player);sync(player);notify(player,f.name.." equipado!","reward")
	Forge.Telemetry.event("snackroll.food_bought",{player=player.UserId,food=f.id})
end)
Net.on("Pet",function(player,args)
	local s=state(player);if not s or s.run then return end;touch(player)
	local i=args.index;if i%1~=0 or not C.pets[i] then return end;local def=C.pets[i];local p=s.p
	if def.pass and not p.premium[def.pass] then
		Net.fire(player,"Effect",{kind="promptPass",id=def.pass});return
	end
	if not p.pets[def.id] then
		if p.coins<def.cost then notify(player,"Faltam "..C.format(def.cost-p.coins).." moedas.","error");return end
		p.coins-=def.cost;p.pets[def.id]=true;notify(player,def.name.." agora faz parte da equipe!","reward")
		if #p.equipped<C.petCapacity(p) then table.insert(p.equipped,def.id) end
	else
		local index=table.find(p.equipped,def.id)
		if index then table.remove(p.equipped,index)
		elseif #p.equipped<C.petCapacity(p) then table.insert(p.equipped,def.id)
		else notify(player,"Equipe cheia. Guarde um pet antes de equipar outro.","error") end
	end
	sync(player)
end)
Net.on("Rebirth",function(player)
	local s=state(player);if not s or s.run then return end;touch(player)
	local p=s.p;local cost=C.rebirthCost(p)
	if p.weight<cost or p.best<5 then notify(player,"Precisa de "..C.format(cost).." de peso e recorde de 5 fitas.","error");return end
	p.rebirths+=1;p.weight=0;p.coins=0;p.food=1;s.autoRoll=false;s.autoEat=false;s.result=nil
	appearance(player);sync(player);notify(player,"Renascimento! Bônus permanente de comida e moedas aumentado.","reward")
end)
Net.on("Reward",function(player,args)
	local s=state(player);if not s then return end;touch(player);local p=s.p;resetDay(p)
	local index=args.index;if index%1~=0 then return end
	if index==0 then
		local day=math.floor(os.time()/86400)
		if p.lastDaily==day then return end
		p.streak=if p.lastDaily==day-1 then math.min(7,p.streak+1) else 1;p.lastDaily=day
		local reward=200*p.streak*(1+p.rebirths);credit(p,reward);notify(player,"Dia "..p.streak..": +"..C.format(reward).." moedas!","reward")
	else
		local gift=C.rewards[index]
		if not gift or p.claims[tostring(index)] or p.playSeconds<gift.seconds then return end
		p.claims[tostring(index)]=true;credit(p,gift.coins*(1+p.rebirths));notify(player,"Presente de tempo resgatado!","reward")
	end
	sync(player)
end)
Net.on("Auto",function(player,args)
	local s=state(player);if not s then return end;touch(player)
	if args.kind=="eat" then
		if s.p.food<3 and s.p.rebirths<1 then notify(player,"A alimentação automática libera nas fritas (comida 3).","error");return end;s.autoEat=not s.autoEat
	elseif args.kind=="roll" then
		if s.p.rebirths<1 then notify(player,"Renascimento 1 libera rolar automaticamente.","error");return end;s.autoRoll=not s.autoRoll
	end
	sync(player)
end)
Net.on("Trail",function(player,args)
	local s=state(player);if not s then return end
	local i=args.index;if i%1~=0 or not C.trails[i] then return end
	local def=C.trails[i]
	if def.pass and not s.p.premium[def.pass] then Net.fire(player,"Effect",{kind="promptPass",id=def.pass});return end
	if s.p.rebirths<def.rebirth then return end
	s.p.trail=i;appearance(player);sync(player)
end)
Net.on("Premium",function(player,args)
	local s=state(player);local pass=passDefinition(args.id)
	if not s or not pass then return end
	if pass.gamePassId<1 then notify(player,"Passe Robux aguardando o ID da experiência onde será criado.","error");return end
	local ok,owns=pcall(function() return MarketplaceService:UserOwnsGamePassAsync(player.UserId,pass.gamePassId) end)
	if ok and owns then grantPass(player,pass.id);return end
	Net.fire(player,"Effect",{kind="promptPass",id=pass.id})
end)
Net.on("PremiumFood",function(player,args)
	local s=state(player);if not s or s.run then return end
	for _,food in C.premiumFoods do if food.id==args.id then
		if not s.p.premium[food.pass] then Net.fire(player,"Effect",{kind="promptPass",id=food.pass});return end
		s.p.premiumFood=if s.p.premiumFood==food.id then "" else food.id
		appearance(player);sync(player);return
	end end
end)
MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player,gamePassId,purchased)
	if not purchased then return end
	for _,pass in C.premiumPasses do if pass.gamePassId==gamePassId and gamePassId>0 then
		task.spawn(function()
			local ok,owns=pcall(function() return MarketplaceService:UserOwnsGamePassAsync(player.UserId,gamePassId) end)
			if ok and owns then grantPass(player,pass.id) else notify(player,"A compra foi concluída; não consegui confirmar o passe ainda. Reabra a loja em instantes.","error") end
		end)
		return
	end end
end)
Save.configure({store="SnackRoll_Profiles_v1",version=1,template=C.template,autosaveInterval=45,enabled=not RunService:IsStudio()})
Save.onFailed:Connect(function(player) player:Kick("Seu progresso não pôde ser carregado com segurança. Entre novamente.") end)
Save.observe(function(player,p)
	resetDay(p)
	p.pets=p.pets or {};p.equipped=p.equipped or {};p.premium=p.premium or {};p.premiumFood=p.premiumFood or ""
	local s={p=p,lane=((player.UserId%5)-2)*7,lastActive=os.clock(),autoEat=false,autoRoll=false};states[player]=s
	task.spawn(function()
		for _,pass in C.premiumPasses do if pass.gamePassId>0 and not p.premium[pass.id] then
			local ok,owns=pcall(function() return MarketplaceService:UserOwnsGamePassAsync(player.UserId,pass.gamePassId) end)
			if ok and owns and player.Parent then grantPass(player,pass.id) end
		end end
	end)
	local stats=Instance.new("Folder");stats.Name="leaderstats";stats.Parent=player
	for _,name in {"Fitas","Vitórias","Renascimentos"} do local v=Instance.new("IntValue");v.Name=name;v.Parent=stats end
	player.CharacterAdded:Connect(function(char)
		local hum=char:WaitForChild("Humanoid");char:WaitForChild("HumanoidRootPart");s.shownFood=nil;s.run=nil;s.paid=false
		if not player:HasAppearanceLoaded() then player.CharacterAppearanceLoaded:Wait() end
		if player.Character~=char or not player.Parent then return end
		hum.WalkSpeed=20;hum.JumpPower=45;char:PivotTo(CFrame.new(0,4,33));appearance(player);sync(player)
		hum.Died:Connect(function()
			if s.run then finish(player,true) end
			task.delay(3,function() if player.Parent then player:LoadCharacterAsync() end end)
		end)
	end)
	player:LoadCharacterAsync();sync(player)
	Forge.Telemetry.event("snackroll.join",{player=player.UserId})
end)
Players.PlayerRemoving:Connect(function(player) states[player]=nil end)
Save.start()
local elapsed=0
RunService.Heartbeat:Connect(function(dt)
	elapsed+=dt
	for player,s in states do
		if s.run and not s.run.finished then
			local root,_,ok=alive(player)
			if not ok then finish(player,true);continue end
			local events=s.run:step(math.min(dt,.15))
			local radius=player.Character:GetAttribute("RollRadius") or 3
			player.Character:PivotTo(CFrame.new(s.lane,radius+1,-46-s.run.distance)*CFrame.Angles(-s.run.distance/radius,0,0))
			for _,event in events do Net.fire(player,"Effect",{kind="break",index=event.index,reward=event.reward,position=root.Position}) end
			if s.run.finished then finish(player,false) end
		elseif not s.run then
			local root,_,ok=alive(player)
			if ok and root.Position.Z< -48 then startRoll(player);if not s.run then player.Character:PivotTo(CFrame.new(0,4,-37)) end end
		end
	end
	if elapsed<.25 then return end
	local tickTime=elapsed;elapsed=0
	for player,s in states do
		resetDay(s.p)
		local root=select(1,alive(player))
		if root and not s.run and (not s.lastPosition or (root.Position-s.lastPosition).Magnitude>.7) then s.lastActive=os.clock() end
		if root then s.lastPosition=root.Position end
		if os.clock()-s.lastActive<300 then
			s.p.playSeconds+=tickTime
			if s.autoEat and not s.run then eat(player) end
			if s.autoRoll and not s.run and os.clock()-(s.nextRoll or 0)>6 then startRoll(player) end
		else s.autoEat=false;s.autoRoll=false end
		sync(player)
	end
end)
if RunService:IsStudio() then task.spawn(function() Forge.Testing.runAndPublish(script.tests,nil,"snackroll") end) end
