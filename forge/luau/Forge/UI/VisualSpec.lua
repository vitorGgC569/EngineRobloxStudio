--!strict
--[[
	VisualKit.Spec — declarative UI spec with fail-closed conformance.

	A UiSpec is data: typed nodes (frame/button/label/image/scroll) with
	token-based styling. The conformance validator walks the tree and
	rejects unknown node kinds, missing required props, raw hex colors
	(tokens only!) and oversized subtrees. The same validator runs at
	build time and as a probe against the live place.
]]

local VisualSpec = {}

export type Node = {
	kind: string,
	name: string?,
	children: { Node }?,
	props: { [string]: any }?,
}

local NODE_KINDS: { [string]: { requiredProps: { string } } } = {
	frame = { requiredProps = {} },
	button = { requiredProps = { "text", "variant" } },
	label = { requiredProps = { "text" } },
	image = { requiredProps = { "assetToken" } },
	scroll = { requiredProps = { "canvasSize" } },
}

local MAX_NODES = 512

-- Returns (ok, problems[]). Problems are stable strings for probes.
function VisualSpec.validate(root: Node): (boolean, { string })
	local problems: { string } = {}
	local count = 0

	local function walk(node: Node, path: string): ()
		count += 1
		if count > MAX_NODES then
			table.insert(problems, ("tree_exceeds_%d_nodes"):format(MAX_NODES))
			return
		end

		local def = NODE_KINDS[node.kind]
		if not def then
			table.insert(problems, ("%s:unknown_kind:%s"):format(path, tostring(node.kind)))
			return
		end
		for _, required in def.requiredProps do
			local value = node.props and node.props[required]
			if value == nil then
				table.insert(problems, ("%s.%s:missing_prop:%s"):format(path, node.kind, required))
			end
		end

		-- Tokens only: no raw Color3/hex strings in specs.
		if node.props then
			for propName, propValue in node.props :: { [string]: any } do
				if type(propValue) == "string" and string.match(propValue, "^#[0-9a-fA-F][0-9a-fA-F]") then
					table.insert(problems, ("%s.%s:raw_hex_forbidden"):format(path, propName))
				end
			end
		end

		for index, child in node.children or {} do
			walk(child, path .. "/" .. (child.name or (node.kind .. tostring(index))))
		end
	end

	walk(root, root.name or "root")
	return #problems == 0, problems
end

function VisualSpec.countNodes(root: Node): number
	local count = 1
	for _, child in root.children or {} do
		count += VisualSpec.countNodes(child)
	end
	return count
end

return VisualSpec
