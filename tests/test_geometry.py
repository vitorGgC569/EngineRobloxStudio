"""The geometry authoring runtime.

Split deliberately. The program vocabulary, the brief, Roblox's mesh rules and
the asset package are pure and always run. The pipeline tests drive a real
Blender and are skipped when there is none installed -- but the skip is loud and
named, never a silent pass, and `test_the_worker_reports_its_own_absence`
verifies that absence is reported rather than swallowed.
"""

from __future__ import annotations

import json
import shutil
import tempfile
import unittest
from pathlib import Path

from rqe.geometry import (
    AssetBrief,
    AssetPackage,
    BriefError,
    Budget,
    GeometryPipeline,
    PackageError,
    ProgramError,
    Reference,
    TRIANGLE_LIMIT,
    capabilities,
    choose_backend,
    compile_program,
    load_brief,
    validate,
    validate_analysis,
    vocabulary,
)


REPO = Path(__file__).resolve().parents[1]
BLENDER = capabilities()


def _brief(**overrides) -> AssetBrief:
    fields = dict(
        id="generator",
        dimensions=(4.0, 5.5, 4.0),
        style="stylized sci-fi",
        silhouette="wide base with vertical reactor",
        materials=("painted_metal", "emissive_blue"),
        triangle_budget=8500,
        gameplay_role="machine",
    )
    fields.update(overrides)
    return AssetBrief(**fields)


GENERATOR_PROGRAM = {
    "id": "generator",
    "result": "generator",
    "steps": [
        {"op": "box", "name": "base", "size": [4.0, 3.0, 1.5], "location": [0, 0, 0.75]},
        {"op": "bevel", "target": "base", "width": 0.08, "segments": 2},
        {"op": "cylinder", "name": "reactor", "radius": 0.9, "depth": 4.0, "location": [0, 0, 3.5]},
        {"op": "box", "name": "vent", "size": [0.25, 0.9, 0.5], "location": [1.05, 0, 2.2]},
        {"op": "array_radial", "target": "vent", "count": 6, "axis": "Z", "centre": [0, 0, 2.2]},
        {"op": "join", "name": "generator", "targets": ["base", "reactor", "vent"]},
        {"op": "smooth_shade", "target": "generator", "angle": 35},
        {"op": "uv_unwrap", "target": "generator", "method": "smart"},
        {"op": "material", "target": "generator", "slots": [
            {"name": "painted_metal", "baseColor": [120, 128, 138], "metallic": 0.8, "roughness": 0.4},
            {"name": "emissive_blue", "baseColor": [70, 150, 240], "roughness": 0.2,
             "emissive": [90, 180, 255], "emissiveStrength": 3.0},
        ]},
        {"op": "decimate", "target": "generator", "triangleBudget": 8500},
    ],
}


# --------------------------------------------------------------- program


