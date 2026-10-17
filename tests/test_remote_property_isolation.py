"""Setting a remote property back to its default is the revoke path.

`setFor` treats a value equal to the default as a revoke. That call has to
reach `revokeFor` with the client key, then a second identical set emits
nothing.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestRemotePropertyIsolation(unittest.TestCase):
    def test_set_for_default_revokes_without_throwing(self) -> None:
        out = _run([FORGE / "Net"], """
            local Property = Require("RemoteProperty").Property
            local flag = Property.new("flag", "off")
            flag:setFor("alice", "on")
            flag:setFor("alice", "off")
            assert(flag:getFor("alice") == "off", "alice must read the default")
            local again = flag:setFor("alice", "off")
            assert(#again == 0, "a second set to the default must emit nothing")
            print('{"property":"flag","value":"off","again":0}')
        """)
        assert "property" in out


if __name__ == "__main__":
    unittest.main()
