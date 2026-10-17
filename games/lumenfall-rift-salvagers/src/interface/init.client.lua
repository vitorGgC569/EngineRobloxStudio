--!strict
-- Lumenfall client: immediate feel, device-neutral input, HUD and accessibility.
local Players=game:GetService("Players")
local ReplicatedStorage=game:GetService("ReplicatedStorage")
local Workspace=game:GetService("Workspace")
local TweenService=game:GetService("TweenService")

local Forge=require(ReplicatedStorage:WaitForChild("Forge"))
local Net=Forge.Net
local Input=Forge.Input
local Feel=Forge.Feel
local Audio=Forge.Audio
local Visual=Forge.Visual
local Access=Forge.Access

local Config=require(ReplicatedStorage.Shared.Config)
local player=Players.LocalPlayer
local gui=player:WaitForChild("PlayerGui")
local camera=Workspace.CurrentCamera

Net.define({
    State={dir="s2c"},Objective={dir="s2c"},Notify={dir="s2c"},Lumen={dir="s2c"},
    Extraction={dir="s2c"},Boss={dir="s2c"},BossWindow={dir="s2c"},Cooldown={dir="s2c"},
    HitConfirm={dir="s2c"},PlayerHit={dir="s2c"},
    Attack={dir="c2s",rate=8,shape={dir="Vector3"}},
    HeavyStart={dir="c2s",rate=4},HeavyRelease={dir="c2s",rate=4,shape={dir="Vector3"}},
    Dodge={dir="c2s",rate=4,shape={dir="Vector3"}},Utility={dir="c2s",rate=4,shape={dir="Vector3"}},
    SetSprint={dir="c2s",rate=10,shape={on="boolean"}},
})

Feel.mount()
Visual.autoQuality()
Access.followSystem()
Access.captionsFor({
    ["boss.telegraph"]="The Hollow Engine is charging a ground shock.",
    ["extraction.wave"]="Rift pressure rising. Enemies incoming.",
})

Audio.defineMany({
    swing={id="rbxasset://sounds/action_falling.ogg",volume=0.28,pitch={1.45,1.75},cooldown=0.06},
    hit={id="rbxasset://sounds/impact_water.mp3",volume=0.42,pitch={0.9,1.15},cooldown=0.03},
    hurt={id="rbxasset://sounds/oof.ogg",volume=0.42,pitch={0.88,1.0},cooldown=0.2},
    lumen={id="rbxasset://sounds/electronicpingshort.wav",volume=0.45,pitch={1.1,1.35},cooldown=0.05},
    boss={id="rbxasset://sounds/impact_explosion_03.mp3",volume=0.55,pitch={0.65,0.8}},
    extract={id="rbxasset://sounds/electronicpingshort.wav",volume=0.5,pitch={0.8,1.0}},
})

Input.defineActions({
    strike={keyboard=Enum.UserInputType.MouseButton1,gamepad=Enum.KeyCode.ButtonR2,touch={label="STRIKE",order=1,size=88}},
    heavy={keyboard=Enum.KeyCode.E,gamepad=Enum.KeyCode.ButtonY,touch={label="CHARGE",order=2,size=76}},
    dodge={keyboard=Enum.KeyCode.Q,gamepad=Enum.KeyCode.ButtonL2,touch={label="DASH",order=3,size=78}},
    utility={keyboard=Enum.KeyCode.F,gamepad=Enum.KeyCode.ButtonR1,touch={label="BOLT",order=4,size=72}},
    sprint={keyboard=Enum.KeyCode.LeftShift,gamepad=Enum.KeyCode.ButtonL3,touch={label="RUN",order=5,size=68}},
})
Input.mount()

local screen=Instance.new("ScreenGui")
screen.Name="LumenfallHUD"
screen.ResetOnSpawn=false
screen.IgnoreGuiInset=false
screen.DisplayOrder=5
screen.Parent=gui

local function rounded(frame: GuiObject,radius: number)
    local c=Instance.new("UICorner");c.CornerRadius=UDim.new(0,radius);c.Parent=frame