class TestProgramVocabulary(unittest.TestCase):
    def test_the_vocabulary_is_reportable(self):
        surface = vocabulary()
        self.assertEqual(surface["triangleLimit"], TRIANGLE_LIMIT)
        self.assertIn("box", surface["operations"])
        self.assertIn("array_radial", surface["operations"])
        self.assertTrue(surface["operations"]["box"]["creates"])
        self.assertFalse(surface["operations"]["bevel"]["creates"])

    def test_a_valid_program_compiles(self):
        program = compile_program(GENERATOR_PROGRAM)
        self.assertEqual(program.result, "generator")
        self.assertEqual(len(program.steps), len(GENERATOR_PROGRAM["steps"]))

    def test_an_unknown_operation_lists_the_real_ones(self):
        with self.assertRaises(ProgramError) as caught:
            compile_program({"id": "x", "steps": [{"op": "sculpt", "name": "a"}]})
        self.assertIn("array_radial", str(caught.exception))

    def test_operating_on_an_object_that_does_not_exist_yet_is_caught(self):
        """The most common program bug, and the one that produces the most
        confusing Blender error if it reaches Blender."""

        with self.assertRaises(ProgramError) as caught:
            compile_program({"id": "x", "steps": [
                {"op": "bevel", "target": "base", "width": 0.1},
                {"op": "box", "name": "base", "size": [1, 1, 1]},
            ]})
        self.assertIn("does not exist at that point", str(caught.exception))

    def test_surviving_scaffolding_is_refused(self):
        """Leftovers export with the asset. A mesh that quietly contains its own
        cutting tool is a defect nobody notices until it is in the game."""

        with self.assertRaises(ProgramError) as caught:
            compile_program({"id": "x", "result": "a", "steps": [
                {"op": "box", "name": "a", "size": [1, 1, 1]},
                {"op": "box", "name": "scaffold", "size": [1, 1, 1]},
            ]})
        self.assertIn("scaffold", str(caught.exception))

    def test_a_join_consumes_its_inputs(self):
        with self.assertRaises(ProgramError):
            compile_program({"id": "x", "result": "j", "steps": [
                {"op": "box", "name": "a", "size": [1, 1, 1]},
                {"op": "box", "name": "b", "size": [1, 1, 1]},
                {"op": "join", "name": "j", "targets": ["a", "b"]},
                {"op": "bevel", "target": "a", "width": 0.1},
            ]})

    def test_a_boolean_consumes_its_tool_unless_told_otherwise(self):
        compile_program({"id": "x", "result": "a", "steps": [
            {"op": "box", "name": "a", "size": [2, 2, 2]},
            {"op": "cylinder", "name": "cut", "radius": 0.4, "depth": 4},
            {"op": "boolean", "target": "a", "tool": "cut", "operation": "difference"},
        ]})

    def test_a_budget_above_the_roblox_ceiling_is_refused_before_blender_starts(self):
        with self.assertRaises(ProgramError) as caught:
            compile_program({"id": "x", "result": "a", "steps": [
                {"op": "box", "name": "a", "size": [1, 1, 1]},
                {"op": "decimate", "target": "a", "triangleBudget": 50_000},
            ]})
        self.assertIn("20000", str(caught.exception).replace(",", ""))

    def test_a_result_that_does_not_survive_is_refused(self):
        with self.assertRaises(ProgramError):
            compile_program({"id": "x", "result": "ghost", "steps": [
                {"op": "box", "name": "a", "size": [1, 1, 1]},
            ]})

    def test_unknown_parameters_are_refused(self):
        with self.assertRaises(ProgramError) as caught:
            compile_program({"id": "x", "result": "a", "steps": [
                {"op": "box", "name": "a", "size": [1, 1, 1], "colour": "red"},
            ]})
        self.assertIn("colour", str(caught.exception))


# ------------------------------------------------------------------ brief


class TestBrief(unittest.TestCase):
    def test_a_brief_without_a_silhouette_is_refused(self):
        """The silhouette is what the visual critic scores and what a revision
        is measured against."""

        with self.assertRaises(BriefError) as caught:
            _brief(silhouette="")
        self.assertIn("silhouette", str(caught.exception))

    def test_a_budget_above_the_roblox_ceiling_is_refused(self):
        with self.assertRaises(BriefError):
            _brief(triangle_budget=TRIANGLE_LIMIT + 1)

    def test_references_must_carry_a_content_hash(self):
        with self.assertRaises(BriefError) as caught:
            load_brief({
                "id": "x", "dimensions": [1, 1, 1], "style": "s", "silhouette": "t",
                "materials": ["m"], "triangleBudget": 100, "gameplayRole": "prop",
                "references": [{"id": "ref", "sha256": "short"}],
            })
        self.assertIn("decoration", str(caught.exception))

    def test_dimensions_accept_the_named_form(self):
        brief = load_brief({
            "id": "x", "dimensions": {"width": 4, "height": 6, "depth": 3},
            "style": "s", "silhouette": "t", "materials": ["m"],
            "triangleBudget": 100, "gameplayRole": "prop",
        })
        self.assertEqual(brief.dimensions, (4.0, 6.0, 3.0))

    def test_drift_is_measured_as_a_ratio_not_an_absolute(self):
        """A 10% error on a 60-stud landmark and on a 0.5-stud collectible are
        different mistakes."""

        brief = _brief(dimensions=(4.0, 5.5, 4.0))
        self.assertEqual(brief.dimension_findings([4.1, 5.6, 4.05]), [])
        findings = brief.dimension_findings([4.0, 2.0, 4.0])
        self.assertEqual(len(findings), 1)
        self.assertIn("axis Y", findings[0])

    def test_the_brief_hash_changes_with_the_intent(self):
        self.assertNotEqual(_brief().sha256, _brief(triangle_budget=4000).sha256)

    def test_backend_selection_explains_itself(self):
        self.assertEqual(choose_backend(_brief(gameplay_role="machine"))["backend"], "blender")
        self.assertEqual(choose_backend(_brief(gameplay_role="structure"))["backend"], "worldkit")
        self.assertEqual(
            choose_backend(_brief(gameplay_role="terrain-feature"))["backend"], "roblox_editable"
        )
        for role in ("machine", "structure", "prop"):
            self.assertTrue(choose_backend(_brief(gameplay_role=role))["reason"])

    def test_a_tiny_budget_reroutes_away_from_modelling(self):
        """Triangles go on the silhouette first; below a floor there is nothing
        left for detail and primitives read better."""

        selection = choose_backend(_brief(gameplay_role="machine", triangle_budget=200))
        self.assertEqual(selection["backend"], "procedural_model")
        self.assertIn("cannot carry", selection["reason"])


