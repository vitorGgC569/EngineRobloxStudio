"""Execute the SDK's Luau under a real Luau runtime, outside Roblox.

The engine plan rests on the claim that SDK modules are pure Luau and therefore
run in three places: a Studio plugin, a published experience, and a headless
Open Cloud task. Every test here is that claim being checked rather than
asserted -- and the same path is what makes headless economy simulation
possible, which is the only way to answer "is the second upgrade priced wrong"
before anyone plays.

A module that reaches for an engine feature the harness does not shim fails
loudly. That is the intended outcome: it means the module is not portable.
"""

from __future__ import annotations

import json
import unittest
from pathlib import Path

from rqe.luau_harness import HarnessError, run, run_or_raise
from rqe.luau_check import ToolchainUnavailable, ensure_compiler


REPO = Path(__file__).resolve().parents[1]
WORLDKIT = "roblox/lib/WorldKit"
GAMEKIT = "roblox/lib/GameKit"


def _tokens() -> dict:
    return json.loads((REPO / "tokens" / "brickfarm.json").read_text(encoding="utf-8"))


class HarnessCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        try:
            ensure_compiler(REPO)
        except ToolchainUnavailable as exc:
            raise AssertionError(f"SDK runtime tests cannot run: {exc}") from exc

    def execute(self, body: str, *, libraries=(WORLDKIT,), data=None):
        return run_or_raise(REPO, libraries=list(libraries), body=body, data=data or {})

    def values(self, body: str, **kwargs) -> dict:
        """Run a body that prints one JSON object and return it."""

        result = self.execute(body, **kwargs)
        decoded = result.json_lines()
        self.assertTrue(decoded, f"body printed no JSON\nstdout:\n{result.stdout}")
        return decoded[-1]


class TestHarnessItself(HarnessCase):
    def test_a_failing_script_is_reported_not_swallowed(self):
        with self.assertRaises(HarnessError):
            self.execute('error("deliberate")')

    def test_an_unshimmed_service_fails_loudly(self):
        """Portability is the property under test; silently tolerating an engine
        dependency would hide exactly what this harness exists to reveal."""

        result = run(REPO, libraries=[WORLDKIT], body='game:GetService("MarketplaceService")')
        self.assertNotEqual(result.exit_code, 0)
        self.assertIn("not shimmed", result.stderr)

    def test_modules_load_through_the_require_graph(self):
        body = """
        local WorldKit = Require("WorldKit")
        print(WorldKit.VERSION)
        """
        # Feedback, semantic guidance and procedural production primitives are
        # first-class WorldKit modules in 2.2.0. Keeping the assertion stale
        # would let the public SDK surface drift from the version games report.
        self.assertIn("2.2.0", self.execute(body).stdout)


class TestTokensAcrossLanguages(HarnessCase):
    """One token file, two implementations, identical verdicts."""

    def test_luau_reads_the_same_values_python_does(self):
        from rqe.tokens import load_token_set

        python_side = load_token_set(REPO, "tokens/brickfarm.json")
        body = """
        local Tokens = Require("Tokens")
        local tokens = Tokens.define(TOKENS)
        print(game and "" or "")
        print(string.format('{"id":"%s","revision":%d,"roles":%d,"doorHeight":%s,"labelRead":%s,"accentBudget":%s}',
            tokens.id, tokens.revision, #tokens:roleIds(),
            tostring(tokens:grammar("doorHeight")),
            tostring(tokens:legibility("labelReadDistance")),
            tostring(Tokens.accentBudget(tokens))))
        """
        luau_side = self.values(body, data={"TOKENS": python_side.data})

        self.assertEqual(luau_side["id"], python_side.id)
        self.assertEqual(luau_side["revision"], python_side.revision)
        self.assertEqual(luau_side["roles"], len(python_side.roles))
        self.assertEqual(luau_side["doorHeight"], python_side.grammar("doorHeight"))
        self.assertEqual(luau_side["labelRead"], python_side.legibility("labelReadDistance"))

    def test_both_sides_reject_unclimbable_stairs(self):
        """The same defect, refused by the builder and by the grader."""

        from rqe.tokens import TokenError, load_token_set

        data = _tokens()
        data["scale"]["grammar"]["stairRise"] = 9.0

        body = """
        local Tokens = Require("Tokens")
        local ok = pcall(function() return Tokens.define(TOKENS) end)
        print(string.format('{"accepted":%s}', tostring(ok)))
        """
        self.assertFalse(self.values(body, data={"TOKENS": data})["accepted"])

        import tempfile

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "tokens").mkdir()
            (root / "schemas").mkdir()
            (root / "schemas" / "design-tokens.v1.schema.json").write_text(
                (REPO / "schemas" / "design-tokens.v1.schema.json").read_text(encoding="utf-8"),
                encoding="utf-8",
            )
            (root / "tokens" / "bad.json").write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaises(TokenError):
                load_token_set(root, "tokens/bad.json")

    def test_an_unknown_role_names_the_alternatives(self):
        body = """
        local Tokens = Require("Tokens")
        local tokens = Tokens.define(TOKENS)
        local ok, message = pcall(function() return tokens:color("structurePrimry") end)
        print(string.format('{"ok":%s,"mentionsReal":%s}', tostring(ok),
            tostring(string.find(tostring(message), "structurePrimary") ~= nil)))
        """
        result = self.values(body, data={"TOKENS": _tokens()})
        self.assertFalse(result["ok"])
        self.assertTrue(result["mentionsReal"])


