"""Landmarks are placed by measurement, and the measurements are auditable.

`LandmarkService.plan` is pure: the world it describes comes from SeaPlan's
heightfield and one seeded stream, so the entire layout -- the harbor marks,
the five zone shrines, the campfire, the watchtower, the cave mouth, the
wreck, the sea arch, and the reef scatter -- can be rebuilt here with no
Studio and no place file.

These tests lock the invariants the layout was surveyed to hold: the same
world plans the same hash, land marks stand above the waterline on ground
that is not a cliff, hub furniture keeps its clearance, landmarks keep their
distance from each other and from the pier lanes boats use, and the whole
thing fits inside a sane instance and light budget. The clearance rectangles
below mirror WorldService.buildHub; if the hub moves, this file moves with
it on purpose.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
LIBS = [
    ROOT / "forge/luau/Forge",
    ROOT / "forge/luau/Forge/Core",
    ROOT / "forge/luau/Forge/World",
    ROOT / "games/tidebound/src/shared",
    ROOT / "games/tidebound/src/server/Lib",
    ROOT / "games/tidebound/src/server/Services",
]

PRELUDE = """
local Config = Require("Config")
local SeaPlan = Require("SeaPlan")
local World = Require("World")
local Rng = Require("Rng")
local LandmarkService = Require("LandmarkService")

local function freshField()
	return World.heightfield(SeaPlan.heightfieldConfig())
end

local function planWith(seed, field)
	Rng.seed(seed)
	return LandmarkService.plan({ field = field, streamFor = Rng.at })
end

local function itemsOf(plan, tag)
	local found = {}
	for _, item in plan.items do
		if item.tag == tag then
			table.insert(found, item)
		end
	end
	return found