end
local function stroke(frame: GuiObject,color: Color3,transparency: number?)
    local s=Instance.new("UIStroke");s.Color=color;s.Transparency=transparency or 0.35;s.Thickness=1;s.Parent=frame
end
local function text(parent: Instance,value: string,size: number,bold: boolean?): TextLabel
    local t=Instance.new("TextLabel")
    t.BackgroundTransparency=1;t.Text=value;t.TextColor3=Color3.fromRGB(238,239,246)
    t.Font=bold and Enum.Font.GothamBold or Enum.Font.GothamMedium;t.TextSize=size
    t.TextXAlignment=Enum.TextXAlignment.Left;t.Parent=parent
    return t
end

local top=Instance.new("Frame")
top.Name="Top";top.AnchorPoint=Vector2.new(0.5,0);top.Position=UDim2.new(0.5,0,0,18)
top.Size=UDim2.fromOffset(520,74);top.BackgroundColor3=Color3.fromRGB(18,17,27);top.BackgroundTransparency=0.12
top.Parent=screen;rounded(top,14);stroke(top,Config.palette.storm,0.45)

local healthBack=Instance.new("Frame")
healthBack.Position=UDim2.fromOffset(18,17);healthBack.Size=UDim2.fromOffset(210,13)
healthBack.BackgroundColor3=Color3.fromRGB(47,43,57);healthBack.Parent=top;rounded(healthBack,7)
local healthFill=Instance.new("Frame")
healthFill.Size=UDim2.fromScale(1,1);healthFill.BackgroundColor3=Config.palette.safe;healthFill.Parent=healthBack;rounded(healthFill,7)
local healthLabel=text(top,"SALVAGER",13,true);healthLabel.Position=UDim2.fromOffset(18,38);healthLabel.Size=UDim2.fromOffset(210,22)

local carried=text(top,"UNSTABLE  0",16,true);carried.Position=UDim2.fromOffset(255,13);carried.Size=UDim2.fromOffset(245,24)
local refined=text(top,"REFINED   0",13,false);refined.Position=UDim2.fromOffset(255,40);refined.Size=UDim2.fromOffset(245,20)
carried.TextColor3=Config.palette.lumen;refined.TextColor3=Config.palette.lumenCool

local objective=Instance.new("TextLabel")
objective.Name="Objective";objective.AnchorPoint=Vector2.new(0.5,1);objective.Position=UDim2.new(0.5,0,1,-32)
objective.Size=UDim2.new(0.72,0,0,54);objective.BackgroundColor3=Color3.fromRGB(18,17,27);objective.BackgroundTransparency=0.10
objective.TextColor3=Color3.fromRGB(245,243,252);objective.Font=Enum.Font.GothamBold;objective.TextSize=18
objective.TextWrapped=true;objective.Text="Cross the rift bridges. Harvest Lumen and reach Storm Crown."
objective.Parent=screen;rounded(objective,14);stroke(objective,Config.palette.lumen,0.55)

local boss=Instance.new("Frame")
boss.Name="Boss";boss.AnchorPoint=Vector2.new(0.5,0);boss.Position=UDim2.new(0.5,0,0,110);boss.Size=UDim2.fromOffset(460,50)
boss.BackgroundColor3=Color3.fromRGB(25,18,35);boss.Visible=false;boss.Parent=screen;rounded(boss,12);stroke(boss,Config.palette.danger,0.25)
local bossTitle=text(boss,"THE HOLLOW ENGINE",16,true);bossTitle.Position=UDim2.fromOffset(14,6);bossTitle.Size=UDim2.fromOffset(430,20);bossTitle.TextColor3=Config.palette.lumen
local bossHint=text(boss,"CORE SEALED",12,true);bossHint.Position=UDim2.fromOffset(14,28);bossHint.Size=UDim2.fromOffset(430,18);bossHint.TextColor3=Color3.fromRGB(190,170,210)

