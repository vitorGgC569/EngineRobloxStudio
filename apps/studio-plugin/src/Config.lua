--!strict
-- Shared constants for the RQE Studio Bridge plugin.

local Config = {}

Config.PROTOCOL = "rqe.bridge/2"
Config.PLUGIN_VERSION = "2.1.0"
Config.PLUGIN_BUILD_ID = "__RQE_BUILD_ID__"

-- The hub always binds to loopback. A bridge that accepted remote commands
-- would be a remote code execution surface on the developer's machine.
Config.DEFAULT_HUB_URL = "http://127.0.0.1:8790"

-- Long-poll budget. The hub holds a poll for ~1.5s, so this must exceed it while
-- staying under Roblox's own 60s HTTP ceiling.
Config.POLL_TIMEOUT_SECONDS = 30

-- Backoff applied after a failed request so a stopped hub does not spin the
-- request budget (Roblox allows roughly 500 HTTP calls per minute).
Config.RECONNECT_DELAY_SECONDS = 2
Config.MAX_RECONNECT_DELAY_SECONDS = 15

-- How many commands the plugin accepts per poll.
Config.MAX_BATCH = 8

-- Guardrails on introspection so one query cannot lock Studio or blow the
-- agent's context window.
Config.MAX_TREE_NODES = 1500
Config.MAX_TREE_DEPTH = 12
Config.MAX_FIND_RESULTS = 500
Config.MAX_LOG_LINES = 500

Config.SETTING_KEYS = {
	hubUrl = "RQEBridge_HubUrl",
	autoConnect = "RQEBridge_AutoConnect",
}

return Config
