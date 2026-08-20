import unittest

from rqe.contract import validate_contract
from rqe.project import Project


class ContractTests(unittest.TestCase):
    def test_mvp_contract_is_valid(self):
        project = Project.load(".")
        self.assertEqual(validate_contract(project.contract), [])

    def test_contract_rejects_duplicate_ids(self):
        contract = {
            "game": {"name": "x", "genre": "tycoon", "max_players": 1},
            "requirements": [
                {"id": "same", "probe": "x", "type": "gameplay", "severity": "critical"},
                {"id": "same", "probe": "y", "type": "gameplay", "severity": "critical"},
            ],
        }
        self.assertTrue(any("duplicate" in issue for issue in validate_contract(contract)))

    def test_product_truth_cannot_bind_an_unknown_requirement(self):
        project = Project.load(".")
        contract = dict(project.contract)
        contract["productId"] = "generic-product"
        contract["productTruth"] = {
            "intentId": "generic-product.intent",
            "semanticBindings": {
                "worldRoles": {"primary-landmark": ["does_not_exist"]},
                "uiSurfaces": {"initial-interface": ["does_not_exist"]},
                "gameplayVerbs": {"collect": ["does_not_exist"]},
            },
        }
        self.assertTrue(any(
            "unknown requirements" in issue for issue in validate_contract(contract)
        ))


if __name__ == "__main__":
    unittest.main()
