"""Every NPC's voice is walkable, gated, and free of the fishing controls.

NpcData builds dialogue trees per conversation from a context the server
assembles. A tree that points at a missing node, invents an action, or
greets a pauper and a captain identically is a content bug that only shows
up in front of a player -- which is exactly the class of thing the
headless harness exists to catch before Studio does.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
SHARED = ROOT / "games/tidebound/src/shared"

BODY = """
local NpcData = Require("NpcData")

local checks = 0
local failures = {}
local function check(name, ok, detail)
	checks += 1
	if not ok then
		table.insert(failures, name .. (detail ~= nil and (": " .. tostring(detail)) or ""))
	end
end

-- ================================ roster ===================================
local hub, fisher = 0, 0
local ids, keys = {}, {}
local BLOCKED = { Q = true, W = true, A = true, S = true, D = true }
for _, npc in NpcData.roster do
	check("id is unique: " .. tostring(npc.id), ids[npc.id] == nil)
	ids[npc.id] = true
	check("key is unique: " .. tostring(npc.id), keys[npc.key] == nil, npc.key)
	keys[npc.key] = true
	check("key stays off fishing controls: " .. tostring(npc.id), not BLOCKED[npc.key], npc.key)
	check("offset stays near the dock: " .. tostring(npc.id), npc.offset.Magnitude <= 80, npc.offset.Magnitude)
	check("palette is complete: " .. tostring(npc.id),
		typeof(npc.palette.shirt) == "Color3" and typeof(npc.palette.pants) == "Color3"
		and typeof(npc.palette.skin) == "Color3" and typeof(npc.palette.hat) == "Color3")
	check("zone exists: " .. tostring(npc.id),
		npc.zone == "shallows" or npc.zone == "kelp" or npc.zone == "coral"
		or npc.zone == "storm" or npc.zone == "abyss", npc.zone)
	check("kind is known: " .. tostring(npc.id), npc.kind == "hub" or npc.kind == "fisher", npc.kind)
	if npc.kind == "hub" then
		hub += 1
	else
		fisher += 1
	end
end
check("four live at the harbor", hub == 4, hub)
check("every outer water has a watcher", fisher == 4, fisher)

-- ============================== two climates ===============================
local LOW = {
	level = 1, coins = 0, streak = 0, quests = 0, questsDone = 0, claimable = 0,
	species = 0, zones = { shallows = true }, met = {},
}
local HIGH = {
	level = 30, coins = 60000, streak = 9, quests = 3, questsDone = 2, claimable = 2,
	species = 40, zones = { shallows = true, kelp = true, coral = true },
	met = { ["npc.harbormaster"] = true, ["npc.merchant"] = true, ["npc.questclerk"] = true, ["npc.sailor"] = true },
}

-- =============================== all voices ================================
for _, npc in NpcData.roster do
	for _, climate in { LOW, HIGH } do
		local tree = NpcData.voice(npc.id, climate)
		check("has a voice: " .. npc.id, type(tree) == "table" and tree.nodes ~= nil)
		if tree then
			check("start node exists: " .. npc.id, tree.nodes[tree.start] ~= nil, tree.start)
			local conditionals, onces = 0, 0
			for nodeId, node in tree.nodes do
				check("node speaks: " .. npc.id .. "." .. nodeId,
					type(node.text) == "string" and #node.text > 0)
				for _, choice in node.choices or {} do
					check("choice has words: " .. npc.id .. "." .. nodeId,
						type(choice.text) == "string" and #choice.text > 0)
					if choice.goto then
						check("goto resolves: " .. npc.id .. "." .. nodeId,
							tree.nodes[choice.goto] ~= nil, choice.goto)
					end
					if choice.action then
						check("action is registered: " .. npc.id .. "." .. nodeId,
							NpcData.actions[choice.action] == true or choice.action == "close", choice.action)
					end
					if choice.condition then
						check("condition is a function: " .. npc.id .. "." .. nodeId,
							type(choice.condition) == "function")
						local okLow = pcall(choice.condition, LOW)
						local okHigh = pcall(choice.condition, HIGH)
						check("condition survives both climates: " .. npc.id .. "." .. nodeId,
							okLow and okHigh)
						conditionals += 1
					end
					if choice.once then
						onces += 1
					end
				end
			end
			check("has a conditional line: " .. npc.id, conditionals >= 1, conditionals)
			check("has a once line: " .. npc.id, onces >= 1, onces)
		end
	end
end

check("an unknown id has no voice", NpcData.voice("nobody", LOW) == nil)

-- ============================== interpolation ==============================
local lowGreet = NpcData.voice("harbormaster", LOW).nodes.greet.text
local highGreet = NpcData.voice("harbormaster", HIGH).nodes.greet.text
check("the harbormaster remembers returning captains", lowGreet ~= highGreet, lowGreet)

local lowShop = NpcData.voice("merchant", LOW).nodes.greet.text
local highShop = NpcData.voice("merchant", HIGH).nodes.greet.text
check("the merchant prices the purse", lowShop ~= highShop, lowShop)

local clerkGreet = NpcData.voice("questclerk", HIGH).nodes.greet.text
check("the clerk counts ready claims", string.find(clerkGreet, "2", 1, true) ~= nil, clerkGreet)

-- ================================= verdict =================================
local status = if #failures == 0 then "PASS" else "FAIL"
print("TIDEBOUND_NPC " .. status .. " checks=" .. tostring(checks) .. " failures=" .. tostring(#failures))
for _, failure in failures do
	print("  FAIL " .. failure)
end
if #failures > 0 then
	error("npc voice validation failed")
end
"""


class TestNpcDialogue(unittest.TestCase):
    def test_roster_and_every_voice(self) -> None:
        out = run_or_raise(ROOT, libraries=[SHARED], body=BODY, timeout=60.0).stdout
        assert "TIDEBOUND_NPC PASS" in out, out


if __name__ == "__main__":
    unittest.main()