local extraction=Instance.new("Frame")
extraction.AnchorPoint=Vector2.new(0.5,0.5);extraction.Position=UDim2.fromScale(0.5,0.28);extraction.Size=UDim2.fromOffset(310,72)
extraction.BackgroundColor3=Color3.fromRGB(16,24,31);extraction.Visible=false;extraction.Parent=screen;rounded(extraction,14);stroke(extraction,Config.palette.lumenCool,0.25)
local extractionTitle=text(extraction,"RIFT BEACON",14,true);extractionTitle.Position=UDim2.fromOffset(14,10);extractionTitle.Size=UDim2.fromOffset(280,20)
local extractionTime=text(extraction,"24",30,true);extractionTime.Position=UDim2.fromOffset(14,31);extractionTime.Size=UDim2.fromOffset(280,34);extractionTime.TextColor3=Config.palette.lumenCool

local cooldowns=Instance.new("Frame")
cooldowns.AnchorPoint=Vector2.new(1,1);cooldowns.Position=UDim2.new(1,-22,1,-105);cooldowns.Size=UDim2.fromOffset(190,62)
cooldowns.BackgroundTransparency=1;cooldowns.Parent=screen
local dash=text(cooldowns,"DASH  READY",13,true);dash.Size=UDim2.fromOffset(190,24);dash.TextXAlignment=Enum.TextXAlignment.Right
local utility=text(cooldowns,"BOLT   READY",13,true);utility.Position=UDim2.fromOffset(0,28);utility.Size=UDim2.fromOffset(190,24);utility.TextXAlignment=Enum.TextXAlignment.Right

local toast=Instance.new("TextLabel")
toast.AnchorPoint=Vector2.new(0.5,0);toast.Position=UDim2.new(0.5,0,0,178);toast.Size=UDim2.fromOffset(440,44)
toast.BackgroundColor3=Color3.fromRGB(18,17,27);toast.BackgroundTransparency=0.08;toast.TextColor3=Color3.fromRGB(245,243,252)
toast.Font=Enum.Font.GothamBold;toast.TextSize=16;toast.Visible=false;toast.Parent=screen;rounded(toast,12)

local settingsButton=Instance.new("TextButton")
settingsButton.AnchorPoint=Vector2.new(1,0);settingsButton.Position=UDim2.new(1,-18,0,18);settingsButton.Size=UDim2.fromOffset(46,46)
settingsButton.BackgroundColor3=Color3.fromRGB(24,22,34);settingsButton.Text="⚙";settingsButton.TextSize=23;settingsButton.TextColor3=Color3.fromRGB(225,225,235)
settingsButton.Parent=screen;rounded(settingsButton,12)

local settings=Instance.new("Frame")
settings.AnchorPoint=Vector2.new(1,0);settings.Position=UDim2.new(1,-18,0,72);settings.Size=UDim2.fromOffset(260,152)
settings.BackgroundColor3=Color3.fromRGB(20,18,30);settings.Visible=false;settings.Parent=screen;rounded(settings,14);stroke(settings,Config.palette.storm,0.35)
local st=text(settings,"ACCESSIBILITY",15,true);st.Position=UDim2.fromOffset(14,12);st.Size=UDim2.fromOffset(230,22)
local motion=Instance.new("TextButton");motion.Position=UDim2.fromOffset(14,48);motion.Size=UDim2.fromOffset(232,36);motion.Text="Reduced motion: OFF";motion.Font=Enum.Font.GothamMedium;motion.TextSize=14;motion.TextColor3=Color3.fromRGB(235,235,242);motion.BackgroundColor3=Color3.fromRGB(42,38,57);motion.Parent=settings;rounded(motion,9)
local large=Instance.new("TextButton");large.Position=UDim2.fromOffset(14,94);large.Size=UDim2.fromOffset(232,36);large.Text="Larger text: OFF";large.Font=Enum.Font.GothamMedium;large.TextSize=14;large.TextColor3=Color3.fromRGB(235,235,242);large.BackgroundColor3=Color3.fromRGB(42,38,57);large.Parent=settings;rounded(large,9)

