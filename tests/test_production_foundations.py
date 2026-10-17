"""Run shipped Luau with explicit fault-injecting fakes, not Studio evidence."""
from pathlib import Path
import subprocess
import tempfile
import unittest

from rqe.luau_harness import runtime_path

ROOT = Path(__file__).resolve().parents[1]


class ProductionFoundationsTests(unittest.TestCase):
    def test_original_modules_under_faults(self):
        template = (ROOT / "tests/fixtures/production-foundations.luau").read_text(encoding="utf-8")
        for name in ("Save", "Net", "Nav", "Monetization"):
            code = (ROOT / f"forge/luau/Forge/{name}/init.lua").read_text(encoding="utf-8")
            template = template.replace(f"-- MODULE:{name}", code)
        template = template.replace("-- MODULE:GameKitSave", (ROOT / "roblox/lib/GameKit/Save.lua").read_text(encoding="utf-8"))
        template = template.replace("-- MODULE:JSON", (ROOT / "tools/luau-harness/json.luau").read_text(encoding="utf-8"))
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "foundations.luau"
            path.write_text(template, encoding="utf-8")
            result = subprocess.run([str(runtime_path(ROOT)), str(path)], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("FOUNDATIONS_PASS", result.stdout)


if __name__ == "__main__":
    unittest.main()