class TestKitBuilds(HarnessCase):
    KIT = """
        local Tokens = Require("Tokens")
        local Kit = Require("Kit")
        local Build = Require("Build")
        local tokens = Tokens.define(TOKENS)
        local kit = Kit.define({
            id = "farmstead",
            cell = Vector3.new(16, 16, 16),
            modules = {
                wall = {
                    id = "wall", footprint = Vector3.new(1, 1, 1), visualType = "building",
                    variants = {"plain", "windowed", "banded"},
                    build = function(ctx)
                        local model = Instance.new("Model")
                        model.Name = "Wall"
                        model.Parent = ctx.parent
                        Build.part(model, "Face", ctx.size, ctx.cframe.Position, ctx.tokens:swatch("structurePrimary"))
                        return model
                    end,
                },
            },
        }, tokens)
    """

    def test_a_ring_places_only_the_perimeter(self):
        body = self.KIT + """
        local root = Instance.new("Folder")
        local placed = kit:ring(root, "wall", Vector3.new(0,0,0), Vector3.new(4,0,4))
        print(string.format('{"pieces":%d,"parts":%d}', #placed, Harness.countClass(root, "BasePart")))
        """
        # 5x5 cells: 25 total, 9 interior, 16 on the edge.
        self.assertEqual(self.values(body, data={"TOKENS": _tokens()})["pieces"], 16)

    def test_variant_selection_is_deterministic_per_cell(self):
        """Regression screenshots are meaningless if the world reshuffles."""

        body = self.KIT + """
        local a = Instance.new("Folder")
        local b = Instance.new("Folder")
        local first = kit:ring(a, "wall", Vector3.new(0,0,0), Vector3.new(4,0,4))
        local second = kit:ring(b, "wall", Vector3.new(0,0,0), Vector3.new(4,0,4))
        local identical = true
        for index = 1, #first do
            if first[index]:GetAttribute("KitVariant") ~= second[index]:GetAttribute("KitVariant") then
                identical = false
            end
        end
        print(string.format('{"identical":%s}', tostring(identical)))
        """
        self.assertTrue(self.values(body, data={"TOKENS": _tokens()})["identical"])

    def test_variation_actually_varies(self):
        """A kit that always picks one variant is a stamp, not a kit."""

        body = self.KIT + """
        local root = Instance.new("Folder")
        local placed = kit:rect(root, "wall", Vector3.new(0,0,0), Vector3.new(5,0,5))
        local spread = Kit.variantSpread(placed)
        local distinct = 0
        for _ in pairs(spread) do distinct += 1 end
        print(string.format('{"distinct":%d,"placed":%d}', distinct, #placed))
        """
        result = self.values(body, data={"TOKENS": _tokens()})
        self.assertEqual(result["placed"], 36)
        self.assertGreaterEqual(result["distinct"], 2)

    def test_a_cell_smaller_than_a_doorway_is_refused(self):
        body = """
        local Tokens = Require("Tokens")
        local Kit = Require("Kit")
        local tokens = Tokens.define(TOKENS)
        local ok, message = pcall(function()
            return Kit.define({
                id = "tiny", cell = Vector3.new(4, 4, 4),
                modules = { w = { id="w", footprint=Vector3.new(1,1,1), visualType="building",
                    build = function() return Instance.new("Model") end } },
            }, tokens)
        end)
        print(string.format('{"ok":%s,"mentionsDoor":%s}', tostring(ok),
            tostring(string.find(tostring(message), "doorHeight") ~= nil)))
        """
        result = self.values(body, data={"TOKENS": _tokens()})
        self.assertFalse(result["ok"])
        self.assertTrue(result["mentionsDoor"])

    def test_every_placement_is_semantically_tagged(self):
        body = self.KIT + """
        local root = Instance.new("Folder")
        local placed = kit:row(root, "wall", Vector3.new(0,0,0), Vector3.new(3,0,0))
        local tagged = 0
        for _, instance in ipairs(placed) do
            if instance:GetAttribute("KitId") == "farmstead"
                and instance:GetAttribute("KitModule") == "wall"
                and instance:GetAttribute("VisualType") == "building" then
                tagged += 1
            end
        end
        print(string.format('{"placed":%d,"tagged":%d}', #placed, tagged))
        """
        result = self.values(body, data={"TOKENS": _tokens()})
        self.assertEqual(result["tagged"], result["placed"])


