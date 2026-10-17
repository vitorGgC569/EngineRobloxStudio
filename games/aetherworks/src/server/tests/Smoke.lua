local RS=game:GetService("ReplicatedStorage")
local Forge=require(RS.Forge)
local C=require(RS.Shared.TycoonConfig)
return function(Testing)
    Testing.scenario("pet floors require purchase and rebirth and preserve the permanent home",function(t)
        local H=require(script.Parent.Parent.Habitat)
        local p={coins=2499,stars=0};H.prepare(p)
        t:expect(not H.buyFloor(p) and p.coins==2499 and H.snapshot(p).capacity==0,"unaffordable lot granted rooms")
        p.coins=1e9;t:expect(H.buyFloor(p) and H.snapshot(p).capacity==2,"first floor did not grant exactly two rooms")
        local before=p.coins;t:expect(not H.buyFloor(p) and p.coins==before,"rebirth lock spent funds")
        t:expect(not H.adopt(p,"fern") and not H.equip(p,"breeze",3),"locked floor allowed pet adoption or equipment")
        p.stars=1;t:expect(H.buyFloor(p) and H.snapshot(p).capacity==4,"second floor failed")
        p.stars=2;t:expect(H.buyFloor(p) and H.snapshot(p).capacity==6,"third floor failed")
        p.stars=3;t:expect(H.buyFloor(p) and H.snapshot(p).capacity==8,"fourth floor failed")
        p.stars=4;t:expect(not H.buyFloor(p),"last floor must require rebirth five")
        p.stars=5;t:expect(H.buyFloor(p) and H.snapshot(p).capacity==10,"last floor failed")
        before=p.coins;t:expect(not H.buyFloor(p) and p.coins==before,"completed house charged again")
        p.stars+=1;p.level=0;p.machineLevels={};p.coins=100
        local copy=game:GetService("HttpService"):JSONDecode(game:GetService("HttpService"):JSONEncode(p))
        t:expect(H.snapshot(copy).capacity==10 and copy.habitat.owned.breeze==1,"saved home did not survive rebirth round trip")
    end)
    Testing.scenario("pets grant only equipped category bonuses and cannot duplicate or bypass ownership",function(t)
        local H=require(script.Parent.Parent.Habitat)
        local p={coins=1e9,stars=1};H.buyFloor(p)
        local stats=H.bonuses(p);t:expect(math.abs(stats.production-1.06)<1e-6 and math.abs(stats.manual-1.12)<1e-6,"starter bonuses incorrect")
        H.equip(p,"breeze",2);t:expect(not p.habitat.slots["1"] and H.bonuses(p).manual==1,"move duplicated pet or kept evicted bonus")
        t:expect(not H.equip(p,"fern",1) and not H.equip(p,"breeze",1.5) and not H.equip(p,"breeze",0/0),"unowned pet or fractional slot accepted")
        H.unequip(p,2);t:expect(H.bonuses(p).production==1,"reserve pet still produces")
        H.buyFloor(p);t:expect(H.adopt(p,"fern"),"unlocked adoption refused")
        local before=p.coins;t:expect(not H.adopt(p,"fern") and p.coins==before,"duplicate adoption charged")
        local original=H.bonuses(p).production
        t:expect(H.upgrade(p,"fern") and H.bonuses(p).production>original,"pet upgrade gave no economic benefit")
        p.coins=0;local level=p.habitat.owned.fern;t:expect(not H.upgrade(p,"fern") and level==p.habitat.owned.fern,"unaffordable pet improvement succeeded")
        p.coins=1e9;for _=1,4 do H.upgrade(p,"fern")end
        before=p.coins;t:expect(p.habitat.owned.fern==5 and not H.upgrade(p,"fern") and p.coins==before,"pet max level overcharged")
        p.habitat.slots["2"]="fern";t:expect(H.bonuses(p).production<=1.2+1e-6,"duplicate saved slot stacked bonus")
    end)
    Testing.scenario("crafted specialization requires boss blueprint crystal discovery and funds",function(t)
        local D=require(script.Parent.Parent.Discovery)
        local p={level=1,machineLevels={},cores=10,relics=0};D.discover(p)
        t:expect(not D.craft(p,"focus") and p.cores==10,"missing blueprint allowed crafting")
        D.boss(p,5);t:expect(not D.craft(p,"focus"),"missing crystal allowed crafting")
        p.machineLevels.extractor=4;D.discover(p)
        t:expect(D.craft(p,"focus") and p.cores==9,"valid recipe failed")
        t:expect(not D.craft(p,"focus") and p.cores==9,"duplicate recipe spent funds")
        p.level=0;p.machineLevels={};D.discover(p)
        t:expect(p.discovery.crystals["2"] and p.discovery.crafted.focus,"rebirth erased discoveries")
    end)
    Testing.scenario("weekly rewards are idempotent and rollover preserves permanent discovery",function(t)
        local D=require(script.Parent.Parent.Discovery)
        local p={cores=0,relics=0};D.prepare(p,0);p.discovery.crystals["3"]=true
        p.weekly.progress.mine=1000
        t:expect(D.claim(p,"mine",0),"complete objective refused")
        local relics=p.relics;t:expect(not D.claim(p,"mine",0) and p.relics==relics,"duplicate weekly claim paid")
        D.prepare(p,604800)
        t:expect(not p.weekly.claims.mine and not p.weekly.progress.mine and p.discovery.crystals["3"],"weekly rollover erased permanent progress")
    end)
    Testing.scenario("published art is present and every rarity has distinct geometry",function(t)
        local templates=RS:FindFirstChild("AetherArtTemplates");t:expect(templates and templates:GetAttribute("Ready"),"art catalogue not ready")
        local seen={}
        for i=1,5 do local mesh=templates:FindFirstChild("crystal_"..i)
            t:expect(mesh and mesh:IsA("MeshPart") and mesh.MeshId~="","crystal is not a published mesh")
            if mesh then t:expect(not seen[mesh.MeshId],"two rarities reuse the same geometry");seen[mesh.MeshId]=true end
        end
        local Art=require(RS.Shared.Art);local machine=Art.machine(nil,CFrame.new(),"drill",1);Art.evolve(machine,5)
        t:expect(machine:FindFirstChild("CoolingLoop",true) and machine:FindFirstChild("VoidPanel",true),"late tiers only change a color")
        machine:Destroy()
    end)
    Testing.scenario("animation waits for the full replicated skeleton",function(t)
        for _,rigType in {"R6","R15"} do
            local model=Forge.Rig.build({name="ReadinessProbe",rigType=rigType,detail=false})
            t:expect(Forge.Anim.isRigReady(model),"complete "..rigType.." rig rejected")
            local joint=model:FindFirstChild(if rigType=="R6" then "Right Shoulder" else "RightShoulder",true)
            local parent=joint.Parent;joint.Parent=nil
            t:expect(not Forge.Anim.isRigReady(model),"partial replication accepted")
            joint.Parent=parent;local part=joint.Part1;joint.Part1=nil
            t:expect(not Forge.Anim.isRigReady(model),"joint without attached limb accepted")
            joint.Part1=part;t:expect(Forge.Anim.isRigReady(model),"completed replication never became ready")
            model:Destroy()
        end
    end)
    Testing.scenario("fractional remote rates allow the first request and throttle a burst",function(t)
        local Sched=require(RS.Forge.Core.Sched)
        for _,rate in {.4,.5,2} do
            local allow=Sched.bucket(rate,1)
            t:expect(allow("one"),"first request rejected at "..rate)
            t:expect(not allow("one"),"immediate repeat accepted at "..rate)
            t:expect(allow("two"),"another player's bucket was consumed")
        end
        t:expect(Sched.bucket(.5)(),"default burst cannot hold a whole request")
    end)
    Testing.scenario("crystal rarity grows at exact level boundaries and never resets at the final tier",function(t)
        for index,tier in C.crystals do
            local actual=C.crystal(tier.level);t:expect(actual==tier,"wrong tier at "..tier.level)
            if index>1 then t:expect(C.crystal(tier.level-1)==C.crystals[index-1],"tier unlocked too early") end
        end
        t:expect(C.crystal(10000)==C.crystals[5],"infinite levels lost void rarity")
    end)
    Testing.scenario("machine improvement prices stay finite and production grows beyond level 75",function(t)
        local u=C.upgrades[1];local previous=0
        for _,rank in {1,5,15,35,75,76,100,1000,10000} do
            local levels={[u.id]=rank-1};local value=C.rate(1,0,0,levels)
            t:expect(value>previous,"production stopped growing at "..rank);previous=value
            local cost=C.machinePrice(u,levels,0,10);t:expect(cost>0 and cost<math.huge,"infinite upgrade overflowed")
        end
        local levels={};local sum=0
        for n=0,9 do levels[u.id]=n;sum+=C.machinePrice(u,levels,0,1) end
        t:expect(sum==C.machinePrice(u,{},0,10),"bulk upgrade discounts or overcharges")
        t:expect(C.rate(24,0,0,{})==12000,"existing factory income was changed by migration")
    end)
    Testing.scenario("domination requires uncontested time and clears after the owner leaves",function(t)
        local D=require(script.Parent.Parent.Dominion);local s={progress=0}
        D.stepControl(s,{Aurora=2},17);t:expect(s.owner==nil,"capture awarded too early")
        D.stepControl(s,{Aurora=2,Brisa=2},1);t:expect(s.contested and s.progress==0,"contested presence kept capture progress")
        D.stepControl(s,{Aurora=2},18);t:expect(s.owner=="Aurora" and not s.contested,"sole army could not capture")
        D.stepControl(s,{Aurora=2,Brisa=1},1);t:expect(s.contested,"invading army failed to suspend ownership bonus")
        D.stepControl(s,{Brisa=1},1);t:expect(s.owner==nil and s.contender=="Brisa","absent owner kept the center")
        D.stepControl(s,{},1);t:expect(s.owner==nil and s.progress==0,"empty center awards control")
    end)
    Testing.scenario("army levels improve strength without unbounded NPC spawning",function(t)
        local weak=C.armyStats(1,"balanced");local strong=C.armyStats(100,"balanced")
        t:expect(strong.damage>weak.damage and strong.health>weak.health,"training gives no strength")
        t:expect(strong.count<=6 and C.armyStats(10000,"assault").count<=6,"NPC budget grows without bound")
        t:expect(C.armyStats(10,"guard").health>C.armyStats(10,"assault").health,"tactical choice has no tradeoff")
    end)
    Testing.scenario("playtime rewards count elapsed time and one visit per day",function(t)
        local Rewards=require(script.Parent.Parent.Rewards)
        local p={lastVisitDay=-1,daysPlayed=0,playDay=-1,dayPlaySeconds=0,timeClaims={},totalPlaySeconds=0,lastDailyDay=-1,dailyClaims=0}
        Rewards.step(p,299);Rewards.step(p,1)
        t:expect(p.daysPlayed==1,"the same day's second heartbeat counted another visit")
        t:expect(p.totalPlaySeconds==300,"playtime did not match elapsed time")
        t:expect(Rewards.snapshot(p).timeReady,"five-minute reward is not ready")
        p.timeClaims.five=true
        t:expect(not Rewards.snapshot(p).timeReady,"a claimed reward became available again")
    end)
    Testing.scenario("rebirth is reachable before its exclusive construction gates",function(t)
        for stars=0,8 do
            local required=C.requiredLevel(stars)
            t:expect(required<=#C.upgrades,"rebirth requires nonexistent content")
            for index=1,required do t:expect((C.upgrades[index].rebirth or 0)<=stars,"rebirth deadlock at construction "..index) end
            if stars>0 then t:expect(C.prestigePrice(stars)>C.prestigePrice(stars-1),"later rebirth should require a larger reserve") end
        end
        t:expect(C.price(C.upgrades[1],0)<=C.startingCoins,"new player cannot start the factory")
        t:expect(C.price(C.upgrades[4],2)>C.price(C.upgrades[4],0),"later generations should not bypass the economy")
    end)
    Testing.scenario("all constructions can be previewed and built",function(t)
        local previews=RS:FindFirstChild("AetherPreviews")
        t:expect(previews~=nil,"preview catalogue is missing")
        for i,u in C.upgrades do
            local machine=previews and previews:FindFirstChild("Machine_"..i)
            t:expect(machine and #machine:GetDescendants()>3,"missing geometry for "..u.id)
            t:expect(u.cost>0 and u.rate>0,"invalid economy data")
            if i>1 then t:expect(u.rate>C.upgrades[i-1].rate,"an upgrade reduces production") end
        end
    end)
    Testing.scenario("daily claims are idempotent and streaks reset without losing calendar progress",function(t)
        local R=require(script.Parent.Parent.Rewards)
        local p={lastDailyDay=-1,dailyClaims=0,dailyStreak=0,bestStreak=0}
        local first=R.claimDay(p,100);t:expect(first==1 and p.dailyStreak==1,"first day failed")
        t:expect(R.claimDay(p,100)==nil and p.dailyClaims==1,"duplicate claim awarded")
        local _,bonus=R.claimDay(p,101);t:expect(p.dailyStreak==2 and bonus>1,"consecutive visit lost bonus")
        R.claimDay(p,104);t:expect(p.dailyStreak==1 and p.dailyClaims==3 and p.bestStreak==2,"missed day erased calendar or record")
        t:expect(R.claimDay(p,103)==nil,"clock rollback awarded another claim")
    end)
    Testing.scenario("inactive time cannot unlock rewards and midnight rotates only daily state",function(t)
        local R=require(script.Parent.Parent.Rewards)
        local p={lastVisitDay=100,daysPlayed=4,playDay=100,dayPlaySeconds=299,timeClaims={five=true},totalPlaySeconds=400}
        R.step(p,50,false,100);t:expect(p.dayPlaySeconds==299,"AFK time counted")
        R.step(p,1,true,101);t:expect(p.daysPlayed==5 and p.dayPlaySeconds==1 and p.totalPlaySeconds==401,"daily rollover lost totals")
        t:expect(p.timeClaims.five==nil,"new day retained old claim")
    end)
    Testing.scenario("permanent research rejects invalid and locked purchases without spending",function(t)
        local P=require(script.Parent.Parent.Progression)
        local p={stars=0,cores=100,relics=100,perks={},legacy={},towerResearch={}}
        t:expect(not P.purchase(p,"legacy","industry") and p.cores==100,"rebirth gate bypassed")
        p.stars=1
        t:expect(not P.purchase(p,"legacy","industry") and p.cores==100,"prerequisite bypassed")
        p.perks.magnet=true
        t:expect(P.purchase(p,"legacy","industry") and p.legacy.industry==1 and p.cores==99,"research purchase failed")
        local before=p.relics;t:expect(not P.purchase(p,"unknown","power") and p.relics==before,"unknown tree spent money")
        p.relics=0;t:expect(not P.purchase(p,"towerResearch","power") and not p.towerResearch.power,"insufficient funds granted research")
    end)
    Testing.scenario("research affects production troops combat and bounded offline recovery",function(t)
        t:expect(C.rate(12,2,0,{}, {industry=5})>C.rate(12,2,0,{}),"industry node has no effect")
        t:expect(C.weaponDamage({towerResearch={power=5}})>C.weaponDamage({}),"power node has no effect")
        t:expect(C.armorHealth({towerResearch={vitality=5}})>C.armorHealth({}),"vitality node has no effect")
        t:expect(C.dodgeCooldown({towerResearch={evasion=10000}})>=.8,"dodge became spammable")
        t:expect(C.offlineLimit({legacy={recovery=10000}})==86400,"offline cap overflowed")
        t:expect(C.armyStats(10,"guard",{command=5}).health>C.armyStats(10,"guard").health,"command node has no effect")
    end)
    Testing.scenario("tower health and damage keep increasing beyond the old limits with a bounded population",function(t)
        local prev=C.waveStats(1,false)
        for _,wave in {10,100,1000,10000} do
            local next=C.waveStats(wave,false)
            t:expect(next.health>prev.health and next.damage>prev.damage,"wave difficulty stopped increasing")
            t:expect(next.count<=10 and next.health<math.huge,"unbounded NPC count or numeric overflow")
            prev=next
        end
        t:expect(C.waveStats(10,true).health>C.waveStats(10,false).health,"heroic difficulty identical")
    end)
    Testing.scenario("plot allocation isolates two players and releases only its owner",function(t)
        local a=Forge.Tycoon.PlotAllocator.new(C.plotIds)
        local first=a:assign("one");local second=a:assign("two")
        t:expect(first~=second,"two players share a factory")
        t:expect(not a:isOwner("one",second),"foreign ownership accepted")
        a:release("one");t:expect(a:plotOf("two")==second,"leaving erased another player")
    end)
    Testing.scenario("a failed purchase cannot debit the wallet",function(t)
        local wallet=Forge.Economy.Balance.new({currencies={coins={start=50}}})
        t:expect(not wallet:debit({coins=75}),"unaffordable purchase was accepted")
        t:expect(wallet:get("coins")==50,"failed purchase changed money")
        t:expect(wallet:debit({coins=25}),"affordable purchase was refused")
        t:expect(wallet:get("coins")==25,"incorrect debit")
    end)
    Testing.scenario("every factory provides a spawn and interaction points",function(t)
        local world=workspace:FindFirstChild("Aetherworks")
        for _,id in C.plotIds do
            local plot=world and world:FindFirstChild(id)
            t:expect(plot~=nil,"missing plot "..id)
            if plot then
                local spawn=plot:FindFirstChild("Arrival")
                t:expect(spawn and spawn:IsA("SpawnLocation"),"missing arrival")
                t:expect(plot:FindFirstChild("Collector")~=nil,"missing collector")
                t:expect(plot:FindFirstChild("BuildPad")~=nil,"missing construction pad")
            end
        end
    end)
end
