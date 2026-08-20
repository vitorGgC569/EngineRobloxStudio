"""Tests for the authoring half.

They check the two things that would make Forge quietly useless: that the
scaffold stays empty of gameplay, and that the doctor actually catches the
mistakes it claims to catch.
"""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

from forge.cli import doctor, scaffold  # noqa: E402

ENGINE = REPO / "forge" / "luau" / "Forge"


class ScaffoldTests(unittest.TestCase):
    def test_scaffold_creates_a_buildable_project(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = scaffold.create("testgame", Path(tmp), vendor=True)
            self.assertTrue((root / "default.project.json").exists())
            self.assertTrue((root / "src" / "server" / "init.server.lua").exists())
            self.assertTrue((root / "src" / "client" / "init.client.lua").exists())
            self.assertTrue((root / "vendor" / "Forge" / "init.lua").exists())

    def test_scaffold_ships_no_gameplay(self) -> None:
        """The whole point. A scaffold that ships a working genre is a ceiling."""
        with tempfile.TemporaryDirectory() as tmp:
            root = scaffold.create("testgame", Path(tmp), vendor=False)
            systems = root / "src" / "server" / "systems"
            self.assertTrue(systems.is_dir())
            self.assertEqual(list(systems.glob("*.lua")), [])

            source = "\n".join(
                p.read_text(encoding="utf-8")
                for p in (root / "src").rglob("*.lua")
            ).lower()
            for genre_word in ("tycoon", "dropper", "conveyor", "obby", "simulator", "tower defense"):
                self.assertNotIn(genre_word, source, f"scaffold leaked a genre: {genre_word}")

    def test_scaffold_rejects_a_bad_name(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError):
                scaffold.create("../escape", Path(tmp))


class DoctorTests(unittest.TestCase):
    def _project(self, tmp: str, body: str, name: str = "sys.server.lua") -> Path:
        root = Path(tmp) / "proj"
        (root / "src").mkdir(parents=True)
        (root / "src" / name).write_text(body, encoding="utf-8")
        return root

    def test_catches_a_syntax_error(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = self._project(tmp, "local broken = = 1\n")
            findings = doctor.run(root)
            self.assertTrue(
                any(f.severity == "error" and "does not compile" in f.message for f in findings),
                findings,
            )

    def test_catches_an_undeclared_net_event(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = self._project(tmp, 'Net.on("NeverDeclared", function() end)\n')
            findings = doctor.run(root)
            self.assertTrue(
                any("never declared" in f.message for f in findings), findings
            )

    def test_catches_a_spinning_loop(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = self._project(tmp, "while true do\n\tlocal x = 1\nend\n")
            findings = doctor.run(root)
            self.assertTrue(any("no yield" in f.message for f in findings), findings)

    def test_catches_localplayer_on_the_server(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = self._project(tmp, "local p = game.Players.LocalPlayer\n")
            findings = doctor.run(root)
            self.assertTrue(any("LocalPlayer" in f.message for f in findings), findings)

    def test_clean_source_reports_nothing_severe(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = self._project(tmp, "local M = {}\nfunction M.start() end\nreturn M\n", name="ok.lua")
            findings = doctor.run(root)
            self.assertEqual([f for f in findings if f.severity == "error"], [])


class EngineTests(unittest.TestCase):
    def test_every_module_compiles(self) -> None:
        from rqe import luau_check

        try:
            compiler = luau_check.ensure_compiler(REPO, allow_download=False)
        except Exception as exc:  # toolchain absent: blocked, never passed
            self.skipTest(f"luau compiler unavailable: {exc}")

        failures = []
        for path in sorted(ENGINE.rglob("*.lua")):
            failure = luau_check.compile_file(compiler, path)
            if failure:
                failures.append(str(failure))
        self.assertEqual(failures, [])

    def test_engine_exposes_a_describe_per_module(self) -> None:
        """Debug.snapshot() collects these; a module without one is invisible."""
        expected = {
            "Actor", "Anim", "Combat", "Data", "Net", "Rig", "Save", "UI", "World", "Debug",
            "Entity", "Assets", "Scene", "Events", "Inventory", "Progression", "Quest",
            "Ability", "Interaction", "Dialogue", "Streaming", "Editor",
            "Input", "Audio", "Visual", "Telemetry", "Monetization", "Bench",
        }
        missing = []
        for name in sorted(expected):
            source = (ENGINE / name / "init.lua").read_text(encoding="utf-8")
            if "function %s.describe" % name not in source and ".describe" not in source:
                missing.append(name)
        self.assertEqual(missing, [])

    def test_the_engine_ships_no_genre(self) -> None:
        """Code only. The docs are allowed to say the word while forbidding it."""
        import re

        code = []
        for path in ENGINE.rglob("*.lua"):
            text = path.read_text(encoding="utf-8")
            text = re.sub(r"--\[\[.*?\]\]", "", text, flags=re.S)
            text = re.sub(r"--.*", "", text)
            code.append(text)
        source = "\n".join(code).lower()

        for genre_word in ("tycoon", "dropper", "obby", "simulator"):
            self.assertNotIn(genre_word, source, f"engine leaked a genre: {genre_word}")


class ReuseTests(unittest.TestCase):
    """The definitive test: two games, one engine, no shared game code."""

    GAMES = ("provingground", "lanternreach")

    def _sources(self, name: str) -> dict[str, str]:
        root = REPO / "games" / name / "src"
        return {p.relative_to(root).as_posix(): p.read_text(encoding="utf-8") for p in root.rglob("*.lua")}

    def test_both_games_exist(self) -> None:
        for name in self.GAMES:
            self.assertTrue((REPO / "games" / name / "src").is_dir(), name)

    def test_no_file_is_shared_between_games(self) -> None:
        a, b = (self._sources(name) for name in self.GAMES)
        shared = set(a.values()) & set(b.values())
        self.assertEqual(shared, set(), "two games sharing a whole file means one is a template of the other")

    def test_games_share_only_boilerplate(self) -> None:
        a, b = (self._sources(name) for name in self.GAMES)
        la = {line.strip() for text in a.values() for line in text.splitlines()}
        lb = {line.strip() for text in b.values() for line in text.splitlines()}
        common = {
            line for line in (la & lb)
            if len(line) > 40 and not line.startswith("--")
        }
        # require/print wiring only. A real ceiling shows up as dozens.
        self.assertLess(len(common), 40, sorted(common)[:10])

    def test_the_games_use_disjoint_gameplay_modules(self) -> None:
        import re

        used = []
        for name in self.GAMES:
            text = "\n".join(self._sources(name).values())
            used.append(set(re.findall(r"Forge\.([A-Z][A-Za-z]+)", text)))
        only_a = used[0] - used[1]
        only_b = used[1] - used[0]
        self.assertTrue(only_a, "one game uses nothing the other does not — same game twice")
        self.assertTrue(only_b, "one game uses nothing the other does not — same game twice")


class ProductionTests(unittest.TestCase):
    """The things that separate a demo from something that can ship."""

    def _engine_source(self) -> str:
        return "\n".join(p.read_text(encoding="utf-8") for p in ENGINE.rglob("*.lua"))

    def test_input_is_abstracted_not_hardcoded(self) -> None:
        """No game file may read UserInputService directly.

        The moment one does, that action exists on desktop only, and nobody
        notices until a phone session cannot perform it.
        """
        import re

        offenders = []
        for name in ("provingground", "lanternreach"):
            for path in (REPO / "games" / name / "src").rglob("*.lua"):
                # Comments may name the services they replaced; code may not.
                text = path.read_text(encoding="utf-8")
                text = re.sub(r"--\[\[.*?\]\]", "", text, flags=re.S)
                text = re.sub(r"--[^\n]*", "", text)
                if "UserInputService" in text or "ContextActionService" in text:
                    offenders.append(str(path.relative_to(REPO)))
        self.assertEqual(offenders, [], "these bypass Forge.Input")

    def test_every_action_is_reachable_on_touch(self) -> None:
        """An action with no `touch` spec cannot be performed on a phone."""
        import re

        for name in ("provingground", "lanternreach"):
            for path in (REPO / "games" / name / "src").rglob("*.client.lua"):
                text = path.read_text(encoding="utf-8")
                block = re.search(r"Input\.defineActions\s*\(\s*\{(.*?)\n\}\)", text, re.S)
                if not block:
                    continue
                actions = re.findall(r"^\t(\w+)\s*=\s*\{", block.group(1), re.M)
                touches = len(re.findall(r"touch\s*=", block.group(1)))
                self.assertEqual(
                    len(actions), touches,
                    f"{path.name}: {len(actions)} actions but {touches} touch specs",
                )

    def test_receipts_are_idempotent(self) -> None:
        """ProcessReceipt must grant inside an UpdateAsync transaction.

        Granting outside it means a Roblox retry grants twice.
        """
        source = (ENGINE / "Monetization" / "init.lua").read_text(encoding="utf-8")
        self.assertIn("UpdateAsync", source)
        transaction = source[source.index("UpdateAsync"):source.index("if not ok then")]
        self.assertIn("product.grant(player)", transaction, "the grant is outside the transaction")

    def test_saves_are_checksummed(self) -> None:
        source = (ENGINE / "Save" / "init.lua").read_text(encoding="utf-8")
        for expected in ("__checksum", "__backups", "function Save.rollback"):
            self.assertIn(expected, source)

    def test_bench_is_honest_about_what_it_cannot_measure(self) -> None:
        source = (ENGINE / "Bench" / "init.lua").read_text(encoding="utf-8")
        self.assertIn("notMeasured", source)
        self.assertIn("replication bandwidth", source)


class ShootingTests(unittest.TestCase):
    """Whoever decides where a bullet went is the person playing the game."""

    @staticmethod
    def _code(path: Path) -> str:
        """Source with comments removed.

        Needed because these tests search for calls, and the comments
        deliberately name the calls that must NOT appear.
        """
        import re

        text = path.read_text(encoding="utf-8")
        text = re.sub(r"--\[\[.*?\]\]", "", text, flags=re.S)
        return re.sub(r"--[^\n]*", "", text)

    def _client(self) -> str:
        return self._code(REPO / "games/provingground/src/client/init.client.lua")

    def _range(self) -> str:
        return self._code(REPO / "games/provingground/src/server/systems/Range.lua")

    def test_the_client_never_pulls_the_trigger(self) -> None:
        """`Weapon.fire` on a client is a client that decides its own hits.

        Reading definitions there is fine and necessary — the tracer and the
        HUD both need them. Firing is not.
        """
        text = self._client()
        self.assertNotIn("Weapon.fire", text, "the client resolves its own shots")
        self.assertIn('Net.send("Shoot"', text, "the client must ask the server instead")

    def test_the_shot_carries_nothing_but_an_aim(self) -> None:
        """Origin, charge, damage and hits are all the server's to decide.

        Each one this payload gained would be a number a modified client could
        pick for itself, and every one of them is worth picking.
        """
        import re

        sent = re.search(r'Net\.send\("Shoot",\s*\{(.*?)\}\)', self._client(), re.S)
        self.assertIsNotNone(sent, "the client never sends a shot")
        keys = set(re.findall(r"(\w+)\s*=", sent.group(1)))
        self.assertEqual(keys, {"dir"}, f"the shot packet carries more than aim: {sorted(keys)}")

    def test_the_server_reads_only_the_aim_back(self) -> None:
        """The other half of the same rule, checked where it is enforced."""
        import re

        source = self._range()
        handler = source[source.index("local function onShoot"):source.index("function Range.start")]
        used = set(re.findall(r"payload\.(\w+)", handler))
        self.assertEqual(used, {"dir"}, f"onShoot trusts more than the aim: {sorted(used)}")

    def test_spread_is_reproducible(self) -> None:
        """Prediction only works if both machines draw the same cone.

        `math.random` inside the spread would put the server's pellets and the
        client's tracer in different places on every shot.
        """
        source = self._code(ENGINE / "Weapon" / "init.lua")
        fn = source[source.index("function Weapon.spreadDirection"):]
        fn = fn[:fn.index("\nend")]
        self.assertIn("Random.new", fn)
        self.assertNotIn("math.random", fn)

    def test_the_draw_is_timed_by_the_server(self) -> None:
        """A client that reports its own draw time reports a full one."""
        source = self._range()
        self.assertIn("Weapon.beginCharge", source, "nothing starts the server's clock")
        # The charge that reaches Weapon.fire comes from Weapon's own timer,
        # never from the packet.
        handler = source[source.index("local function onShoot"):source.index("function Range.start")]
        self.assertNotIn("charge", handler.split("Weapon.fire")[0])


class ScaffoldGuardTests(unittest.TestCase):
    def test_force_refuses_a_directory_forge_did_not_create(self) -> None:
        """--force once ate a real project that shared a name. Never again."""
        with tempfile.TemporaryDirectory() as tmp:
            foreign = Path(tmp) / "someone_elses_game"
            foreign.mkdir()
            (foreign / "game.json").write_text("{}", encoding="utf-8")
            with self.assertRaises(FileExistsError):
                scaffold.create("someone_elses_game", Path(tmp), force=True)
            self.assertTrue((foreign / "game.json").exists(), "the guard must not delete first")

    def test_force_accepts_a_forge_project(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            scaffold.create("mine", Path(tmp))
            self.assertTrue((Path(tmp) / "mine" / ".forge-project").exists())
            scaffold.create("mine", Path(tmp), force=True)


if __name__ == "__main__":
    unittest.main()
