-- Original smooth meshes shared by the avatar, food and diner furniture.
local RS=game:GetService("ReplicatedStorage")
local Run=game:GetService("RunService")
local C=require(script.Parent.Config)
local IDs=require(script.Parent.PublishedShapes)
local Art={}
local templates
function Art.prepare()
	if templates then return end
	if Run:IsClient() then templates=RS:WaitForChild("SnackShapes",45);assert(templates,"Snack shapes were not replicated");return end
	local folder=Instance.new("Folder");folder.Name="SnackShapes"
	for name,id in IDs do
		local p=game:GetService("AssetService"):CreateMeshPartAsync(Content.fromUri(id),{CollisionFidelity=Enum.CollisionFidelity.Box})
		p.Name=name;p.Anchored=true;p.CanCollide=false;p.CanTouch=false;p.CanQuery=false;p.DoubleSided=true;p.Parent=folder
	end
	folder.Parent=RS;templates=folder
end
function Art.mesh(parent,name,shape,size,cf,color,material)
	Art.prepare();local p=templates[shape]:Clone();p.Name=name;p.Size=size;p.CFrame=cf;p.Color=color;p.Material=material or Enum.Material.SmoothPlastic;p.Parent=parent;return p
end
function Art.part(parent,name,size,cf,color,shape)
	local p=Instance.new("Part");p.Name=name;p.Size=size;p.CFrame=cf;p.Color=color;p.Material=Enum.Material.SmoothPlastic
	p.Anchored=true;p.CanCollide=false;p.CanTouch=false;p.CanQuery=false
	if shape then p.Shape=shape end
	p.Parent=parent;return p
end
local function ball(m,n,s,pos,c) return Art.part(m,n,s,CFrame.new(pos),c,Enum.PartType.Ball) end
local function disc(m,n,r,h,y,c)
	return Art.part(m,n,Vector3.new(h,r,r),CFrame.new(0,y,0)*CFrame.Angles(0,0,math.pi/2),c,Enum.PartType.Cylinder)
