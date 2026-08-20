--!strict
-- Machine-readable roles emitted by WorldKit builders.
--
-- Names and hierarchy are presentation details. These tags are the stable
-- contract used by validators, scenario locators and deterministic cameras.

local CollectionService = game:GetService("CollectionService")

local Semantics = {}

Semantics.Tags = table.freeze({
	visualCandidate = "RQEVisualCandidate",
	visualRoot = "RQEVisualRoot",
	visualRegion = "RQEVisualRegion",
	visualExclude = "RQEVisualExclude",
	landmark = "RQELandmark",
	landmarkAnchor = "RQELandmarkAnchor",
})

local function nonEmpty(value: string, label: string)
	if value == "" then
		error(label .. " must not be empty", 3)
	end
end

function Semantics.candidate(instance: Instance)
	CollectionService:AddTag(instance, Semantics.Tags.visualCandidate)
end

function Semantics.root(instance: Instance, visualType: string, variant: string, assetKey: string?)
	nonEmpty(visualType, "visualType")
	nonEmpty(variant, "variant")
	Semantics.candidate(instance)
	CollectionService:AddTag(instance, Semantics.Tags.visualRoot)
	instance:SetAttribute("VisualType", visualType)
	instance:SetAttribute("VisualVariant", variant)
	if assetKey ~= nil then
		nonEmpty(assetKey, "assetKey")
		instance:SetAttribute("AssetKey", assetKey)
	end
end

function Semantics.region(instance: Instance, profile: string, regionId: string)
	nonEmpty(profile, "profile")
	nonEmpty(regionId, "regionId")
	CollectionService:AddTag(instance, Semantics.Tags.visualRegion)
	instance:SetAttribute("VisualRegionProfile", profile)
	instance:SetAttribute("RegionId", regionId)
end

function Semantics.exclude(instance: Instance)
	CollectionService:AddTag(instance, Semantics.Tags.visualExclude)
end

function Semantics.landmark(instance: Instance, landmarkId: string)
	nonEmpty(landmarkId, "landmarkId")
	CollectionService:AddTag(instance, Semantics.Tags.landmark)
	instance:SetAttribute("LandmarkId", landmarkId)
end

function Semantics.anchor(parent: Instance, landmarkId: string, position: Vector3): BasePart
	nonEmpty(landmarkId, "landmarkId")
	local anchor = Instance.new("Part")
	anchor.Name = "RQELandmarkAnchor_" .. landmarkId
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.Position = position
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanTouch = false
	anchor.CanQuery = false
	anchor.CastShadow = false
	anchor:SetAttribute("LandmarkId", landmarkId)
	CollectionService:AddTag(anchor, Semantics.Tags.landmarkAnchor)
	CollectionService:AddTag(anchor, Semantics.Tags.visualExclude)
	anchor.Parent = parent
	return anchor
end

return Semantics
