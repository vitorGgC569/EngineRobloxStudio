local P={}
P.maxLevel=5
P.floors={
    {rebirth=0,cost=2500},{rebirth=1,cost=80000},{rebirth=2,cost=600000},
    {rebirth=3,cost=3000000},{rebirth=5,cost=18000000},
}
P.pets={
    {id="breeze",name="Raposa de brisa",kind="production",bonus=.06,floor=1,cost=0,species="fox",tier=1},
    {id="pebble",name="Toupeira de aether",kind="manual",bonus=.12,floor=1,cost=0,species="mole",tier=1},
    {id="fern",name="Coruja esmeralda",kind="production",bonus=.10,floor=2,cost=30000,species="owl",tier=2},
    {id="sprout",name="Coelho do bosque",kind="manual",bonus=.20,floor=2,cost=30000,species="rabbit",tier=2},
    {id="sun",name="Raposa solar",kind="production",bonus=.14,floor=3,cost=220000,species="fox",tier=3},
    {id="amber",name="Toupeira âmbar",kind="manual",bonus=.30,floor=3,cost=220000,species="mole",tier=3},
    {id="nova",name="Coruja astral",kind="production",bonus=.20,floor=4,cost=1200000,species="owl",tier=4},
    {id="comet",name="Coelho cometa",kind="manual",bonus=.42,floor=4,cost=1200000,species="rabbit",tier=4},
    {id="eclipse",name="Dragão do eclipse",kind="production",bonus=.30,floor=5,cost=8000000,species="dragon",tier=5},
    {id="void",name="Raposa do vazio",kind="manual",bonus=.60,floor=5,cost=8000000,species="fox",tier=5},
}
P.byId={};for _,pet in P.pets do P.byId[pet.id]=pet end
function P.bonus(pet,level)return pet.bonus*(1+.25*(level-1))end
function P.upgradePrice(pet,level)return math.floor(math.max(1500,pet.cost*.8)*(level+1)^2.6)end
return P
