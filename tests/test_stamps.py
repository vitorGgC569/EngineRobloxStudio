"""The derived hashes, and the drift that killed the gate for twenty-five commits.

The last class is the one that matters: it asserts the real repository is not
drifted right now. Everything else here can pass while the actual catalogue is
stale, which is exactly the state this module was written to end.
"""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from rqe.stamps import STAMPS, Stamp, StampError, drifted, refresh, verify

REPO = Path(__file__).resolve().parents[1]


def _fixture(root: Path, recorded: str, source: bytes = b"{}\n") -> Stamp:
    (root / "schemas").mkdir(parents=True, exist_ok=True)
    (root / "quality").mkdir(parents=True, exist_ok=True)
    (root / "schemas" / "src.json").write_bytes(source)
    (root / "quality" / "doc.json").write_text(
        json.dumps({"commandManifest": {"sha256": recorded, "path": "schemas/src.json"}},
                   indent=2) + "\n", encoding="utf-8")
    return Stamp(
        name="fixture", document="quality/doc.json",
        pointer=("commandManifest", "sha256"), source="schemas/src.json",
        why="so the test says why, like the real one does")


#: sha256 of b"{}\n", so the fixture can be exactly right without recomputing it
#: in the assertion -- a test that hashes the file to check the hash of the file
#: proves only that hashlib is deterministic.
EMPTY_DOC = "8c3ebb0d97a19a9e1f0a2dfb9a6ee2ac6a1f47a0e1a1f16bb64bf8c1b7cf0cbb"


class VerifyTests(unittest.TestCase):
    def test_a_matching_stamp_is_ok(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            stamp = _fixture(root, "placeholder")
            measured = stamp.measure(root)
            stamp.write(root, measured)
            result, = verify(root, [stamp])
            self.assertTrue(result.ok)
            self.assertIn("ok", result.render())

    def test_drift_is_reported_with_both_numbers_and_the_reason(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            stamp = _fixture(root, "0" * 64)
            result, = verify(root, [stamp])
            self.assertFalse(result.ok)
            rendered = result.render()
            self.assertIn("DRIFT", rendered)
            self.assertIn("0" * 64, rendered)
            self.assertIn(stamp.measure(root), rendered)
            self.assertIn("so the test says why", rendered)

    def test_a_missing_source_is_an_error_not_a_pass(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            stamp = _fixture(root, "0" * 64)
            (root / "schemas" / "src.json").unlink()
            result, = verify(root, [stamp])
            self.assertFalse(result.ok)
            self.assertIn("does not exist", result.error)

    def test_a_missing_field_is_an_error_not_a_pass(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            stamp = _fixture(root, "0" * 64)
            (root / "quality" / "doc.json").write_text("{}", encoding="utf-8")
            result, = verify(root, [stamp])
            self.assertFalse(result.ok)
            self.assertIn("has no field", result.error)

    def test_a_dot_in_a_key_is_not_a_path_separator(self):
        # The pointer is a tuple for exactly this reason. A dotted string would
        # split "commandManifest.sha256" correctly and "a.b"/"c" wrongly, and
        # the wrong split fails silently as a missing field.
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / "quality").mkdir()
            (root / "schemas").mkdir()
            (root / "schemas" / "src.json").write_bytes(b"{}\n")
            (root / "quality" / "doc.json").write_text(
                json.dumps({"a.b": {"sha256": "0" * 64}}), encoding="utf-8")
            stamp = Stamp("dotted", "quality/doc.json", ("a.b", "sha256"),
                          "schemas/src.json", "keys may contain dots")
            result, = verify(root, [stamp])
            self.assertEqual(result.error, "")
            self.assertEqual(result.recorded, "0" * 64)


class RefreshTests(unittest.TestCase):
    def test_refreshing_makes_verify_clean_and_reports_what_moved(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            stamp = _fixture(root, "0" * 64)
            changed = refresh(root, [stamp])
            self.assertEqual(len(changed), 1)
            self.assertEqual(changed[0].recorded, "0" * 64)
            self.assertTrue(verify(root, [stamp])[0].ok)

    def test_refreshing_a_clean_stamp_changes_nothing(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            stamp = _fixture(root, "0" * 64)
            refresh(root, [stamp])
            before = (root / "quality" / "doc.json").read_bytes()
            self.assertEqual(refresh(root, [stamp]), [])
            self.assertEqual((root / "quality" / "doc.json").read_bytes(), before)

    def test_refreshing_preserves_every_other_field_and_the_formatting(self):
        # A refresh that reformats buries its own one-line change in a
        # thousand-line diff, and a diff nobody can read is a review nobody does.
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            stamp = _fixture(root, "0" * 64)
            refresh(root, [stamp])
            payload = json.loads((root / "quality" / "doc.json").read_text(encoding="utf-8"))
            self.assertEqual(payload["commandManifest"]["path"], "schemas/src.json")
            text = (root / "quality" / "doc.json").read_text(encoding="utf-8")
            self.assertTrue(text.endswith("\n"))
            self.assertIn('\n  "commandManifest"', text)

    def test_refresh_refuses_rather_than_writing_over_an_error(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            stamp = _fixture(root, "0" * 64)
            (root / "schemas" / "src.json").unlink()
            with self.assertRaises(StampError):
                refresh(root, [stamp])


class TheRealRepositoryTests(unittest.TestCase):
    """The assertion the six failing tests were a symptom of."""

    def test_every_registered_stamp_matches_its_source(self):
        results = verify(REPO)
        self.assertTrue(results, "no stamps are registered")
        bad = drifted(results)
        self.assertEqual(
            bad, [],
            "a checked-in derived hash has drifted; run "
            "`python rqe.py stamp --write` and review the diff:\n"
            + "\n".join(item.render() for item in bad))

    def test_the_bridge_manifest_is_one_of_them(self):
        # Named explicitly so deleting the registration is a test failure and
        # not a silently emptier gate.
        self.assertIn("bridge-command-manifest", {item.name for item in STAMPS})


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
