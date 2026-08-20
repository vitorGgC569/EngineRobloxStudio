--!strict
-- Read the build-time product identity stamp from the real DataModel.
--
-- This command reports only what exists in the place. It does not accept an
-- expected identity in params and therefore cannot turn caller input into
-- apparent runtime evidence.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ProductCommands = {}

local REQUIRED_STRINGS = {
	"ProductId",
	"IntentId",
	"ContractId",
	"VisualSpecId",
	"ProductIntentSha256",
	"ContractSha256",
	"VisualQualitySpecSha256",
	"ReferenceBenchmarkSha256",
	"VisualCalibrationSha256",
	"StampSha256",
}

local function context(): string
	if RunService:IsRunning() then
		if RunService:IsServer() and RunService:IsClient() then
			return "run"
		elseif RunService:IsServer() then
			return "server"
		elseif RunService:IsClient() then
			return "client"
		end
		return "run"
	end
	return "edit"
end

function ProductCommands.identity(_params: { [string]: any }): any
	local stamp = ReplicatedStorage:FindFirstChild("RQEProductIdentity")
	if stamp == nil then
		return {
			available = false,
			conclusive = true,
			reason = "build has no RQEProductIdentity stamp",
			context = context(),
			placeName = game.Name,
		}
	end
	if not stamp:IsA("Configuration") then
		return {
			available = false,
			conclusive = true,
			reason = "RQEProductIdentity is not a Configuration",
			className = stamp.ClassName,
			context = context(),
			placeName = game.Name,
		}
	end

	local missing = {}
	for _, name in ipairs(REQUIRED_STRINGS) do
		local value = stamp:GetAttribute(name)
		if type(value) ~= "string" or value == "" then
			table.insert(missing, name)
		end
	end
	local schemaVersion = stamp:GetAttribute("SchemaVersion")
	if schemaVersion ~= 1 then
		table.insert(missing, "SchemaVersion=1")
	end
	if #missing > 0 then
		return {
			available = false,
			conclusive = true,
			reason = "product identity stamp is incomplete",
			missing = missing,
			context = context(),
			placeName = game.Name,
		}
	end

	return {
		available = true,
		conclusive = true,
		schemaVersion = schemaVersion,
		measuredIdentity = {
			productId = stamp:GetAttribute("ProductId"),
			intentId = stamp:GetAttribute("IntentId"),
			contractId = stamp:GetAttribute("ContractId"),
			visualSpecId = stamp:GetAttribute("VisualSpecId"),
		},
		artifactHashes = {
			productIntent = stamp:GetAttribute("ProductIntentSha256"),
			contract = stamp:GetAttribute("ContractSha256"),
			visualQualitySpec = stamp:GetAttribute("VisualQualitySpecSha256"),
			referenceBenchmark = stamp:GetAttribute("ReferenceBenchmarkSha256"),
			visualCalibration = stamp:GetAttribute("VisualCalibrationSha256"),
		},
		stampSha256 = stamp:GetAttribute("StampSha256"),
		context = context(),
		placeName = game.Name,
		placeId = game.PlaceId,
		gameId = game.GameId,
	}
end

return ProductCommands
