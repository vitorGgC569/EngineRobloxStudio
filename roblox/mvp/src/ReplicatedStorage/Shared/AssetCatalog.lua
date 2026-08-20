local AssetCatalog = {}

local definitions = {
	ridge_exchange = {source = "native-procedural", status = "approved"},
	old_lantern_mine = {source = "native-procedural", status = "approved"},
	claim_beacon = {source = "native-procedural", status = "approved"},
	lantern_post = {source = "native-procedural", status = "approved"},
	ore_cluster = {source = "native-procedural", status = "approved"},
	pine_tree = {source = "native-procedural", status = "approved"},
	mine_cart = {source = "native-procedural", status = "approved"},
	ridge_bench = {source = "native-procedural", status = "approved"},
	ore_crate = {source = "native-procedural", status = "approved"},
	ridge_lift = {source = "native-procedural", status = "approved"},
}

function AssetCatalog.decorate(model, key)
	local definition = definitions[key]
	assert(definition, "Unknown asset key: " .. tostring(key))
	model:SetAttribute("AssetKey", key)
	model:SetAttribute("AssetSource", definition.source)
	model:SetAttribute("AssetStatus", definition.status)
	model:SetAttribute("ScriptScan", "clean")
	return model
end

function AssetCatalog.isApproved(key)
	local definition = definitions[key]
	return definition ~= nil and definition.status == "approved" and definition.source == "native-procedural"
end

return AssetCatalog
