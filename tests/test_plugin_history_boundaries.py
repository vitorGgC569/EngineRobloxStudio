from __future__ import annotations
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
COMMANDS=ROOT/"apps"/"studio-plugin"/"src"/"Commands"

def test_transform_mutations_are_change_history_transactions():
    text=(COMMANDS/"Transform.lua").read_text(encoding="utf-8")
    assert 'require(script.Parent.Parent.History)' in text
    for name in ("move","orient","align","snap","settle"):
        assert f'History.record("RQE transform.{name}"' in text

def test_terrain_writes_are_change_history_transactions_but_reads_are_not_forced():
    text=(COMMANDS/"Terrain.lua").read_text(encoding="utf-8")
    assert 'require(script.Parent.Parent.History)' in text
    assert 'if mode=="write" or mode=="clear" then' in text
    assert 'History.record("RQE world.terrain "..mode' in text
    assert 'return terrainImpl(params)' in text
