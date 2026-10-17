-- Aetherworks: all progression is shared data; only the server changes it.
local C = {}
C.name = "AETHERWORKS"
C.subtitle = "FÁBRICAS ACIMA DAS NUVENS"
C.seed = 46129
C.startingCoins = 100
C.saveStore = "Aetherworks_Profiles_v1"
C.offlineCap = 3600
C.timeRewards={
    {id="five",minutes=5,coins=250,relics=0},
    {id="ten",minutes=10,coins=600,relics=1},
    {id="twenty",minutes=20,coins=1500,relics=2},
    {id="thirty",minutes=30,coins=3500,relics=3},
    {id="sixty",minutes=60,coins=8500,relics=5},
}
C.dayRewards={180,280,420,650,950,1400,2200}
C.visitMilestones={{days=3,relics=3,cores=0},{days=7,relics=10,cores=1},{days=14,relics=20,cores=2},{days=30,relics=50,cores=5}}
C.activityGrace=180
C.plotIds = {"Aurora", "Brisa", "Celeste", "Solstice"}
C.world={hubSize=196,plotDistance=296,captureRadius=28,captureSeconds=18}
C.factions={Color3.fromRGB(76,196,247),Color3.fromRGB(99,220,130),Color3.fromRGB(250,187,66),Color3.fromRGB(193,128,245)}
C.crystals={
    {name="Aether azul",level=1,multiplier=1,color=Color3.fromRGB(86,211,255)},
    {name="Esmeralda viva",level=5,multiplier=1.6,color=Color3.fromRGB(68,238,119)},
    {name="Âmbar solar",level=15,multiplier=2.7,color=Color3.fromRGB(255,207,50)},
    {name="Prisma astral",level=35,multiplier=4.4,color=Color3.fromRGB(189,105,255)},
    {name="Obsidiana do vazio",level=75,multiplier=7,color=Color3.fromRGB(12,10,20),aura=Color3.fromRGB(187,118,255)},
}
function C.crystal(level)
    local index=1
    for i,tier in C.crystals do if level>=tier.level then index=i end end
    return C.crystals[index],index
end
-- Polynomial costs keep later levels attainable without an exponential overflow.
-- No configured level cap. Wallet bounds are numerical safeguards, not content gates.
function C.infinitePrice(base,level) return math.floor(math.min(1e140,base*(level+1)^1.65*(1+math.floor(level/25)*.12))) end
function C.isMachine(u) return u and u.kind~="land" and u.kind~="floor" end
function C.machineLevel(levels,id) return 1+math.max(0,(levels and levels[id]) or 0) end
function C.machinePrice(u,levels,stars,count)
    local n=C.machineLevel(levels,u.id)-1;local total=0
    for offset=0,(count or 1)-1 do total+=C.infinitePrice(math.max(120,u.cost*.7)*(1+(stars or 0)*.2),n+offset) end
    return total
end
C.tactics={assault={name="Assalto",damage=1.22,health=.86,speed=16},guard={name="Guarda",damage=.86,health=1.35,speed=12},balanced={name="Equilibrado",damage=1,health=1,speed=14}}
function C.armyStats(level,tactic,legacy)
    local t=C.tactics[tactic] or C.tactics.balanced
    local bonus=1+((legacy and legacy.command) or 0)*.08
    return {count=math.min(6,2+math.floor(level/5)),health=math.floor((85+level*18)*t.health*bonus),damage=(9+level*2.8)*t.damage*bonus,speed=t.speed,respawn=math.max(8,24-level*.25)}
