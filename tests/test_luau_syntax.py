"""Every shipped Luau file must compile.

Rojo packages sources without parsing them, so a place can build cleanly from
Luau that never runs. This repository has already paid for that once: a HUD died
silently because a handler referenced a variable declared later in the file, and
nothing anywhere reported an error.

The check fails closed. A missing toolchain is a failure, not a skip.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_check import (
    DEFAULT_SOURCE_ROOTS,
    ToolchainUnavailable,
    check_all,
    compile_file,
    discover,
    ensure_compiler,
)


REPO = Path(__file__).resolve().parents[1]


class TestLuauCompiles(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        try:
            cls.compiler = ensure_compiler(REPO)
        except ToolchainUnavailable as exc:
            raise AssertionError(
                f"the Luau syntax gate cannot run: {exc}. "
                "This is a blocked check, not a passing one."
            ) from exc

    def test_the_toolchain_is_present(self):
        self.assertTrue(self.compiler.is_file())

    def test_sources_were_actually_discovered(self):
        """Guards the guard: an empty file list would pass vacuously."""

        sources = discover(REPO)
        self.assertGreater(len(sources), 30, "source discovery found suspiciously few Luau files")

    def test_worldkit_is_covered(self):
        sources = {path.name for path in discover(REPO)}
        for required in ("Tokens.lua", "Fab.lua", "Build.lua", "Grid.lua", "init.lua"):
            self.assertIn(required, sources)

    def test_every_luau_source_compiles(self):
        failures = check_all(REPO, allow_download=False)
        self.assertEqual(
            [str(item) for item in failures],
            [],
            "Luau sources failed to compile",
        )

    def test_retired_scripts_are_excluded(self):
        """`.lua.disabled` is how this repo retires code without deleting it."""

        sources = discover(REPO)
        self.assertFalse([path for path in sources if path.name.endswith(".disabled")])

    def test_third_party_salvage_is_excluded(self):
        sources = discover(REPO)
        self.assertFalse(
            [path for path in sources if "salvage" in path.parts],
            "third-party salvage must not become a first-party syntax blocker",
        )

    def test_games_are_covered(self):
        sources = discover(REPO)
        echo_client = REPO / "games" / "echo-riot" / "src" / "client" / "init.client.lua"
        self.assertIn(echo_client, sources)

    def test_the_checker_detects_a_real_syntax_error(self):
        """A gate nobody has seen fail is a gate nobody should trust."""

        import tempfile

        with tempfile.TemporaryDirectory() as directory:
            broken = Path(directory) / "broken.lua"
            broken.write_text("local x =\nreturn x\n", encoding="utf-8")
            failure = compile_file(self.compiler, broken)
        self.assertIsNotNone(failure)
        assert failure is not None
        self.assertIn("SyntaxError", failure.message)

    def test_the_checker_accepts_valid_luau(self):
        import tempfile

        with tempfile.TemporaryDirectory() as directory:
            good = Path(directory) / "good.lua"
            good.write_text("local Module = {}\nfunction Module.f(): number\n\treturn 1\nend\nreturn Module\n", encoding="utf-8")
            self.assertIsNone(compile_file(self.compiler, good))

    def test_source_roots_that_exist_are_scanned(self):
        present = [relative for relative in DEFAULT_SOURCE_ROOTS if (REPO / relative).exists()]
        self.assertIn("roblox/lib", present)
        self.assertIn("games", present)
        self.assertIn("apps", present)
        self.assertIn("tools", present)


if __name__ == "__main__":
    unittest.main()
