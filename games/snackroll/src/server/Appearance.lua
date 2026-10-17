local RS=game:GetService("ReplicatedStorage")
local Proportions=require(RS.Forge).Rig.Proportions
local Art=require(RS.Shared.Art)
local C=require(RS.Shared.Config)
local Appearance={}
local avatars=setmetatable({}, {__mode="k"})
local cream=Color3.fromRGB(255,243,223)
local navy=Color3.fromRGB(36,94,149)
local function cover(character,limb,shape,color,extra,name,offset)
	local mesh=Art.mesh(character,name or ("Suit_"..limb.Name),shape,limb.Size,limb.CFrame,color)
	mesh.Anchored=false;mesh.Massless=true
	local w=Instance.new("Weld");w.Name="Fit";w.Part0=limb;w.Part1=mesh;w.Parent=mesh
	limb.Transparency=1
	local function fit()
		mesh.Size=limb.Size*(extra or Vector3.new(1.06,1.025,1.06))
		w.C0=CFrame.new((offset or Vector3.zero)*limb.Size+Vector3.new(0,0,if shape=="shirt" then -.035*limb.Size.Z else 0))
	end
	fit();limb:GetPropertyChangedSignal("Size"):Connect(fit)
	return mesh
end
function Appearance.update(character,weight)
	local hum=character:FindFirstChildOfClass("Humanoid");if not hum then return end
	local g=math.clamp(math.log(1+weight/35)/math.log(180),0,1.5)
	local scale=Proportions.apply(character,{width=1+g*1.18,depth=1+g*1.55,height=1+g*.2,head=1+g*.22})
	if not avatars[character] then
		avatars[character]=true
		local old=character:FindFirstChild("SnackBelly");if old then old:Destroy() end
		for _,limb in character:GetChildren() do
			if limb:IsA("BasePart") then
				local n=limb.Name
				if n=="UpperTorso" or n=="Torso" then
					local shirt=cover(character,limb,"shirt",cream,Vector3.new(1.12,1.08,1.14),"SnackShirt")
					local gui=Instance.new("SurfaceGui");gui.Face=Enum.NormalId.Front;gui.CanvasSize=Vector2.new(512,512);gui.LightInfluence=.15;gui.Parent=shirt
					local mark=Instance.new("TextLabel");mark.Size=UDim2.fromScale(.62,.35);mark.Position=UDim2.fromScale(.19,.36);mark.BackgroundTransparency=1;mark.Text="SNACK\nCLUB";mark.TextColor3=navy;mark.Font=Enum.Font.FredokaOne;mark.TextScaled=true;mark.Parent=gui
				elseif n=="LowerTorso" then cover(character,limb,"rounded",navy,Vector3.new(1.11,1.08,1.14),"SnackShorts")
				elseif n:find("UpperArm") or n:find("LowerArm") or n:find("UpperLeg") or n:find("LowerLeg") or n:find(" Arm") or n:find(" Leg") then
					local skin=character:FindFirstChild("Head");cover(character,limb,"rounded",if n:find("UpperLeg") then navy elseif skin then skin.Color else limb.Color)
					if n:find("UpperArm") then cover(character,limb,"rounded",cream,Vector3.new(1.15,.55,1.15),"SnackSleeve",Vector3.new(0,.28,0)) end
				end
			end
		end
	end
	character:SetAttribute("Growth",g)
	character:SetAttribute("RollRadius",2.9+g*1.75)
	return scale
end
return Appearance
