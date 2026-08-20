--!strict
--[[
	Mark — tell the Quality Engine what it is looking at.

	The gap this closes
	-------------------

	The Quality Engine can photograph a place, measure its palette, check that
	the thing a scene is about stays visible from the viewpoints a player
	actually gets, and score whether a region reads. It finds all of that by
	**tag**: `RQEVisualRoot` on a thing, `RQEVisualRegion` on a floor,
	`RQELandmark` on the subject, `RQELandmarkAnchor` on the points that must
	be visible.

	A world built by `World.scatter` carries none of those. So the strongest
	half of the validator looked at every Forge game and correctly reported
	that it could not see anything — not a low score, an inability to be
	looked at. Two halves of one repository, each complete, unable to speak.

	This is the vocabulary they now share.

		Mark.root(rock, "rock", "granite")
		Mark.region(floor, "arena")
		Mark.landmark(obelisk, "objective-core")
		Mark.ringAnchors(obelisk, "objective-core")

	Why tags and not a manifest
	---------------------------

	A manifest is written once and is wrong the moment the world generator
	changes a number. A tag travels with the instance, so a world that
	regenerates on a new seed stays describable without anyone editing
	anything — and the marking survives `forge scene pull`, which a side-car
	file would not.

	Nothing here changes how anything looks. Every function is a label.
]]

local CollectionService = game:GetService("CollectionService")

local Mark = {}

--[[
	The names, exactly as the Quality Engine's classification block spells them.

	Constants rather than literals at each call site, because these strings are
	a contract between two programs and a typo in one of them is a silence
	rather than an error: the validator would simply find nothing and report
	the game as unlookable, which is indistinguishable from a game with nothing
	in it.
]]
Mark.TAGS = {
	candidate = "RQEVisualCandidate",
	root = "RQEVisualRoot",
	region = "RQEVisualRegion",
	landmark = "RQELandmark",
	anchor = "RQELandmarkAnchor",
	exclude = "RQEVisualExclude",
}

Mark.ATTRIBUTES = {
	kind = "VisualType",
	variant = "VisualVariant",
	assetKey = "AssetKey",
	regionProfile = "VisualRegionProfile",
	landmarkId = "LandmarkId",
}

local counts = { roots = 0, regions = 0, landmarks = 0, anchors = 0, excluded = 0 }

-- ================================== roots ===================================
--[[
	This instance is one thing worth looking at.

	A root is the top of a single visual object: the rock, not its six meshes.
	Marking parts instead of models is the mistake that turns a scene of forty
	props into a scene of nine hundred, and every density and coverage number
	computed afterwards then means something other than what it says.
]]
function Mark.root(instance: Instance, kind: string, variant: string?, assetKey: string?)
	CollectionService:AddTag(instance, Mark.TAGS.root)
	CollectionService:AddTag(instance, Mark.TAGS.candidate)
	instance:SetAttribute(Mark.ATTRIBUTES.kind, kind)
	if variant then
		instance:SetAttribute(Mark.ATTRIBUTES.variant, variant)
	end
	if assetKey then
		instance:SetAttribute(Mark.ATTRIBUTES.assetKey, assetKey)
	end
	counts.roots += 1
end

--[[
	Mark a container's children in one call.

	`World.scatter` puts its output into a folder, and marking them one by one
	at the call site is how half of them end up unmarked the next time somebody
	adds a branch. Returns the count so a caller can assert on it rather than
	assume.
]]
function Mark.rootsIn(container: Instance, kind: string, variant: string?): number
	local marked = 0
	for _, child in container:GetChildren() do
		if child:IsA("Model") or child:IsA("BasePart") then
			Mark.root(child, kind, variant)
			marked += 1
		end
	end
	return marked
end

-- ================================= regions ==================================
--[[
	A named area, with a profile the spec holds to a standard.

	The profile is the join: the spec says what an "arena" must contain and how
	much of it, this says which instance is one. Regions are what let the
	question be "is this place composed" rather than only "is this prop
	floating".
]]
function Mark.region(instance: Instance, profile: string)
	CollectionService:AddTag(instance, Mark.TAGS.region)
	instance:SetAttribute(Mark.ATTRIBUTES.regionProfile, profile)
	counts.regions += 1
end

-- ================================ landmarks =================================
--[[
	The thing the scene is about.

	What the camera is pointed at, and what must stay visible from every
	viewpoint the spec declares. Most places have exactly one. A place with
	none is a place with nothing to look at, which is a real finding rather
	than a missing tag.
]]
function Mark.landmark(instance: Instance, id: string)
	CollectionService:AddTag(instance, Mark.TAGS.landmark)
	instance:SetAttribute(Mark.ATTRIBUTES.landmarkId, id)
	counts.landmarks += 1
