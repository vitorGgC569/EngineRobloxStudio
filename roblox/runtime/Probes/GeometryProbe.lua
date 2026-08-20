local GeometryProbe = {}

local function samplePoints(boxCFrame, boxSize)
	local half = boxSize / 2
	return {
		boxCFrame.Position,
		(boxCFrame * CFrame.new(-half.X, 0, -half.Z)).Position,
		(boxCFrame * CFrame.new(half.X, 0, -half.Z)).Position,
		(boxCFrame * CFrame.new(-half.X, 0, half.Z)).Position,
		(boxCFrame * CFrame.new(half.X, 0, half.Z)).Position,
		(boxCFrame * CFrame.new(0, 0, -half.Z)).Position,
		(boxCFrame * CFrame.new(half.X, 0, 0)).Position,
		(boxCFrame * CFrame.new(0, 0, half.Z)).Position,
		(boxCFrame * CFrame.new(-half.X, 0, 0)).Position,
	}
end

function GeometryProbe.groundSupport(target, maxGap, params)
	local boxCFrame, boxSize = target:GetBoundingBox()
	local points = samplePoints(boxCFrame, boxSize)
	local supported = 0
	local unsupportedPoints = {}
	for index, point in ipairs(points) do
		local result = workspace:Raycast(point + Vector3.new(0, 0.5, 0), Vector3.new(0, -maxGap - 0.5, 0), params)
		if result and result.Instance then
			supported += 1
		else
			table.insert(unsupportedPoints, { index = index, point = point })
		end
	end
	return {
		status = #unsupportedPoints == 0 and "PASS" or "FAIL",
		supportCoverage = supported / #points,
		unsupportedPoints = unsupportedPoints,
		largestGap = maxGap,
	}
end

return GeometryProbe