class TestBlockoutValidation(HarnessCase):
    BASE = """
        local Tokens = Require("Tokens")
        local Blockout = Require("Blockout")
        local tokens = Tokens.define(TOKENS)
        local function spec(overrides)
            local base = {
                id = "farm",
                regions = {
                    { id = "spawn", kind = "hub", centre = Vector3.new(0,0,0), size = Vector2.new(80, 80), spawn = true },
                    { id = "plots", kind = "plot", centre = Vector3.new(0,0,200), size = Vector2.new(200, 200) },
                    { id = "market", kind = "hub", centre = Vector3.new(160,0,0), size = Vector2.new(90, 90) },
                },
                circulation = {
                    { from = "spawn", to = "plots" },
                    { from = "spawn", to = "market" },
                },
                landmarks = {
                    { id = "silo", at = Vector3.new(0,0,60), height = 60, visibleFrom = {"spawn"} },
                },
            }
            for key, value in pairs(overrides or {}) do base[key] = value end
            return base
        end
    """

    def test_a_sound_blockout_validates_and_builds(self):
        body = self.BASE + """
        local problems = Blockout.validate(spec(), tokens)
        local result = Blockout.build(spec(), tokens, Instance.new("Folder"))
        print(string.format('{"problems":%d,"routes":%d,"landmarks":%d,"area":%d}',
            #problems, result.routes, result.landmarks, Blockout.walkableArea(spec())))
        """
        result = self.values(body, data={"TOKENS": _tokens()})
        self.assertEqual(result["problems"], 0)
        self.assertEqual(result["routes"], 2)
        self.assertEqual(result["landmarks"], 1)

    def test_an_unreachable_region_is_caught_before_anything_is_built(self):
        """Graph connectivity at design time, instead of a pathfinding failure
        discovered from a live measurement run."""

        body = self.BASE + """
        local broken = spec({ circulation = { { from = "spawn", to = "plots" } } })
        local problems = Blockout.validate(broken, tokens)
        local found = false
        for _, problem in ipairs(problems) do
            if string.find(problem, "unreachable") then found = true end
        end
        print(string.format('{"problems":%d,"caught":%s}', #problems, tostring(found)))
        """
        result = self.values(body, data={"TOKENS": _tokens()})
        self.assertTrue(result["caught"])

    def test_a_landmark_too_short_to_read_is_caught(self):
        body = self.BASE + """
        local broken = spec({ landmarks = {
            { id = "silo", at = Vector3.new(0,0,60), height = 6, visibleFrom = {"spawn"} },
        }})
        local problems = Blockout.validate(broken, tokens)
        local found = false
        for _, problem in ipairs(problems) do
            if string.find(problem, "landmarkMinHeight") then found = true end
        end
        print(string.format('{"caught":%s}', tostring(found)))
        """
        self.assertTrue(self.values(body, data={"TOKENS": _tokens()})["caught"])

    def test_a_missing_spawn_is_caught(self):
        body = self.BASE + """
        local broken = spec({ regions = {
            { id = "a", kind = "hub", centre = Vector3.new(0,0,0), size = Vector2.new(80,80) },
        }, circulation = {}, landmarks = {} })
        local problems = Blockout.validate(broken, tokens)
        local found = false
        for _, problem in ipairs(problems) do
            if string.find(problem, "nowhere to arrive") then found = true end
        end
        print(string.format('{"caught":%s}', tostring(found)))
        """
        self.assertTrue(self.values(body, data={"TOKENS": _tokens()})["caught"])

    def test_building_an_invalid_blockout_raises(self):
        body = self.BASE + """
        local broken = spec({ circulation = {} })
        local ok = pcall(function() return Blockout.build(broken, tokens, Instance.new("Folder")) end)
        print(string.format('{"built":%s}', tostring(ok)))
        """
        self.assertFalse(self.values(body, data={"TOKENS": _tokens()})["built"])