end

--[[
	The points on a landmark that have to be visible.

	Visibility is cast at anchors rather than at a bounding box, because a
	bounding box counts as visible the moment one corner clears a wall and a
	player would still say they cannot see the thing. Several anchors spread
	over the silhouette is what makes "visible" mean visible.
]]
function Mark.anchor(instance: Instance, landmarkId: string)
	CollectionService:AddTag(instance, Mark.TAGS.anchor)
	instance:SetAttribute(Mark.ATTRIBUTES.landmarkId, landmarkId)
	counts.anchors += 1
end

--[[
	Ring a landmark with anchors instead of authoring them by hand.

	Invisible, non-colliding and parented to the landmark so they travel with
	it. Ringed at roughly eye height rather than scattered through the volume:
	the question is whether the silhouette reads from around the place, and a
	point buried inside the model answers a question nobody asked.
]]
function Mark.ringAnchors(landmark: Instance, landmarkId: string, count: number?, radius: number?): number
	local pivot: CFrame, extents: Vector3
	if landmark:IsA("Model") then
		pivot = landmark:GetPivot()
		extents = landmark:GetExtentsSize()
	elseif landmark:IsA("BasePart") then
		pivot = landmark.CFrame
		extents = landmark.Size
	else
		return 0
	end

	local total = count or 6
	local distance = radius or math.max(extents.X, extents.Z) * 0.5

	for index = 1, total do
		local angle = (index / total) * math.pi * 2
		local anchor = Instance.new("Part")
		anchor.Name = string.format("VisualAnchor%d", index)
		anchor.Size = Vector3.new(0.4, 0.4, 0.4)
		anchor.Transparency = 1
		anchor.CanCollide = false
		anchor.CanQuery = false
		anchor.CanTouch = false
		anchor.Anchored = true
		anchor.CFrame = pivot * CFrame.new(
			math.cos(angle) * distance,
			extents.Y * 0.4,
			math.sin(angle) * distance)
		anchor.Parent = landmark
		Mark.anchor(anchor, landmarkId)
		--[[
			An anchor is apparatus, not scenery.

			Left classifiable, six of them would count as six more visual
			objects and move every density number the spec computes — a
			measuring instrument changing the measurement.
		]]
		CollectionService:AddTag(anchor, Mark.TAGS.exclude)
	end
	return total
end

-- ================================= exclude ==================================
--[[
	Present, but not scenery: effects, debug markers, test rigs, apparatus.

	The spec requires a fraction of candidates to be classified, so anything
	that is in the world without being part of the composition has to say so,
	or the game fails a composition check because of a particle emitter.
]]
function Mark.exclude(instance: Instance)
	CollectionService:AddTag(instance, Mark.TAGS.exclude)
	counts.excluded += 1
end

function Mark.excludeIn(container: Instance): number
	local marked = 0
	for _, descendant in container:GetDescendants() do
		if descendant:IsA("BasePart") then
			Mark.exclude(descendant)
			marked += 1
		end
	end
	return marked
end

-- ================================= reading ==================================
--[[
	What is actually marked in the live place.

	Counted from CollectionService rather than from the tallies below, because
	the tallies only know about this session and the question is what the place
	contains.
]]
function Mark.audit(): { [string]: any }
	local tagged = {}
	for name, tag in Mark.TAGS do
		tagged[name] = #CollectionService:GetTagged(tag)
	end

	local landmarkIds: { string } = {}
	local profiles: { [string]: number } = {}
	for _, instance in CollectionService:GetTagged(Mark.TAGS.landmark) do
		local id = instance:GetAttribute(Mark.ATTRIBUTES.landmarkId)
		if id then
			table.insert(landmarkIds, tostring(id))
		end
	end
	for _, instance in CollectionService:GetTagged(Mark.TAGS.region) do
		local profile = instance:GetAttribute(Mark.ATTRIBUTES.regionProfile)
		if profile then
			local key = tostring(profile)
			profiles[key] = (profiles[key] or 0) + 1
		end
	end

	return {
		tagged = tagged,
		landmarkIds = landmarkIds,
		regionProfiles = profiles,
		--[[
			Whether the place can be scored at all.

			A world with roots and no landmark photographs perfectly well and
			cannot be evaluated: there is nothing the camera is meant to be
			pointed at. Surfacing it means "the validator saw nothing" is a
			line in a snapshot rather than an unexplained zero.
		]]
		scoreable = #CollectionService:GetTagged(Mark.TAGS.landmark) > 0
			and #CollectionService:GetTagged(Mark.TAGS.region) > 0,
	}
end

function Mark.describe(): { [string]: any }
	local report = Mark.audit()
	report.markedThisSession = table.clone(counts)
	return report
end

return Mark
