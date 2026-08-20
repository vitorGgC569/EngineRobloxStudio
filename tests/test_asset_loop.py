"""The first closed asset loop: author an image, publish it, record what it was.

Images were chosen as the narrow end of the wedge deliberately -- cheapest to
generate, fastest through moderation, no external tool, and they unblock the
three places the current game looks worst.

Nothing here contacts Roblox. What is verified is that the human gates are
reported honestly, that generated content is deterministic and attributable, and
that a publish is shaped so it can never be auto-retried into a duplicate.
"""

from __future__ import annotations

import json
import unittest
from pathlib import Path

from rqe.assets.image_authoring import (
    Canvas,
    ImageAuthoringError,
    icon,
    panel,
    rarity_card,
)
from rqe.assets.preflight import CHECKLIST, GateStatus, evaluate
from rqe.tokens import load_token_set


REPO = Path(__file__).resolve().parents[1]


def _tokens():
    return load_token_set(REPO, "tokens/brickfarm.json")


BLOCKED_CAPABILITIES = {
    "createAsset": False,
    "editableImage": False,
    "blockers": [
        'AssetService:CreateAssetAsync is unavailable; enable the '
        '"CreateAssetAsync Luau API" beta in Studio > File > Beta Features',
        "EditableImage is unavailable; the experience owner must be 13+ and "
        'ID-verified, and "Allow Mesh / Image APIs" must be enabled in Game '
        "Settings > Security",
    ],
}

OPEN_CAPABILITIES = {"createAsset": True, "editableImage": True, "blockers": []}
READY_ENV = {
    "ROBLOX_OPEN_CLOUD_KEY": "k",
    "ROBLOX_UNIVERSE_ID": "1",
    "ROBLOX_PLACE_ID": "2",
}


class TestPreflight(unittest.TestCase):
    def test_an_unreachable_studio_is_unknown_not_blocked(self):
        """An unreachable Studio is not evidence that a toggle is off."""

        report = evaluate(None, environment=READY_ENV)
        studio_gates = [gate for gate in report.gates if gate.id != "open-cloud-key" and gate.id != "cloud-target"]
        self.assertTrue(all(gate.status is GateStatus.UNKNOWN for gate in studio_gates))
        self.assertFalse(report.ready)

    def test_unknown_never_counts_as_satisfied(self):
        report = evaluate(None, environment=READY_ENV)
        self.assertFalse(report.ready)
        self.assertTrue(report.unknown)

    def test_every_blocked_gate_names_a_specific_remedy(self):
        """A pipeline that cannot say why it stopped costs more than one that
        never started."""

        report = evaluate(BLOCKED_CAPABILITIES, environment={})
        self.assertTrue(report.blocked)
        for gate in report.blocked:
            self.assertTrue(gate.remedy, f"{gate.id} is blocked with no remedy")

    def test_the_beta_flag_remedy_names_the_exact_menu_path(self):
        report = evaluate(BLOCKED_CAPABILITIES, environment={})
        gate = next(item for item in report.gates if item.id == "create-asset-beta")
        self.assertIs(gate.status, GateStatus.BLOCKED)
        self.assertIn("Beta Features", gate.remedy)

    def test_a_fully_open_environment_is_ready(self):
        report = evaluate(OPEN_CAPABILITIES, environment=READY_ENV)
        self.assertTrue(report.ready, report.summary())
        self.assertEqual(report.to_dict()["blocked"], 0)

    def test_a_missing_key_blocks_even_when_studio_is_open(self):
        report = evaluate(OPEN_CAPABILITIES, environment={})
        self.assertFalse(report.ready)
        self.assertIn("open-cloud-key", [gate.id for gate in report.blocked])

    def test_the_report_serialises(self):
        payload = evaluate(OPEN_CAPABILITIES, environment=READY_ENV).to_dict()
        json.dumps(payload)
        self.assertEqual(payload["schemaVersion"], 1)
        self.assertEqual(payload["unknown"], 0)

    def test_the_checklist_covers_all_four_human_gates(self):
        for fragment in ("ID-verified", "Allow Mesh / Image APIs",
                         "CreateAssetAsync Luau API", "asset:write"):
            self.assertIn(fragment, CHECKLIST)


class TestCanvas(unittest.TestCase):
    def test_dimensions_are_bounded(self):
        with self.assertRaises(ImageAuthoringError):
            Canvas(0, 10)
        with self.assertRaises(ImageAuthoringError):
            Canvas(10, 2048)

    def test_alpha_compositing_reaches_the_source_colour(self):
        canvas = Canvas(1, 1)
        canvas.set(0, 0, (0, 0, 0, 255))
        canvas.blend(0, 0, (255, 255, 255, 255))
        self.assertEqual(tuple(canvas.data), (255, 255, 255, 255))

    def test_a_half_alpha_blend_lands_between(self):
        canvas = Canvas(1, 1)
        canvas.set(0, 0, (0, 0, 0, 255))
        canvas.blend(0, 0, (255, 255, 255, 128))
        self.assertTrue(100 < canvas.data[0] < 155)

    def test_writes_outside_the_canvas_are_ignored_not_wrapped(self):
        canvas = Canvas(2, 2)
        canvas.set(5, 5, (255, 0, 0, 255))
        self.assertEqual(set(canvas.data), {0})