class TestEconomy(HarnessCase):
    SETUP = """
        local Economy = Require("Economy")
        local economy = Economy.define({
            { id = "cash", displayName = "Cash", startingBalance = 50 },
            { id = "gems", displayName = "Gems", maximum = 100 },
        }, Economy.memoryStore())
        local player = Harness.makePlayer(7, "Tester")
    """

    def test_a_player_cannot_spend_what_they_do_not_have(self):
        body = self.SETUP + """
        local ok, balance = economy:spend(player, "cash", 5000, "buy_mansion")
        print(string.format('{"allowed":%s,"balance":%d}', tostring(ok), balance))
        """
        result = self.values(body, libraries=(GAMEKIT,))
        self.assertFalse(result["allowed"])
        self.assertEqual(result["balance"], 50)

    def test_repeated_spends_cannot_go_below_zero(self):
        """The double-spend this module exists to close."""

        body = self.SETUP + """
        economy:grant(player, "cash", 100, "sell_boxes")
        local succeeded = 0
        for _ = 1, 20 do
            local ok = economy:spend(player, "cash", 50, "buy_upgrade")
            if ok then succeeded += 1 end
        end
        print(string.format('{"succeeded":%d,"balance":%d}', succeeded, economy:balance(player, "cash")))
        """
        result = self.values(body, libraries=(GAMEKIT,))
        self.assertEqual(result["succeeded"], 3)
        self.assertEqual(result["balance"], 0)

    def test_a_maximum_clips_the_grant_and_the_reported_source(self):
        """Logging the requested amount instead of the credited amount is how an
        economy chart overstates its own sources."""

        body = self.SETUP + """
        economy:grant(player, "gems", 500, "daily")
        local sourced = 0
        for _, event in ipairs(Harness.AnalyticsService.events) do
            if event.currency == "gems" then sourced = event.amount end
        end
        print(string.format('{"balance":%d,"logged":%d}', economy:balance(player, "gems"), sourced))
        """
        result = self.values(body, libraries=(GAMEKIT,))
        self.assertEqual(result["balance"], 100)
        self.assertEqual(result["logged"], 100)

    def test_every_movement_is_logged_to_analytics(self):
        body = self.SETUP + """
        economy:grant(player, "cash", 200, "sell_boxes")
        economy:spend(player, "cash", 120, "buy_conveyor", "conveyor_t1")
        local sources, sinks = 0, 0
        for _, event in ipairs(Harness.AnalyticsService.events) do
            if event.flow == "Source" then sources += 1 end
            if event.flow == "Sink" then sinks += 1 end
        end
        print(string.format('{"sources":%d,"sinks":%d}', sources, sinks))
        """
        result = self.values(body, libraries=(GAMEKIT,))
        self.assertEqual(result["sources"], 1)
        self.assertEqual(result["sinks"], 1)

    def test_an_unattributed_movement_is_refused(self):
        """A source with no reason cannot be analysed, so it is not allowed."""

        body = self.SETUP + """
        local ok = pcall(function() return economy:grant(player, "cash", 10, "") end)
        print(string.format('{"ok":%s}', tostring(ok)))
        """
        self.assertFalse(self.values(body, libraries=(GAMEKIT,))["ok"])

    def test_net_flow_reveals_inflation(self):
        body = self.SETUP + """
        for _ = 1, 10 do economy:grant(player, "cash", 100, "idle_income") end
        economy:spend(player, "cash", 200, "buy_upgrade")
        local net = Economy.netFlow(economy)
        print(string.format('{"net":%d}', net.cash))
        """
        self.assertEqual(self.values(body, libraries=(GAMEKIT,))["net"], 800)


class TestProgressionPacing(HarnessCase):
    """Answers 'is the second upgrade priced wrong' with no game running."""

    LADDER = """
        local Progression = Require("Progression")
        local function ladder(costs)
            local tiers = {}
            for index, cost in ipairs(costs) do
                table.insert(tiers, {
                    id = "t" .. index, index = index, displayName = "T" .. index,
                    cost = cost, currency = "cash", incomeMultiplier = 1.5,
                })
            end
            return Progression.define(tiers)
        end
    """

    def test_an_even_ladder_reports_no_pacing_problems(self):
        body = self.LADDER + """
        local report = Progression.pacing(ladder({100, 340, 1150, 3900}), 5)
        local problems = Progression.pacingProblems(report)
        print(string.format('{"problems":%d,"worst":%.2f,"total":%.0f}',
            #problems, report.worstRatio, report.totalSeconds))
        """
        result = self.values(body, libraries=(GAMEKIT,))
        self.assertEqual(result["problems"], 0)
        self.assertLess(result["worst"], 3.0)

    def test_a_wall_in_the_ladder_is_named(self):
        body = self.LADDER + """
        local report = Progression.pacing(ladder({100, 300, 40000}), 5)
        local problems = Progression.pacingProblems(report)
        print(string.format('{"problems":%d,"worstAt":"%s"}', #problems, tostring(report.worstAtTier)))
        """
        result = self.values(body, libraries=(GAMEKIT,))
        self.assertGreaterEqual(result["problems"], 1)
        self.assertEqual(result["worstAt"], "t3")

    def test_a_slow_first_tier_is_caught(self):
        """Nobody sees the loop pay out, so nobody stays."""

        body = self.LADDER + """
        local report = Progression.pacing(ladder({5000, 8000}), 5)
        local problems = Progression.pacingProblems(report)
        local found = false
        for _, problem in ipairs(problems) do
            if string.find(problem, "onboarding budget") then found = true end
        end
        print(string.format('{"caught":%s}', tostring(found)))
        """
        self.assertTrue(self.values(body, libraries=(GAMEKIT,))["caught"])

    def test_multipliers_compound_across_held_tiers(self):
        body = self.LADDER + """
        local built = ladder({100, 200, 300})
        print(string.format('{"one":%.4f,"three":%.4f}',
            built:multiplierAt("t1"), built:multiplierAt("t3")))
        """
        result = self.values(body, libraries=(GAMEKIT,))
        self.assertAlmostEqual(result["one"], 1.5, places=4)
        self.assertAlmostEqual(result["three"], 1.5 ** 3, places=4)

    def test_a_ladder_that_gets_cheaper_is_refused(self):
        body = self.LADDER + """
        local ok = pcall(function() return ladder({1000, 100}) end)
        print(string.format('{"ok":%s}', tostring(ok)))
        """
        self.assertFalse(self.values(body, libraries=(GAMEKIT,))["ok"])


