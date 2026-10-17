"""The engine's version promise, asserted instead of written down.

`Forge/init.lua` carries a careful semver contract and a `Forge.require` that
errors when a game asks for an engine it was not written against. That machinery
was real and the discipline behind it was not:

    Forge.VERSION       "0.2.0"
    nine games          Forge.require("0.2.0")
    CHANGELOG           ## 0.2.0 -- unreleased
    families recorded   43 of 58

A version nine games depend on cannot also be a version that never shipped, and
a changelog missing a quarter of the engine is a changelog nobody can use to
decide whether upgrading is safe. Both were true for months because nothing
checked either.

These are cheap and they are the difference between a contract and a paragraph.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
ENGINE = REPO / "forge" / "luau" / "Forge"
CHANGELOG = REPO / "forge" / "CHANGELOG.md"


def _engine_version() -> str:
    text = (ENGINE / "init.lua").read_text(encoding="utf-8")
    found = re.search(r'Forge\.VERSION\s*=\s*"([^"]+)"', text)
    assert found, "Forge.VERSION is not declared in init.lua"
    return found.group(1)


def _families() -> list[str]:
    return sorted(p.name for p in ENGINE.iterdir() if p.is_dir())


def _required_versions() -> dict[str, list[str]]:
    """Which version each game pins, and where."""

    wanted: dict[str, list[str]] = {}
    for path in sorted((REPO / "games").rglob("*.lua")) + \
            sorted((REPO / "games").rglob("*.luau")):
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        for version in re.findall(r'Forge\.require\("([^"]+)"\)', text):
            wanted.setdefault(version, []).append(
                path.relative_to(REPO).as_posix())
    return wanted


class TheVersionIsOneNumberTests(unittest.TestCase):
    def test_the_engine_declares_a_semver(self):
        self.assertRegex(_engine_version(), r"^\d+\.\d+\.\d+$")

    def test_the_python_package_carries_the_same_version(self):
        # Two halves of one product. They were 0.1.0 and 0.2.0.
        import tomllib

        project = tomllib.loads(
            (REPO / "pyproject.toml").read_text(encoding="utf-8"))["project"]
        self.assertEqual(project["version"], _engine_version())

        import rqe

        self.assertEqual(rqe.__version__, _engine_version())

    def test_audit_reports_carry_the_package_version(self):
        from rqe.models import AuditReport

        payload = AuditReport(
            project="version-probe",
            generated_at="",
            evidence=[],
            scores={},
            summary={},
            release_allowed=False,
            release_reasons=[],
            runtime_trace={},
            static_scan={},
        ).to_dict()
        self.assertEqual(payload["engine"]["version"], _engine_version())

    def test_every_game_pins_a_version_the_engine_can_satisfy(self):
        # `Forge.require` errors at the first line rather than three systems
        # deep, so a game pinning a version this engine is not is a game that
        # will not boot -- and CI can say so without opening Studio.
        engine = _engine_version()
        for wanted, where in _required_versions().items():
            with self.subTest(version=wanted):
                self.assertEqual(
                    wanted, engine,
                    f"pinned by {', '.join(where[:3])} but the engine is {engine}")


class TheChangelogRecordsWhatShippedTests(unittest.TestCase):
    def test_the_current_version_has_a_section(self):
        text = CHANGELOG.read_text(encoding="utf-8")
        # Multiline: the header is a section inside the file, not its first line.
        self.assertTrue(
            re.search(rf"^## {re.escape(_engine_version())}\b", text, re.M),
            "the shipped version has no changelog section")

    def test_the_current_version_is_not_marked_unreleased(self):
        text = CHANGELOG.read_text(encoding="utf-8")
        header = next(line for line in text.splitlines()
                      if line.startswith(f"## {_engine_version()}"))
        self.assertNotIn("unreleased", header.lower(),
                         "games depend on this version; it has shipped")

    def test_every_family_in_the_engine_is_named_in_the_changelog(self):
        # The guard that makes this a discipline rather than a one-time tidy:
        # a family added tomorrow fails this until somebody writes the line
        # that says what it is.
        text = CHANGELOG.read_text(encoding="utf-8")
        missing = [family for family in _families()
                   if not re.search(rf"\b{re.escape(family)}\b", text)]
        self.assertEqual(
            missing, [],
            "families in the engine that the changelog never mentions: "
            + ", ".join(missing)
            + " -- add a line to forge/CHANGELOG.md saying what each one is")

    def test_the_breaking_change_rule_is_still_stated(self):
        # `Forge.require` implements the pre-1.0 rule that the minor carries
        # breaking changes. If that paragraph goes, the code enforcing it
        # becomes arbitrary.
        text = CHANGELOG.read_text(encoding="utf-8").lower()
        self.assertIn("breaking", text)
        self.assertIn("minor", text)


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