settingsButton.Activated:Connect(function() settings.Visible=not settings.Visible end)
local reduced=false
motion.Activated:Connect(function()
    reduced=not reduced;Access.reducedMotion(reduced);motion.Text="Reduced motion: "..(reduced and "ON" or "OFF")
end)
local largeText=false
large.Activated:Connect(function()
    largeText=not largeText;Access.textScale(largeText and 1.2 or 1);large.Text="Larger text: "..(largeText and "ON" or "OFF")
end)

local function aim(): Vector3
    local cam=Workspace.CurrentCamera or camera
    local look=cam and cam.CFrame.LookVector or Vector3.new(0,0,-1)
    local flat=Vector3.new(look.X,0,look.Z)
    return flat.Magnitude>0.05 and flat.Unit or Vector3.new(0,0,-1)
end

local function aim3D(): Vector3
    local cam=Workspace.CurrentCamera or camera
    if not cam then return Vector3.new(0,0,-1) end

    local look=cam.CFrame.LookVector
    local character=player.Character
    local root=character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
    if not root then
        return look.Magnitude>0.05 and look.Unit or Vector3.new(0,0,-1)
    end

    -- Correct third-person parallax: first find what the centre camera ray
    -- actually points at, then aim from the projectile muzzle to that point.
    local params=RaycastParams.new()
    params.FilterType=Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances={character}
    local cameraOrigin=cam.CFrame.Position
    local cameraDirection=look*500
    local hit=Workspace:Raycast(cameraOrigin,cameraDirection,params)
    local target=hit and hit.Position or (cameraOrigin+cameraDirection)
    local muzzle=root.Position+Vector3.new(0,1.5,0)
    local delta=target-muzzle
    return delta.Magnitude>0.05 and delta.Unit or look.Unit
end

local lastAttack=0
Input.bind("strike",function(phase)
    if phase~="begin" then return end
    local now=os.clock();if now-lastAttack<0.34 then return end;lastAttack=now
    Net.send("Attack",{dir=aim()})
    Audio.play("swing")
    if Access.motionScale()>0.2 then Feel.shake(0.11) end
end)
Input.bind("heavy",function(phase)
    if phase=="begin" then
        Net.send("HeavyStart",{})
    elseif phase=="end" then
        Net.send("HeavyRelease",{dir=aim()})
        Audio.play("swing",{pitch=0.72})
        if Access.motionScale()>0.2 then Feel.shake(0.24) end
    end
end)
Input.bind("dodge",function(phase)
    if phase~="begin" then return end
    local character=player.Character
    local humanoid=character and character:FindFirstChildOfClass("Humanoid")
    local root=character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
    if not (humanoid and root) then return end
    local move=humanoid.MoveDirection
    local dir=move.Magnitude>0.1 and move.Unit or -root.CFrame.LookVector
    Net.send("Dodge",{dir=dir})
    root:ApplyImpulse(dir*58*root.AssemblyMass)
end)
Input.bind("utility",function(phase)
    if phase=="begin" then Net.send("Utility",{dir=aim3D()}) end
end)
Input.bind("sprint",function(phase)
    Net.send("SetSprint",{on=phase=="begin"})
end)

local function showToast(value: string,color: Color3?)
    toast.Text=value;toast.TextColor3=color or Color3.fromRGB(245,243,252);toast.Visible=true
    toast.TextTransparency=1;TweenService:Create(toast,TweenInfo.new(0.16),{TextTransparency=0}):Play()
    local stamp=os.clock();toast:SetAttribute("Stamp",stamp)
    task.delay(2.6,function() if toast:GetAttribute("Stamp")==stamp then toast.Visible=false end end)
end

local function connectHealth(character: Model)
    local h=character:WaitForChild("Humanoid") :: Humanoid
    local function update()
        healthFill.Size=UDim2.fromScale(math.clamp(h.Health/math.max(h.MaxHealth,1),0,1),1)
        healthFill.BackgroundColor3=if h.Health/h.MaxHealth<0.3 then Config.palette.danger else Config.palette.safe
    end
    h.HealthChanged:Connect(update);update()
