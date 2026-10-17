local RS=game:GetService("ReplicatedStorage")
local Build=require(game.ServerScriptService.WorldKit.Build)
local C=require(RS.Shared.Config)
local Art=require(RS.Shared.Art)
local World={}
local P=C.colors
local root
local function part(name,size,pos,color,options)
	return Build.part(root,name,size,pos,{color=color,material=Enum.Material.SmoothPlastic},options)
end
local function cylinder(name,size,pos,color)
	return Build.cylinder(root,name,size,pos,{color=color,material=Enum.Material.SmoothPlastic})
end
local function rounded(name,size,cf,color,material)
	return Art.mesh(root,name,"rounded",size,cf,color,material)
end
local function sign(name,text,cf,size,color)
	local p=part(name,Vector3.new(size.X,size.Y,.35),cf.Position,color or P.ink,{canCollide=false});p.CFrame=cf
	for _,face in {Enum.NormalId.Front,Enum.NormalId.Back} do
		local gui=Instance.new("SurfaceGui");gui.Face=face;gui.CanvasSize=Vector2.new(size.X*35,size.Y*35);gui.LightInfluence=0;gui.Parent=p
		local t=Instance.new("TextLabel");t.Size=UDim2.fromScale(.94,.88);t.Position=UDim2.fromScale(.03,.06);t.BackgroundTransparency=1;t.Text=text;t.TextScaled=true;t.TextColor3=P.cream;t.Font=Enum.Font.FredokaOne;t.Parent=gui
	end
	return p
end
local function tree(x,z,scale,color)
	cylinder("Trunk",Vector3.new(1.2,5,1.2)*scale,Vector3.new(x,2.5*scale,z),Color3.fromRGB(139,100,71))
	for i=0,2 do
		local p=part("Foliage",Vector3.new(7-i,6,7-i)*scale,Vector3.new(x+math.sin(i*3)*1.6*scale,(5+i*1.7)*scale,z),color,{shape=Enum.PartType.Ball})
		p.CanCollide=false
	end
end
local function display(def,x,z,label,pet,onMenu)
	cylinder("DisplayBase",Vector3.new(11,.7,11),Vector3.new(x,.75,z),P.ink)
	cylinder("DisplayRim",Vector3.new(10,.28,10),Vector3.new(x,1.25,z),def.color)
	cylinder("DisplayTop",Vector3.new(8.9,.3,8.9),Vector3.new(x,1.45,z),P.cream)
	Art.mesh(root,"PedestalTrim","ring",Vector3.new(10.1,.22,10.1),CFrame.new(x,1.37,z),Color3.fromRGB(187,215,220),Enum.Material.Metal)
	local m=if pet then Art.pet(def) else Art.food(def.id);m.Parent=root;m:ScaleTo(if pet then 1.7 else 2);m:PivotTo(CFrame.new(x,3.9,z)*CFrame.Angles(0,math.pi+math.pi/7,0))
	sign("DisplayLabel",label,CFrame.new(x,7.7,z+1),Vector2.new(10,2),P.ink)
	if onMenu then
		local prompt=Instance.new("ProximityPrompt");prompt.ActionText=if pet then "Ver pets" else "Ver cardápio";prompt.ObjectText=if pet then "Adoção" else "Comidas";prompt.KeyboardKeyCode=Enum.KeyCode.Q;prompt.MaxActivationDistance=13;prompt.RequiresLineOfSight=false;prompt.Parent=m:FindFirstChildWhichIsA("BasePart")
		prompt.Triggered:Connect(function(player) onMenu(player,if pet then "pets" else "foods") end)
	end