end
"""


def _run(body: str) -> str:
    return run_or_raise(ROOT, libraries=LIBS, body=PRELUDE + body, timeout=180).stdout


class TestLandmarkPlacement(unittest.TestCase):
    def test_layout_is_deterministic(self) -> None:
        out = _run(
            """
            local field = freshField()
            local a = planWith(Config.seed, field)
            local b = planWith(Config.seed, field)
            assert(a.hash == b.hash,
                "the same seed and field must hash the same: " .. a.hash .. " vs " .. b.hash)
            assert(#a.items == #b.items, "the same seed must place the same items")
            for index = 1, #a.items do
                local x, y = a.items[index], b.items[index]
                assert(x.kind == y.kind and x.tag == y.tag,
                    "item " .. index .. " changed kind")
                assert(math.abs(x.at.X - y.at.X) < 1e-6
                    and math.abs(x.at.Y - y.at.Y) < 1e-6
                    and math.abs(x.at.Z - y.at.Z) < 1e-6,
                    "item " .. index .. " moved between identical plans")
                assert(math.abs(x.yaw - y.yaw) < 1e-6,
                    "item " .. index .. " turned between identical plans")
            end
            print("PASS determinism " .. a.hash)
            """
        )
        self.assertIn("PASS determinism", out)

    def test_sea_seed_moves_only_the_reef(self) -> None:
        out = _run(
            """
            local field = freshField()
            local a = planWith(Config.seed, field)
            local b = planWith(Config.seed + 977, field)
            assert(a.hash ~= b.hash, "a different sea seed must change the layout hash")

            local landA, landB = itemsOf(a, "land"), itemsOf(b, "land")
            assert(#landA == #landB, "land placement must not depend on the sea seed")
            for index = 1, #landA do
                assert(landA[index].kind == landB[index].kind,
                    "land item " .. index .. " changed kind with the seed")
                assert(math.abs(landA[index].at.X - landB[index].at.X) < 1e-6
                    and math.abs(landA[index].at.Z - landB[index].at.Z) < 1e-6,
                    "land item " .. index .. " moved when only the sea seed changed")
            end

            local reefA, reefB = itemsOf(a, "reef"), itemsOf(b, "reef")
            assert(#reefA > 0 and #reefB > 0, "both seeds must scatter reef props")
            local moved = 0
            for index = 1, math.min(#reefA, #reefB) do
                if math.abs(reefA[index].at.X - reefB[index].at.X) > 0.01 then
                    moved += 1
                end
            end
            assert(moved > 10,
                "the reef must actually move with the seed, only " .. moved .. " props did")
            print("PASS seed-variation reef-moved=" .. moved)
            """
        )
        self.assertIn("PASS seed-variation", out)

    def test_land_items_stand_above_the_waterline(self) -> None:
        out = _run(
            """
            local field = freshField()
            local plan = planWith(Config.seed, field)
            local land = itemsOf(plan, "land")
            assert(#land == 11, "expected 11 land landmarks, found " .. #land)
            for _, item in land do
                assert(item.at.Y >= Config.waterLevel + 1,
                    string.format("%s at (%.1f, %.1f) is only %.2f above the waterline",
                        item.kind, item.at.X, item.at.Z, item.at.Y - Config.waterLevel))
                local slope = field:slope(item.at.X, item.at.Z)
                assert(slope >= 0.4,
                    string.format("%s stands on a %.2f slope", item.kind, slope))
            end
            print("PASS land-above-waterline count=" .. #land)
            """
        )
        self.assertIn("PASS land-above-waterline", out)

    def test_hub_landmarks_keep_their_clearances(self) -> None:
        out = _run(
            """
            local field = freshField()
            local plan = planWith(Config.seed, field)
            local hub = SeaPlan.dockPoint(Config.zone("shallows"))

            -- Mirrors the padded furniture rectangles in LandmarkService,
            -- which mirror WorldService.buildHub.
            local RECTS = {
                { "stalls", 0, -34, 26, 7 },
                { "crates", 1, -39, 25, 10 },
                { "lamps", 0, -9, 28, 15 },
                { "mooringsWest", -34, 12, 6, 23 },
                { "mooringEast", 34, -6, 6, 6 },
                { "spawnPlaza", 0, -2, 12, 10 },
            }
            local function rectDistance(p, cx, cz, hx, hz)
                local dx = math.max(math.abs(p.X - cx) - hx, 0)
                local dz = math.max(math.abs(p.Y - cz) - hz, 0)
                return math.sqrt(dx * dx + dz * dz)
            end
            local function laneDistance(p)
                -- The pier lane: from the deck north to the tip.
                local a = Vector2.new(hub.X, hub.Y + 97)
                local b = Vector2.new(hub.X + 6, hub.Y + 181)
                local ab = b - a
                local t = ((p.X - a.X) * ab.X + (p.Y - a.Y) * ab.Y) / (ab.Magnitude * ab.Magnitude)
                t = math.max(0, math.min(1, t))
                local closest = Vector2.new(a.X + ab.X * t, a.Y + ab.Y * t)
                return (p - closest).Magnitude
            end

            local nearHarbor = {}
            for _, item in itemsOf(plan, "land") do
                local p = Vector2.new(item.at.X, item.at.Z)
                for _, r in RECTS do
                    local d = rectDistance(p, hub.X + r[2], hub.Y + r[3], r[4], r[5])
                    assert(d >= 24,
                        string.format("%s is %.1f from the %s", item.kind, d, r[1]))
                end
                local d = laneDistance(p)
                assert(d >= 24,
                    string.format("%s is %.1f from the pier lane", item.kind, d))
                if (p - hub).Magnitude <= 120 then
                    table.insert(nearHarbor, item.kind)
                end
            end

            assert(#nearHarbor == 3,
                "expected the lighthouse, the shack and the shrine at the harbor, found " .. #nearHarbor)
            local kinds = {}
            for _, kind in nearHarbor do
                kinds[kind] = true
            end
            assert(kinds.lighthouse and kinds.fishingShack and kinds.shrine,
                "the harbor trio must be the lighthouse, the shack and the shrine")
            print("PASS hub-clearances")
            """
        )
        self.assertIn("PASS hub-clearances", out)

    def test_landmarks_keep_their_spacing(self) -> None:
        out = _run(
            """
            local field = freshField()
            local plan = planWith(Config.seed, field)

            local land = itemsOf(plan, "land")
            for i = 1, #land do
                for j = i + 1, #land do
                    local a = Vector2.new(land[i].at.X, land[i].at.Z)
                    local b = Vector2.new(land[j].at.X, land[j].at.Z)
                    local d = (a - b).Magnitude
                    assert(d >= 40,
                        string.format("%s and %s are only %.1f apart", land[i].kind, land[j].kind, d))
                end
            end

            local byZone = {}
            for _, item in itemsOf(plan, "reef") do
                local list = byZone[item.zone]
                if not list then
                    list = {}
                    byZone[item.zone] = list
                end
                table.insert(list, item)
            end
            local zones = 0
            local props = 0
            for zone, list in byZone do
                zones += 1
                props += #list
                assert(#list >= 24, "reef zone " .. zone .. " has only " .. #list .. " props")
                for i = 1, #list do
                    for j = i + 1, #list do
                        local a = Vector2.new(list[i].at.X, list[i].at.Z)
                        local b = Vector2.new(list[j].at.X, list[j].at.Z)
                        local d = (a - b).Magnitude
                        assert(d >= 12,
                            string.format("two %s props in %s are only %.1f apart",
                                list[i].kind, zone, d))
                    end
                end
            end
            assert(zones == 2, "expected both reef zones scattered, found " .. zones)
            print("PASS spacing land=" .. #land .. " reef=" .. props)
            """
        )
        self.assertIn("PASS spacing", out)

    def test_pier_lanes_stay_sailable(self) -> None:
        out = _run(
            """
            local field = freshField()
            local plan = planWith(Config.seed, field)

            local docks = {}
            local seawards = {}
            for _, zone in Config.zones do
                local dock = SeaPlan.dockPoint(zone)
                docks[zone.id] = dock
                seawards[zone.id] = (zone.center - dock).Unit
            end
            local function laneDistance(p, a, seaward)
                local b = a + seaward * 150
                local ab = b - a
                local t = ((p.X - a.X) * ab.X + (p.Y - a.Y) * ab.Y) / (ab.Magnitude * ab.Magnitude)
                t = math.max(0, math.min(1, t))
                local closest = Vector2.new(a.X + ab.X * t, a.Y + ab.Y * t)
                return (p - closest).Magnitude
            end

            for _, item in itemsOf(plan, "reef") do
                local p = Vector2.new(item.at.X, item.at.Z)
                local d = laneDistance(p, docks[item.zone], seawards[item.zone])
                assert(d >= 14,
                    string.format("%s in %s is %.1f from the pier lane", item.kind, item.zone, d))
            end

            local arch = nil
            local wreck = nil
            local coralShrine = nil
            for _, item in plan.items do
                if item.kind == "seaArch" then
                    arch = item
                elseif item.kind == "shipwreck" then
                    wreck = item
                elseif item.kind == "shrine" and item.flavor == "coral" then
                    coralShrine = item
                end
            end
            assert(arch, "no sea arch in the plan")
            assert(wreck, "no shipwreck in the plan")
            assert(coralShrine, "no coral shrine in the plan")

            local archP = Vector2.new(arch.at.X, arch.at.Z)
            local hubLaneA = Vector2.new(docks.shallows.X, docks.shallows.Y + 97)
            local hubLaneB = Vector2.new(docks.shallows.X + 6, docks.shallows.Y + 181)
            local ab = hubLaneB - hubLaneA
            local t = ((archP.X - hubLaneA.X) * ab.X + (archP.Y - hubLaneA.Y) * ab.Y) / (ab.Magnitude * ab.Magnitude)
            t = math.max(0, math.min(1, t))
            local closest = Vector2.new(hubLaneA.X + ab.X * t, hubLaneA.Y + ab.Y * t)
            assert((archP - closest).Magnitude >= 30, "the sea arch blocks the hub lane")
            for _, item in itemsOf(plan, "land") do
                local d = (archP - Vector2.new(item.at.X, item.at.Z)).Magnitude
                assert(d >= 60,
                    string.format("the sea arch is only %.1f from the %s", d, item.kind))
            end

            local wreckP = Vector2.new(wreck.at.X, wreck.at.Z)
            assert(laneDistance(wreckP, docks.coral, seawards.coral) >= 30,
                "the shipwreck blocks the coral pier lane")
            local shrineP = Vector2.new(coralShrine.at.X, coralShrine.at.Z)
            assert((wreckP - shrineP).Magnitude >= 45,
                "the shipwreck crowds the coral shrine")
            print("PASS lanes")
            """
        )
        self.assertIn("PASS lanes", out)

    def test_instance_and_light_budget(self) -> None:
        out = _run(
            """
            local LandmarkKit = Require("LandmarkKit")

            local field = freshField()
            local plan = planWith(Config.seed, field)

            local root = Instance.new("Model")
            root.Name = "Budget"
            for _, item in plan.items do
                local model = LandmarkKit.build({
                    kind = item.kind,
                    at = item.at,
                    yaw = item.yaw,
                    scale = item.scale,
                    flavor = item.flavor,
                }, root)
                assert(model.PrimaryPart, item.kind .. " came back without a PrimaryPart")
                for _, descendant in model:GetDescendants() do
                    if descendant:IsA("BasePart") then
                        assert(descendant.Anchored == true,
                            item.kind .. " has a part that is not anchored")
                        if item.tag == "reef" then
                            assert(descendant.CanCollide == false,
                                item.kind .. " reef props must not collide")
                        end
                    end
                end
            end

            local total, parts, lights, beams, scripts = 0, 0, 0, 0, 0
            for _, descendant in root:GetDescendants() do
                total += 1
                if descendant:IsA("BasePart") then
                    parts += 1
                end
                if descendant.ClassName == "PointLight" then
                    lights += 1
                elseif descendant.ClassName == "Beam" then
                    beams += 1
                elseif descendant.ClassName == "Script"
                    or descendant.ClassName == "LocalScript"
                    or descendant.ClassName == "ModuleScript" then
                    scripts += 1
                end
            end
            assert(total <= 2000, "landmark instance budget blown: " .. total)
            assert(lights >= 1 and lights <= 20, "light count out of range: " .. lights)
            assert(beams == 1, "expected exactly one lighthouse beam, found " .. beams)
            assert(scripts == 0, "landmarks must carry no scripts, found " .. scripts)
            print(string.format("PASS part-budget total=%d parts=%d lights=%d beams=%d",
                total, parts, lights, beams))
            """
        )
        self.assertIn("PASS part-budget", out)


if __name__ == "__main__":
    unittest.main()