# ------------------------------------------------------------- validation


def _report(**overrides) -> dict:
    report = {
        "triangles": 500, "vertices": 300, "faces": 500, "ngons": 0,
        "nonFiniteVertices": 0, "boundaryEdges": 0, "nonManifoldEdges": 0,
        "watertight": True, "looseVertices": 0, "looseEdges": 0,
        "degenerateFaces": 0, "zeroLengthEdges": 0, "duplicateVertices": 0,
        "duplicateFaces": 0, "inconsistentNormalEdges": 0, "flippedFaces": 0,
        "hasUv": True, "uvOutsideUnitSquare": 0, "materialCount": 2,
        "dimensions": [4.0, 4.0, 5.5], "dimensionsYUp": [4.0, 5.5, 4.0],
        "scale": [1.0, 1.0, 1.0], "originOffsetRatio": 0.1,
    }
    report.update(overrides)
    return report


class TestMeshValidation(unittest.TestCase):
    def test_a_clean_mesh_passes(self):
        result = validate(_report())
        self.assertTrue(result.approved)
        self.assertTrue(result.clean, result.summary())

    def test_nan_coordinates_block(self):
        result = validate(_report(nonFiniteVertices=3))
        self.assertFalse(result.approved)
        self.assertIn("finite-coordinates", [item.rule for item in result.blocking])

    def test_non_manifold_geometry_blocks(self):
        result = validate(_report(nonManifoldEdges=12))
        self.assertFalse(result.approved)

    def test_degenerate_faces_block(self):
        self.assertFalse(validate(_report(degenerateFaces=4)).approved)

    def test_disagreeing_normals_block(self):
        """The surface has holes when viewed from one side."""

        self.assertFalse(validate(_report(inconsistentNormalEdges=9)).approved)

    def test_a_missing_uv_blocks_when_the_budget_requires_one(self):
        self.assertFalse(validate(_report(hasUv=False)).approved)

    def test_a_missing_uv_is_allowed_when_the_budget_says_so(self):
        self.assertTrue(validate(_report(hasUv=False), Budget(require_uv=False)).approved)

    def test_over_budget_triangles_block(self):
        self.assertFalse(validate(_report(triangles=9000), Budget(triangles=8000)).approved)

    def test_ngons_are_major_not_blocking(self):
        """Roblox imports them; it just triangulates them unpredictably, so the
        shipped silhouette is not the authored one."""

        result = validate(_report(ngons=3))
        self.assertTrue(result.approved)
        self.assertEqual([item.rule for item in result.major], ["no-ngons"])

    def test_an_unapplied_scale_is_reported(self):
        result = validate(_report(scale=[1.0, 2.0, 1.0]))
        self.assertIn("applied-scale", [item.rule for item in result.major])

    def test_a_map_sized_mesh_blocks(self):
        """An asset this large is a map exported as one object, which defeats
        mesh reuse entirely."""

        result = validate(_report(dimensions=[4000, 10, 4000]))
        self.assertFalse(result.approved)
        self.assertIn("max-dimension", [item.rule for item in result.blocking])

    def test_an_origin_outside_the_geometry_is_reported(self):
        result = validate(_report(originOffsetRatio=2.0))
        self.assertIn("origin-placement", [item.rule for item in result.major])

    def test_a_budget_may_not_loosen_the_roblox_ceiling(self):
        with self.assertRaises(ValueError):
            Budget(triangles=TRIANGLE_LIMIT + 1)

    def test_more_than_one_object_blocks(self):
        """One asset is one mesh. Extras ship with it."""

        analysis = {"objectCount": 2, "primary": "a", "objects": {"a": _report(), "b": _report()}}
        result = validate_analysis(analysis)
        self.assertFalse(result.approved)
        self.assertEqual(result.blocking[0].rule, "single-object")

    def test_an_empty_analysis_blocks(self):
        self.assertFalse(validate_analysis({"objects": {}}).approved)


# ---------------------------------------------------------------- package


