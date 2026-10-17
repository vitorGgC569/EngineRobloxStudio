--!strict
-- Display strings for Saltmere. Numbers stay in Config.

local Content = {}

Content.gradeName = {
	coarse = "Coarse salt",
	fine = "Fine salt",
	flake = "Flake salt",
	smoked = "Smoked salt",
}

Content.gradeBlurb = {
	coarse = "Salt raked from a ready pan during harvest.",
	fine = "Coarse salt refined to a finer grade when a grader's bench or a grader is on the works.",
	flake = "A share of the salt raked from a pan at its highest level after the lighthouse is built.",
	smoked = "Fine salt cured in the smokehouse.",
}

Content.upgradeName = {
	cistern = "Cistern",
	rake = "Rake",
	sluice = "Sluice",
	grader_bench = "Grader's bench",
	smokehouse = "Smokehouse",
	cooperage = "Cooperage",
	lighthouse = "Lighthouse",
	lantern = "Copper lantern",
}

Content.upgradeBlurb = {
	cistern = "Each level adds room for brine in every pan.",
	rake = "Each level draws more salt from the brine when a pan is raked.",
	sluice = "Each level fills the pans faster during the flood.",
	grader_bench = "Lets the works refine coarse salt into fine.",
	smokehouse = "Lets the works cure fine salt into smoked salt.",
	cooperage = "Each level raises the price the quay pays for salt.",
	lighthouse = "Each level raises the quay price; building it allows flake salt and the spring tide, and the light stays when the marsh resets.",
	lantern = "Shows a copper lantern for your works, and the spring tide keeps it.",
}

Content.roleName = {
	raker = "Raker",
	grader = "Grader",
	watch = "Watch",
}

Content.roleBlurb = {
	raker = "Rakes an assigned ready pan during harvest, and again at the start of spoil.",
	grader = "Lets the works refine coarse salt into fine.",
	watch = "While hired, a ready pan that spoils keeps more of its brine.",
}

Content.panBlurb = "Pans on the plot fill in the flood and yield salt when raked during harvest."

Content.phaseName = {
	flood = "Flood",
	settle = "Settle",
	harvest = "Harvest",
	spoil = "Spoil",
}

local NAMES: { [string]: { [string]: string } } = {
	grade = Content.gradeName,
	upgrade = Content.upgradeName,
	role = Content.roleName,
	phase = Content.phaseName,
}

function Content.lookup(kind: string, id: string): string
	local names = NAMES[kind]
	if names == nil then
		return id
	end
	return names[id] or id
end

return Content
