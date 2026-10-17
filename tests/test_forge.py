"""Tests for the authoring half.

They check the two things that would make Forge quietly useless: that the
scaffold stays empty of gameplay, and that the doctor actually catches the
mistakes it claims to catch.
"""

from __future__ import annotations

import os
import socket
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

from forge.cli import doctor, preflight, scaffold  # noqa: E402

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

        # Whole words, not substrings. The first version matched "obby" inside
        # "lobby" and failed on a cross-server destination name — a check whose
        # false positives look exactly like true ones is a check people learn
        # to silence.
        for genre_word in ("tycoon", "dropper", "obby", "simulator"):
            found = re.search(rf"{genre_word}", source)
            self.assertIsNone(found, f"engine leaked a genre: {genre_word}")


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


class EditorPersistenceTests(unittest.TestCase):
    """An editor that cannot keep its work is an inspector."""

    def test_save_and_pull_agree_on_where_scenes_live(self) -> None:
        """The engine publishes and the CLI collects; both must name the same place.

        `Editor.save` writes a StringValue under `Workspace.ForgeScenes`, and
        `forge scene pull` reads from there. Nothing connects the two but this
        string, so a rename on either side would silently pull nothing — which
        is exactly the failure the first version of the puller had.
        """
        engine = (ENGINE / "Editor" / "init.lua").read_text(encoding="utf-8")
        cli = (REPO / "forge/cli/scene.py").read_text(encoding="utf-8")
        self.assertIn("ForgeScenes", engine)
        self.assertIn("ForgeScenes", cli)

    def test_the_puller_names_the_property_it_wants(self) -> None:
        """`dm.properties` returns a generic set unless you ask for a field.

        This test previously asserted the opposite — that the puller must avoid
        `dm.properties` entirely — because the first version called it without
        `properties`, got nothing back, and concluded the command could not
        read a StringValue at all. It could; it just answers what it is asked.
        A test written from that mistake locked the workaround in place, and
        the workaround only ran in edit mode.
        """
        cli = (REPO / "forge/cli/scene.py").read_text(encoding="utf-8")
        pull = cli[cli.index("def pull("):cli.index("_MODULE_HEADER")]
        self.assertIn('"properties": ["Value"]', pull,
                      "the puller must name the field it wants")


class RigTests(unittest.TestCase):
    def test_r15_joint_names_match_a_real_character(self) -> None:
        """These were read off a live rig; a typo makes every clip miss silently."""
        rig = (ENGINE / "Rig" / "init.lua").read_text(encoding="utf-8")
        anim = (ENGINE / "Anim" / "init.lua").read_text(encoding="utf-8")
        # The builder composes side-specific names ("Right" .. "Elbow"), so the
        # literals are the suffixes, not the full joint names.
        for joint in ('"Root"', '"Waist"', '"Neck"', '"Shoulder"', '"Elbow"',
                      '"Wrist"', '"Hip"', '"Knee"', '"Ankle"'):
            self.assertIn(joint, rig, f"R15 builder never makes {joint}")
        for joint in ("RightElbow", "RightKnee", "RightWrist", "RightAnkle"):
            self.assertIn(joint, anim, f"joint map does not drive {joint}")


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