end
function Art.food(id)
	local m=Instance.new("Model");m.Name="Food_"..id
	local cream=C.colors.cream;local brown=Color3.fromRGB(94,52,34)
	if id=="prismcookie" then
		Art.mesh(m,"PrismBiscuit","bun",Vector3.new(3.2,.58,3.2),CFrame.new(),Color3.fromRGB(135,88,221))
		Art.mesh(m,"VanillaIcing","donut",Vector3.new(2.72,.3,2.72),CFrame.new(0,.31,0),Color3.fromRGB(125,224,243))
		for i=1,14 do local a=i*2.4;local r=.45+(i%4)*.28;ball(m,"SugarCrystal",Vector3.new(.24,.17,.22),Vector3.new(math.cos(a)*r,.45,math.sin(a)*r),({C.colors.pink,C.colors.gold,C.colors.green,cream})[(i%4)+1]) end
		for i=1,3 do local shard=Art.mesh(m,"OrbitingSugar","rounded",Vector3.new(.35,.52,.34),CFrame.new(math.cos(i*2.1)*1.8,.66,math.sin(i*2.1)*1.8)*CFrame.Angles(0,0,i*.55),Color3.fromRGB(244,245,255),Enum.Material.Neon) end
	elseif id=="cocoawaffle" then
		Art.mesh(m,"Waffle","bun",Vector3.new(3.2,.65,3.2),CFrame.new(0,0,0),Color3.fromRGB(216,151,75))
		Art.mesh(m,"ChocolateGlaze","bun",Vector3.new(2.75,.35,2.75),CFrame.new(0,.4,0),Color3.fromRGB(92,49,42))
		for x=-1,1 do for z=-1,1 do ball(m,"Berry",Vector3.new(.52,.45,.52),Vector3.new(x*.65,.68,z*.65),if (x+z)%2==0 then C.colors.pink else Color3.fromRGB(251,206,91)) end end
		for i=1,8 do local a=i*2.4;ball(m,"CocoaNib",Vector3.new(.24,.18,.24),Vector3.new(math.cos(a)*1.05,.7,math.sin(a)*1.05),Color3.fromRGB(58,35,33)) end
	elseif id=="cookie" or id=="galaxy" then
		Art.mesh(m,"Biscuit","bun",Vector3.new(3,.45,3),CFrame.new(),if id=="galaxy" then Color3.fromRGB(127,91,199) else Color3.fromRGB(211,150,79))
		for i=1,10 do local a=i*2.4;local r=.4+(i%3)*.32;ball(m,"Chocolate",Vector3.new(.32,.12,.25),Vector3.new(math.cos(a)*r,.25,math.sin(a)*r),if id=="galaxy" then C.colors.blue else brown) end
	elseif id=="donut" then
		Art.mesh(m,"Dough","donut",Vector3.new(2.8,.8,2.8),CFrame.new(),Color3.fromRGB(223,164,94))
		Art.mesh(m,"Icing","donut",Vector3.new(2.79,.48,2.79),CFrame.new(0,.25,0),C.colors.pink)
		for i=1,12 do local a=i*2.4;Art.part(m,"Sprinkle",Vector3.new(.1,.12,.32),CFrame.new(math.cos(a),.53,math.sin(a))*CFrame.Angles(0,a,0),if i%2==0 then cream else C.colors.gold) end
	elseif id=="fries" then
		Art.mesh(m,"Carton","rounded",Vector3.new(1.8,1.8,.9),CFrame.new(0,0,0),Color3.fromRGB(238,73,69))
		for i=1,7 do Art.mesh(m,"Fry","rounded",Vector3.new(.26,1.8+(i%3)*.25,.25),CFrame.new((i-4)*.23,1,0)*CFrame.Angles(0,0,(i-4)*.055),C.colors.gold) end
	elseif id=="burger" or id=="feast" then
		disc(m,"LowerBun",3,.45,-.4,Color3.fromRGB(228,157,63));disc(m,"Beef",3.1,.38,0,brown)
		Art.part(m,"Cheese",Vector3.new(2.65,.12,2.65),CFrame.new(0,.24,0)*CFrame.Angles(0,.25,0),C.colors.gold)
		disc(m,"Tomato",2.8,.2,.39,Color3.fromRGB(236,74,63));disc(m,"Lettuce",3.3,.17,.55,C.colors.green)
		Art.mesh(m,"CrownBun","bun",Vector3.new(3.1,1.1,3.1),CFrame.new(0,1.04,0),Color3.fromRGB(230,162,73))
		for i=1,12 do local a=i*math.pi/6;local leaf=Art.mesh(m,"LettuceFrill","rounded",Vector3.new(.75,.15,.75),CFrame.new(math.cos(a)*1.3,.54,math.sin(a)*1.3)*CFrame.Angles(.18*math.sin(a),a,.14),C.colors.green) end
		for i=1,9 do local a=i*2.4;ball(m,"Sesame",Vector3.new(.13,.08,.25),Vector3.new(math.cos(a)*.95,1.6,math.sin(a)*.95),cream) end
		if id=="feast" then for i=1,5 do Art.part(m,"Crown",Vector3.new(.25,1,.25),CFrame.new((i-3)*.4,2.25,0),C.colors.gold) end end
	elseif id=="pizza" then
		disc(m,"Crust",3.6,.3,0,Color3.fromRGB(225,150,77));disc(m,"Cheese",3.2,.15,.2,C.colors.gold)
		for i=1,7 do local a=i*2.4;disc(m,"Pepperoni",.56,.07,.32,Color3.fromRGB(210,62,53)).Position+=Vector3.new(math.cos(a),0,math.sin(a)) end
	else
		Art.mesh(m,"Cake","bun",Vector3.new(2.6,1.8,2.6),CFrame.new(0,.3,0),cream);disc(m,"PinkCream",2.8,.28,1.1,C.colors.pink)
		for i=1,5 do local a=i*1.257;ball(m,"Berry",Vector3.new(.45,.5,.45),Vector3.new(math.cos(a),1.4,math.sin(a)),Color3.fromRGB(226,63,82)) end
	end
	local primary=m:FindFirstChildWhichIsA("BasePart")
	if primary then m.PrimaryPart=primary end
	-- Cylinders have a rotated local axis; using one as PrimaryPart would
	-- rotate the entire food upright when a display calls PivotTo.
	m.WorldPivot=CFrame.new();return m
