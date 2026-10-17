return function(T)
	local RS=game:GetService("ReplicatedStorage")
	local B=require(RS.Forge).Progression.BarrierRun
	local C=require(RS.Shared.Config)
	T.scenario("barrier energy cannot bypass or repay a gate",function(t)
		local r=B.new({speed=10,gates={{distance=10,cost=8,reward=5},{distance=20,cost=9,reward=7}}},8)
		local events=r:step(3)
		t:expect(#events==1 and r.broken==1 and r.energy==0,"exact energy must break exactly one gate")
		t:expect(r.finished and r.distance==20 and r.reward==5,"insufficient energy must end at blocking gate")
		r:step(10);t:expect(r.reward==5,"a finished run must never repay")
	end)
	T.scenario("distance results do not depend on frame division",function(t)
		local a=B.new(C.course,2000);local b=B.new(C.course,2000)
		a:step(100)
		for _=1,1000 do b:step(.1) end
		t:expect(a.broken==b.broken and a.reward==b.reward and a.energy==b.energy,"timesteps must give identical payout")
	end)
	T.scenario("cancelled run is closed and cannot farm rewards",function(t)
		local r=B.new(C.course,10000);r:step(.8);local before=r.reward;r:cancel();r:step(300)
		t:expect(r.reward==before and r.reason=="cancelled","cancel must freeze payout")
	end)
	T.scenario("rebirth pet capacity and starter economy are coherent",function(t)
		t:expect(C.petCapacity({rebirths=0})==2 and C.petCapacity({rebirths=100})==5,"pet slots bounded")
		local p={rebirths=0,food=1,equipped={"pup"}}
		t:expect(C.multiplier(p)==1.15,"equipped pet affects food gain")
		p.equipped={};t:expect(C.gain(p)==4,"first food gain")
		local r=B.new(C.course,40);r:step(100)
		t:expect(r.reward>=C.foods[2].cost,"ten starter bites must afford the donut after a run")
	end)
	T.scenario("food display pivots preserve a horizontal bun",function(t)
		local art=require(RS.Shared.Art)
		local burger=art.food("burger");burger:PivotTo(CFrame.new(20,5,30))
		local bun=burger:FindFirstChild("LowerBun")
		t:expect(math.abs(bun.CFrame.RightVector.Y)>.99,"cylinder axis must remain vertical after display placement")
		burger:Destroy()
	end)
	T.scenario("restaurant checkerboard includes both tile colors",function(t)
		local colors={}
		for _,p in workspace.SnackRollWorld:GetChildren() do if p.Name=="CheckerTile" then colors[p.Color:ToHex()]=true end end
		local count=0;for _ in colors do count+=1 end
		t:expect(count==2,"checkerboard must alternate instead of collapsing to a single color")
	end)
	T.scenario("whole-body growth is absolute and reversible on a real R15 rig",function(t)
		local Players=game:GetService("Players")
		local Proportions=require(RS.Forge).Rig.Proportions
		local desc=Instance.new("HumanoidDescription")
		for _,name in {"HeadColor","LeftArmColor","RightArmColor","LeftLegColor","RightLegColor","TorsoColor"} do desc[name]=Color3.fromRGB(237,187,143) end
		local model=Players:CreateHumanoidModelFromDescriptionAsync(desc,Enum.HumanoidRigType.R15)
		model.Name="GrowthRegression";model.Parent=workspace;model:PivotTo(CFrame.new(5000,30,5000));model.HumanoidRootPart.Anchored=true
		local base={};for _,name in {"UpperTorso","LeftUpperArm","LeftUpperLeg","Head"} do base[name]=model[name].Size end
		Proportions.apply(model,{width=2,depth=2.3,height=1.15,head=1.2});task.wait(.15)
		for name,size in base do t:expect(model[name].Size.X>size.X*1.1,name.." must grow with the body") end
		local torso=model.UpperTorso.Size
		Proportions.apply(model,{width=2,depth=2.3,height=1.15,head=1.2});task.wait(.1)
		t:expect((model.UpperTorso.Size-torso).Magnitude<.02,"repeated updates must not compound")
		Proportions.apply(model,{width=1,depth=1,height=1,head=1});task.wait(.1)
		for name,size in base do t:expect((model[name].Size-size).Magnitude<.03,name.." must return to original size") end
		local ok,args=pcall(function() return game:GetService("StudioTestService"):GetTestArgs() end)
		if ok and args and args.artReview then
			local Appearance=require(game.ServerScriptService.Server.Appearance)
			local gallery=Instance.new("Folder");gallery.Name="GrowthArtReview";gallery.Parent=workspace
			for i,weight in {0,2500,20000} do
				local clone=model:Clone();clone.Name="Preview_"..weight;clone.Parent=gallery
				Appearance.update(clone,weight);clone:PivotTo(CFrame.new(5000+(i-2)*10,30,5000)*CFrame.Angles(0,math.pi,0))
				local label=Instance.new("BillboardGui");label.Size=UDim2.fromOffset(180,44);label.StudsOffsetWorldSpace=Vector3.new(0,3,0);label.MaxDistance=100;label.AlwaysOnTop=true;label.Parent=clone.Head
				local text=Instance.new("TextLabel");text.Size=UDim2.fromScale(1,1);text.BackgroundColor3=Color3.fromRGB(33,38,62);text.TextColor3=Color3.fromRGB(255,246,222);text.Font=Enum.Font.FredokaOne;text.TextSize=20;text.Text="PRÉVIA: "..weight.." PESO";text.Parent=label
			end
			game:GetService("Debris"):AddItem(gallery,180)
		end
		model:Destroy()
	end)
end