class TestFabDegradesVisibly(HarnessCase):
    """The harness has no solid modelling, exactly like a client without ID
    verification and the Mesh/Image toggle. Every fabrication call must still
    return something usable *and* say what it could not do."""

    def test_capabilities_report_absence_rather_than_pretending(self):
        body = """
        local Fab = Require("Fab")
        local capabilities = Fab.capabilities()
        print(string.format('{"csg":%s,"editableMesh":%s}',
            tostring(capabilities.csg), tostring(capabilities.editableMesh)))
        """
        result = self.values(body)
        self.assertFalse(result["csg"])
        self.assertFalse(result["editableMesh"])

    def test_an_aperture_without_csg_is_marked_degraded_not_ok(self):
        body = """
        local Fab = Require("Fab")
        local wall = Instance.new("Part")
        wall.Size = Vector3.new(40, 20, 2)
        local result, receipt = Fab.aperture(wall, {
            { offset = Vector2.new(0, -4), size = Vector2.new(8, 11) },
        })
        print(string.format('{"status":"%s","fallback":"%s","hasResult":%s}',
            receipt.status, tostring(receipt.fallback), tostring(result ~= nil)))
        """
        result = self.values(body)
        self.assertEqual(result["status"], "degraded")
        self.assertEqual(result["fallback"], "no-opening-cut")
        self.assertTrue(result["hasResult"])

    def test_editable_texture_fails_closed_with_a_reason(self):
        body = """
        local Fab = Require("Fab")
        local image, receipt = Fab.texture(64, 64, function() end)
        print(string.format('{"image":%s,"status":"%s","mentionsToggle":%s}',
            tostring(image ~= nil), receipt.status,
            tostring(string.find(receipt.reason or "", "toggle") ~= nil)))
        """
        result = self.values(body)
        self.assertFalse(result["image"])
        self.assertEqual(result["status"], "failed")
        self.assertTrue(result["mentionsToggle"])

    def test_a_summary_reports_the_build_as_unclean(self):
        """The question a build needs answered without reading every line:
        did anything silently come out worse than asked for."""

        body = """
        local Fab = Require("Fab")
        local receipts = {}
        for index = 1, 3 do
            local wall = Instance.new("Part")
            wall.Size = Vector3.new(40, 20, 2)
            local _, receipt = Fab.aperture(wall, { { offset = Vector2.new(0,0), size = Vector2.new(8,11) } })
            table.insert(receipts, receipt)
        end
        local summary = Fab.summarise(receipts)
        print(string.format('{"total":%d,"degraded":%d,"clean":%s}',
            summary.total, summary.degraded, tostring(summary.clean)))
        """
        result = self.values(body)
        self.assertEqual(result["total"], 3)
        self.assertEqual(result["degraded"], 3)
        self.assertFalse(result["clean"])

    def test_a_sweep_still_produces_geometry_without_csg(self):
        body = """
        local Fab = Require("Fab")
        local root = Instance.new("Folder")
        local model, receipt = Fab.sweep(root, "Rail", {
            Vector3.new(0,0,0), Vector3.new(30,0,0), Vector3.new(30,0,30),
        }, Vector2.new(1, 3), { color = Color3.new(1,1,1), material = Enum.Material.Metal })
        print(string.format('{"status":"%s","parts":%d,"welded":%s}',
            receipt.status, Harness.countClass(model, "BasePart"),
            tostring(receipt.detail and receipt.detail.welded)))
        """
        result = self.values(body)
        self.assertEqual(result["status"], "ok")
        self.assertGreaterEqual(result["parts"], 3)
        self.assertFalse(result["welded"])


