--!strict
-- L7: genre templates.
--
-- A template composes L0-L6 into the artefacts one genre needs, from a compact
-- definition. It owns no geometry, no colours and no thresholds -- those come
-- from the token set, the kit and the grammar, which is what lets two games in
-- the same genre look nothing alike and two games in different genres share
-- every layer beneath.
--
-- The set is deliberately more than one. A single template proves nothing about
-- genericity: whatever shape it has, the layers below could have been built
-- around it. Two templates that disagree structurally on every axis and still
-- compile through the same stack is the actual evidence.

local Templates = {}

Templates.Tycoon = require(script.Tycoon)
Templates.Defense = require(script.Defense)

Templates.VERSION = "1.0.0"

--- Compare two compiled games structurally.
---
--- Used as a guard rather than a report: if two genres produce the same
--- signature, one of them is the other wearing different names, and the
--- generality claim is not evidenced.
function Templates.differ(a: { [string]: any }, b: { [string]: any }): { string }
	local differences: { string } = {}
	local left, right = a.signature, b.signature
	for _, field in ipairs({ "topology", "progression", "privateSpace" }) do
		if left[field] ~= right[field] then
			table.insert(differences, string.format(
				"%s: %s vs %s", field, tostring(left[field]), tostring(right[field])
			))
		end
	end
	return differences
end

return Templates
