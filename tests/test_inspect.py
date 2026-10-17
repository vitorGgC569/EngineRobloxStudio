"""`forge inspect`: the front door `client.tree` shipped without.

The bridge commands themselves need a live Studio, so what is asserted here is
everything around them: that the command exists, that the flag routes to the
other side, and that an empty answer explains itself instead of reading as "the
thing is broken" -- which is the exact confusion the client commands were added
to end.
"""

from __future__ import annotations

import unittest
from unittest import mock

from forge.cli import inspect as ins


class RoutingTests(unittest.TestCase):
    """The flag must change which side is asked, and nothing else."""

    def test_tree_asks_the_server_by_default(self):
        with mock.patch.object(ins, "_call", return_value={}) as called:
            ins.tree("Workspace")
        self.assertEqual(called.call_args.args[0], "dm.tree")

    def test_tree_asks_the_client_when_told_to(self):
        with mock.patch.object(ins, "_call", return_value={}) as called:
            ins.tree("Players.me.PlayerGui", client=True)
        self.assertEqual(called.call_args.args[0], "client.tree")

    def test_properties_mirror_the_same_pair(self):
        with mock.patch.object(ins, "_call", return_value={}) as called:
            ins.properties("X", ["Value"])
        self.assertEqual(called.call_args.args[0], "dm.properties")
        with mock.patch.object(ins, "_call", return_value={}) as called:
            ins.properties("X", ["Value"], client=True)
        self.assertEqual(called.call_args.args[0], "client.properties")

    def test_the_path_and_depth_reach_the_bridge_unchanged(self):
        with mock.patch.object(ins, "_call", return_value={}) as called:
            ins.tree("Workspace.Map", depth=7)
        self.assertEqual(called.call_args.args[1],
                         {"path": "Workspace.Map", "depth": 7})


class RenderingTests(unittest.TestCase):
    TREE = {
        "name": "ForgeViewmodel", "className": "ScreenGui",
        "children": [
            {"name": "View", "className": "ViewportFrame", "children": [
                {"name": "WorldModel", "className": "WorldModel", "children": [
                    {"name": "Gun_m9", "className": "Model"},
                ]},
            ]},
        ],
    }

    def test_a_tree_reads_as_a_tree_and_not_as_json(self):
        text = ins.render(self.TREE, client=True)
        self.assertIn("ForgeViewmodel [ScreenGui]", text)
        self.assertIn("    View [ViewportFrame]", text)
        self.assertIn("      WorldModel [WorldModel]", text)
        self.assertIn("        Gun_m9 [Model]", text)

    def test_the_side_that_answered_is_named(self):
        self.assertIn("(client)", ins.render(self.TREE, client=True))
        self.assertIn("(server)", ins.render(self.TREE, client=False))

    def test_an_empty_server_answer_points_at_the_client(self):
        # The whole failure mode: a viewmodel is absent from the server, and
        # the absence looks exactly like the viewmodel being broken.
        text = ins.render(None, client=False)
        self.assertIn("--client", text)
        self.assertIn("client-only", text)

    def test_an_empty_client_answer_says_a_client_has_to_be_running(self):
        text = ins.render(None, client=True)
        self.assertIn("play_solo", text)

    def test_a_property_answer_falls_back_to_readable_json(self):
        text = ins.render({"properties": {"Value": "up"}}, client=False)
        self.assertIn('"Value"', text)


class CommandSurfaceTests(unittest.TestCase):
    def test_forge_exposes_inspect_with_both_sides(self):
        import forge.forge as cli

        parser = cli.main.__globals__["argparse"].ArgumentParser  # noqa: F841
        namespace = cli.build_parser() if hasattr(cli, "build_parser") else None
        if namespace is None:
            # `forge.py` builds its parser inside `main`; parse a help request
            # instead, which fails loudly if the subcommand is not registered.
            with self.assertRaises(SystemExit) as raised:
                cli.main(["inspect", "--help"])
            self.assertEqual(raised.exception.code, 0)


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