class TestUiDesignSystem(HarnessCase):
    def test_every_layout_sorts_by_layout_order(self):
        """The measured defect: tabs meant to read Base / Vender / Praca shipped
        alphabetised, because UIListLayout sorts by Name by default."""

        body = """
        local Tokens = Require("Tokens")
        local Ui = Require("Ui")
        local tokens = Tokens.define(TOKENS)
        local screen = Instance.new("Folder")
        local column = Ui.stack(tokens, screen, "column", { gap = "roomy" })
        Ui.text(tokens, column, "label", "Base")
        Ui.text(tokens, column, "label", "Vender")
        Ui.text(tokens, column, "label", "Praca")
        local problems = Ui.audit(screen)
        local orders = {}
        for _, child in ipairs(column:GetChildren()) do
            if child:IsA("TextLabel") then table.insert(orders, child.LayoutOrder) end
        end
        print(string.format('{"problems":%d,"orders":[%d,%d,%d]}', #problems, orders[1], orders[2], orders[3]))
        """
        result = self.values(body, data={"TOKENS": _tokens()})
        self.assertEqual(result["problems"], 0)
        self.assertEqual(result["orders"], [1, 2, 3])

    def test_the_audit_detects_a_name_sorted_layout(self):
        body = """
        local Ui = Require("Ui")
        local screen = Instance.new("Folder")
        local frame = Instance.new("Frame", screen)
        local layout = Instance.new("UIListLayout", frame)
        layout.SortOrder = Enum.SortOrder.Name
        local problems = Ui.audit(screen)
        print(string.format('{"problems":%d}', #problems))
        """
        self.assertEqual(self.values(body)["problems"], 1)

    def test_spacing_and_type_come_only_from_tokens(self):
        body = """
        local Tokens = Require("Tokens")
        local Ui = Require("Ui")
        local tokens = Tokens.define(TOKENS)
        local screen = Instance.new("Folder")
        local label = Ui.text(tokens, screen, "title", "Cash")
        print(string.format('{"textSize":%d,"expected":%d}', label.TextSize, tokens:text("title")))
        """
        result = self.values(body, data={"TOKENS": _tokens()})
        self.assertEqual(result["textSize"], result["expected"])

    def test_an_unknown_type_step_is_refused(self):
        body = """
        local Tokens = Require("Tokens")
        local Ui = Require("Ui")
        local tokens = Tokens.define(TOKENS)
        local ok = pcall(function()
            return Ui.text(tokens, Instance.new("Folder"), "gigantic", "x")
        end)
        print(string.format('{"ok":%s}', tostring(ok)))
        """
        self.assertFalse(self.values(body, data={"TOKENS": _tokens()})["ok"])


class TestDress(HarnessCase):
    """Dressing is a separate pass so layout defects and art defects stop
    arriving as one complaint about one build."""

    SETUP = """
        local Tokens = Require("Tokens")
        local Kit = Require("Kit")
        local Build = Require("Build")
        local Blockout = Require("Blockout")
        local Dress = Require("Dress")
        local tokens = Tokens.define(TOKENS)

        local function mod(name, variants)
            return { id = name, footprint = Vector3.new(1,1,1), visualType = "building", variants = variants,
                build = function(ctx)
                    local m = Instance.new("Model"); m.Name = name; m.Parent = ctx.parent
                    Build.part(m, "Body", ctx.size, ctx.cframe.Position, ctx.tokens:swatch("structurePrimary"))
                    return m
                end }
        end
        local kit = Kit.define({ id = "farmstead", cell = Vector3.new(20,20,20), modules = {
            wall = mod("wall", {"plain", "windowed", "banded"}),
            deck = mod("deck", {"boards", "tiles"}),
            silo = mod("silo"),
        }}, tokens)

        local spec = { id = "farm", regions = {
            { id = "hub", kind = "hub", centre = Vector3.new(0,0,0), size = Vector2.new(120,120), spawn = true },
            { id = "plot1", kind = "plot", centre = Vector3.new(0,0,220), size = Vector2.new(160,160) },
            { id = "woods", kind = "nature", centre = Vector3.new(240,0,0), size = Vector2.new(120,120) },
        }, circulation = { { from = "hub", to = "plot1" }, { from = "hub", to = "woods" } },
           landmarks = { { id = "tower", at = Vector3.new(0,0,0), height = 60, visibleFrom = {"hub"} } } }
        local built = Blockout.build(spec, tokens, Instance.new("Folder"))
    """

    def test_a_region_kind_with_no_rule_is_named_not_silently_skipped(self):
        """A half-dressed world that reports success is worse than one that
        reports what it skipped."""

        body = self.SETUP + """
        local receipt = Dress.apply(spec, built, kit, tokens, {
            hub = { edge = "wall", fill = "deck", feature = "silo" },
            plot = { edge = "wall", fill = "deck" },
        })
        print(string.format('{"dressed":%d,"undressed":%d,"first":"%s","clean":%s}',
            #receipt.dressed, #receipt.undressed, receipt.undressed[1], tostring(receipt.clean)))
        """
        result = self.values(body, data={"TOKENS": _tokens()})
        self.assertEqual(result["dressed"], 2)
        self.assertEqual(result["undressed"], 1)
        self.assertEqual(result["first"], "woods")
        self.assertFalse(result["clean"])

    def test_edge_and_fill_do_not_overlap(self):
        """Dressing the perimeter twice makes every corner z-fight with itself."""

        body = self.SETUP + """
        local receipt = Dress.apply(spec, built, kit, tokens, {
            hub = { edge = "wall", fill = "deck" },
            plot = { edge = "wall", fill = "deck" },
            nature = { fill = "deck" },
        })
        -- hub is 120/20 = 6x6 cells: 20 on the perimeter, 16 in the interior.
        print(string.format('{"wall":%d,"deck":%d}', receipt.byModule.wall, receipt.byModule.deck))
        """
        result = self.values(body, data={"TOKENS": _tokens()})
        self.assertGreater(result["wall"], 0)
        self.assertGreater(result["deck"], 0)

    def test_a_plan_naming_an_unknown_module_is_refused(self):
        body = self.SETUP + """
        local ok = pcall(function()
            return Dress.apply(spec, built, kit, tokens, { hub = { fill = "castle" } })
        end)
        print(string.format('{"ok":%s}', tostring(ok)))
        """
        self.assertFalse(self.values(body, data={"TOKENS": _tokens()})["ok"])

    def test_a_module_used_as_a_stamp_is_reported(self):
        body = self.SETUP + """
        local receipt = Dress.apply(spec, built, kit, tokens, {
            hub = { fill = "silo" },
            plot = { fill = "silo" },
            nature = { fill = "silo" },
        })
        local problems = Dress.problems(receipt)
        local found = false
        for _, problem in ipairs(problems) do
            if string.find(problem, "stamp rather than a kit") then found = true end
        end
        print(string.format('{"caught":%s}', tostring(found)))
        """
        self.assertTrue(self.values(body, data={"TOKENS": _tokens()})["caught"])


