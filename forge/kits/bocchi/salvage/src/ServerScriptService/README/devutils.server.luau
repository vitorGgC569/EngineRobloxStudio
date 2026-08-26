-- set all parts in workspace to studs


for i,v in pairs(workspace:GetDescendants()) do
	if (v:IsA("BasePart") and v.Material == Enum.Material.Plastic) then
		v.TopSurface = "Studs";
		v.BottomSurface = "Studs";
		v.LeftSurface = "Studs";
		v.RightSurface = "Studs";
		v.FrontSurface = "Studs";
		v.BackSurface = "Studs";
	end
end




-- print all buttons


for i = 1, 50 do
	local button = workspace.Buttons:FindFirstChild(i)
	if (button) then
		local info = require(button.Info)
		
		print(`{info.Name} - {info.Descriptions.Default} - Cost: {info.Cost(1):toString()}`)
	end
end