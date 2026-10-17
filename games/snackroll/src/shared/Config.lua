local C = {}
C.title = "SNACK ROLL"
C.colors = {ink=Color3.fromRGB(33,38,62),cream=Color3.fromRGB(255,246,222),orange=Color3.fromRGB(255,138,61),
	blue=Color3.fromRGB(61,161,235),pink=Color3.fromRGB(242,101,160),green=Color3.fromRGB(136,221,78),gold=Color3.fromRGB(255,212,78)}
C.foods = {
	{id="cookie",name="Cookie caseiro",gain=4,cost=0,icon="🍪",color=Color3.fromRGB(218,148,76)},
	{id="donut",name="Donut de morango",gain=10,cost=50,icon="🍩",color=C.colors.pink},
	{id="fries",name="Fritas crocantes",gain=26,cost=450,icon="🍟",color=C.colors.gold},
	{id="burger",name="Hambúrguer duplo",gain=70,cost=2800,icon="🍔",color=C.colors.orange},
	{id="pizza",name="Pizza da casa",gain=185,cost=16000,icon="🍕",color=C.colors.gold},
	{id="cake",name="Bolo de festa",gain=500,cost=85000,icon="🍰",color=C.colors.pink},
	{id="feast",name="Banquete real",gain=1400,cost=440000,icon="👑",color=C.colors.blue},
	{id="galaxy",name="Cookie galáctico",gain=4000,cost=2200000,icon="🌌",color=Color3.fromRGB(154,104,243)},
}
C.pets = {
	{id="pup",name="Pudim",kind="dog",cost=200,bonus=.15,color=Color3.fromRGB(231,174,100)},
	{id="cat",name="Mochi",kind="cat",cost=1200,bonus=.35,color=C.colors.pink},
	{id="bee",name="Mel",kind="bee",cost=6000,bonus=.65,color=C.colors.gold},
	{id="dragon",name="Fagulha",kind="dragon",cost=32000,bonus=1.1,color=C.colors.orange},
	{id="ice",name="Nevasca",kind="dragon",cost=180000,bonus=1.8,color=C.colors.blue},
	{id="cosmic",name="Órbita",kind="cat",cost=1000000,bonus=3,color=Color3.fromRGB(159,119,239)},
	{id="sugarfox",name="Raposa Estelar",kind="fox",cost=0,bonus=.28,color=Color3.fromRGB(248,203,119),headColor=Color3.fromRGB(255,230,174),accent=Color3.fromRGB(142,109,243),tailColor=Color3.fromRGB(255,232,184),premium=true,pass="sugar_constellation"},
	{id="cocoadrake",name="Dragão Cacau",kind="dragon",cost=0,bonus=.42,color=Color3.fromRGB(105,59,55),headColor=Color3.fromRGB(139,79,66),belly=Color3.fromRGB(239,177,119),wingColor=Color3.fromRGB(172,76,84),wingTip=Color3.fromRGB(255,147,100),hornColor=Color3.fromRGB(255,200,111),tailColor=Color3.fromRGB(83,47,47),accent=Color3.fromRGB(237,135,91),premium=true,pass="cocoa_comet"},
}
C.premiumPasses={
	{id="sugar_constellation",name="Constelação Doce",gamePassId=0,description="Raposa Estelar, Cookie Prisma e rastro Poeira de Estrelas."},
	{id="cocoa_comet",name="Cometa de Cacau",gamePassId=0,description="Dragão Cacau, Waffle de Cacau e rastro Brasa de Canela."},
}
C.premiumFoods={
	{id="prismcookie",name="Cookie Prisma",gain=300,color=Color3.fromRGB(169,117,240),pass="sugar_constellation"},
	{id="cocoawaffle",name="Waffle de Cacau",gain=900,color=Color3.fromRGB(133,77,68),pass="cocoa_comet"},
}
C.course = {speed=46,gates={}}
for i=1,36 do
	local cost=math.floor(8*1.23^(i-1))
	table.insert(C.course.gates,{distance=i*27,cost=cost,reward=math.floor(cost*1.8),zone=math.ceil(i/12)})
end
C.zones={{name="JARDIM CROCANTE",color=C.colors.blue},{name="VALE DOCE",color=C.colors.pink},{name="CIRCUITO CÓSMICO",color=Color3.fromRGB(148,111,238)}}
C.rewards={{seconds=60,coins=100},{seconds=300,coins=800},{seconds=900,coins=5000},{seconds=1800,coins=20000}}
C.trails={{name="Sem rastro",color=C.colors.cream,rebirth=0},{name="Tangerina",color=C.colors.orange,rebirth=1},{name="Chiclete",color=C.colors.pink,rebirth=2},{name="Cósmico",color=C.colors.blue,rebirth=3},
	{name="Poeira de Estrelas",color=Color3.fromRGB(184,144,255),rebirth=0,pass="sugar_constellation"},
	{name="Brasa de Canela",color=Color3.fromRGB(255,111,74),rebirth=0,pass="cocoa_comet"}}
C.net={State={dir="s2c"},Feedback={dir="s2c"},Effect={dir="s2c"},Ready={dir="c2s",rate=1,shape={}},Eat={dir="c2s",rate=4,shape={}},Roll={dir="c2s",rate=1,shape={}},Return={dir="c2s",rate=1,shape={}},BuyFood={dir="c2s",rate=2,shape={index="number"}},Pet={dir="c2s",rate=3,shape={index="number"}},Rebirth={dir="c2s",rate=1,shape={}},Reward={dir="c2s",rate=2,shape={index="number"}},Auto={dir="c2s",rate=2,shape={kind="string"}},Trail={dir="c2s",rate=2,shape={index="number"}},Premium={dir="c2s",rate=1,shape={id="string"}},PremiumFood={dir="c2s",rate=2,shape={id="string"}}}
C.template={coins=0,weight=0,food=1,rebirths=0,pets={},equipped={},premium={},premiumFood="",best=0,runs=0,wins=0,eaten=0,lastDaily=-1,streak=0,day=-1,playSeconds=0,claims={},trail=1}
function C.format(n)
	for _,v in {{1e12,"T"},{1e9,"B"},{1e6,"M"},{1e3,"K"}} do if n>=v[1] then return string.format("%.1f%s",n/v[1],v[2]) end end
	return tostring(math.floor(n))
end
function C.petCapacity(p) return math.min(5,2+math.floor(p.rebirths/2)) end
function C.multiplier(p)
	local bonus=1
	for _,id in p.equipped do for _,pet in C.pets do if pet.id==id and (not pet.pass or (p.premium and p.premium[pet.pass])) then bonus+=pet.bonus end end end
	return bonus*(1+p.rebirths*.5)
end
function C.gain(p)
	local base=C.foods[p.food].gain
	if p.premiumFood and p.premiumFood~="" then for _,food in C.premiumFoods do if food.id==p.premiumFood and p.premium and p.premium[food.pass] then base=food.gain;break end end end
	return math.floor(base*C.multiplier(p))
end
function C.rebirthCost(p) return math.floor(2500*2.4^math.min(p.rebirths,20)) end
function C.level(weight) return 1+math.floor(math.log(1+weight/40)/math.log(1.45)) end
function C.levelBounds(weight)
	local lv=C.level(weight)
	return math.floor(40*(1.45^(lv-1)-1)),math.floor(40*(1.45^lv-1))
end
return C