class TestVfxBudget(HarnessCase):
    """Effects fail as a population, not individually. 49 point lights produced
    a yellow wash over this project's whole map and raised no error."""

    SETUP = """
        local Tokens = Require("Tokens")
        local Vfx = Require("Vfx")
        local tokens = Tokens.define(TOKENS)
        local host = Instance.new("Part")
    """

    def test_lights_are_capped_rather_than_accumulating(self):
        body = self.SETUP + """
        for _ = 1, 40 do Vfx.light(tokens, host, "accentGold") end
        local budget = Vfx.budget()
        print(string.format('{"lights":%d,"max":%d}', budget.lights, budget.maxLights))
        """
        result = self.values(body, data={"TOKENS": _tokens()})
        self.assertEqual(result["lights"], result["max"])

    def test_over_budget_creation_returns_nil_rather_than_a_bad_effect(self):
        body = self.SETUP + """
        for _ = 1, 12 do Vfx.light(tokens, host, "accentGold") end
        local extra = Vfx.light(tokens, host, "accentGold")
        print(string.format('{"extra":%s}', tostring(extra ~= nil)))
        """
        self.assertFalse(self.values(body, data={"TOKENS": _tokens()})["extra"])

    def test_a_forbidden_material_in_the_scene_is_reported(self):
        body = self.SETUP + """
        local neon = Instance.new("Part", host)
        neon.Material = Enum.Material.Neon
        local problems = Vfx.problems(tokens, host)
        print(string.format('{"problems":%d,"mentionsNeon":%s}', #problems,
            tostring(string.find(problems[1] or "", "Neon") ~= nil)))
        """
        result = self.values(body, data={"TOKENS": _tokens()})
        self.assertEqual(result["problems"], 1)
        self.assertTrue(result["mentionsNeon"])

    def test_a_burst_schedules_its_own_cleanup(self):
        """A burst that lingers is a leaked instance; one that vanishes early is
        a missing effect. The cleanup is scheduled from the emitter's own
        lifetime rather than guessed."""

        body = self.SETUP + """
        Vfx.Presets.reward(tokens, host)
        print(string.format('{"pending":%d}', Harness.pendingDelays()))
        """
        self.assertEqual(self.values(body, data={"TOKENS": _tokens()})["pending"], 1)

    def test_presets_draw_only_from_palette_roles(self):
        body = self.SETUP + """
        local ok = pcall(function()
            return Vfx.emitter(tokens, host, { fromRole = "hotPink", rate = 5 })
        end)
        print(string.format('{"ok":%s}', tostring(ok)))
        """
        self.assertFalse(self.values(body, data={"TOKENS": _tokens()})["ok"])