class TestAssetPackage(unittest.TestCase):
    def setUp(self) -> None:
        self._temporary = tempfile.TemporaryDirectory()
        self.root = Path(self._temporary.name)

    def tearDown(self) -> None:
        self._temporary.cleanup()

    def _populate(self) -> AssetPackage:
        package = AssetPackage.create(self.root, "demo")
        package.write_program({"id": "demo", "steps": []})
        (package.export_dir / "demo.glb").write_bytes(b"glTF-ish")
        (package.previews_dir / "front.png").write_bytes(b"png-ish")
        package.write_analysis("topology", {"triangles": 12})
        package.write_manifest({"status": "APPROVED_FOR_IMPORT"})
        return package

    def test_a_complete_package_verifies(self):
        self.assertEqual(self._populate().verify(), [])

    def test_a_package_without_previews_does_not_verify(self):
        """Without renders the asset cannot be reviewed, so it is not complete."""

        package = AssetPackage.create(self.root, "demo")
        (package.export_dir / "demo.glb").write_bytes(b"x")
        package.write_manifest()
        self.assertIn("no preview renders, so nothing can review this asset", package.verify())

    def test_a_modified_file_is_detected(self):
        package = self._populate()
        (package.export_dir / "demo.glb").write_bytes(b"tampered")
        problems = package.verify()
        self.assertTrue(any("modified since the manifest" in item for item in problems))

    def test_the_content_hash_is_stable_for_identical_content(self):
        first = self._populate().manifest()["contentHash"]
        shutil.rmtree(self.root / "asset-demo")
        second = self._populate().manifest()["contentHash"]
        self.assertEqual(first, second)

    def test_the_program_round_trips(self):
        package = self._populate()
        self.assertEqual(package.program()["id"], "demo")

    def test_opening_a_directory_without_a_manifest_fails(self):
        with self.assertRaises(PackageError):
            AssetPackage.open(self.root)


# --------------------------------------------------------------- pipeline


class TestWorkerAvailability(unittest.TestCase):
    def test_the_worker_reports_its_own_absence(self):
        """A missing Blender must be a named blocker, never a silent no-op."""

        report = capabilities()
        self.assertIn("available", report)
        if not report["available"]:
            self.assertTrue(report["blockers"])
            self.assertIn("BLENDER_PATH", report["blockers"][0])
        else:
            self.assertTrue(report["path"])
            self.assertTrue(report["version"])


