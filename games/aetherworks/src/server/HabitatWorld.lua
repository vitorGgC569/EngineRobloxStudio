local RS=game:GetService("ReplicatedStorage")
local Art=require(RS.Shared.Art)
local C=require(RS.Shared.TycoonConfig)
local Pets=require(RS.Shared.PetConfig)
local H={};local V=Vector3.new;local P=C.colors
function H.create(plot,build,callbacks)
    local root=Art.group(plot.model,"PetEstate",plot.cf);plot.habitatRoot=root
    local cf=plot.cf*CFrame.new(-80,0,-4);plot.habitatCF=cf
    build.island(root,plot.cf*CFrame.new(-80,0,0),46,64)
    build.part(root,"PetPromenade",V(42,.6,13),plot.cf*CFrame.new(-67,.6,18),P.cream,Enum.Material.Pavement)
    plot.habitatArrival=cf*CFrame.new(0,4,22)*CFrame.Angles(0,math.pi,0)
    local console=Art.casing(root,"HomeRegister",V(3,3,2),cf*CFrame.new(11,2,19),P.teal)
    Art.crystal(root,cf*CFrame.new(11,3.6,19),.3,2)
    local prompt=Instance.new("ProximityPrompt");prompt.ActionText="Ver casa e pets";prompt.ObjectText="Residência dos companheiros"
    prompt.MaxActivationDistance=12;prompt.RequiresLineOfSight=false;prompt.Parent=console
    prompt.Triggered:Connect(function(player)if callbacks.onHabitat then callbacks.onHabitat(player,plot,console.Position)end end)
    plot.habitatBuild=build;plot.habitatCallbacks=callbacks
    H.update(plot,{stars=0,habitat={floors=0,owned={},slots={}}})
