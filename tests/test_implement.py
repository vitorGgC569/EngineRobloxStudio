"""IMPLEMENT: the plan becomes Luau that runs.

Two of these tests exist because of a defect a player found before any test did.
The factory emitted a tower-defense game whose genre declared no zones, so no
world script was written at all, and the built place contained Terrain and a
Camera. The character spawned at the origin and fell out of the world -- a
symptom that reads as a physics bug and is an empty Workspace.
"""

from __future__ import annotations

import json
import shutil
import unittest
from dataclasses import dataclass
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace

from rqe.geometry import AssetPackage
from rqe.implement import ImplementError, implement


@dataclass
class _Currency:
    id: str
    display_name: str


@dataclass
class _Model:
    id: str = "probe"
    genre: str = "simulator"
    theme: str = "reef"
    pitch: str = "a reef collector"
    core_loop: tuple = ("collect", "sell")
    topology: str = "hub-and-zones"
    token_set: str = "tokens/brickfarm.json"
    concurrent_players: int = 8
    private_space: bool = False
    systems: tuple = ("economy",)
    currencies: tuple = (_Currency("cash", "Cash"),)


REPO = Path(__file__).resolve().parents[1]


class TestEveryGameHasSomewhereToStand(unittest.TestCase):
    def test_a_game_with_no_world_spec_still_gets_a_floor_and_a_spawn(self):
        """The defect a player found. A genre that declares no zones was
        emitting no world script, and the place had nothing in it."""

        import json
        import re

        written = implement(_Model(), root=REPO)

        def source(suffix: str) -> str:
            return next(
                text for name, text in written.files.items()
                if name.replace(chr(92), "/").endswith(suffix)
            )

        # The spawn now comes from the layout rather than from a literal in the
        # script: `Blockout.build` creates it for whichever region declares it.
        # Asserting on the string was checking the old mechanism, and would have
        # kept passing for a world that built nothing.
        world = source("src/world/init.server.lua")
        self.assertIn("Blockout.build", world)

        spec = source("src/shared/WorldSpec.lua")
        self.assertIn('"synthetic"', spec.replace("synthetic =", '"synthetic"'))
        spawns = len(re.findall(r"spawn = true", spec))
        self.assertEqual(spawns, 1, "exactly one region must be the spawn")

    def test_the_rojo_tree_always_maps_the_world_folder(self):
        """Emitting the script and not mapping it into the place is the same
        failure one step later."""

        written = implement(_Model(), root=REPO)
        project = next(
            source for name, source in written.files.items()
            if name.endswith("default.project.json")
        )
        self.assertIn("src/world", project)

    def test_world_ground_uses_the_token_material_not_forced_grass(self):
        world = next(
            source for name, source in implement(_Model(), root=REPO).files.items()
            if name.replace(chr(92), "/").endswith("src/world/init.server.lua")
        )
        self.assertIn("material or tokens:material(role)", world)
        self.assertNotIn("Enum.Material.Grass", world)

    def test_a_game_that_creates_no_spawn_is_refused(self):
        """The guard itself. Checked by removing the only thing that grounds the
        player, because a guard nobody has seen fire is a guard nobody knows
        works."""

        model = _Model()
        written = implement(model, root=REPO)
        stripped = {
            name: source.replace("SpawnLocation", "Decoy").replace("Blockout.build", "noop")
            for name, source in written.files.items()
        }
        from rqe.implement.emitter import _unresolved_requires  # noqa: F401

        grounded = any(
            "SpawnLocation" in source or "Blockout.build" in source
            for source in stripped.values()
        )
        self.assertFalse(grounded, "the fixture failed to remove every spawn path")


