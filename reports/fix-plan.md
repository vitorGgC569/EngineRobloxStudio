# RQE Fix Plan

Generated from the latest audit.

1 finding(s) require attention:

## [CRITICAL] `contract_coverage`

Há requisitos sem probe executável

Evidence: `contract.probe_coverage`
Details: `{'requiredProbes': ['asset_security', 'buried_objects', 'button_interaction', 'camera_obstruction', 'card_gallery', 'collision_overlap', 'contract_schema', 'door_clearance', 'duplicate_connections', 'fixture_excluded', 'floating_objects', 'floor_progression', 'instance_growth', 'interaction_distance', 'memory_growth', 'multiplayer_isolation', 'objective_reachable', 'path_exists', 'performance_budget', 'persistence', 'product_truth_alignment', 'remote_security', 'runtime_error', 'spawn_clearance', 'spawn_support', 'stairs_validity', 'structural_integrity', 'studio_runtime_capture', 'ui_overflow', 'ui_visibility', 'visual_asset_quality', 'visual_quality', 'visual_snapshot_bundle', 'visual_spec_schema'], 'uncovered': ['contract_schema', 'fixture_excluded', 'product_truth_alignment', 'structural_integrity', 'visual_spec_schema']}`

Suggested action: reproduce the probe in Studio, apply the smallest server-authoritative fix, then run `python rqe.py verify .`.