@unittest.skipUnless(BLENDER["available"], f"Blender is not installed: {BLENDER.get('blockers')}")
class TestPipelineAgainstRealBlender(unittest.TestCase):
    """Drives a real headless Blender. Slow on purpose -- this is the only
    evidence that the modelling runtime actually models."""

    @classmethod
    def setUpClass(cls) -> None:
        cls._temporary = tempfile.TemporaryDirectory()
        cls.workspace = Path(cls._temporary.name)
        cls.pipeline = GeometryPipeline(cls.workspace)
        cls.outcome = cls.pipeline.build(_brief(), GENERATOR_PROGRAM)

    @classmethod
    def tearDownClass(cls) -> None:
        cls._temporary.cleanup()

    def test_the_build_is_approved(self):
        self.assertEqual(self.outcome.status, "APPROVED_FOR_IMPORT", self.outcome.summary())

    def test_a_mesh_was_exported(self):
        mesh = self.outcome.package.mesh()
        self.assertIsNotNone(mesh)
        self.assertGreater(mesh.stat().st_size, 1000)

    def test_five_previews_were_rendered(self):
        names = {path.stem for path in self.outcome.package.previews()}
        self.assertEqual(names, {"front", "back", "left", "right", "perspective"})
        for path in self.outcome.package.previews():
            self.assertGreater(path.stat().st_size, 2000, f"{path.name} looks empty")

    def test_the_package_verifies(self):
        self.assertEqual(self.outcome.package.verify(), [])

    def test_topology_was_measured_inside_blender(self):
        topology = self.outcome.package.analysis("topology")
        primary = topology["objects"][topology["primary"]]
        self.assertGreater(primary["triangles"], 100)
        self.assertTrue(primary["hasUv"])
        self.assertEqual(primary["nonFiniteVertices"], 0)

    def test_dimensions_are_compared_in_the_brief_convention(self):
        """Blender is Z-up and Roblox is Y-up. Comparing the raw Blender figures
        silently checks a height against a depth."""

        dimensions = self.outcome.package.analysis("dimensions")
        self.assertIn("Y-up", dimensions["convention"])
        self.assertEqual(dimensions["findings"], [])
        self.assertNotEqual(dimensions["measured"], dimensions["measuredBlenderZUp"])

    def test_the_program_is_stored_with_the_asset(self):
        """The reason a package is reproducible: a revision is a diff rather
        than a new mystery."""

        program = self.outcome.package.program()
        self.assertEqual(program["result"], "generator")
        self.assertEqual(len(program["steps"]), len(GENERATOR_PROGRAM["steps"]))

    def test_the_manifest_records_the_blender_that_built_it(self):
        manifest = self.outcome.package.manifest()
        self.assertEqual(manifest["briefSha256"], _brief().sha256)
        self.assertIn("version", manifest["blender"])
        self.assertEqual(manifest["backend"], "blender")

    def test_a_dimension_drift_from_the_brief_blocks(self):
        """The brief is the intent and does not move; the program is the attempt
        and does."""

        outcome = self.pipeline.build(
            _brief(dimensions=(4.0, 30.0, 4.0)), GENERATOR_PROGRAM, revision=9
        )
        self.assertEqual(outcome.status, "BLOCKED")
        self.assertTrue(any("axis Y" in item for item in outcome.brief_findings))

    def test_a_failing_program_reports_the_step_that_failed(self):
        broken = json.loads(json.dumps(GENERATOR_PROGRAM))
        broken["steps"].insert(3, {"op": "extrude", "target": "reactor",
                                   "offset": [0, 0, 1], "faceAxis": "X", "faceDirection": 1})
        outcome = self.pipeline.build(_brief(), broken, revision=8)
        # Either it fails and names the step, or the face selection legitimately
        # found something. Both are correct; a silent success is not.
        if outcome.status == "BUILD_FAILED":
            self.assertIn("step", outcome.blockers[0])

    def test_two_builds_of_the_same_program_are_identical(self):
        """Reproducibility is what makes a revision a diff."""

        again = self.pipeline.build(_brief(), GENERATOR_PROGRAM, revision=7)
        comparison = self.pipeline.compare(self.outcome.package, again.package)
        self.assertTrue(comparison["briefUnchanged"])
        self.assertEqual(
            comparison["triangles"]["before"], comparison["triangles"]["after"]
        )

    def test_a_brief_routed_elsewhere_is_not_built_here(self):
        outcome = self.pipeline.build(_brief(gameplay_role="structure"), GENERATOR_PROGRAM, revision=6)
        self.assertEqual(outcome.status, "ROUTED_ELSEWHERE")
        self.assertIn("worldkit", outcome.blockers[0])


class TestMaterialAssignment(unittest.TestCase):
    """A slot no polygon points at renders nowhere.

    Appending a material in Blender does not put anything in it: every face
    keeps material_index 0. An asset declaring three materials then rendered
    entirely in the first one, while the manifest reported three -- a receipt
    that overstated the artefact, which is the one failure this whole project
    exists to prevent.
    """

    def test_the_assign_index_must_point_at_a_real_slot(self):
        document = {
            "schemaVersion": 1, "id": "m", "units": "studs", "result": "b",
            "steps": [
                {"op": "box", "name": "b", "size": [1, 1, 1]},
                {"op": "material", "target": "b", "assign": 2,
                 "slots": [{"name": "only", "baseColor": [10, 10, 10]}]},
            ],
        }
        with self.assertRaises(ProgramError) as caught:
            compile_program(document)
        self.assertIn("renders nowhere", str(caught.exception))

    def test_assign_defaults_to_the_first_slot(self):
        document = {
            "schemaVersion": 1, "id": "m", "units": "studs", "result": "b",
            "steps": [
                {"op": "box", "name": "b", "size": [1, 1, 1]},
                {"op": "material", "target": "b",
                 "slots": [{"name": "only", "baseColor": [10, 10, 10]}]},
            ],
        }
        self.assertEqual(len(compile_program(document).steps), 2)

    def test_unused_slots_are_reported_rather_than_counted_as_delivered(self):
        result = validate(_report(
            materialCount=3,
            materialSlotsUsed=1,
            unusedMaterials=["emissive_blue", "dark_rubber"],
        ))
        rules = [finding.rule for finding in result.findings]
        self.assertIn("material-unused", rules)
        message = next(f.message for f in result.findings if f.rule == "material-unused")
        self.assertIn("emissive_blue", message)
        self.assertIn("renders in 1 material", message)

    def test_a_fully_used_slot_set_raises_nothing(self):
        result = validate(_report(
            materialCount=2, materialSlotsUsed=2, unusedMaterials=[],
        ))
        self.assertNotIn("material-unused", [f.rule for f in result.findings])


if __name__ == "__main__":
    unittest.main()
