--!strict
-- Absolute avatar proportions, relative to the original rig (never compounded).
-- R15 uses Roblox's scale channels so attachments, animation constraints,
-- layered accessories and HipHeight are rebuilt together by the engine.
local Proportions={}
local snapshots=setmetatable({}, {__mode="k"})
function Proportions.apply(character: Model, factors: any): any
	local hum=character:FindFirstChildOfClass("Humanoid")
	assert(hum,"proportions require a humanoid")
	local base=snapshots[character]
	if not base then
		base={channels={},parts={},joints={}};snapshots[character]=base
		for _,name in {"BodyWidthScale","BodyDepthScale","BodyHeightScale","HeadScale"} do
			local value=hum:FindFirstChild(name)
			if value and value:IsA("NumberValue") then base.channels[name]={object=value,value=value.Value} end
		end
		if hum.RigType==Enum.HumanoidRigType.R6 then
			for _,p in character:GetChildren() do if p:IsA("BasePart") then base.parts[p]=p.Size end end
			for _,j in character:GetDescendants() do if j:IsA("Motor6D") then base.joints[j]={c0=j.C0,c1=j.C1} end end
		end
	end
	local w,d,h,head=factors.width or 1,factors.depth or 1,factors.height or 1,factors.head or 1
	for _,v in {w,d,h,head} do assert(v==v and v>=.5 and v<=5,"invalid body proportion") end
	if hum.RigType==Enum.HumanoidRigType.R15 then
		hum.AutomaticScalingEnabled=true
		for name,value in {BodyWidthScale=w,BodyDepthScale=d,BodyHeightScale=h,HeadScale=head} do
			local channel=base.channels[name]
			if channel then channel.object.Value=channel.value*value end
		end
	else
		local function factor(p)
			return if p and p.Name=="Head" then Vector3.one*head else Vector3.new(w,h,d)
		end
		for p,size in base.parts do if p.Parent then p.Size=size*factor(p) end end
		for joint,original in base.joints do
			if joint.Parent then
				joint.C0=CFrame.new(original.c0.Position*factor(joint.Part0))*original.c0.Rotation
				joint.C1=CFrame.new(original.c1.Position*factor(joint.Part1))*original.c1.Rotation
			end
		end
	end
	character:SetAttribute("BodyWidthFactor",w);character:SetAttribute("BodyDepthFactor",d)
	character:SetAttribute("BodyHeightFactor",h);character:SetAttribute("HeadFactor",head)
	return {width=w,depth=d,height=h,head=head}
end
return Proportions
