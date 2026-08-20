"""Guards for the upload-free WorldKit faceless threat primitive."""

from __future__ import annotations

import json
import unittest
from pathlib import Path

from rqe.luau_check import ToolchainUnavailable, compile_file, ensure_compiler
from rqe.luau_harness import run_or_raise


ROOT = Path(__file__).resolve().parents[1]
WORLDKIT = "roblox/lib/WorldKit"
SOURCE = ROOT / WORLDKIT / "Threat.lua"


def _tokens() -> dict:
    return json.loads((ROOT / "tokens/brickfarm.json").read_text(encoding="utf-8"))


class TestThreatPrimitive(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        try:
            cls.compiler = ensure_compiler(ROOT)
        except ToolchainUnavailable as exc:
            raise AssertionError(f"Luau toolchain unavailable: {exc}") from exc

    def values(self, body: str) -> dict:
        result = run_or_raise(
            ROOT,
            libraries=[WORLDKIT],
            body=body,
            data={"TOKENS": _tokens()},
        )
        decoded = result.json_lines()
        self.assertTrue(decoded, result.stdout)
        return decoded[-1]

    def test_source_compiles_with_the_pinned_luau_compiler(self) -> None:
        self.assertIsNone(compile_file(self.compiler, SOURCE))

    def test_threat_is_on_the_public_worldkit_surface(self) -> None:
        result = self.values(
            r'''
                local WorldKit = Require("WorldKit")
                local Threat = Require("Threat")
                print(string.format('{"exported":%s,"version":"%s"}',
                    tostring(WorldKit.Threat == Threat), WorldKit.VERSION))
            '''
        )
        self.assertTrue(result["exported"])
        self.assertEqual(result["version"], "2.2.0")

    def test_build_is_one_token_driven_model_with_a_primary_part(self) -> None:
        body = r'''
            local Tokens = Require("Tokens")
            local Threat = Require("Threat")
            local tokens = Tokens.define(TOKENS)
            local world = Instance.new("Folder")
            local model = Threat.build(world, tokens, {
                id = "pilgrim-1",
                cframe = CFrame.new(3, 4, 5),
                displayName = "The Pilgrim",
                seed = 17,
                showName = true,
                showHealth = true,
                health = 75,
                maxHealth = 100,
            })
            local rooted = model.PrimaryPart ~= nil and model.PrimaryPart.Name == "Root"
            local tokenDriven = true
            local visible = 0
            local allAnchored = true
            for _, child in ipairs(model:GetChildren()) do
                if child:IsA("BasePart") and child.Name ~= "Root" then
                    visible += 1
                    allAnchored = allAnchored and child.Anchored
                    local role = child:GetAttribute("WorldKitRole")
                    tokenDriven = tokenDriven and type(role) == "string"
                        and child.Color == tokens:color(role)
                        and child.Material == tokens:material(role)
                end
            end
            local status = model:FindFirstChild("Status")
            local face = model:FindFirstChild("Face")
            print(string.format(
                '{"model":%s,"rooted":%s,"visible":%d,"anchored":%s,"tokenDriven":%s,"status":%s,"faceless":%s,"id":"%s","x":%s}',
                tostring(model:IsA("Model")), tostring(rooted), visible,
                tostring(allAnchored), tostring(tokenDriven), tostring(status ~= nil),
                tostring(face ~= nil and face.Shape == Enum.PartType.Cylinder),
                model:GetAttribute("RQEThreatId"), tostring(model:GetAttribute("RQEThreatX"))))
        '''
        result = self.values(body)
        self.assertTrue(result["model"])
        self.assertTrue(result["rooted"])
        self.assertEqual(result["visible"], 8)
        self.assertTrue(result["anchored"])
        self.assertTrue(result["tokenDriven"])
        self.assertTrue(result["status"])
        self.assertTrue(result["faceless"])
        self.assertEqual(result["id"], "pilgrim-1")
        self.assertEqual(result["x"], 3)

    def test_pivot_moves_the_model_surface_not_an_individual_body_part(self) -> None:
        body = r'''
            local Tokens = Require("Tokens")
            local Threat = Require("Threat")
            local tokens = Tokens.define(TOKENS)
            local world = Instance.new("Folder")
            local model = Threat.build(world, tokens, {
                id = "moving-threat", cframe = CFrame.new(0, 3, 0),
            })
            local before = model:GetAttribute("RQEThreatRevision")
            Threat.pivot(model, CFrame.new(21, 6, -14))
            local pivot = model.Pivot
            print(string.format(
                '{"x":%s,"y":%s,"z":%s,"attributeX":%s,"revisionMoved":%s,"primary":"%s"}',
                tostring(pivot.Position.X), tostring(pivot.Position.Y), tostring(pivot.Position.Z),
                tostring(model:GetAttribute("RQEThreatX")),
                tostring(model:GetAttribute("RQEThreatRevision") > before), model.PrimaryPart.Name))
        '''
        result = self.values(body)
        self.assertEqual((result["x"], result["y"], result["z"]), (21, 6, -14))
        self.assertEqual(result["attributeX"], 21)
        self.assertTrue(result["revisionMoved"])
        self.assertEqual(result["primary"], "Root")

    def test_health_attributes_and_optional_bar_change_together(self) -> None:
        body = r'''
            local Tokens = Require("Tokens")
            local Threat = Require("Threat")
            local tokens = Tokens.define(TOKENS)
            local world = Instance.new("Folder")
            local model = Threat.build(world, tokens, {
                id = "hurt-threat", cframe = CFrame.new(0, 3, 0),
                showHealth = true, maxHealth = 80,
            })
            local fraction = Threat.setHealth(model, 20)
            local status = model:FindFirstChild("Status")
            local track = status and status:FindFirstChild("HealthTrack")
            local fill = track and track:FindFirstChild("Fill")
            local size = fill and fill.Size.X.Scale or -1
            Threat.setHealth(model, -30)
            print(string.format(
                '{"fraction":%s,"size":%s,"health":%s,"max":%s,"alive":%s}',
                tostring(fraction), tostring(size), tostring(model:GetAttribute("RQEThreatHealth")),
                tostring(model:GetAttribute("RQEThreatMaxHealth")),
                tostring(model:GetAttribute("RQEThreatAlive"))))
        '''
        result = self.values(body)
        self.assertEqual(result["fraction"], 0.25)
        self.assertEqual(result["size"], 0.25)
        self.assertEqual(result["health"], 0)
        self.assertEqual(result["max"], 80)
        self.assertFalse(result["alive"])

    def test_status_is_absent_unless_requested_and_bad_roles_fail_closed(self) -> None:
        body = r'''
            local Tokens = Require("Tokens")
            local Threat = Require("Threat")
            local tokens = Tokens.define(TOKENS)
            local world = Instance.new("Folder")
            local quiet = Threat.build(world, tokens, {
                id = "quiet", cframe = CFrame.new(0, 3, 0),
            })
            local ok, message = pcall(function()
                Threat.build(world, tokens, {
                    id = "bad", cframe = CFrame.new(0, 3, 0), bodyRole = "almostInk",
                })
            end)
            print(string.format(
                '{"status":%s,"accepted":%s,"namesRole":%s}',
                tostring(quiet:FindFirstChild("Status") ~= nil), tostring(ok),
                tostring(string.find(tostring(message), "bodyRole") ~= nil)))
        '''
        result = self.values(body)
        self.assertFalse(result["status"])
        self.assertFalse(result["accepted"])
        self.assertTrue(result["namesRole"])


if __name__ == "__main__":
    unittest.main()