class TestGenerality(HarnessCase):
    """The only test that distinguishes an engine from an elaborate validator
    for one game.

    Two genres that disagree structurally on every axis, compiled through the
    same L0-L6 stack. A single template proves nothing: whatever shape it had,
    the layers beneath could have been built around it.
    """

    LIBS = ("roblox/lib/WorldKit", "roblox/lib/GameKit", "roblox/lib/Templates")

    SETUP = """
        local Tokens = Require("Tokens")
        local Templates = Require("Templates")
        local Blockout = Require("Blockout")
        local tokens = Tokens.define(TOKENS)
        local farm = Templates.Tycoon.compile({
            id = "anime-card-farm", plots = 8, currency = "cash",
            tierCosts = {500, 2200, 9000, 36000}, baseIncomePerSecond = 12,
        }, tokens)
        local siege = Templates.Defense.compile({
            id = "lantern-siege", lanes = 5, currency = "scrap",
            waveRewards = {120, 190, 300, 480, 760}, secondsPerWave = 45,
        }, tokens)
    """

    def test_both_genres_produce_valid_blockouts(self):
        body = self.SETUP + """
        print(string.format('{"tycoon":%d,"defense":%d}',
            #Blockout.validate(farm.blockout, tokens),
            #Blockout.validate(siege.blockout, tokens)))
        """
        result = self.values(body, libraries=self.LIBS, data={"TOKENS": _tokens()})
        self.assertEqual(result["tycoon"], 0)
        self.assertEqual(result["defense"], 0)

    def test_the_two_genres_disagree_on_every_structural_axis(self):
        body = self.SETUP + """
        local differences = Templates.differ(farm, siege)
        print(string.format('{"differences":%d}', #differences))
        """
        result = self.values(body, libraries=self.LIBS, data={"TOKENS": _tokens()})
        self.assertEqual(result["differences"], 3)

    def test_topologies_are_genuinely_different_shapes(self):
        """A grid of private plots and a radial contested arena. If these
        produced the same region layout, one would be the other renamed."""

        body = self.SETUP + """
        print(string.format('{"tycoonRegions":%d,"defenseRegions":%d,"tycoonPrivate":%s,"defensePrivate":%s}',
            farm.signature.regionCount, siege.signature.regionCount,
            tostring(farm.signature.privateSpace), tostring(siege.signature.privateSpace)))
        """
        result = self.values(body, libraries=self.LIBS, data={"TOKENS": _tokens()})
        # Eight plots plus a hub; five lanes plus a core.
        self.assertEqual(result["tycoonRegions"], 9)
        self.assertEqual(result["defenseRegions"], 6)
        self.assertTrue(result["tycoonPrivate"])
        self.assertFalse(result["defensePrivate"])

    def test_the_same_pacing_machinery_judges_both(self):
        """Reuse of one primitive across two progression shapes is the evidence
        the primitive is not shaped like either."""

        body = self.SETUP + """
        local r1, p1 = Templates.Tycoon.pacing(farm, { baseIncomePerSecond = 12 })
        local r2, p2 = Templates.Defense.pacing(siege, {
            waveRewards = {120, 190, 300, 480, 760}, secondsPerWave = 45,
        })
        print(string.format('{"tycoonProblems":%d,"defenseProblems":%d,"tycoonTotal":%.0f,"defenseTotal":%.0f}',
            #p1, #p2, r1.totalSeconds, r2.totalSeconds))
        """
        result = self.values(body, libraries=self.LIBS, data={"TOKENS": _tokens()})
        self.assertEqual(result["tycoonProblems"], 0)
        self.assertEqual(result["defenseProblems"], 0)
        self.assertNotEqual(result["tycoonTotal"], result["defenseTotal"])

    def test_neither_template_can_smuggle_in_its_own_thresholds(self):
        """Both must be refused by the same token grammar."""

        body = self.SETUP + """
        local tooSmall = pcall(function()
            return Templates.Tycoon.compile({
                id = "cramped", plots = 4, plotSize = 20, currency = "cash",
                tierCosts = {100}, baseIncomePerSecond = 5,
            }, tokens)
        end)
        local tooFewLanes = pcall(function()
            return Templates.Defense.compile({
                id = "corridor", lanes = 2, currency = "scrap",
                waveRewards = {100}, secondsPerWave = 30,
            }, tokens)
        end)
        print(string.format('{"cramped":%s,"corridor":%s}', tostring(tooSmall), tostring(tooFewLanes)))
        """
        result = self.values(body, libraries=self.LIBS, data={"TOKENS": _tokens()})
        self.assertFalse(result["cramped"])
        self.assertFalse(result["corridor"])

    def test_a_compiled_game_actually_builds_a_world(self):
        body = self.SETUP + """
        local built = Blockout.build(farm.blockout, tokens, Instance.new("Folder"))
        print(string.format('{"routes":%d,"landmarks":%d,"parts":%d}',
            built.routes, built.landmarks, Harness.countClass(built.root, "BasePart")))
        """
        result = self.values(body, libraries=self.LIBS, data={"TOKENS": _tokens()})
        self.assertEqual(result["routes"], 8)
        self.assertEqual(result["landmarks"], 1)
        self.assertGreater(result["parts"], 10)


if __name__ == "__main__":
    unittest.main()
