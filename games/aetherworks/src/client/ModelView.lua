local RS=game:GetService("ReplicatedStorage")
local Art=require(RS.Shared.Art)
local View={}
function View.mount(parent,name,x,y,w,h)
    local frame=Instance.new("ViewportFrame");frame.Name=name;frame.Position=UDim2.fromOffset(x,y);frame.Size=UDim2.fromOffset(w,h)
    frame.BackgroundColor3=Color3.fromRGB(34,61,67);frame.BorderSizePixel=0;frame.Ambient=Color3.fromRGB(153,179,184)
    frame.LightColor=Color3.fromRGB(255,238,207);frame.LightDirection=Vector3.new(-1,-1,-1);frame.Parent=parent
    local corner=Instance.new("UICorner");corner.CornerRadius=UDim.new(0,10);corner.Parent=frame
    local cam=Instance.new("Camera");cam.FieldOfView=32;cam.Parent=frame;frame.CurrentCamera=cam
    local self={frame=frame,key=nil}
    function self:show(kind,id,tier)
        local key=kind..tostring(id)..":"..tostring(tier);if key==self.key then return end
        local old=frame:FindFirstChild("Scene");if old then old:Destroy() end
        local scene=Instance.new("WorldModel");scene.Name="Scene";scene.Parent=frame
        local m
        if kind=="machine" then
            local book=RS:FindFirstChild("AetherPreviews");local source=book and book:FindFirstChild("Machine_"..id)
            if not source then scene:Destroy();return end
            m=source:Clone();m.Parent=scene;Art.evolve(m,tier)
        elseif kind=="crystal" then m=Art.crystal(scene,CFrame.new(),1,tier)
        elseif kind=="pet" then m=Art.pet(scene,CFrame.new(),id,tier)
        else
            m=Art.group(scene,"Equipment",CFrame.new())
            Art.mesh(m,"Gauntlet","gauntlet",Vector3.new(2.4,3,2),CFrame.Angles(-.3,.25,0),Color3.fromRGB(45,130,136))
            Art.crystal(m,CFrame.new(.8,.5,-.5),.4,tier)
        end
        self.key=key
        for _,v in scene:GetDescendants() do if v:IsA("ParticleEmitter") or v:IsA("Trail") then v.Enabled=false end end
        local cf,size=m:GetBoundingBox();local distance=math.max(size.X,size.Y,size.Z)*2.25
        cam.CFrame=CFrame.lookAt(cf.Position+Vector3.new(distance*.6,distance*.35,distance*.85),cf.Position)
    end
    return self
end
return View
