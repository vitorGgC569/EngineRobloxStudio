"""Unit tests for Open Cloud DataStore test harness."""

import unittest
from rqe.cloud.datastore_harness import DatastoreHarness, SimulatedDatastoreBackend
from rqe.cloud.open_cloud import OpenCloudClient, Outcome


class TestOpenCloudDatastoreHarness(unittest.TestCase):
    def test_simulated_datastore_harness_full_cycle_passes(self):
        harness = DatastoreHarness(simulated=True)
        receipt = harness.run_test_session(
            universe_id="12345678",
            datastore="TestPersistenceStore",
            run_id="run-test-ds-001",
        )
        self.assertTrue(receipt.ok)
        self.assertEqual(receipt.status, "PASS")
        self.assertEqual(receipt.outcome, Outcome.OK.value)
        self.assertTrue(receipt.data_integrity)
        self.assertEqual(len(receipt.operations), 5)
        op_names = [op.operation for op in receipt.operations]
        self.assertEqual(
            op_names,
            ["set_entry", "get_entry", "update_entry", "verify_update", "delete_entry"]
        )
        self.assertEqual(receipt.persisted_payload["currency"], 900)
        self.assertEqual(receipt.persisted_payload["floorLevel"], 2)

    def test_unauthenticated_cloud_client_reports_blocked(self):
        client = OpenCloudClient(environment={})
        harness = DatastoreHarness(client=client, simulated=False)
        receipt = harness.run_test_session(
            universe_id="12345678",
            datastore="TestPersistenceStore",
            run_id="run-test-ds-002",
        )
        self.assertFalse(receipt.ok)
        self.assertEqual(receipt.status, "BLOCKED")
        self.assertEqual(receipt.outcome, Outcome.BLOCKED.value)
        self.assertTrue(any("ROBLOX_OPEN_CLOUD_KEY" in b for b in receipt.blockers))


if __name__ == "__main__":
    unittest.main()
