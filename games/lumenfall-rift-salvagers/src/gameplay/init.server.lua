--!strict
-- Lumenfall server bootstrap.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
Forge.require("0.2.0")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Content = require(Shared:WaitForChild("Content"))

local Rng = Forge.Core.Rng
local Net = Forge.Net
local Save = Forge.Save
local Debug = Forge.Debug

local World = require(script:WaitForChild("World"))
local Gameplay = require(script:WaitForChild("Gameplay"))
local Expedition = require(script:WaitForChild("Playable"))

local startedAt=os.clock()
Rng.seed(Config.seed)
Players.CharacterAutoLoads=false

for _,name in Config.containers do
    if not Workspace:FindFirstChild(name) then
        local folder=Instance.new("Folder")
        folder.Name=name
        folder.Parent=Workspace
    end
end

Net.define({
    State={dir="s2c"}, Objective={dir="s2c"}, Notify={dir="s2c"},
    Lumen={dir="s2c"}, Extraction={dir="s2c"}, Boss={dir="s2c"},
    BossWindow={dir="s2c"}, Cooldown={dir="s2c"}, HitConfirm={dir="s2c"},
    PlayerHit={dir="s2c"},
    Attack={dir="c2s",rate=8,shape={dir="Vector3"}},
    HeavyStart={dir="c2s",rate=4}, HeavyRelease={dir="c2s",rate=4,shape={dir="Vector3"}},
    Dodge={dir="c2s",rate=4,shape={dir="Vector3"}},
    Utility={dir="c2s",rate=4,shape={dir="Vector3"}},
    SetSprint={dir="c2s",rate=10,shape={on="boolean"}},
})

Content.load()
Save.configure({
    store=Config.saveStore,
    version=1,
    template={
        refined=0, power=0, bestDepth=0, onboarded=false, joinCount=0, lastExtraction="",
        settings={reducedShake=false,flashIntensity=1},
    },
})
Save.start()

World.start()
Gameplay.start()
Expedition.start(World,Gameplay)

local function onCharacter(player: Player, character: Model)
    local humanoid=character:WaitForChild("Humanoid") :: Humanoid
    humanoid.MaxHealth=Config.player.health
    humanoid.Health=Config.player.health
    humanoid.WalkSpeed=Config.player.walkSpeed
    humanoid.BreakJointsOnDeath=false
    local checkpoint=player:GetAttribute("Checkpoint")
    if typeof(checkpoint)~="Vector3" then checkpoint=World.spawnPoint end
    character:PivotTo(CFrame.new(checkpoint))

    humanoid.Died:Connect(function()
        Expedition.onDeath(player)
        task.delay(3,function()
            if player.Parent then player:LoadCharacter() end
        end)
    end)
end

local function attachPlayer(player: Player)
    player.CharacterAdded:Connect(function(character) onCharacter(player,character) end)
    if player.Character then onCharacter(player,player.Character) end
end

Players.PlayerAdded:Connect(attachPlayer)
for _,player in Players:GetPlayers() do attachPlayer(player) end

Save.observe(function(player,profile)
    player:SetAttribute("PowerUpgrade",profile.power or 0)
    Net.fire(player,"Notify",{text="Rift link established",kind="info"})
    if not player.Character then player:LoadCharacter() end
end)

Players.CharacterAutoLoads=true

task.defer(function()
    for _,player in Players:GetPlayers() do
        if not player.Character then player:LoadCharacter() end
    end
end)

-- Live rules: these are product assertions, not build assertions.
if Config.selfTest then
    task.defer(function()
        local suite=script:FindFirstChild("tests")
        if suite then
            local report=Forge.Testing.runAndPublish(suite,nil,"lumenfall-rift-salvagers")
            Debug.info(("Lumenfall self-test: %d passed, %d failed, %d hung"):format(
                report.passed or 0,report.failed or 0,report.timedOut or 0))
        end
    end)
end

Debug.expose()
Debug.probe("lumenfall.bootstrap",function()
    local world=Workspace:FindFirstChild("LumenWorld")
    return {
        uptime=os.clock()-startedAt,
        players=#Players:GetPlayers(),
        worldReady=world~=nil,
        spawn=World.spawnPoint,
        nodes=#World.lumenNodes,
    }
end)

Debug.info(("Lumenfall ready in %.2fs"):format(os.clock()-startedAt))
print(("[Lumenfall] server ready in %.2fs"):format(os.clock()-startedAt))
