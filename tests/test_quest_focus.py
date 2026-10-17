"""QuestFocus ranks the day's errands the way the tracker advertises.

The tracker shows one quest and one beam. The ranking rule -- nearest to
complete, then richest reward, deepest owned water for quests that name no
water -- is small enough that it will be rewritten someday by someone who
believes they remember it. This is the remembering.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
SHARED = ROOT / "games/tidebound/src/shared"

BODY = """
local QuestFocus = Require("QuestFocus")

local checks = 0
local failures = {}
local function check(name, ok, detail)
	checks += 1
	if not ok then
		table.insert(failures, name .. (detail ~= nil and (": " .. tostring(detail)) or ""))
	end
end

local function quest(id, kind, progress, target, reward, extra)
	local q = {
		id = id, kind = kind, label = kind .. " " .. id,
		progress = progress, target = target, rewardCoins = reward, claimed = false,
	}
	for key, value in extra or {} do
		q[key] = value
	end
	return q
end

-- ============================== the ranking ================================
local focus = QuestFocus.pick({
	quest("quarter", "zone", 1, 4, 9999),
	quest("nearly", "sell", 800, 1000, 10),
})
check("nearest to done wins even against a richer one", focus ~= nil and focus.id == "nearly",
	focus and focus.id)
check("the fraction is the fraction", focus ~= nil and math.abs(focus.fraction - 0.8) < 0.001)

focus = QuestFocus.pick({
	quest("rich-partial", "zone", 3, 4, 9999),
	quest("finished", "big", 1, 1, 5),
})
check("a finished errand outranks a rich unfinished one", focus ~= nil and focus.id == "finished",
	focus and focus.id)
check("done reads as done", focus ~= nil and focus.done == true)

focus = QuestFocus.pick({
	quest("poor", "zone", 1, 2, 100),
	quest("rich", "zone", 1, 2, 9000),
})
check("ties pay the richer reward", focus ~= nil and focus.id == "rich", focus and focus.id)

local claimed = quest("claimed", "zone", 2, 2, 100)
claimed.claimed = true
focus = QuestFocus.pick({ claimed, quest("open", "zone", 0, 5, 50) })
check("claimed errands leave the tracker", focus ~= nil and focus.id == "open", focus and focus.id)

check("all claimed means nothing", QuestFocus.pick({ claimed }) == nil)
check("an empty ledger means nothing", QuestFocus.pick({}) == nil)
check("a missing ledger means nothing", QuestFocus.pick(nil) == nil)

-- ============================== the target zone ============================
focus = QuestFocus.pick({ quest("anywhere", "rarity", 0, 3, 100) }, nil, { "shallows", "kelp", "coral" })
check("a quest with no water hunts the deepest you own",
	focus ~= nil and focus.zoneId == "coral", focus and focus.zoneId)

focus = QuestFocus.pick({ quest("kelpish", "zone", 0, 4, 100, { zoneId = "kelp" }) }, nil, { "shallows", "kelp" })
check("a zone quest keeps its own water", focus ~= nil and focus.zoneId == "kelp", focus and focus.zoneId)

focus = QuestFocus.pick({ quest("stored", "zone", 0, 4, 100) }, { stored = 4 })
check("livelier numbers override the stored ones", focus ~= nil and focus.done == true)

-- ================================ the line =================================
local function lineOf(kind, label, progress, target, done)
	return QuestFocus.line({
		id = "x", kind = kind, label = label, progress = progress, target = target,
		fraction = progress / target, done = done, zoneId = "shallows", rewardCoins = 1,
	})
end

local doneLine = lineOf("sell", "Sell $900 in catches", 900, 900, true)
check("a finished errand says where to claim",
	doneLine ~= nil and string.find(doneLine, "board", 1, true) ~= nil, doneLine)

local openLine = lineOf("zone", "Catch 4 fish", 2, 4, false)
check("an open errand counts", openLine ~= nil and string.find(openLine, "2/4", 1, true) ~= nil, openLine)

local sellLine = lineOf("sell", "Sell $900", 450, 900, false)
check("a sale reads in coins", sellLine ~= nil and string.find(sellLine, "$450", 1, true) ~= nil, sellLine)

check("no focus, no line", QuestFocus.line(nil) == nil)

-- ================================= verdict =================================
local status = if #failures == 0 then "PASS" else "FAIL"
print("TIDEBOUND_QUESTFOCUS " .. status .. " checks=" .. tostring(checks) .. " failures=" .. tostring(#failures))
for _, failure in failures do
	print("  FAIL " .. failure)
end
if #failures > 0 then
	error("quest focus validation failed")
end
"""


class TestQuestFocus(unittest.TestCase):
    def test_pick_rank_line(self) -> None:
        out = run_or_raise(ROOT, libraries=[SHARED], body=BODY, timeout=60.0).stdout
        assert "TIDEBOUND_QUESTFOCUS PASS" in out, out


if __name__ == "__main__":
    unittest.main()