end
local function tableSet(x,z)
	Art.mesh(root,"CafeTable","bun",Vector3.new(9,.55,9),CFrame.new(x,3.45,z),Color3.fromRGB(239,230,210))
	Art.mesh(root,"TableRim","ring",Vector3.new(8.9,.18,8.9),CFrame.new(x,3.35,z),Color3.fromRGB(158,179,188),Enum.Material.Metal)
	cylinder("TableLeg",Vector3.new(.55,3,.55),Vector3.new(x,1.7,z),P.ink)
	cylinder("Foot",Vector3.new(3,.2,3),Vector3.new(x,.3,z),P.ink)
	for _,dx in {-6,6} do
		rounded("ChairSeat",Vector3.new(3.5,.65,3.5),CFrame.new(x+dx,2,z),Color3.fromRGB(44,133,153),Enum.Material.Fabric)
		rounded("ChairBack",Vector3.new(.7,3.4,3.5),CFrame.new(x+dx+math.sign(dx)*1.4,3.5,z),Color3.fromRGB(44,133,153),Enum.Material.Fabric)
		for _,a in {-1,1} do for _,b in {-1,1} do cylinder("ChairLeg",Vector3.new(.25,1.6,.25),Vector3.new(x+dx+a*1.2,1,z+b*1.2),P.ink) end end
	end
	local food=Art.food(if z>15 then "burger" else "donut");food.Parent=root;food:ScaleTo(.55);food:PivotTo(CFrame.new(x,4.2,z))
	cylinder("CeramicPlate",Vector3.new(2.6,.15,2.6),Vector3.new(x,3.8,z),P.cream)
	rounded("NapkinDispenser",Vector3.new(.7,.85,.5),CFrame.new(x+2,4.1,z),Color3.fromRGB(156,179,193),Enum.Material.Metal)
	rounded("Napkins",Vector3.new(.58,.32,.4),CFrame.new(x+2,4.66,z),P.cream)
	cylinder("SodaCup",Vector3.new(.66,1,.66),Vector3.new(x-2,4.2,z),P.pink)
	part("Straw",Vector3.new(.08,1,.08),Vector3.new(x-2,5,z),P.cream,{canCollide=false})
