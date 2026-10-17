"""A blocked result outbox must drop the session, the way a failed poll does.

The hub answers an unknown session with HTTP 409 on /bridge/result and on
/bridge/poll. Poll calls transport:disconnect(), so the next cycle runs the
handshake. The outbox path used to wait and retry the same session, which
never reaches poll, so a restarted hub left the bridge wedged with results
it could not deliver.
"""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INIT = ROOT / "apps" / "studio-plugin" / "src" / "init.server.lua"


def _between(source: str, start: str, end: str) -> str:
    return source[source.index(start):source.index(end)]


def test_result_failure_disconnects_before_retrying() -> None:
    source = INIT.read_text(encoding="utf-8")
    loop = _between(source, "local function loop()", "local function flusher()")

    flush_fail = loop.index("if not flushPending(transport, pending) then")
    after_flush = loop.index("local currentContext = Runtime.context()", flush_fail)
    branch = loop[flush_fail:after_flush]

    assert "transport:disconnect()" in branch
    assert branch.index("transport:disconnect()") < branch.index("task.wait(backoff)")

    poll_fail = loop.index('setStatus(string.format("poll failed')
    poll_branch = loop[poll_fail:loop.index("backoff = Config.RECONNECT_DELAY_SECONDS", poll_fail)]
    assert "transport:disconnect()" in poll_branch

    second = loop.index("if not flushPending(transport, pending) then", flush_fail + 1)
    second_branch = loop[second:loop.index("task.wait()", second)]
    assert "transport:disconnect()" in second_branch
    assert "retrying" not in second_branch


def test_flush_does_not_start_a_second_post_while_one_is_in_flight() -> None:
    source = INIT.read_text(encoding="utf-8")
    flush = _between(source, "local function flushPending(", "local pending = {}")

    assert "local flushing = false" in source
    guard = flush.index("if flushing or #pending == 0 then")
    clone = flush.index("local batch = table.clone(pending)")
    assert guard < clone
    assert flush.index("flushing = true", guard) < clone
    report = flush.index("transport:report(batch)")
    assert flush.index("flushing = false", report) > report
    assert "pcall" in flush


def test_flusher_does_not_report_a_disconnected_session() -> None:
    source = INIT.read_text(encoding="utf-8")
    flusher = _between(source, "local function flusher()", "local function start()")

    assert "transport.connected" in flusher
    assert "if transport ~= nil and #pending > 0 then" not in flusher
    failed = flusher.index("if not flushPending(transport, pending) then")
    assert flusher.index("transport:disconnect()", failed) < flusher.index("task.wait(0.05)", failed)


def test_a_throwing_command_still_releases_the_session() -> None:
    source = INIT.read_text(encoding="utf-8")
    spawn_at = source.index("task.spawn(function()")
    spawn = source[spawn_at:source.index("if not flushPending(transport, pending) then", spawn_at)]

    call = spawn.index("pcall(handle, command)")
    release = spawn.index("activeCommands -= 1")
    assert call < release
    assert "local response = handle(command)" not in spawn
