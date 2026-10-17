import shutil
import tempfile
import unittest
from pathlib import Path

from tests.support import copy_project
from rqe.continuous import run_cycle


ROOT = Path(__file__).resolve().parents[1]


class ContinuousImprovementTests(unittest.TestCase):
    def test_single_cycle_writes_persistent_status(self):
        with tempfile.TemporaryDirectory() as directory:
            temp_root = Path(directory) / "project"
            copy_project(ROOT, temp_root)
            status = run_cycle(temp_root)
            self.assertEqual(status["status"], "BLOCKED")
            self.assertFalse(status["releaseAllowed"])
            self.assertEqual(status["qualityFocus"]["status"], "IMPROVE")
            self.assertTrue(
                any("visual" in gap["domain"] for gap in status["qualityFocus"]["gaps"]),
                status["qualityFocus"]["gaps"],
            )
            self.assertTrue(status["improvementActions"])
            self.assertTrue((temp_root / "reports/continuous-status.json").exists())
            self.assertTrue(status["reports"]["fixPlan"].endswith("fix-plan.md"))


if __name__ == "__main__":
    unittest.main()
