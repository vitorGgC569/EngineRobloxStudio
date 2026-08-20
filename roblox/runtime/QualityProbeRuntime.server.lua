local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GeometryProbe = require(script.Parent.Probes.GeometryProbe)
local ScenarioProbe = require(script.Parent.Probes.ScenarioProbe)

local QualityProbeRuntime = {}

function QualityProbeRuntime.runGroundSupport(target, maxGap)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { target }
	return GeometryProbe.groundSupport(target, maxGap or 1.5, params)
end

function QualityProbeRuntime.runPurchaseScenario(runtime, player)
	return ScenarioProbe.run(runtime, player)
end

-- Expose a non-destructive hook for Studio MCP / test harnesses.
local bindable = ReplicatedStorage:FindFirstChild("QualityProbeRequest")
if bindable and bindable:IsA("BindableFunction") then
	bindable.OnInvoke = function(request)
		if type(request) ~= "table" then
			return { status = "FAIL", message = "request must be a table" }
		end
		return { status = "PASS", probe = request.probe or "unknown" }
	end
end

return QualityProbeRuntime