class TestImageGenerators(unittest.TestCase):
    def setUp(self) -> None:
        self.tokens = _tokens()

    def test_a_card_uses_the_trading_card_ratio(self):
        card = rarity_card(self.tokens, rarity_role="accentRare")
        self.assertAlmostEqual(card.height / card.width, 7 / 5, places=1)

    def test_the_raster_length_matches_the_declared_size(self):
        card = rarity_card(self.tokens, rarity_role="accentRare", width=64, height=90)
        self.assertEqual(len(card.pixels), 64 * 90 * 4)

    def test_generation_is_deterministic_for_a_seed(self):
        """A regression screenshot is meaningless if the art reshuffles."""

        first = rarity_card(self.tokens, rarity_role="accentRare", seed=7)
        second = rarity_card(self.tokens, rarity_role="accentRare", seed=7)
        self.assertEqual(first.sha256, second.sha256)

    def test_a_different_seed_produces_a_different_raster(self):
        first = rarity_card(self.tokens, rarity_role="accentRare", seed=1)
        second = rarity_card(self.tokens, rarity_role="accentRare", seed=2)
        self.assertNotEqual(first.sha256, second.sha256)

    def test_rarity_changes_the_output(self):
        gold = rarity_card(self.tokens, rarity_role="accentGold", seed=1)
        rare = rarity_card(self.tokens, rarity_role="accentRare", seed=1)
        self.assertNotEqual(gold.sha256, rare.sha256)

    def test_colours_come_only_from_token_roles(self):
        with self.assertRaises(Exception):
            rarity_card(self.tokens, rarity_role="hotPink")

    def test_an_unknown_glyph_is_refused(self):
        with self.assertRaises(ImageAuthoringError):
            icon(self.tokens, role="accentGold", glyph="spiral")

    def test_icons_and_panels_generate(self):
        self.assertEqual(len(icon(self.tokens, role="accentGold").pixels), 128 * 128 * 4)
        self.assertEqual(len(panel(self.tokens).pixels), 512 * 288 * 4)

    def test_provenance_binds_the_raster_to_its_token_set(self):
        card = rarity_card(self.tokens, rarity_role="accentRare", seed=3)
        provenance = card.provenance()
        self.assertEqual(provenance["tokenSha256"], self.tokens.sha256)
        self.assertEqual(provenance["sha256"], card.sha256)
        self.assertFalse(provenance["placeholder"])

    def test_command_params_match_the_bridge_schema(self):
        """What the generator emits must be exactly what the manifest accepts."""

        manifest = json.loads(
            (REPO / "schemas" / "bridge-commands.v1.json").read_text(encoding="utf-8")
        )
        schema = manifest["commands"]["assets.create_image"]["params"]
        params = icon(self.tokens, role="accentGold", size=8).to_command_params("Icon")

        from rqe.schema_validation import validate_schema_instance

        self.assertEqual([str(issue) for issue in validate_schema_instance(params, schema)], [])


class TestPublishSafety(unittest.TestCase):
    def test_publishing_is_declared_at_most_once(self):
        """A retry would create a second asset and a second moderation queue
        entry. There is no safe automatic retry for a publish."""

        manifest = json.loads(
            (REPO / "schemas" / "bridge-commands.v1.json").read_text(encoding="utf-8")
        )
        spec = manifest["commands"]["assets.create_image"]
        self.assertEqual(spec["idempotency"], "at-most-once")
        self.assertEqual(spec["effect"], "mutation")

    def test_publishing_is_edit_context_only(self):
        """CreateAssetAsync is not permitted in a published experience."""

        manifest = json.loads(
            (REPO / "schemas" / "bridge-commands.v1.json").read_text(encoding="utf-8")
        )
        self.assertEqual(manifest["commands"]["assets.create_image"]["contexts"], ["edit"])

    def test_the_result_can_report_every_terminal_state(self):
        manifest = json.loads(
            (REPO / "schemas" / "bridge-commands.v1.json").read_text(encoding="utf-8")
        )
        states = set(manifest["commands"]["assets.create_image"]["result"]["properties"]["status"]["enum"])
        self.assertEqual(states, {"PUBLISHED", "BLOCKED", "FAILED", "RATE_LIMITED"})


if __name__ == "__main__":
    unittest.main()