end
C.armyOrders={advance="Conquistar",hold="Defender centro",regroup="Reagrupar na base"}
C.soldierRoles={
    Vanguard={name="Vanguarda",health=1,damage=1,reach=7,counters="Gunner"},
    Shield={name="Defensor",health=1.5,damage=.7,reach=7,counters="Vanguard"},
    Gunner={name="Atirador",health=.8,damage=1,reach=25,counters="Support"},
    Support={name="Médico",health=.85,damage=.45,reach=20,counters="Siege"},
    Siege={name="Artilheiro",health=.9,damage=1.2,reach=30,counters="Shield"},
}
C.armyRoutes={center="Centro",left="Relé oeste",right="Relé leste"}
C.armyPriorities={nearest="Mais próximo",support="Curadores",weak="Feridos"}
C.defaultArmy={"Vanguard","Shield","Gunner","Support","Siege","Shield"}
C.towerChoices={
    focus={name="Foco",desc="+12% dano nesta expedição",color="mint"},
    repair={name="Reparar",desc="Recuperar 35% da vida",color="cream"},
    risk={name="Sobrecarga",desc="+20% vida inimiga · +25% saque",color="gold"},
}
C.blueprints={
    {id="focus",name="Lente prismática",wave=5,tier=2,cores=1,desc="+20% de dano contra chefes"},
    {id="renewal",name="Núcleo vital",wave=10,tier=3,cores=2,desc="Recupera 8% de vida entre ondas"},
    {id="industry",name="Regulador astral",wave=15,tier=4,cores=3,desc="+10% de produção da fábrica"},
}
C.colors = {
    ink=Color3.fromRGB(20,38,47), panel=Color3.fromRGB(26,48,56),
    text=Color3.fromRGB(250,242,216), muted=Color3.fromRGB(159,188,185),
    mint=Color3.fromRGB(114,230,196), gold=Color3.fromRGB(255,199,91),
    copper=Color3.fromRGB(185,111,66), cream=Color3.fromRGB(233,218,179),
    teal=Color3.fromRGB(45,130,136), grass=Color3.fromRGB(123,174,143),
    rock=Color3.fromRGB(89,108,118), crystal=Color3.fromRGB(129,240,237),
}
C.upgrades = {
    {id="extractor", name="Extrator de brisa", desc="Seu primeiro cristal automático.", cost=75, rate=3, kind="drill", x=-25,z=10},
    {id="polisher", name="Lapidador de luz", desc="Dê valor aos cristais da primeira linha.", cost=180, rate=7, kind="polisher", x=0,z=10},
    {id="furnace", name="Forno solar", desc="Transforme luz em energia de verdade.", cost=420, rate=14, kind="furnace", x=25,z=10},
    {id="garden", name="Jardim de cristais", desc="Cristais que crescem sob o céu aberto.", cost=850, rate=24, kind="garden", x=-25,z=29},
    {id="turbine", name="Turbina celeste", desc="O vento também trabalha para você.", cost=1500, rate=38, kind="turbine", x=0,z=29},
    {id="condenser", name="Condensador de nuvens", desc="Uma nova matéria-prima. Um novo ritmo.", cost=2800, rate=60, kind="tank", x=25,z=29},
    {id="drill2", name="Extrator profundo", desc="Uma segunda linha de produção.", cost=4700, rate=90, kind="drill", x=-25,z=-25},
    {id="beacon", name="Farol de aurora", desc="Ilumine a ilha e amplifique a fábrica.", cost=7800, rate=135, kind="beacon", x=25,z=-25},
    {id="dispatch", name="Despacho automático", desc="Os ganhos vão direto para sua carteira.", cost=12500, rate=180, kind="dispatch", x=-42,z=10, autoCollect=true},
    {id="observatory", name="Observatório astral", desc="Encontre energia entre as estrelas.", cost=20000, rate=250, kind="observatory", x=42,z=10},
    {id="airship", name="Porto dos ventos", desc="Seu próprio dirigível de carga.", cost=33000, rate=340, kind="airship", x=-42,z=30},
    {id="heart", name="Coração de aether", desc="A maravilha que coroa sua ilha.", cost=55000, rate=500, kind="heart", x=0,z=49},
    {id="land",name="Novo horizonte de terra",desc="Duplique o terreno com uma ilha de expansão.",cost=85000,rate=680,kind="land",x=0,z=88},
    {id="heavy",name="Fundição de aether",desc="Produção pesada no novo terreno.",cost=115000,rate=900,kind="furnace",x=-23,z=83},
    {id="refinery",name="Refinaria de aurora",desc="Abasteça a próxima geração da fábrica.",cost=160000,rate=1200,kind="tank",x=23,z=83},
    {id="floor2",name="Segundo andar",desc="Uma plataforma elevada com escada e elevador.",cost=230000,rate=1500,kind="floor",x=0,z=91,y=25},
    {id="astral",name="Laboratório astral",desc="Pesquisa industrial no segundo andar.",cost=330000,rate=1900,kind="observatory",x=-20,z=88,y=25},
    {id="reactor",name="Reator celeste",desc="Concentre a energia acima das nuvens.",cost=470000,rate=2400,kind="tank",x=20,z=88,y=25},
    {id="floor3",name="Terceiro andar",desc="Sua fábrica alcança o céu. Suba pelo elevador.",cost=680000,rate=2900,kind="floor",x=0,z=91,y=50},
    {id="crown",name="Coroa dos horizontes",desc="O monumento final de uma potência industrial.",cost=950000,rate=3600,kind="heart",x=0,z=91,y=50},
    {id="frontier",name="Fronteira prismática",desc="RENASCIMENTO 1 · um segundo terreno de expansão.",cost=1800000,rate=4700,kind="land",x=0,z=156,rebirth=1},
    {id="prism",name="Forja prismática",desc="RENASCIMENTO 1 · domine a indústria de relíquias.",cost=2900000,rate=6400,kind="heart",x=-23,z=153,rebirth=1},
    {id="stargarden",name="Jardim de estrelas",desc="RENASCIMENTO 2 · cultive matéria das expedições.",cost=4500000,rate=8500,kind="garden",x=23,z=153,rebirth=2},
    {id="eternity",name="Núcleo da eternidade",desc="RENASCIMENTO 2 · o auge de um império celeste.",cost=7200000,rate=12000,kind="heart",x=0,z=179,rebirth=2},
    {id="voidland",name="Arquipélago do vazio",desc="RENASCIMENTO 3 · um novo distrito industrial.",cost=11000000,rate=15500,kind="land",x=0,z=224,rebirth=3},
    {id="voiddrill",name="Perfurador de obsidiana",desc="Extraia matéria do vazio no novo distrito.",cost=16000000,rate=20000,kind="drill",x=-23,z=222,rebirth=3},
    {id="voidforge",name="Forja da singularidade",desc="Uma linha industrial além do horizonte.",cost=24000000,rate=27000,kind="furnace",x=23,z=222,rebirth=3},
    {id="floor4",name="Quarto andar",desc="RENASCIMENTO 4 · pesquisa sobre as nuvens.",cost=36000000,rate=35000,kind="floor",x=0,z=91,y=75,rebirth=4},
    {id="orbital",name="Observatório orbital",desc="Transforme conhecimento em produção.",cost=54000000,rate=46000,kind="observatory",x=0,z=91,y=75,rebirth=4},
    {id="floor5",name="Quinto andar",desc="RENASCIMENTO 5 · o topo do seu império.",cost=81000000,rate=62000,kind="floor",x=0,z=91,y=100,rebirth=5},
    {id="singularity",name="Coração da singularidade",desc="Seu monumento ao domínio do vazio.",cost=125000000,rate=85000,kind="heart",x=0,z=91,y=100,rebirth=5},
    {id="voidgarden",name="Jardim do infinito",desc="A construção final; suas máquinas continuam evoluindo.",cost=190000000,rate=115000,kind="garden",x=0,z=244,rebirth=5},
}
C.contracts = {
    {name="A primeira faísca",desc="Extraia 3 cristais no veio da sua ilha.",stat="mined",goal=3,reward=80},
    {name="Deixe as máquinas trabalhar",desc="Construa 3 melhorias.",stat="level",goal=3,reward=300},
    {name="Entrega expressa",desc="Recolha os ganhos da fábrica 3 vezes.",stat="collections",goal=3,reward=500},
    {name="A ilha desperta",desc="Construa 6 melhorias.",stat="level",goal=6,reward=1500},
    {name="Uma obra nas nuvens",desc="Complete a primeira ilha: 12 construções.",stat="level",goal=12,reward=10000},
    {name="Além da margem",desc="Compre a expansão de terreno.",stat="level",goal=13,reward=18000},
    {name="Indústria vertical",desc="Construa o segundo andar.",stat="level",goal=16,reward=50000},
    {name="Um império no céu",desc="Complete as 20 construções.",stat="level",goal=20,reward=180000},
}
C.prestigeCost=2500000
function C.requiredLevel(stars) return ({20,22,24,27,29})[stars+1] or #C.upgrades end
function C.prestigePrice(stars) return math.floor(math.min(1e140,C.prestigeCost*(1+stars*1.5)*(1+math.max(0,stars-2)^2))) end
function C.price(upgrade,stars) return math.floor(upgrade.cost*(if upgrade.id=="extractor" then 1 else 1.6)*(1+stars*.4)) end
C.perks={
    magnet={name="Coleta magnética",description="Colete automaticamente desde a primeira máquina.",rebirth=1,cores=1},
    drone={name="Drone sentinela",description="Um companheiro dispara nos inimigos da torre.",rebirth=2,cores=2},
    overdrive={name="Sobrecarga industrial",description="Produção ×3 por 30s. Recarga de 3 minutos.",rebirth=3,cores=3},
}
C.weapons={
    {name="Luva de brisa",damage=14,cost=0},
    {name="Lançador de luz",damage=25,cost=1800},
    {name="Canhão de aurora",damage=42,cost=16000},
    {name="Pulso astral",damage=70,cost=110000},
    {name="Lança prismática",damage=105,cost=550000,rebirth=1},
    {name="Ruptura estelar",damage=155,cost=1800000,rebirth=2},
}
C.armors={{name="Traje de explorador",health=100,cost=0},{name="Couraça de cobre",health=140,cost=2500},{name="Escudo celeste",health=190,cost=22000},{name="Armadura astral",health=260,cost=135000}}
function C.weaponDamage(p) return math.floor(C.weapons[p.weapon or 1].damage*(1+(p.weaponMastery or 0)*.18)*(1+((p.towerResearch or {}).power or 0)*.08)*(1+((p.legacy or {}).warfare or 0)*.06)) end
function C.armorHealth(p) return C.armors[p.armor or 1].health+(p.armorMastery or 0)*35+((p.towerResearch or {}).vitality or 0)*25 end
C.legacyNodes={
    {id="industry",name="Herança industrial",desc="+8% de produção por nível",rebirth=1,requires="magnet",base=1},
    {id="warfare",name="Disciplina astral",desc="+6% de dano na torre por nível",rebirth=2,requires="drone",base=2},
    {id="command",name="Comando eterno",desc="+8% de vida e dano das tropas por nível",rebirth=3,requires="overdrive",base=3},
    {id="recovery",name="Reserva do horizonte",desc="+10 minutos de renda offline por nível (até 24h)",rebirth=1,requires="magnet",base=1},
}
C.towerNodes={
    {id="power",name="Foco de aether",desc="+8% de dano por nível",base=3},
    {id="vitality",name="Vitalidade",desc="+25 de vida por nível",base=3},
    {id="evasion",name="Passos do vento",desc="Reduz recarga de esquiva; mínimo 0,8s",base=4},
    {id="salvage",name="Caçador de relíquias",desc="+1 relíquia por onda a cada 5 níveis",base=5},
}
function C.nodePrice(node,level) return math.ceil(node.base*(level+1)^1.35) end
function C.dodgeCooldown(p) return .8+1.2/(1+((p.towerResearch or {}).evasion or 0)*.15) end
function C.offlineLimit(p) return math.min(86400,C.offlineCap+((p.legacy or {}).recovery or 0)*600) end
function C.waveStats(wave,heroic)
    local growth=(1+wave*.12)^1.8*(if heroic then 2.2 else 1)
    return {health=growth,damage=math.min(1e140,12*(1+wave*.09)^1.2)*(if heroic then 1.5 else 1),elite=wave>=8,count=math.min(10,2+math.floor((wave-1)/3))}