end
if player.Character then task.spawn(connectHealth,player.Character) end
player.CharacterAdded:Connect(connectHealth)

Net.on("State",function(payload)
    carried.Text=("UNSTABLE  %d"):format(payload.carried or 0)
    refined.Text=("REFINED   %d   ·   POWER %d"):format(payload.refined or 0,payload.power or 0)
    if payload.objective then objective.Text=payload.objective end
end)
Net.on("Objective",function(payload) objective.Text=payload.text or objective.Text end)
Net.on("Notify",function(payload)
    local c=payload.kind=="good" and Config.palette.safe or payload.kind=="warn" and Config.palette.lumen or nil
    showToast(payload.text or "",c)
end)
Net.on("Lumen",function(payload)
    carried.Text=("UNSTABLE  %d"):format(payload.total or 0);Audio.play("lumen")
    Feel.number((player.Character and player.Character:GetPivot().Position or Vector3.zero)+Vector3.new(0,4,0),
        "+"..tostring(payload.amount or 0),{color=Config.palette.lumen})
end)
Net.on("Boss",function(payload)
    boss.Visible=payload.active==true
    if payload.active then Audio.play("boss");Access.announce("boss.telegraph",2) end
    if payload.defeated then showToast("THE HOLLOW ENGINE SHATTERS",Config.palette.lumen) end
end)
Net.on("BossWindow",function(payload)
    bossHint.Text=("CORE EXPOSED · PHASE %d"):format(payload.phase or 1);bossHint.TextColor3=Config.palette.lumen
    task.delay(payload.seconds or 4,function() bossHint.Text="CORE SEALED";bossHint.TextColor3=Color3.fromRGB(190,170,210) end)
end)
Net.on("Extraction",function(payload)
    extraction.Visible=payload.active==true
    extractionTime.Text=tostring(payload.seconds or 0)
    if payload.active and payload.seconds==payload.total then Audio.play("extract");Access.announce("extraction.wave",2) end
    if payload.success then showToast("EXTRACTION SECURED",Config.palette.safe) end
end)
Net.on("Cooldown",function(payload)
    local label=payload.id=="dash" and dash or utility
    local name=payload.id=="dash" and "DASH" or "BOLT"
    local seconds=payload.seconds or 1
    label.Text=name.."  "..string.format("%.1f",seconds)
    local started=os.clock()
    task.spawn(function()
        while os.clock()-started<seconds do
            local left=math.max(0,seconds-(os.clock()-started))
            label.Text=name.."  "..string.format("%.1f",left)
            task.wait(0.1)
        end
        label.Text=name.."  READY"
    end)
end)
Net.on("HitConfirm",function(payload)
    Audio.play("hit")
    if Access.motionScale()>0.2 then Feel.shake(payload.heavy and 0.20 or 0.08) end
end)
Net.on("PlayerHit",function(_payload)
    Audio.play("hurt")
    if Access.motionScale()>0.2 then Feel.screenTint(Config.palette.danger,0.13,0.18) end
end)

-- Compact phone layout: the action buttons come from Forge.Input; only informational HUD moves.
local function fit()
    local cam=Workspace.CurrentCamera
    if not cam then return end
    local narrow=cam.ViewportSize.X<760
    top.Size=UDim2.fromOffset(narrow and 360 or 520,74)
    carried.Position=UDim2.fromOffset(narrow and 190 or 255,13)
    refined.Position=UDim2.fromOffset(narrow and 190 or 255,40)
    healthBack.Size=UDim2.fromOffset(narrow and 150 or 210,13)
    objective.Size=UDim2.new(narrow and 0.88 or 0.72,0,0,narrow and 64 or 54)
    objective.TextSize=narrow and 15 or 18
    boss.Size=UDim2.fromOffset(narrow and 340 or 460,50)
end
if Workspace.CurrentCamera then Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fit) end
fit()

print("[Lumenfall] client ready")