end
function H.update(plot,profile)
    local h=profile.habitat or {floors=0,owned={},slots={}}
    local bits={tostring(h.floors)}
    for slot=1,h.floors*2 do local id=h.slots[tostring(slot)];table.insert(bits,(id or "empty")..":"..tostring(id and h.owned[id] or 0))end
    local stamp=table.concat(bits,"|");if stamp==plot.habitatStamp then return end;plot.habitatStamp=stamp
    local old=plot.habitatRoot:FindFirstChild("Residence");if old then old:Destroy()end
    local m=Art.group(plot.habitatRoot,"Residence",plot.habitatCF);local cf=plot.habitatCF;local b=plot.habitatBuild
    m:SetAttribute("Floors",h.floors);m:SetAttribute("PetCapacity",h.floors*2)
    if h.floors==0 then
        b.part(m,"LotPaving",V(34,.5,28),cf*CFrame.new(0,.5,0),P.rock,Enum.Material.Pavement)
        for _,x in {-16,16}do for _,z in {-12,12}do Art.mesh(m,"SurveyPost","girder",V(.8,4,.8),cf*CFrame.new(x,2,z),P.teal)end end
        b.sign(m,cf*CFrame.new(0,7,0),"SEU FUTURO LAR","2 PETS INICIAIS INCLUÍDOS · ¤ "..C.format(Pets.floors[1].cost),24)
        return
    end
    for floor=1,h.floors do
        local y=(floor-1)*12
        b.part(m,"HabitatFloor_"..floor,V(34,.9,28),cf*CFrame.new(0,y+.7,0),P.cream,Enum.Material.Concrete)
        b.part(m,"RearWall",V(33,10,.7),cf*CFrame.new(0,y+6,-13),P.teal)
        b.part(m,"SideWall",V(.7,10,26),cf*CFrame.new(-16.5,y+6,0),P.cream)
        for _,z in {-7,5}do
            -- Recessed framed windows break the blank side elevation.
            Art.casing(m,"WindowFrame",V(.35,6,7.6),cf*CFrame.new(-17,y+6,z),P.teal)
            Art.casing(m,"WindowGlass",V(.4,5,6.6),cf*CFrame.new(-17.25,y+6,z),P.mint,Enum.Material.Glass).Transparency=.2
            Art.casing(m,"WindowMullion",V(.5,5,.18),cf*CFrame.new(-17.5,y+6,z),P.cream)
            Art.casing(m,"WindowSill",V(1.2,.4,8.1),cf*CFrame.new(-17.2,y+3,z),P.teal)
        end
        Art.casing(m,"FloorCornice",V(35,.65,29),cf*CFrame.new(0,y+11.5,0),P.teal)
        for _,x in {-16,16}do
            for _,z in {-12,12}do Art.mesh(m,"HouseColumn","girder",V(1.2,11,1.2),cf*CFrame.new(x,y+6.5,z),P.teal)end
        end
        -- Open front galleries keep both residents visible from the courtyard.
        for _,x in {-10,10}do
            b.part(m,"GalleryRail",V(11,.3,.4),cf*CFrame.new(x,y+3.4,13.5),P.teal)
            for post=-4,4,2 do b.part(m,"Baluster",V(.18,2.2,.2),cf*CFrame.new(x+post,y+2.3,13.5),P.teal)end
        end
        Art.mesh(m,"GalleryEntrance","arch",V(7,9,.9),cf*CFrame.new(0,y+5.6,13.2),P.teal)
        for room=1,2 do
            local slot=(floor-1)*2+room;local bedCF=cf*CFrame.new(if room==1 then -7 else 5,y+1.3,-4)
            Art.casing(m,"PetBed_"..slot,V(8,.65,7),bedCF,P.teal)
            Art.casing(m,"Cushion",V(6.8,.35,5.8),bedCF*CFrame.new(0,.5,0),P.muted,Enum.Material.Fabric)
            Art.mesh(m,"WaterBowl","collar",V(1.4,.45,1.4),bedCF*CFrame.new(3,0,3.7),P.cream)
            local id=h.slots[tostring(slot)];local pet=id and Pets.byId[id]
            if pet and h.owned[id]then
                local resident=Art.pet(m,bedCF*CFrame.new(0,.8,0),pet.id,h.owned[id]);resident.Name="Resident_"..slot;resident:SetAttribute("PetId",id);resident:SetAttribute("Slot",slot)
            end
            b.sign(m,bedCF*CFrame.new(0,5.6,-3.2),if pet then pet.name else "ESPAÇO "..slot,if pet then "NÍVEL "..h.owned[id] else "U · HOSPEDAR PET",9)
        end
        b.sign(m,cf*CFrame.new(11,y+9,14.2),floor.."º ANDAR","2 COMPANHEIROS",8)
        -- Distinct up/down pads, only generated for floors already purchased.
        for _,direction in {-1,1}do
            local target=floor+direction
            if target>=1 and target<=h.floors then
                local pos=cf*CFrame.new(13,y+1.3,if direction==1 then -4 else 6)
                local pad=Art.casing(m,"ResidenceLift",V(4,.3,4),pos,P.mint)
                Art.mesh(m,"LiftArch","arch",V(4,6,.6),pos*CFrame.new(0,3,-1.8),P.teal)
                local prompt=Instance.new("ProximityPrompt");prompt.ActionText=if direction==1 then "Subir" else "Descer";prompt.ObjectText="Andar "..target
                prompt.MaxActivationDistance=7;prompt.RequiresLineOfSight=false;prompt.Parent=pad
                prompt.Triggered:Connect(function(player)
                    if plot.habitatCallbacks.onHabitatLift then plot.habitatCallbacks.onHabitatLift(player,plot,pad.Position,target)end
                end)
            end
        end
    end
    local roofY=h.floors*12+1
    for _,side in {-1,1}do Art.casing(m,"SlopedRoof",V(19,.7,31),cf*CFrame.new(side*8.3,roofY+.8,0)*CFrame.Angles(0,0,-side*.15),P.teal)end
    Art.casing(m,"RoofRidge",V(1,1,32),cf*CFrame.new(0,roofY+2.2,0),P.cream)
    Art.crystal(m,cf*CFrame.new(0,roofY+2.6,0),.7,math.min(h.floors,5))
    b.sign(m,cf*CFrame.new(0,roofY+2,15.7),"CASA AURORA","UM LAR PARA SEUS COMPANHEIROS",22)
    for _,x in {-12,12}do
        Art.casing(m,"GardenBox",V(7,1.5,2.6),cf*CFrame.new(x,1.1,16.1),P.teal)
        for j=-1,1 do Art.crystal(m,cf*CFrame.new(x+j*2,1.7,16.1),.22,2)end
    end
end
return H