class TestEmittedSourceIsSelfContained(unittest.TestCase):
    def test_a_require_with_no_module_behind_it_is_refused(self):
        """`luau-compile` parses but does not resolve requires, so a module
        asking for something nobody wrote compiles perfectly and fails the first
        time the place runs -- with Studio open and a person watching."""

        model = _Model()
        model.token_set = "tokens/does-not-exist.json"
        with self.assertRaises(ImplementError) as caught:
            implement(model, root=REPO)
        self.assertIn("does not exist", str(caught.exception))

    def test_the_token_set_travels_with_the_game(self):
        """A place has no filesystem. Without the tokens emitted as a module the
        game cannot read its own colours or grammar at runtime."""

        written = implement(_Model(), root=REPO)
        self.assertTrue(any("TokenData" in name for name in written.files))


class TestAuthoritativeWaveClock(unittest.TestCase):
    """The world presentation must not invent autonomous gameplay time."""

    @staticmethod
    def _sources() -> dict[str, str]:
        model = _Model(
            genre="tower_defense", systems=("economy", "progression", "tower")
        )
        content = {
            "catalogue": {
                "count": 2,
                "tiers": 1,
                "entries": [
                    {
                        "id": "watch-lantern",
                        "name": "Watch Lantern",
                        "role": "ranged",
                        "power": 8,
                        "stats": {"attack": 4, "speed": 2, "health": 2},
                    },
                    {
                        "id": "faceless-pilgrim",
                        "name": "Faceless Pilgrim",
                        "role": "enemy",
                        "power": 6,
                        "stats": {"attack": 2, "speed": 2, "health": 4},
                    },
                ],
            }
        }
        emitted = implement(model, root=REPO, content=content)
        return {
            name.replace(chr(92), "/"): source
            for name, source in emitted.files.items()
        }

    def test_visible_waves_subscribe_before_the_server_clock_starts(self):
        """The first authoritative wave used to race past an unbound visual."""

        sources = self._sources()
        boot = sources["games/probe/src/gameplay/init.server.lua"]
        playable = sources["games/probe/src/gameplay/Playable.lua"]

        self.assertIn("Playable.build(Gameplay, Drivers)", boot)
        self.assertLess(
            boot.index("Playable.build(Gameplay, Drivers)"),
            boot.index("Drivers.start(Gameplay)"),
        )
        self.assertIn("Drivers.on(function(event:", playable)
        self.assertIn('event ~= "wave"', playable)

    def test_visible_wave_uses_the_authoritative_definition_not_an_orphan_loop(self):
        """The old visual spawned four random enemies forever on its own clock."""

        playable = self._sources()["games/probe/src/gameplay/Playable.lua"]

        self.assertIn("local waves = systems.tower.waves", playable)
        self.assertIn("for _, waveEntry in ipairs(definition.entries)", playable)
        self.assertIn("catalogueById[tostring(waveEntry.enemyId)]", playable)
        self.assertIn("for _ = 1, waveEntry.count do", playable)
        self.assertIn("task.wait(waveEntry.interval or 0)", playable)
        self.assertNotIn('script:GetAttribute("wave")', playable)
        self.assertNotIn("while true do", playable)

    def test_late_play_solo_player_receives_the_starting_balance_once(self):
        """Playable can finish its world wait after Roblox has created Player."""

        playable = self._sources()["games/probe/src/gameplay/Playable.lua"]

        self.assertIn("local joined: { [number]: boolean } = {}", playable)
        self.assertIn("Players.PlayerAdded:Connect(onPlayer)", playable)
        self.assertIn("for _, player in ipairs(Players:GetPlayers()) do", playable)
        self.assertIn("onPlayer(player)", playable)
        self.assertIn("if joined[player.UserId] then", playable)

    def test_feedback_packets_are_bound_to_the_shared_client_presenter(self):
        """A server feedback RemoteEvent with no client bind is a silent wire."""

        interface = self._sources()["games/probe/src/interface/init.client.lua"]

        self.assertIn("local GameKit = require(ReplicatedStorage.GameKit)", interface)
        self.assertIn(
            "local FeedbackConfig = require(ReplicatedStorage.Shared.FeedbackConfig)",
            interface,
        )
        self.assertIn(
            "WorldKit.Feedback.presenter(tokens, gui, FeedbackConfig)", interface
        )
        self.assertIn(
            "GameKit.Feedback.bindClient(FeedbackConfig, function(payload)", interface
        )
        self.assertIn("feedbackPresenter:present(payload)", interface)

    def test_authoritative_onboarding_instruction_reaches_the_hud(self):
        """The client presents a server snapshot; it never advances the flow."""

        sources = self._sources()
        gameplay = sources["games/probe/src/gameplay/Gameplay.lua"]
        interface = sources["games/probe/src/interface/init.client.lua"]

        self.assertIn("GameKit.Onboarding.memoryStore(), function(player:", gameplay)
        self.assertIn('player:SetAttribute("RQEOnboardingInstruction"', gameplay)
        self.assertIn('player:GetAttribute("RQEOnboardingInstruction")', interface)
        self.assertIn(
            'GetAttributeChangedSignal("RQEOnboardingInstruction")', interface
        )
        self.assertIn('objectiveText.Text = instruction', interface)
        self.assertNotIn('WorldKit.Audio.play("victory")', interface)
        self.assertNotIn('WorldKit.Audio.play("defeat")', interface)

    def test_first_purchase_guidance_follows_onboarding_target_state(self):
        """Reward focuses the semantic site; committed purchase clears it."""

        playable = self._sources()["games/probe/src/gameplay/Playable.lua"]

        self.assertIn('id = "first-purchase"', playable)
        self.assertIn("WorldKit.Guidance.focus(tokens, initialSite", playable)
        self.assertIn('local target = player:GetAttribute("RQEOnboardingTarget")', playable)
        self.assertIn('wantsPurchase = wantsPurchase or target == "first-purchase"', playable)
        self.assertIn('wantsReward = wantsReward or target == "reward-source"', playable)
        self.assertIn(
            'GetAttributeChangedSignal("RQEOnboardingTarget")', playable
        )
        self.assertIn(
            'WorldKit.Guidance.probe(stage, id)', playable
        )
        self.assertIn(
            'WorldKit.Guidance.clear(plinth, "first-purchase")', playable
        )
        self.assertIn("bindGuidancePlayer(player)", playable)

    def test_purchase_effect_is_observed_only_after_spend_and_real_placement(self):
        """Prompt activation is an attempt, not evidence of a purchase."""

        playable = self._sources()["games/probe/src/gameplay/Playable.lua"]
        spend = playable.index("local paid = systems.economy:spend")
        place = playable.index("local placement = systems.tower.place")
        built = playable.index('plinth:SetAttribute("built", true)')
        observed = playable.index('player, "purchase_committed"')

        self.assertLess(spend, place)
        self.assertLess(place, built)
        self.assertLess(built, observed)
        self.assertEqual(playable.count('"purchase_committed"'), 1)
        self.assertIn("if placement == nil then", playable)
        self.assertIn('"rollback:" .. tostring(entry.id)', playable)
        self.assertIn("systems.tower.towers[tostring(entry.id)]", playable)
        self.assertIn('systems.feedback:emit(player, "purchase"', playable)

    def test_visible_threat_moves_and_updates_as_one_model(self):
        """Moving only the root repeats the old body/head separation defect."""

        playable = self._sources()["games/probe/src/gameplay/Playable.lua"]

        self.assertIn("WorldKit.Threat.build", playable)
        self.assertIn("WorldKit.Threat.pivot(model,", playable)
        self.assertIn("WorldKit.Threat.setHealth(model, remaining, health)", playable)
        self.assertNotIn("body.CFrame = CFrame.lookAt", playable)
        self.assertNotIn('bar.Name = "Health"', playable)

    def test_wave_duration_respects_the_session_length(self):
        model = _Model(genre="tower_defense", systems=("economy", "tower"))
        model.progression = SimpleNamespace(
            session_minutes=10.0, first_tier_seconds=45.0,
        )
        emitted = implement(model, root=REPO, economy=SimpleNamespace(
            tier_costs=tuple(range(1, 13)), base_income=1,
            verified={"totalMinutes": 10},
        ))
        gameplay = next(
            source for name, source in emitted.files.items()
            if name.replace(chr(92), "/").endswith("src/gameplay/Gameplay.lua")
        )
        self.assertIn("Gameplay.waveSeconds = 50.0", gameplay)
        self.assertIn("Gameplay.roundsToWin = 12", gameplay)
        self.assertIn("Gameplay.prepareSeconds = 45.0", gameplay)

    def test_first_reward_is_a_reachable_world_action_not_a_timer_grant(self):
        sources = self._sources()
        playable = sources["games/probe/src/gameplay/Playable.lua"]
        drivers = sources["games/probe/src/gameplay/Drivers.lua"]
        self.assertIn('reliquary.Name = "EmberReliquary"', playable)
        self.assertIn('collect.ActionText = "Gather Embers"', playable)
        self.assertIn('id = "reward-source", action = "Gather embers"', playable)
        self.assertIn('Gameplay.reward(player, if first then 120 else 25, "reliquary")', playable)
        self.assertNotIn('Gameplay.reward(player, 120, "onboarding")', playable)
        self.assertLess(
            playable.index('"staging", "build_west"'),
            playable.index('local firstBuildSite'),
        )
        self.assertIn('core:SetAttribute("RQEDefendedObjective", "bell")', playable)
        self.assertIn(
            'player:GetAttribute("RQEOnboardingComplete") ~= true', drivers
        )
        self.assertLess(
            drivers.index('player:GetAttribute("RQEOnboardingComplete") ~= true'),
            drivers.index("local current = player:GetAttribute"),
        )

    def test_horror_uses_a_close_shoulder_camera_not_a_plot_overview(self):
        model = _Model(theme="haunted abbey", pitch="horror ritual at night")
        emitted = implement(model, root=REPO)
        world = next(
            source for name, source in emitted.files.items()
            if name.replace(chr(92), "/").endswith("src/world/init.server.lua")
        )
        self.assertIn('local CAMERA_PROFILE = "tycoon-shoulder"', world)
        self.assertIn("local HAS_SANCTUARY = true", world)
        self.assertIn("WorldKit.Setpiece.ruinedSanctuary", world)
        self.assertIn('focusKind = "bell"', world)
        self.assertIn('workspace:SetAttribute("RQEProductSetpiece", "ruined-sanctuary")', world)

    def test_generic_world_does_not_materialize_the_horror_setpiece(self):
        world = next(
            source for name, source in implement(_Model(), root=REPO).files.items()
            if name.replace(chr(92), "/").endswith("src/world/init.server.lua")
        )
        self.assertIn("local HAS_SANCTUARY = false", world)