end
function World.build(onMenu)
	Art.prepare()
	local old=workspace:FindFirstChild("SnackRollWorld");if old then old:Destroy() end
	root=Instance.new("Folder");root.Name="SnackRollWorld";root.Parent=workspace
	part("DinerFoundation",Vector3.new(130,2,116),Vector3.new(0,-1,12),P.ink)
	for x=-60,60,8 do for z=-40,64,8 do
		local parity=(math.floor((x+60)/8)+math.floor((z+40)/8))%2
		local tile=part("CheckerTile",Vector3.new(7.96,.15,7.96),Vector3.new(x,.05,z),if parity==0 then Color3.fromRGB(108,160,181) else Color3.fromRGB(229,231,220));tile.Material=Enum.Material.Marble;tile.Reflectance=.035
	end end
	local aisle=part("PeachAisle",Vector3.new(22,.18,112),Vector3.new(0,.17,12),Color3.fromRGB(229,177,145));aisle.Material=Enum.Material.Concrete
	for _,x in {-11.3,11.3} do part("AisleInlay",Vector3.new(.45,.08,112),Vector3.new(x,.24,12),P.cream,{canCollide=false}) end
	for z=-32,48,12 do
		for _,s in {-1,1} do local p=part("GoArrow",Vector3.new(4.7,.1,1),Vector3.new(s*1.6,.33,z),P.gold,{canCollide=false});p.Orientation=Vector3.new(0,s*-40,0) end
	end
	-- Open-front restaurant, with a wide unobstructed view of the course.
	for _,x in {-65,65} do
		part("SideWall",Vector3.new(2,30,116),Vector3.new(x,15,12),Color3.fromRGB(255,196,150))
		part("Wainscot",Vector3.new(2.3,7,116),Vector3.new(x,3.5,12),P.cream)
		part("BlueTrim",Vector3.new(2.5,.6,116),Vector3.new(x,7.4,12),P.blue)
		for z=-40,64,8 do part("WallStripe",Vector3.new(2.05,22,3.8),Vector3.new(x,19,z),Color3.fromRGB(245,147,105)) end
		for z=-40,64,12 do
			part("PanelDivider",Vector3.new(2.4,5.6,.22),Vector3.new(x,3.5,z),Color3.fromRGB(205,194,174))
		end
	end
	part("BackWall",Vector3.new(130,30,2),Vector3.new(0,15,70),P.orange)
	for _,x in {-44,44} do
		part("FrontWing",Vector3.new(40,30,2),Vector3.new(x,15,-46),P.orange)
		part("FrontWainscot",Vector3.new(40,7,2.5),Vector3.new(x,3.5,-46),P.cream)
		part("FrontTrim",Vector3.new(40,.6,2.8),Vector3.new(x,7.4,-46),Color3.fromRGB(38,115,135))
		for sx=-16,16,8 do part("FrontStripe",Vector3.new(3.2,22,2.05),Vector3.new(x+sx,19,-46),Color3.fromRGB(241,175,125)) end
		part("Doorframe",Vector3.new(2.2,27,3.4),Vector3.new(math.sign(x)*24,13.5,-46),P.ink)
	end
	part("DoorLintel",Vector3.new(50,3,4),Vector3.new(0,28,-46),P.ink)
	sign("CourseEntrance","COMA. CRESÇA. QUEBRE TUDO!",CFrame.new(0,25,-44),Vector2.new(44,3.5),P.blue)
	sign("Brand","SNACK ROLL\nDINER & RACE CLUB",CFrame.new(0,20,68),Vector2.new(38,10),P.ink)
	for _,x in {-44,44} do for _,z in {-15,9,33} do tableSet(x,z) end end
	for _,x in {-44,44} do
		local color=if x<0 then P.blue else P.pink
		sign("FoodPoster","",CFrame.new(x,17,-44),Vector2.new(14,20),P.cream)
		sign("PosterInset","",CFrame.new(x,17,-43.7),Vector2.new(12.5,18.4),color)
		sign("PosterTitle",if x<0 then "DUPLO SABOR!" else "FEITO COM AMOR",CFrame.new(x,24,-43.3),Vector2.new(11,2.1),color)
		sign("PosterCaption",if x<0 then "MAIS PESO. MAIS LONGE." else "A VIDA É MAIS DOCE AQUI",CFrame.new(x,10,-43.3),Vector2.new(11,2.2),color)
		local food=Art.food(if x<0 then "burger" else "donut");food.Parent=root;food:ScaleTo(2.6);food:PivotTo(CFrame.new(x,17,-41)*CFrame.Angles(math.rad(45),0,math.rad(-12)))
	end
	-- Service counter, backsplash, stools and suspended menu boards.
	rounded("Counter",Vector3.new(38,4,8),CFrame.new(-38,2,58),Color3.fromRGB(42,123,144),Enum.Material.Wood)
	rounded("CounterTop",Vector3.new(40,.7,10),CFrame.new(-38,4.3,58),P.cream,Enum.Material.Marble)
	for x=-54,-22,4 do rounded("CounterFlute",Vector3.new(.25,3.1,.22),CFrame.new(x,2.1,53.96),Color3.fromRGB(95,164,176)) end
	rounded("PastryCase",Vector3.new(12,4.5,5),CFrame.new(-42,7,59),Color3.fromRGB(202,231,230),Enum.Material.Glass).Transparency=.72
	rounded("PastryBase",Vector3.new(12.3,.5,5.3),CFrame.new(-42,4.9,59),Color3.fromRGB(78,99,111),Enum.Material.Metal)
	rounded("Register",Vector3.new(3,2.2,2.2),CFrame.new(-25,5.7,58)*CFrame.Angles(.15,0,0),P.ink)
	rounded("RegisterScreen",Vector3.new(2.6,1.4,.1),CFrame.new(-25,6.1,56.8)*CFrame.Angles(.15,0,0),Color3.fromRGB(120,207,195))
	for x=-52,-24,7 do
		cylinder("Stool",Vector3.new(3,.5,3),Vector3.new(x,2.8,49),P.pink)
		cylinder("StoolStem",Vector3.new(.45,2.5,.45),Vector3.new(x,1.3,49),P.ink)
		local f=Art.food(C.foods[(math.floor((x+52)/7)%4)+1].id);f.Parent=root;f:PivotTo(CFrame.new(x,5,58))
	end
	sign("CounterMenu","FEITO NA HORA\nCOOKIES • DONUTS • BURGERS",CFrame.new(-40,13,68),Vector2.new(35,6),P.ink)
	display(C.foods[4],-17,-26,"COMIDAS  [F]",false,onMenu)
	display(C.pets[1],18,-21,"PETS  [P]",true,onMenu)
	display(C.pets[4],43,55,"ADOTE UM AMIGO",true,onMenu)
	-- Sculpted mascot chef: layered uniform, stitched apron, expressive face and toque.
	local chef=Instance.new("Model");chef.Name="ChefCookie";chef.Parent=root
	local skin=Color3.fromRGB(246,194,147);local cocoa=Color3.fromRGB(105,65,57);local mint=Color3.fromRGB(91,194,171)
	local function chefPart(n,size,pos,color,rot,material)
		return Art.mesh(chef,n,"rounded",size,CFrame.new(pos)*CFrame.Angles(0,0,rot or 0),color,material)
	end
	chefPart("ChefTrousers",Vector3.new(4.3,2.5,2.8),Vector3.new(0,1.75,0),Color3.fromRGB(67,82,101))
	for _,x in {-1,1} do
		chefPart("TrouserSeam",Vector3.new(.13,1.65,.08),Vector3.new(x*.46,1.7,1.42),Color3.fromRGB(121,137,148))
		chefPart("PolishedShoe",Vector3.new(2.15,.9,2.8),Vector3.new(x*1.22,.55,.42),P.ink)
		chefPart("Sole",Vector3.new(2.2,.19,2.82),Vector3.new(x*1.22,.2,.42),Color3.fromRGB(75,73,85))
		chefPart("Sleeve",Vector3.new(1.9,3.1,2.35),Vector3.new(x*2.84,5.15,.08),P.cream,x*.13)
		chefPart("Cuff",Vector3.new(1.87,.53,2.37),Vector3.new(x*3.01,3.75,.17),mint,x*.13)
		chefPart("Hand",Vector3.new(1.19,1.25,1.1),Vector3.new(x*3.13,3.12,.48),skin)
		chefPart("GloveCuff",Vector3.new(1.23,.31,1.12),Vector3.new(x*3.13,2.68,.48),P.cream)
		chefPart("Eyebrow",Vector3.new(.73,.2,.16),Vector3.new(x*.55,8.77,1.12),cocoa,x*-.13)
		chefPart("EyeWhite",Vector3.new(.43,.56,.22),Vector3.new(x*.5,8.38,1.16),Color3.fromRGB(255,251,236))
		chefPart("Pupil",Vector3.new(.21,.34,.12),Vector3.new(x*.5,8.38,1.3),P.ink)
		chefPart("EyeGlint",Vector3.new(.09,.12,.07),Vector3.new(x*.5-.05,8.51,1.37),Color3.new(1,1,1))
		chefPart("MustacheWing",Vector3.new(.85,.35,.3),Vector3.new(x*.39,7.64,1.28),cocoa,x*-.2)
		chefPart("Cheek",Vector3.new(.55,.27,.12),Vector3.new(x*.91,7.91,1.1),Color3.fromRGB(241,139,130))
	end
	chefPart("UniformJacket",Vector3.new(5.65,5.1,3.55),Vector3.new(0,4.55,0),Color3.fromRGB(248,242,225))
	chefPart("JacketCollar",Vector3.new(2.4,.75,.34),Vector3.new(0,6.84,1.76),mint)
	chefPart("ApronBib",Vector3.new(3.15,2.25,.3),Vector3.new(0,5.93,1.91),Color3.fromRGB(91,194,171))
	chefPart("ApronBody",Vector3.new(4.15,3.75,.38),Vector3.new(0,3.65,1.94),Color3.fromRGB(73,174,155))
	chefPart("ApronHem",Vector3.new(4.25,.32,.42),Vector3.new(0,1.83,1.94),Color3.fromRGB(54,142,139))
	chefPart("Pocket",Vector3.new(1.62,1.06,.2),Vector3.new(0,3.48,2.2),Color3.fromRGB(244,203,116))
	chefPart("PocketTop",Vector3.new(1.64,.13,.22),Vector3.new(0,4.06,2.2),Color3.fromRGB(255,230,167))
	chefPart("Neck",Vector3.new(1.32,.83,1.1),Vector3.new(0,7.2,.12),skin)
	chefPart("Head",Vector3.new(2.98,2.78,2.45),Vector3.new(0,8.2,.12),skin)
	chefPart("Ear",Vector3.new(.53,.73,.54),Vector3.new(-1.51,8.17,.2),skin)
	chefPart("Ear",Vector3.new(.53,.73,.54),Vector3.new(1.51,8.17,.2),skin)
	chefPart("Nose",Vector3.new(.57,.48,.47),Vector3.new(0,7.95,1.39),Color3.fromRGB(232,158,115))
	chefPart("Mouth",Vector3.new(.51,.12,.08),Vector3.new(0,7.31,1.31),Color3.fromRGB(117,58,60))
	chefPart("ToqueBand",Vector3.new(2.55,.66,2.35),Vector3.new(0,9.75,.05),P.cream)
	chefPart("ToqueRidge",Vector3.new(2.72,.25,2.42),Vector3.new(0,10.04,.05),Color3.fromRGB(222,239,229))
	for i=-1,1 do chefPart("ToquePuff",Vector3.new(1.48,1.7,2.1),Vector3.new(i*.75,10.75,.05),P.cream) end
	for i=1,5 do chefPart("JacketButton",Vector3.new(.24,.24,.15),Vector3.new(-.69,6.3-i*.64,1.82),C.colors.orange) end
	for _,x in {-1,1} do chefPart("ApronStrap",Vector3.new(.37,1.13,.35),Vector3.new(x*1.27,7.07,1.76),Color3.fromRGB(73,174,155),x*.28) end
	chefPart("CandyBadge",Vector3.new(.76,.76,.27),Vector3.new(1.26,5.12,1.97),P.gold)
	chefPart("BadgeStar",Vector3.new(.34,.34,.16),Vector3.new(1.26,5.12,2.15),P.cream,0,Enum.Material.Neon)
	chef.WorldPivot=CFrame.new();chef:PivotTo(CFrame.new(-16,0,5)*CFrame.Angles(0,.28,0))
	sign("ChefHello","BEM-VINDO!\nSIRVA-SE E VAMOS ROLAR!",CFrame.new(-17,13,5),Vector2.new(13,3.5),P.orange)
	for _,x in {-42,42} do for _,z in {-14,31} do
		cylinder("PendantCable",Vector3.new(.14,7,.14),Vector3.new(x,27,z),P.ink)
		local lamp=part("PendantShade",Vector3.new(5,2.4,5),Vector3.new(x,23,z),P.orange,{shape=Enum.PartType.Ball,canCollide=false})
		cylinder("LampDiffuser",Vector3.new(4,.25,4),lamp.Position-Vector3.new(0,1,0),P.cream)
	end end
	-- Ceiling beams frame a skylit dining room; keep the course view open.
	for _,x in {-52,52} do rounded("RoofSpar",Vector3.new(2.2,1.8,116),CFrame.new(x,31,12),P.cream) end
	for _,z in {-44,-6,32,68} do rounded("RoofBeam",Vector3.new(130,1.8,2.4),CFrame.new(0,31,z),P.cream) end
	for _,x in {-58,58} do
		for _,z in {-34,48} do
			rounded("Planter",Vector3.new(5,3,5),CFrame.new(x,1.5,z),Color3.fromRGB(222,217,197),Enum.Material.Concrete)
			for j=1,7 do local a=j*2.4;local leaf=part("IndoorLeaf",Vector3.new(1.4,5.4,.45),Vector3.new(x+math.cos(a),4.3,z+math.sin(a)),Color3.fromRGB(86,137,93),{shape=Enum.PartType.Ball,canCollide=false});leaf.Orientation=Vector3.new(math.cos(a)*22,j*51,math.sin(a)*22) end
		end
	end
	local spawn=Instance.new("SpawnLocation");spawn.Name="DinerSpawn";spawn.Size=Vector3.new(10,.2,8);spawn.CFrame=CFrame.new(0,.4,34);spawn.Transparency=1;spawn.Neutral=true;spawn.Duration=0;spawn.Parent=root
	-- The course has three distinct biomes. Tape collision is per run and
	-- server-authoritative, so one player's broken tape never blocks another.
	for zone=1,3 do
		local startZ=-46-(zone-1)*324
		local def=C.zones[zone]
		part("BiomeGround",Vector3.new(170,3,324),Vector3.new(0,-2,startZ-162),if zone==1 then Color3.fromRGB(143,207,103) elseif zone==2 then Color3.fromRGB(240,171,193) else Color3.fromRGB(112,106,179))
		part("Runway",Vector3.new(45,.3,324),Vector3.new(0,.1,startZ-162),if zone==3 then Color3.fromRGB(57,64,112) else Color3.fromRGB(210,228,234))
		for _,x in {-24,24} do part("TrackBorder",Vector3.new(1.3,.8,324),Vector3.new(x,.3,startZ-162),def.color) end
		for z=24,300,36 do
			for _,x in {-45,45} do tree(x+(z%7),startZ-z,.8+(z%5)*.13,if zone==1 then P.green else def.color) end
			for _,x in {-14,0,14} do part("LaneDash",Vector3.new(.25,.08,9),Vector3.new(x,.3,startZ-z),P.cream,{canCollide=false}) end
		end
	end
	local tapes=Instance.new("Folder");tapes.Name="Tapes";tapes.Parent=root
	for i,gate in C.course.gates do
		local z=-46-gate.distance;local color=C.zones[gate.zone].color
		local m=Instance.new("Model");m.Name="Gate_"..i;m.Parent=tapes
		for _,x in {-22,22} do
			local p=cylinder("TapePost",Vector3.new(1.8,8,1.8),Vector3.new(x,4,z),P.cream);p.Parent=m
			local cap=cylinder("PostCap",Vector3.new(2.2,.6,2.2),Vector3.new(x,8,z),color);cap.Parent=m
		end
		for j=1,3 do local tape=part("Tape",Vector3.new(43,1.1,.14),Vector3.new(0,1+j*1.6,z),color,{canCollide=false});tape.Parent=m end
		local label=sign("Strength",tostring(i).."  •  "..C.format(gate.cost),CFrame.new(0,8.7,z),Vector2.new(11,2),P.ink);label.Parent=m
		if (i-1)%12==0 then sign("ZoneSign",C.zones[gate.zone].name,CFrame.new(33,10,z+9)*CFrame.Angles(0,-.3,0),Vector2.new(17,4),color) end
	end
	part("FinishPlatform",Vector3.new(46,1,25),Vector3.new(0,-.2,-1030),P.gold)
	sign("Finish","CAMPEÃO!",CFrame.new(0,14,-1040),Vector2.new(35,6),P.pink)
	local sky=Instance.new("Atmosphere");sky.Density=.18;sky.Offset=.3;sky.Color=Color3.fromRGB(207,232,255);sky.Decay=Color3.fromRGB(168,208,241);sky.Parent=game.Lighting
	local cc=Instance.new("ColorCorrectionEffect");cc.Saturation=.025;cc.Contrast=.08;cc.TintColor=Color3.fromRGB(255,248,237);cc.Parent=game.Lighting
	local sun=Instance.new("SunRaysEffect");sun.Intensity=.035;sun.Spread=.6;sun.Parent=game.Lighting
	workspace:SetAttribute("GameId","snackroll");workspace:SetAttribute("CourseGates",#C.course.gates)
	return root
end
return World