end
function Art.pet(def)
	local m=Instance.new("Model");m.Name="Pet_"..def.id
	local function oval(name,size,pos,color,rot,material)
		return Art.mesh(m,name,"rounded",size,CFrame.new(pos)*CFrame.Angles(rot or 0,0,0),color,material)
	end
	local fur=def.color
	local body=oval("Body",Vector3.new(2.75,1.9,2.2),Vector3.new(0,-.12,.12),fur);m.PrimaryPart=body
	oval("Chest",Vector3.new(1.62,1.35,.32),Vector3.new(0,-.25,-.91),def.belly or C.colors.cream)
	oval("Head",Vector3.new(2.14,1.92,1.72),Vector3.new(0,.7,-.35),def.headColor or fur)
	for _,x in {-1,1} do
		oval("Paw",Vector3.new(.8,.68,.86),Vector3.new(x*.86,-.92,-.35),def.pawColor or fur)
		oval("FootPad",Vector3.new(.37,.12,.3),Vector3.new(x*.86,-1.18,-.56),def.belly or C.colors.cream)
		oval("EyeWhite",Vector3.new(.48,.57,.2),Vector3.new(x*.49,.83,-1.14),Color3.fromRGB(255,252,235))
		oval("Pupil",Vector3.new(.26,.38,.13),Vector3.new(x*.49,.81,-1.27),Color3.fromRGB(32,35,54))
		oval("EyeSpark",Vector3.new(.105,.14,.07),Vector3.new(x*.49-.055,.94,-1.345),Color3.new(1,1,1))
		oval("Blush",Vector3.new(.46,.22,.12),Vector3.new(x*.82,.28,-1.15),C.colors.pink)
	end
	local kind=def.kind
	if kind=="dog" then
		for _,x in {-1,1} do oval("FloppyEar",Vector3.new(.72,1.12,.7),Vector3.new(x*.94,1.32,-.05),def.earColor or Color3.fromRGB(162,96,55),x*-.28) end
		oval("Muzzle",Vector3.new(1.18,.7,.72),Vector3.new(0,.35,-1.12),Color3.fromRGB(250,221,178))
		oval("Nose",Vector3.new(.34,.28,.24),Vector3.new(0,.49,-1.51),Color3.fromRGB(51,40,42))
		oval("Tongue",Vector3.new(.35,.29,.13),Vector3.new(0,.04,-1.38),Color3.fromRGB(244,106,142))
		for i=1,3 do oval("TailPom",Vector3.new(.68,.66,.68),Vector3.new(.25+i*.42,.12+i*.43,1.12+i*.17),fur,i*.22) end
	elseif kind=="cat" or kind=="fox" then
		local earColor=def.earColor or fur
		for _,x in {-1,1} do
			oval("PointedEar",Vector3.new(.79,1.22,.44),Vector3.new(x*.73,1.74,-.16),earColor,x*-.19)
			oval("InnerEar",Vector3.new(.38,.72,.13),Vector3.new(x*.73,1.72,-.42),C.colors.pink,x*-.19)
		end
		oval("Muzzle",Vector3.new(.68,.39,.38),Vector3.new(0,.34,-1.11),def.belly or C.colors.cream)
		oval("Nose",Vector3.new(.24,.19,.14),Vector3.new(0,.49,-1.36),C.colors.pink)
		for i=1,4 do oval("TailRibbon",Vector3.new(.4,.72,.42),Vector3.new(-1.04-i*.18,-.08+i*.43,.92+i*.28),def.tailColor or fur,i*-.2) end
		for _,x in {-1,1} do for i=1,2 do oval("Whisker",Vector3.new(.7,.045,.055),Vector3.new(x*(.79+i*.07),.37-i*.12,-1.27),Color3.fromRGB(248,231,211),x*-.08) end end
	else
		oval("Muzzle",Vector3.new(.66,.43,.42),Vector3.new(0,.35,-1.14),def.belly or C.colors.cream)
		oval("Nose",Vector3.new(.21,.18,.12),Vector3.new(0,.49,-1.36),Color3.fromRGB(47,42,52))
		oval("Smile",Vector3.new(.42,.09,.08),Vector3.new(0,.11,-1.38),Color3.fromRGB(117,57,57))
	end
	if kind=="bee" then
		for i=1,2 do oval("HoneyStripe",Vector3.new(2.66,.24,2.1),Vector3.new(0,-.25+(i-1)*.61,.14),Color3.fromRGB(66,49,48)) end
		for _,x in {-1,1} do
			oval("Wing",Vector3.new(1.12,1.48,.27),Vector3.new(x*1.37,.56,.48),Color3.fromRGB(182,234,249),x*.22,Enum.Material.Glass).Transparency=.24
			oval("Antenna",Vector3.new(.12,.66,.12),Vector3.new(x*.48,1.92,-.12),C.colors.ink,x*-.45)
			oval("AntennaTip",Vector3.new(.31,.31,.31),Vector3.new(x*.72,2.18,-.12),C.colors.pink)
		end
		oval("HoneyPot",Vector3.new(.7,.65,.66),Vector3.new(.91,-.1,-.64),Color3.fromRGB(250,178,44))
	elseif kind=="dragon" then
		for _,x in {-1,1} do
			oval("Wing",Vector3.new(.37,1.6,1.93),Vector3.new(x*1.48,.22,.51),def.wingColor or C.colors.gold,x*-.36)
			oval("WingTip",Vector3.new(.28,.86,.9),Vector3.new(x*1.7,.92,.63),def.wingTip or Color3.fromRGB(255,203,102),x*-.55)
			oval("Horn",Vector3.new(.46,.94,.44),Vector3.new(x*.7,1.9,.05),def.hornColor or C.colors.gold,x*-.2)
		end
		for i=1,3 do oval("BackSpine",Vector3.new(.42,.6,.48),Vector3.new(0,.81+i*.2,.54+i*.31),def.hornColor or C.colors.gold,-.35) end
		for i=1,4 do oval("SpadeTail",Vector3.new(.52,.5,.58),Vector3.new(.18+i*.4,-.18+i*.27,1.04+i*.17),def.tailColor or fur,i*.25) end
		oval("BellyPlate",Vector3.new(1.29,.29,.19),Vector3.new(0,-.43,-1.08),def.belly or Color3.fromRGB(255,205,134))
		oval("Flame",Vector3.new(.42,.42,.38),Vector3.new(0,.18,-1.46),Color3.fromRGB(255,171,67),0,Enum.Material.Neon)
	end
	-- A stitched collar and tiny charm make the pets read as cared-for companions.
	oval("Collar",Vector3.new(1.65,.25,1.48),Vector3.new(0,-.46,-.56),def.accent or C.colors.orange)
	oval("Charm",Vector3.new(.38,.48,.18),Vector3.new(0,-.67,-1.16),def.charmColor or C.colors.gold,0,Enum.Material.Metal)
	if def.premium then
		for i=1,4 do oval("Starlight",Vector3.new(.24,.24,.24),Vector3.new(math.cos(i*1.57)*1.64,1.2+math.sin(i*1.57)*.55,.12),Color3.fromRGB(231,225,255),0,Enum.Material.Neon) end
	end
	return m
end
return Art
