"""Executable contract for WorldKit's reusable authored setpieces."""

from __future__ import annotations

import json
import unittest
from pathlib import Path

from rqe.luau_check import ToolchainUnavailable, ensure_compiler
from rqe.luau_harness import run_or_raise


ROOT = Path(__file__).resolve().parents[1]
WORLDKIT = "roblox/lib/WorldKit"


def _tokens() -> dict:
    return json.loads((ROOT / "tokens/brickfarm.json").read_text(encoding="utf-8"))


class TestRuinedSanctuary(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        try:
            ensure_compiler(ROOT)
        except ToolchainUnavailable as exc:
            raise AssertionError(f"Luau runtime unavailable: {exc}") from exc

    def values(self, body: str) -> dict:
        result = run_or_raise(
            ROOT, libraries=(WORLDKIT,), body=body, data={"TOKENS": _tokens()}
        )
        decoded = result.json_lines()
        self.assertTrue(decoded, result.stdout)
        return decoded[-1]

    def test_builds_an_open_playable_gothic_composition(self) -> None:
        result = self.values(
            """
            local Tokens = Require("Tokens")
            local Setpiece = Require("Setpiece")
            local tokens = Tokens.define(TOKENS)
            local world = Instance.new("Folder")
            local built = Setpiece.ruinedSanctuary(world, tokens, {
                cframe = CFrame.new(30, 0, -40) * CFrame.Angles(0, math.rad(25), 0),
                seed = 17,
                focusKind = "altar",
                bays = 4,
            })
            local ribs, rubble = 0, 0
            for _, item in ipairs(built.model:GetDescendants()) do
                if item.Name == "ArcRib" then ribs += 1 end
                if item.Name == "Rubble" then rubble += 1 end
            end
            print(string.format(
                '{"parts":%d,"pillars":%d,"arches":%d,"ribs":%d,"broken":%d,"rubble":%d,'
                .. '"open":%s,"clear":%.1f,"focus":"%s","focusRole":"%s","entryRole":"%s",'
                .. '"primary":%s}',
                built.parts, built.pillars, built.arches, ribs, built.brokenWalls, rubble,
                tostring(built.model:GetAttribute("OpenRoof")),
                built.model:GetAttribute("NaveClearWidth"), built.focus:GetAttribute("FocusKind"),
                built.focus:GetAttribute("RQESetpieceRole"),
                built.entrance:GetAttribute("RQESetpieceRole"),
                tostring(built.model.PrimaryPart == built.nave)))
            """
        )
        self.assertGreater(result["parts"], 70)
        self.assertEqual(result["pillars"], 10)
        self.assertEqual(result["arches"], 8)
        self.assertEqual(result["ribs"], 16)
        self.assertGreaterEqual(result["broken"], 20)
        self.assertEqual(result["rubble"], 8)
        self.assertTrue(result["open"])
        self.assertGreaterEqual(result["clear"], _tokens()["scale"]["grammar"]["corridorWidth"])
        self.assertEqual(result["focus"], "altar")
        self.assertEqual(result["focusRole"], "focus")
        self.assertEqual(result["entryRole"], "entrance")
        self.assertTrue(result["primary"])

    def test_bell_is_an_asset_free_alternate_focus(self) -> None:
        result = self.values(
            """
            local Tokens = Require("Tokens")
            local Setpiece = Require("Setpiece")
            local tokens = Tokens.define(TOKENS)
            local root = Instance.new("Folder")
            local built = Setpiece.ruinedSanctuary(root, tokens, {
                focusKind = "bell", seed = 9,
            })
            print(string.format('{"name":"%s","kind":"%s","collidable":%s,"models":%d}',
                built.focus.Name, built.focus:GetAttribute("FocusKind"),
                tostring(built.focus.CanCollide), Harness.countClass(root, "Model")))
            """
        )
        self.assertEqual(result["name"], "Bell")
        self.assertEqual(result["kind"], "bell")
        self.assertTrue(result["collidable"])
        self.assertEqual(result["models"], 1)

    def test_invalid_dimensions_fail_without_leaving_partial_geometry(self) -> None:
        result = self.values(
            """
            local Tokens = Require("Tokens")
            local Setpiece = Require("Setpiece")
            local tokens = Tokens.define(TOKENS)
            local root = Instance.new("Folder")
            local ok, message = pcall(function()
                Setpiece.ruinedSanctuary(root, tokens, { width = 12 })
            end)
            print(string.format('{"ok":%s,"parts":%d,"named":%s}', tostring(ok),
                Harness.countClass(root, "BasePart"),
                tostring(string.find(tostring(message), "playable minimum") ~= nil)))
            """
        )
        self.assertFalse(result["ok"])
        self.assertEqual(result["parts"], 0)
        self.assertTrue(result["named"])

    def test_source_has_no_game_or_uploaded_asset_dependency(self) -> None:
        source = (ROOT / "roblox/lib/WorldKit/Setpiece.lua").read_text(encoding="utf-8")
        self.assertNotIn("rbxassetid://", source.casefold())
        self.assertNotIn("last-vigil", source.casefold())
        self.assertNotIn("games/", source.casefold())


if __name__ == "__main__":
    unittest.main()
