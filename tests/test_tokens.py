"""L0 token tests.

The load path is only worth having if it rejects. Each negative case here is a
mistake that would otherwise reach a screenshot: unclimbable stairs, an accent
that is no longer an accent, a palette flat enough to have no silhouette, or a
token set that quietly learned its numbers from the build it governs.
"""

from __future__ import annotations

import copy
import json
import unittest
from pathlib import Path

from rqe.tokens import (
    TokenError,
    derive_visual_thresholds,
    calibration_receipt,
    hue_family,
    load_token_set,
    relative_luminance,
)


REPO = Path(__file__).resolve().parents[1]
TOKEN_RELATIVE = "tokens/brickfarm.json"


def _shipped() -> dict:
    return json.loads((REPO / TOKEN_RELATIVE).read_text(encoding="utf-8"))


class TokenFixture(unittest.TestCase):
    """Write a mutated token set into a temporary tree and load it."""

    def setUp(self) -> None:
        import tempfile

        self._temporary = tempfile.TemporaryDirectory()
        self.root = Path(self._temporary.name)
        (self.root / "tokens").mkdir()
        (self.root / "schemas").mkdir()
        (self.root / "schemas" / "design-tokens.v1.schema.json").write_text(
            (REPO / "schemas" / "design-tokens.v1.schema.json").read_text(encoding="utf-8"),
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self._temporary.cleanup()

    def write(self, data: dict) -> str:
        path = self.root / "tokens" / "candidate.json"
        path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        return "tokens/candidate.json"

    def load(self, data: dict):
        return load_token_set(self.root, self.write(data))

    def assert_rejected(self, data: dict, fragment: str) -> None:
        with self.assertRaises(TokenError) as caught:
            self.load(data)
        self.assertIn(fragment, str(caught.exception))


class TestShippedTokenSet(unittest.TestCase):
    def test_the_repository_token_set_loads(self):
        tokens = load_token_set(REPO, TOKEN_RELATIVE)
        self.assertEqual(tokens.id, "brickfarm")
        self.assertGreaterEqual(len(tokens.roles), 12)
        self.assertEqual(len(tokens.sha256), 64)

    def test_every_role_is_reachable_and_unknown_roles_raise(self):
        tokens = load_token_set(REPO, TOKEN_RELATIVE)
        for role_id in tokens.roles:
            self.assertEqual(tokens.role(role_id).id, role_id)
        with self.assertRaises(TokenError) as caught:
            tokens.role("structurePrimry")
        # The message must list the alternatives; a bare KeyError sends the
        # author back to the file to guess.
        self.assertIn("structurePrimary", str(caught.exception))

    def test_accents_stay_within_the_declared_budget(self):
        tokens = load_token_set(REPO, TOKEN_RELATIVE)
        declared = sum(
            role.maximum_surface_coverage or 0.0 for role in tokens.roles_by_tier("accent")
        )
        self.assertLessEqual(declared, tokens.harmony["accentTotalMaxCoverage"] + 1e-9)

    def test_provenance_cites_hashed_external_references(self):
        tokens = load_token_set(REPO, TOKEN_RELATIVE)
        self.assertEqual(tokens.provenance["derivation"], "external-reference")
        hashes = tokens.reference_hashes()
        self.assertGreaterEqual(len(hashes), 5)
        for digest in hashes:
            self.assertRegex(digest, r"^[0-9a-f]{64}$")

    def test_referenced_frames_exist_on_disk_with_the_declared_hashes(self):
        """A citation nobody can check is decoration."""

        import hashlib

        tokens = load_token_set(REPO, TOKEN_RELATIVE)
        present = set()
        for path in (REPO / "references").rglob("*"):
            if path.is_file():
                present.add(hashlib.sha256(path.read_bytes()).hexdigest())
        missing = sorted(set(tokens.reference_hashes()) - present)
        self.assertEqual(missing, [], "token provenance cites frames that are not in references/")


class TestScaleGrammar(TokenFixture):
    def test_stairs_taller_than_the_step_limit_are_rejected(self):
        data = _shipped()
        data["scale"]["grammar"]["stairRise"] = data["scale"]["character"]["maxStepUp"] + 0.1
        self.assert_rejected(data, "unclimbable")

    def test_a_door_shorter_than_the_character_is_rejected(self):
        data = _shipped()
        data["scale"]["grammar"]["doorHeight"] = data["scale"]["character"]["height"] - 0.5
        self.assert_rejected(data, "doorHeight must exceed")

    def test_a_corridor_too_narrow_for_two_characters_is_rejected(self):
        data = _shipped()
        data["scale"]["grammar"]["corridorWidth"] = data["scale"]["character"]["width"] * 1.5
        self.assert_rejected(data, "two characters abreast")

    def test_legibility_distances_must_increase(self):
        data = _shipped()
        data["scale"]["legibility"]["labelReadDistance"] = 500
        self.assert_rejected(data, "labelReadDistance must be shorter")


class TestPaletteDiscipline(TokenFixture):
    def test_accent_coverage_over_budget_is_rejected(self):
        data = _shipped()
        data["palette"]["roles"]["accentGold"]["maxSurfaceCoverage"] = 0.5
        self.assert_rejected(data, "exceeds palette.harmony.accentTotalMaxCoverage")

    def test_an_accent_without_a_ceiling_is_rejected(self):
        data = _shipped()
        del data["palette"]["roles"]["accentGold"]["maxSurfaceCoverage"]
        self.assert_rejected(data, "must declare maxSurfaceCoverage")

    def test_a_palette_with_no_lightness_spread_is_rejected(self):
        """Every role the same value: nothing has a silhouette."""

        data = _shipped()
        for role in data["palette"]["roles"].values():
            role["srgb"] = [128, 128, 128]
        self.assert_rejected(data, "lightness spread")

    def test_too_many_hue_families_is_rejected(self):
        data = _shipped()
        data["palette"]["harmony"]["maxHueFamilies"] = 1
        self.assert_rejected(data, "hue families")

    def test_a_forbidden_material_is_rejected(self):
        data = _shipped()
        data["palette"]["roles"]["accentGold"]["material"] = "Neon"
        self.assert_rejected(data, "forbidden material Neon")

    def test_a_palette_with_no_dominant_role_is_rejected(self):
        data = _shipped()
        for role in data["palette"]["roles"].values():
            if role["tier"] == "dominant":
                role["tier"] = "supporting"
        self.assert_rejected(data, "at least one dominant role")


class TestProvenanceDiscipline(TokenFixture):
    def test_a_token_set_derived_from_the_candidate_is_rejected(self):
        """The tautology this whole layer exists to prevent.

        The schema enum catches it first, which is the stronger place for it to
        be caught; the assertion here is on the rejection, not on which layer
        produced it.
        """

        data = _shipped()
        data["provenance"]["derivation"] = "measured-from-candidate"
        with self.assertRaises(TokenError) as caught:
            self.load(data)
        self.assertIn("derivation", str(caught.exception))

    def test_forbidden_derivations_are_not_reachable_through_the_schema(self):
        """Keeps the constant and the schema enum from drifting apart."""

        from rqe.tokens import FORBIDDEN_DERIVATIONS

        schema = json.loads(
            (REPO / "schemas" / "design-tokens.v1.schema.json").read_text(encoding="utf-8")
        )
        allowed = set(schema["$defs"]["provenance"]["properties"]["derivation"]["enum"])
        self.assertEqual(allowed & FORBIDDEN_DERIVATIONS, set())

    def test_a_reference_taken_from_the_candidate_tree_is_caught(self):
        """`external-reference` is cheap to claim; this is what makes it mean
        something. A screenshot of our own build hashes identically wherever it
        sits, so the check is content-based rather than path-based."""

        from rqe.tokens import external_reference_issues

        tokens = load_token_set(REPO, TOKEN_RELATIVE)
        clean = external_reference_issues(tokens, [REPO / "roblox"])
        self.assertEqual(clean, [])

        # Plant one of the cited frames inside a pretend candidate tree.
        candidate = self.root / "candidate"
        candidate.mkdir()
        cited = tokens.reference_hashes()[0]
        source = next(
            path
            for path in (REPO / "references").rglob("*")
            if path.is_file()
            and __import__("hashlib").sha256(path.read_bytes()).hexdigest() == cited
        )
        (candidate / "leaked.png").write_bytes(source.read_bytes())

        issues = external_reference_issues(tokens, [candidate])
        self.assertEqual(len(issues), 1)
        self.assertIn("may not calibrate against its own build", issues[0])

    def test_external_reference_without_references_is_rejected(self):
        data = _shipped()
        data["provenance"]["references"] = []
        self.assert_rejected(data, "no references are cited")

    def test_platform_metrics_derivation_needs_no_references(self):
        data = _shipped()
        data["provenance"]["derivation"] = "platform-metrics"
        data["provenance"]["references"] = []
        tokens = self.load(data)
        self.assertEqual(tokens.provenance["derivation"], "platform-metrics")


class TestColourMath(unittest.TestCase):
    def test_near_greys_collapse_into_one_family(self):
        self.assertEqual(hue_family([128, 128, 128]), -1)
        self.assertEqual(hue_family([88, 92, 104]), -1)

    def test_perceptual_greens_share_a_family(self):
        """The bug this default was chosen to avoid: grass and a green accent
        landing in different buckets and reporting a false violation."""

        self.assertEqual(hue_family([115, 198, 88]), hue_family([86, 214, 106]))

    def test_red_and_blue_do_not_share_a_family(self):
        self.assertNotEqual(hue_family([226, 92, 82]), hue_family([92, 168, 222]))

    def test_luminance_is_ordered(self):
        self.assertLess(relative_luminance([44, 46, 56]), relative_luminance([244, 246, 248]))


class TestVisualThresholdProjection(unittest.TestCase):
    def setUp(self) -> None:
        self.tokens = load_token_set(REPO, TOKEN_RELATIVE)
        self.thresholds = derive_visual_thresholds(self.tokens)

    def test_object_envelopes_come_from_the_grammar(self):
        building = self.thresholds.object_scale["building"]
        self.assertEqual(building["minX"], self.tokens.grammar("buildingMinFootprint"))
        self.assertEqual(building["minY"], self.tokens.grammar("buildingMinHeight"))

    def test_every_envelope_has_a_positive_span(self):
        for kind, envelope in self.thresholds.object_scale.items():
            for axis in ("X", "Y", "Z"):
                self.assertLess(
                    envelope[f"min{axis}"],
                    envelope[f"max{axis}"],
                    f"{kind} axis {axis} has an empty envelope",
                )

    def test_allowed_colours_are_exactly_the_declared_roles(self):
        self.assertEqual(len(self.thresholds.allowed_colors), len(self.tokens.roles))
        for role in self.tokens.roles.values():
            self.assertIn(role.srgb, self.thresholds.allowed_colors)

    def test_thresholds_carry_the_token_hash(self):
        """Binding is what stops a spec from outliving the tokens it came from."""

        self.assertEqual(self.thresholds.token_sha256, self.tokens.sha256)

    def test_changing_a_token_changes_the_projection(self):
        mutated = copy.deepcopy(self.tokens.data)
        mutated["scale"]["grammar"]["buildingMinFootprint"] = 999
        import tempfile

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "tokens").mkdir()
            (root / "schemas").mkdir()
            (root / "schemas" / "design-tokens.v1.schema.json").write_text(
                (REPO / "schemas" / "design-tokens.v1.schema.json").read_text(encoding="utf-8"),
                encoding="utf-8",
            )
            (root / "tokens" / "m.json").write_text(json.dumps(mutated), encoding="utf-8")
            other = load_token_set(root, "tokens/m.json")
        projected = derive_visual_thresholds(other)
        self.assertEqual(projected.object_scale["building"]["minX"], 999)
        self.assertNotEqual(projected.token_sha256, self.thresholds.token_sha256)


class TestCalibrationReceipt(unittest.TestCase):
    def test_receipt_carries_derivation_and_references(self):
        tokens = load_token_set(REPO, TOKEN_RELATIVE)
        receipt = calibration_receipt(tokens, derive_visual_thresholds(tokens))
        self.assertEqual(receipt["schemaVersion"], 1)
        self.assertEqual(receipt["tokenSha256"], tokens.sha256)
        self.assertEqual(receipt["derivation"], "external-reference")
        self.assertTrue(receipt["referenceHashes"])
        self.assertIn("objectScale", receipt["thresholds"])


if __name__ == "__main__":
    unittest.main()