class EveryNewGameAnnouncesItself(unittest.TestCase):
    """`Debug.ready` was a rule in CLAUDE.md and a line in no scaffold.

    Two games of thirty-nine had it. Everything that photographs, measures or
    tests a game had to guess when it was up, and a server that spends twelve
    seconds carving terrain got photographed at second two.

    A convention the scaffold does not emit is a convention that does not exist,
    so it is asserted here rather than asked for in a document.
    """

    def _bootstrap(self, tmp: Path) -> str:
        scaffold.create("announcer", tmp)
        return (tmp / "announcer" / "src" / "server" / "init.server.lua").read_text(
            encoding="utf-8")

    def test_a_new_game_calls_debug_ready(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            self.assertIn("Debug.ready(", self._bootstrap(Path(tmp)))

    def test_it_is_the_last_statement_in_the_bootstrap(self) -> None:
        # Anything after it runs once the game has already announced itself as
        # up, which is the exact failure the call prevents.
        with tempfile.TemporaryDirectory() as tmp:
            lines = [ln for ln in self._bootstrap(Path(tmp)).splitlines() if ln.strip()]
            self.assertTrue(lines[-1].startswith("Debug.ready("), lines[-1])

    def test_it_still_exposes_the_debug_seam(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            self.assertIn("Debug.expose()", self._bootstrap(Path(tmp)))


class PreflightHubTests(unittest.TestCase):
    """The hub probe follows this workspace's hub.

    `serve` binds whatever `hub_url()` resolves: `RQE_HUB_URL` when it is set,
    otherwise `RQE_HUB_PORT`, otherwise 8790. A probe with the port baked in
    reports some other listener on 8790 as this workspace's hub, and reports
    this hub missing while it is listening on the port it was given.
    """

    def setUp(self) -> None:
        from rqe.security import TRUSTED_HUB_URLS_ENVIRONMENT
        from rqe.workspace import HUB_PORT_VARIABLE, HUB_URL_VARIABLE

        self._port = HUB_PORT_VARIABLE
        self._url = HUB_URL_VARIABLE
        self._trusted = TRUSTED_HUB_URLS_ENVIRONMENT
        self._saved = {
            key: os.environ.get(key)
            for key in (self._port, self._url, self._trusted)
        }

    def tearDown(self) -> None:
        for key, value in self._saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def _hub(self) -> preflight.Check:
        return next(item for item in preflight.checks() if item.name == "hub")

    def _listen(self) -> tuple[socket.socket, int]:
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.addCleanup(listener.close)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        return listener, listener.getsockname()[1]

    def _quiet_port(self) -> int:
        held = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        held.bind(("127.0.0.1", 0))
        port = held.getsockname()[1]
        held.close()
        return port

    def test_the_hub_check_probes_the_workspace_port(self) -> None:
        _listener, port = self._listen()
        os.environ.pop(self._url, None)
        os.environ[self._port] = str(port)

        answering = self._hub().run()
        self.assertTrue(answering.ok, answering.detail)
        self.assertEqual(answering.detail, f"answering on 127.0.0.1:{port}")

        _listener.close()
        missed = self._hub().run()
        self.assertFalse(missed.ok)
        self.assertEqual(missed.detail, f"nothing on 127.0.0.1:{port}")

    def test_the_hub_url_wins_and_an_unusable_address_does_not_pass(self) -> None:
        _listener, live = self._listen()
        quiet = self._quiet_port()
        os.environ[self._port] = str(quiet)
        os.environ[self._url] = f"http://127.0.0.1:{live}"

        answering = self._hub().run()
        self.assertTrue(answering.ok, answering.detail)
        self.assertEqual(answering.detail, f"answering on 127.0.0.1:{live}")

        os.environ.pop(self._trusted, None)
        os.environ[self._url] = "http://example.com:9"
        refused = self._hub().run()
        self.assertFalse(refused.ok)
        self.assertIn("not loopback", refused.detail)

        os.environ.pop(self._url, None)
        os.environ[self._port] = "nope"
        broken = self._hub().run()
        self.assertFalse(broken.ok)
        self.assertIn(self._port, broken.detail)


class PreflightRojoTests(unittest.TestCase):
    """`rojo --version` has to exit 0 before the toolchain counts as present."""

    def _probe(self, returncode: int, *, stdout: str = "", stderr: str = "") -> tuple[bool, str]:
        from subprocess import CompletedProcess
        from unittest.mock import patch

        completed = CompletedProcess(
            ["rojo", "--version"], returncode, stdout=stdout, stderr=stderr)
        with patch("forge.cli.preflight.shutil.which", return_value="rojo"), \
             patch("forge.cli.preflight.subprocess.run", return_value=completed):
            return preflight._rojo()

    def test_exit_zero_passes_and_any_other_exit_fails(self) -> None:
        ok, detail = self._probe(0, stdout="rojo 7.4.0\n")
        self.assertTrue(ok)
        self.assertEqual(detail, "rojo 7.4.0")

        bad, detail = self._probe(1, stderr="rojo: failed to start")
        self.assertFalse(bad)
        self.assertEqual(detail, "exit 1: rojo: failed to start")

        stdout_only, detail = self._probe(2, stdout="unusable rojo")
        self.assertFalse(stdout_only)
        self.assertEqual(detail, "exit 2: unusable rojo")


class PreflightLuauTests(unittest.TestCase):
    """A compiler file counts only after it compiles `return 1`."""

    def test_an_absent_compiler_stays_an_absence(self) -> None:
        from unittest.mock import patch

        missing = REPO / ".tools" / "luau" / "not-a-compiler-preflight-test"
        self.assertFalse(missing.exists())
        with patch("rqe.luau_check.compiler_path", return_value=missing), \
             patch("rqe.luau_check.compile_file") as compile_file:
            ok, detail = preflight._luau()
        self.assertFalse(ok)
        self.assertTrue(detail.startswith("absent at "), detail)
        self.assertIn(missing.name, detail)
        compile_file.assert_not_called()

    def test_a_clean_run_passes_and_a_failed_run_does_not(self) -> None:
        from unittest.mock import patch

        from rqe.luau_check import LUAU_VERSION, CompileFailure

        with tempfile.TemporaryDirectory() as tmp:
            compiler = Path(tmp) / "luau-compile"
            compiler.write_bytes(b"not a compiler")

            def clean(compiler_arg: Path, source: Path, **_kwargs: object) -> None:
                self.assertEqual(Path(compiler_arg), compiler)
                self.assertEqual(Path(source).read_text(encoding="utf-8").strip(), "return 1")
                self.source = Path(source)
                return None

            with patch("rqe.luau_check.compiler_path", return_value=compiler), \
                 patch("rqe.luau_check.compile_file", side_effect=clean):
                ok, detail = preflight._luau()
            self.assertTrue(ok, detail)
            self.assertEqual(detail, "compiler ran")
            self.assertNotIn(LUAU_VERSION, detail)
            self.assertFalse(self.source.exists())

            def broken(_compiler_arg: Path, source: Path, **_kwargs: object) -> CompileFailure:
                self.source = Path(source)
                return CompileFailure(Path(source), "parse error")

            with patch("rqe.luau_check.compiler_path", return_value=compiler), \
                 patch("rqe.luau_check.compile_file", side_effect=broken):
                bad, detail = preflight._luau()
            self.assertFalse(bad)
            self.assertEqual(detail, "parse error")
            self.assertFalse(self.source.exists())

            def will_not_start(_compiler_arg: Path, source: Path, **_kwargs: object) -> None:
                self.source = Path(source)
                raise OSError("exec format error")

            with patch("rqe.luau_check.compiler_path", return_value=compiler), \
                 patch("rqe.luau_check.compile_file", side_effect=will_not_start):
                spawned, detail = preflight._luau()
            self.assertFalse(spawned)
            self.assertIn("exec format error", detail)
            self.assertFalse(self.source.exists())


class PreflightRuntimeTests(unittest.TestCase):
    """A runtime file counts only after `return 1` exits 0."""

    def test_an_absent_runtime_stays_an_absence(self) -> None:
        from unittest.mock import patch

        missing = REPO / ".tools" / "luau" / "not-a-runtime-preflight-test"
        self.assertFalse(missing.exists())
        with patch("rqe.luau_harness.runtime_path", return_value=missing), \
             patch("forge.cli.preflight.subprocess.run") as run:
            ok, detail = preflight._runtime()
        self.assertFalse(ok)
        self.assertTrue(detail.startswith("absent at "), detail)
        self.assertIn(missing.name, detail)
        self.assertNotIn("present", detail)
        run.assert_not_called()

    def test_exit_zero_passes_and_a_failed_run_does_not(self) -> None:
        from subprocess import CompletedProcess, TimeoutExpired
        from unittest.mock import patch

        with tempfile.TemporaryDirectory() as tmp:
            runtime = Path(tmp) / "luau.exe"
            runtime.write_bytes(b"not a runtime")

            def clean(argv: list[str], **kwargs: object) -> CompletedProcess[str]:
                self.assertEqual(argv[0], str(runtime))
                script = Path(argv[1])
                self.assertEqual(script.suffix, ".luau")
                self.assertEqual(script.read_text(encoding="utf-8").strip(), "return 1")
                self.assertEqual(kwargs.get("capture_output"), True)
                self.assertEqual(kwargs.get("text"), True)
                self.assertEqual(kwargs.get("encoding"), "utf-8")
                self.assertEqual(kwargs.get("errors"), "replace")
                self.assertEqual(kwargs.get("timeout"), 20)
                self.script = script
                return CompletedProcess(argv, 0, stdout="present\n", stderr="")

            with patch("rqe.luau_harness.runtime_path", return_value=runtime), \
                 patch("forge.cli.preflight.subprocess.run", side_effect=clean):
                ok, detail = preflight._runtime()
            self.assertTrue(ok, detail)
            self.assertEqual(detail, "runtime ran")
            self.assertNotIn("present", detail)
            self.assertFalse(self.script.exists())

            def failed(argv: list[str], **_kwargs: object) -> CompletedProcess[str]:
                self.script = Path(argv[1])
                return CompletedProcess(argv, 1, stdout="", stderr="luau: failed to start")

            with patch("rqe.luau_harness.runtime_path", return_value=runtime), \
                 patch("forge.cli.preflight.subprocess.run", side_effect=failed):
                bad, detail = preflight._runtime()
            self.assertFalse(bad)
            self.assertEqual(detail, "exit 1: luau: failed to start")
            self.assertFalse(self.script.exists())

            def will_not_start(argv: list[str], **_kwargs: object) -> None:
                self.script = Path(argv[1])
                raise OSError("exec format error")

            with patch("rqe.luau_harness.runtime_path", return_value=runtime), \
                 patch("forge.cli.preflight.subprocess.run", side_effect=will_not_start):
                spawned, detail = preflight._runtime()
            self.assertFalse(spawned)
            self.assertIn("exec format error", detail)
            self.assertFalse(self.script.exists())

            def timed_out(argv: list[str], **_kwargs: object) -> None:
                self.script = Path(argv[1])
                raise TimeoutExpired(argv, 20)

            with patch("rqe.luau_harness.runtime_path", return_value=runtime), \
                 patch("forge.cli.preflight.subprocess.run", side_effect=timed_out):
                expired, detail = preflight._runtime()
            self.assertFalse(expired)
            self.assertIn("timed out", detail)
            self.assertFalse(self.script.exists())


class PreflightPluginTests(unittest.TestCase):
    """A filename that contains RQE is not the bridge plugin."""

    def _probe(self, local: str) -> tuple[bool, str]:
        from unittest.mock import patch

        with patch.dict(os.environ, {"LOCALAPPDATA": local}), \
             patch("forge.cli.preflight.platform.system", return_value="Windows"):
            return preflight._plugin()

    def test_only_the_installed_plugin_passes_and_a_rival_copy_fails(self) -> None:
        from rqe.hub.install import PLUGIN_FILENAME

        with tempfile.TemporaryDirectory() as tmp:
            plugins = Path(tmp) / "Roblox" / "Plugins"
            plugins.mkdir(parents=True)
            (plugins / "notes-RQE.txt").write_text("not a plugin", encoding="utf-8")
            missing, detail = self._probe(tmp)
            self.assertFalse(missing)
            self.assertIn(PLUGIN_FILENAME, detail)
            self.assertNotIn("notes-RQE.txt", detail)

            plugin = plugins / PLUGIN_FILENAME
            plugin.write_text("<roblox />", encoding="utf-8")
            ok, detail = self._probe(tmp)
            self.assertTrue(ok, detail)
            self.assertEqual(detail, PLUGIN_FILENAME)

            rival = plugins / (Path(PLUGIN_FILENAME).stem + ".rbxm")
            rival.write_bytes(b"stale")
            shadowed, detail = self._probe(tmp)
            self.assertFalse(shadowed)
            self.assertIn(rival.name, detail)


if __name__ == "__main__":
    unittest.main()
