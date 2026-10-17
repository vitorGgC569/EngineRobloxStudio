--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Data = Forge.Data
local Content = {}

function Content.load()
    Data.define("enemy", {
        name={type="string"}, health={type="number",min=1}, damage={type="number",min=0},
        armor={type="number",default=0}, speed={type="number",default=14}, reach={type="number",default=7},
        aggro={type="number",default=70}, attackEvery={type="number",default=1.7}, reward={type="number",default=5},
        profile={type="string",default="grounded"}, kind={type="string",default="melee"}, rig={type="table"},
    })
    Data.load("enemy", {
        skitter={name="Rift Skitter",health=58,damage=9,armor=0,speed=22,reach=5.5,aggro=78,attackEvery=0.95,reward=4,profile="skittering",kind="melee",
            rig={scale=0.72,shape="quadruped",body=Color3.fromRGB(49,43,63),accent=Color3.fromRGB(117,79,190),eyes=Color3.fromRGB(255,190,76),glow=true}},
        sentinel={name="Lumen Sentinel",health=95,damage=14,armor=3,speed=12,reach=30,aggro=95,attackEvery=2.2,reward=7,profile="grounded",kind="ranged",
            rig={scale=1.05,shape="biped",body=Color3.fromRGB(48,55,68),accent=Color3.fromRGB(96,220,255),eyes=Color3.fromRGB(255,203,93),weapon="staff"}},
        bulwark={name="Foundry Bulwark",health=235,damage=25,armor=24,speed=8.5,reach=9,aggro=70,attackEvery=2.7,reward=13,profile="heavy",kind="melee",
            rig={rigType="R15",scale=1.45,shape="hulk",bulky=true,body=Color3.fromRGB(58,55,67),accent=Color3.fromRGB(231,137,60),eyes=Color3.fromRGB(255,190,76),spikes=true,weapon="greatsword"}},
        warden={name="Rift Warden",health=420,damage=28,armor=18,speed=13,reach=11,aggro=110,attackEvery=1.9,reward=28,profile="heavy",kind="melee",
            rig={rigType="R15",scale=1.65,shape="hulk",bulky=true,body=Color3.fromRGB(37,31,54),accent=Color3.fromRGB(137,83,238),eyes=Color3.fromRGB(255,208,91),glow=true,spikes=true,weapon="greatsword"}},
        hollow_engine={name="The Hollow Engine",health=1250,damage=34,armor=28,speed=9,reach=14,aggro=150,attackEvery=2.5,reward=100,profile="heavy",kind="boss",
            rig={rigType="R15",scale=2.4,shape="hulk",bulky=true,body=Color3.fromRGB(32,29,45),accent=Color3.fromRGB(255,161,61),eyes=Color3.fromRGB(114,238,255),glow=true,spikes=true,weapon="greatsword"}},
    })
end
return Content
