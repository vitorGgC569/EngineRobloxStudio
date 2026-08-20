import unittest

from rqe.runtime import MvpGameRuntime


class RuntimeScenarioTests(unittest.TestCase):
    def test_purchase_is_idempotent_and_persists(self):
        runtime = MvpGameRuntime()
        trace = runtime.run_purchase_scenario()
        self.assertTrue(trace["navigationSuccess"])
        self.assertTrue(trace["firstPurchase"])
        self.assertFalse(trace["secondPurchase"])
        self.assertEqual(trace["currencyDelta"], -100)
        self.assertEqual(trace["inventoryDelta"], 1)
        self.assertTrue(trace["persistencePass"])

    def test_invalid_remote_payload_is_rejected(self):
        runtime = MvpGameRuntime()
        runtime.spawn_player(1)
        self.assertTrue(runtime.remote_security_probe(1))

    def test_plot_and_inventory_are_isolated(self):
        runtime = MvpGameRuntime()
        trace = runtime.run_purchase_scenario()
        self.assertTrue(trace["multiplayerIsolation"])

    def test_floor_purchase_and_card_equip_are_persisted(self):
        runtime = MvpGameRuntime()
        runtime.spawn_player(303)
        runtime.set_currency(303, 1000)
        self.assertTrue(runtime.purchase_basic_pack(303))
        self.assertTrue(runtime.purchase_floor(303))
        self.assertEqual(runtime.players[303].floor_level, 2)
        self.assertTrue(runtime.equip_card(303, "tunnel_mole"))
        runtime.disconnect(303)
        runtime.reconnect(303)
        self.assertEqual(runtime.players[303].floor_level, 2)
        self.assertEqual(runtime.players[303].active_card, "tunnel_mole")


if __name__ == "__main__":
    unittest.main()