end
C.waveModifiers={
    {id="normal",name="Avanço",health=1,speed=1,reward=1},
    {id="swift",name="Vendaval",health=.85,speed=1.35,reward=1.2},
    {id="armored",name="Legião blindada",health=1.5,speed=.85,reward=1.35},
    {id="storm",name="Tempestade astral",health=1.1,speed=1,reward=1.5},
}
function C.rate(level, stars, research, machineLevels,legacy)
    local base=0
    for i=1,math.min(level,#C.upgrades) do
        local u=C.upgrades[i];local contribution=u.rate-(if i>1 then C.upgrades[i-1].rate else 0)
        local rank=C.machineLevel(machineLevels,u.id);local tier=C.crystal(rank)
        base+=contribution*(if C.isMachine(u) then (1+(rank-1)*.22)*tier.multiplier else 1)
    end
    return math.floor(math.min(1e140,base * (1 + (stars or 0) * 0.2 + (research or 0)*.1)*(1+((legacy or {}).industry or 0)*.08)))
end
function C.format(value)
    value = math.max(0,tonumber(value) or 0)
    if value>=1e15 then return string.format("%.2e",value) end
    if value>=1e12 then return string.format("%.1fT",value/1e12) end
    if value>=1e9 then return string.format("%.1fB",value/1e9) end
    if value>=1e6 then return string.format("%.1fM",value/1e6) end
    if value>=1e3 then return string.format("%.1fk",value/1e3) end
    return tostring(math.floor(value))
end
C.net = {
    StateSync={dir="s2c"}, Feedback={dir="s2c"}, OpenHabitat={dir="s2c"},
    HabitatBuy={dir="c2s",rate=1,shape={}},PetVisit={dir="c2s",rate=.5,shape={}},
    PetAdopt={dir="c2s",rate=2,shape={id="string"}},PetUpgrade={dir="c2s",rate=2,shape={id="string"}},
    PetEquip={dir="c2s",rate=2,shape={id="string",slot="number"}},PetUnequip={dir="c2s",rate=2,shape={slot="number"}},
    Ready={dir="c2s",rate=2,shape={}},
    Buy={dir="c2s",rate=3,shape={id="string"}},
    MachineUpgrade={dir="c2s",rate=3,shape={id="string",count="number"}},
    ArmyUpgrade={dir="c2s",rate=2,shape={}},ArmyTactic={dir="c2s",rate=2,shape={id="string"}},
    ArmyOrder={dir="c2s",rate=1,shape={id="string"}}, ResearchNode={dir="c2s",rate=2,shape={tree="string",id="string"}},
    ArmyLoadout={dir="c2s",rate=2,shape={slot="number",role="string"}},ArmyRoute={dir="c2s",rate=1,shape={id="string"}},ArmyPriority={dir="c2s",rate=1,shape={id="string"}},
    TowerChoice={dir="c2s",rate=2,shape={id="string"}},TowerTarget={dir="c2s",rate=3,shape={id="number"}},
    Craft={dir="c2s",rate=1,shape={id="string"}},Specialize={dir="c2s",rate=1,shape={id="string"}},WeeklyClaim={dir="c2s",rate=1,shape={id="string"}},Decoration={dir="c2s",rate=1,shape={id="string"}},
    Collect={dir="c2s",rate=3,shape={}}, Mine={dir="c2s",rate=3,shape={}},
    Home={dir="c2s",rate=.4,shape={}}, Rebirth={dir="c2s",rate=.5,shape={}},
    Daily={dir="c2s",rate=.5,shape={}},
    Travel={dir="c2s",rate=.5,shape={}},
    Shop={dir="c2s",rate=2,shape={item="string"}},
    EnterTower={dir="c2s",rate=.5,shape={}},
    EnterCoop={dir="c2s",rate=.5,shape={}},
    LeaveTower={dir="c2s",rate=.5,shape={}},
    Attack={dir="c2s",rate=4,shape={}},Dodge={dir="c2s",rate=1,shape={}},
    EnterHeroic={dir="c2s",rate=.5,shape={}},Legacy={dir="c2s",rate=2,shape={perk="string"}},
    Overdrive={dir="c2s",rate=.5,shape={}},
    TimeReward={dir="c2s",rate=2,shape={id="string"}},
    VisitReward={dir="c2s",rate=1,shape={days="number"}},
}
return C