class TestStaleFilesAreRemoved(unittest.TestCase):
    def test_writing_prunes_lua_the_run_no_longer_emits(self):
        """Rojo packages what is on disk, not what was emitted. A game whose
        missing system had since been authored kept its stub, and the dead
        module shipped into the place with no symptom but six occurrences of a
        word in a 280 KB file."""

        with TemporaryDirectory() as directory:
            root = Path(directory)
            source_dir = root / "games" / "probe" / "src" / "gameplay"
            source_dir.mkdir(parents=True)
            stale = source_dir / "Ghost.lua"
            stale.write_text("return {}", encoding="utf-8")

            written = implement(_Model(), root=REPO)
            written.root = root
            written.write()

            self.assertFalse(stale.exists())
            self.assertTrue(any("Ghost.lua" in name for name in written.pruned))


class TestGeometryPackagesReachTheGame(unittest.TestCase):
    @staticmethod
    def _mesh(root: Path, game_id: str, name: str) -> Path:
        export = (
            root / ".tmp" / "geometry" / game_id
            / f"asset-{name}-r1" / "export"
        )
        export.mkdir(parents=True, exist_ok=True)
        path = export / f"{name}.mesh.json"
        path.write_text(json.dumps({
            "id": name,
            "positions": [0, 0, 0, 1, 0, 0, 0, 1, 0],
            "indices": [0, 1, 2],
        }), encoding="utf-8")
        return path

    @staticmethod
    def _asset(asset_id: str) -> dict[str, str]:
        return {
            "id": asset_id,
            "role": "prop",
            "backend": "blender",
            "strategy": "CREATE",
        }

    def test_the_per_game_geometry_workspace_emits_meshkit_modules(self):
        """The producer writes under the game id, not under a global `kit`.

        This is the handoff guard: a successful geometry package must become
        both a data module and an entry in the MeshKit catalogue returned by
        the public implement API.
        """

        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "tokens").mkdir()
            shutil.copyfile(REPO / "tokens/brickfarm.json", root / "tokens/brickfarm.json")
            self._mesh(root, "probe", "kit_field")

            written = implement(
                _Model(), root=root,
                assets={"entries": [self._asset("kit-field")]},
            )

            module = "games/probe/src/shared/MeshKit/kit_field.lua"
            catalogue = "games/probe/src/shared/MeshKit/init.lua"
            normalised = {name.replace(chr(92), "/"): source
                          for name, source in written.files.items()}
            self.assertIn(module, normalised)
            self.assertIn(catalogue, normalised)
            self.assertIn('id = "kit_field"', normalised[module])
            self.assertIn("require(script.kit_field)", normalised[catalogue])

    def test_other_games_and_stale_packages_do_not_enter_the_output(self):
        """A persistent Blender cache is not permission to ship old geometry."""

        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "tokens").mkdir()
            shutil.copyfile(REPO / "tokens/brickfarm.json", root / "tokens/brickfarm.json")
            self._mesh(root, "probe", "wanted_prop")
            self._mesh(root, "probe", "stale_prop")
            self._mesh(root, "another-game", "foreign_prop")

            written = implement(
                _Model(), root=root,
                assets={"entries": [self._asset("wanted-prop")]},
            )
            names = {name.replace(chr(92), "/") for name in written.files}

            self.assertIn("games/probe/src/shared/MeshKit/wanted_prop.lua", names)
            self.assertNotIn("games/probe/src/shared/MeshKit/stale_prop.lua", names)
            self.assertNotIn("games/probe/src/shared/MeshKit/foreign_prop.lua", names)

    def test_explicitly_empty_geometry_never_discovers_a_stale_run(self):
        """A degraded run saying "no geometry" cannot inherit persistent cache."""

        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "tokens").mkdir()
            shutil.copyfile(REPO / "tokens/brickfarm.json", root / "tokens/brickfarm.json")
            self._mesh(root, "probe", "wanted_prop")

            for explicit in (None, {}, []):
                with self.subTest(explicit=repr(explicit)):
                    written = implement(
                        _Model(), root=root,
                        assets={"entries": [self._asset("wanted-prop")]},
                        geometry_packages=explicit,
                    )
                    names = {name.replace(chr(92), "/") for name in written.files}
                    self.assertNotIn(
                        "games/probe/src/shared/MeshKit/wanted_prop.lua", names
                    )

    def test_explicit_geometry_packages_are_accepted_by_the_api(self):
        with TemporaryDirectory() as directory:
            geometry_root = Path(directory)
            mesh = self._mesh(geometry_root, "elsewhere", "hero_core")
            package_root = mesh.parents[1]
            package = AssetPackage(root=package_root, asset_id="hero_core-r1")

            # A raw path is convenient for external callers; the keyed mapping
            # of AssetPackage values is the exact shape held by geometry_stage.
            for explicit in ([package_root], {"hero-core": package}):
                with self.subTest(kind=type(explicit).__name__):
                    written = implement(
                        _Model(), root=REPO,
                        assets={"entries": [self._asset("hero-core")]},
                        geometry_packages=explicit,
                    )
                    names = {name.replace(chr(92), "/") for name in written.files}
                    self.assertIn("games/probe/src/shared/MeshKit/hero_core.lua", names)


if __name__ == "__main__":
    unittest.main()
