"""The primitive surface, checked rather than claimed.

"113 primitives are implemented" was a sentence in a document until this file
existed. A prose claim about a surface this size drifts the moment anything is
renamed, and it drifts silently -- nothing fails, the table just stops being
true. The platform doc had already listed six primitives as missing that were
shipped, and reported a family as complete while pointing at a module the
server assembly never loaded.

These tests make the drift loud. The one that matters is
`test_every_binding_resolves`: it looks up every primitive's target in the live
MCP server and the live bridge registry, so a renamed tool or a module dropped
from the assembly fails here instead of in a status table somebody believes.
"""

from __future__ import annotations

import unittest

from rqe.primitives import (
    FAMILY_SIZES,
    METAWORLDMODEL,
    PRIMITIVES,
    TOTAL,
    Primitive,
    by_family,
    coverage,
    metaworldmodel_coverage,
    resolve,
    unavailable,
)


class TestTheSurfaceIsWhatItSaysItIs(unittest.TestCase):
    def test_there_are_exactly_one_hundred_and_thirteen(self):
        self.assertEqual(TOTAL, 113)
        self.assertEqual(len(PRIMITIVES), 113)

    def test_no_primitive_is_listed_twice(self):
        """A duplicate inflates the count without adding capability, which is
        the easiest way for this file to start lying."""

        names = [p.name for p in PRIMITIVES]
        duplicates = {name for name in names if names.count(name) > 1}
        self.assertEqual(duplicates, set())

    def test_each_family_holds_the_number_it_declares(self):
        grouped = by_family()
        for family, declared in FAMILY_SIZES.items():
            self.assertEqual(len(grouped[family]), declared, family)

    def test_every_primitive_belongs_to_a_declared_family(self):
        for primitive in PRIMITIVES:
            self.assertIn(primitive.family, FAMILY_SIZES, primitive.name)


class TestBindings(unittest.TestCase):
    def test_every_binding_resolves(self):
        """The test this module exists for.

        Every implemented primitive names a tool on the MCP server or a command
        in the bridge registry. Resolving them against the live registries is
        what stops "implemented" from meaning "written down"."""

        missing = resolve()
        self.assertEqual(
            missing, {},
            "primitives claim implementations that do not exist: " + repr(missing),
        )

    def test_an_implemented_primitive_cannot_omit_its_target(self):
        with self.assertRaises(ValueError):
            Primitive(name="x.y", family="World", surface="BRIDGE")

    def test_an_unavailable_primitive_must_carry_a_reason(self):
        """A gap recorded as a shrug is indistinguishable from an oversight."""

        with self.assertRaises(ValueError):
            Primitive(name="x.y", family="UI", surface="NONE")

    def test_nothing_is_left_unavailable(self):
        """`ui.click` was the last one, and it closed by delegation rather than
        by a stub: VirtualInputManager is refused to plugins and LocalScripts
        alike, so the engine cannot synthesise input and asks Roblox's own MCP
        server to. If a primitive ever goes unavailable again it must arrive
        here with its reason."""

        self.assertEqual([p.name for p in unavailable()], [])

    def test_the_one_primitive_we_cannot_perform_ourselves_says_so(self):
        """A delegated primitive that read as native would hide the one thing a
        caller needs to know: it requires a peer, and without one nothing is
        pressed."""

        click = next(p for p in PRIMITIVES if p.name == "ui.click")
        self.assertEqual(click.target, "ui_click")
        self.assertIn("VirtualInputManager", click.note)
        self.assertIn("delegated", click.note)

    def test_every_mcp_target_is_a_registered_tool_with_a_schema(self):
        """A registered name with no input schema cannot be called by an agent,
        which makes it reachable in a count and unreachable in practice."""

        from rqe.mcp.tools import build_server

        server = build_server(".", include_bridge=True)
        for primitive in PRIMITIVES:
            if primitive.surface != "MCP":
                continue
            tool = server.tools[primitive.target]
            self.assertTrue(tool.description.strip(), primitive.name)
            self.assertEqual(tool.input_schema.get("type"), "object", primitive.name)

    def test_every_bridge_target_is_dispatchable(self):
        from rqe.hub.commands import load_default_registry

        registry = load_default_registry(verify_dispatcher=False)
        methods = set(registry.methods())
        for primitive in PRIMITIVES:
            if primitive.surface == "BRIDGE":
                self.assertIn(primitive.target, methods, primitive.name)


class TestCoverageReport(unittest.TestCase):
    def test_coverage_counts_rather_than_asserts(self):
        report = coverage()
        self.assertEqual(report["total"], 113)
        self.assertEqual(report["available"], 113)
        self.assertEqual(report["unavailable"], [])

    def test_the_surfaces_sum_to_the_whole(self):
        report = coverage()
        self.assertEqual(sum(report["bySurface"].values()), 113)

    def test_every_family_reports_listed_against_declared(self):
        """Reporting availability without the denominator is how a family that
        lost a primitive still reads as complete."""

        for family, counts in coverage()["byFamily"].items():
            self.assertEqual(counts["listed"], counts["declared"], family)
            self.assertLessEqual(counts["available"], counts["listed"], family)


class TestMetaWorldModelSurface(unittest.TestCase):
    """The authoring surface the MetaWorldModel document specifies.

    Kept separate from the 113 because they answer different questions -- one is
    how an agent drives the engine, the other is how it makes something -- and
    averaging them would let a complete control surface hide an incomplete
    authoring one.
    """

    def test_the_documented_surface_is_listed_in_full(self):
        self.assertEqual(len(METAWORLDMODEL), 35)

    def test_every_claimed_binding_resolves(self):
        missing = resolve(METAWORLDMODEL)
        self.assertEqual(missing, {}, repr(missing))

    def test_the_gaps_are_counted_rather_than_omitted(self):
        """Deleting the rows would make the surface read as complete. The
        denominator is the honest part."""

        report = metaworldmodel_coverage()
        self.assertEqual(report["total"], 35)
        self.assertEqual(report["available"], 35)
        self.assertEqual(report["gaps"], [])

    def test_every_gap_says_what_is_missing_and_what_exists(self):
        """Vacuous while nothing is missing, and kept for when something is:
        deleting it would mean the next gap arrives unexplained."""

        for gap in metaworldmodel_coverage()["gaps"]:
            self.assertTrue(gap["reason"].strip(), gap["name"])

    def test_the_families_the_document_leads_with_are_complete(self):
        """Geometry, material and visual QA are the modelling loop. If those are
        not whole, the document's central claim is not implemented."""

        groups = metaworldmodel_coverage()["byGroup"]
        for group in ("mesh", "material", "visual", "asset"):
            self.assertEqual(groups[group]["available"], groups[group]["total"], group)

    def test_every_group_is_whole(self):
        for group, counts in metaworldmodel_coverage()["byGroup"].items():
            self.assertEqual(counts["available"], counts["total"], group)


if __name__ == "__main__":
    unittest.main()
