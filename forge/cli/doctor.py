"""Authoring-time checks.

This is deliberately not a release gate. It does not score, it does not block,
and it never tells you a game is good. It tells you about the specific mistakes
that are cheap to make in Luau and expensive to find at runtime: an event you
declared and never handled, a marker nothing listens for, a require that points
at nothing, a loop with no yield.

Every finding names a file and a line, because a finding you cannot act on in
ten seconds is a finding you will ignore.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Finding:
    severity: str  # "error" | "warning" | "note"
    file: str
    line: int
    message: str

    def render(self, root: Path) -> str:
        try:
            where = Path(self.file).relative_to(root)
        except ValueError:
            where = Path(self.file)
        return f"  {self.severity:<7} {where}:{self.line}  {self.message}"


LUA_SUFFIXES = (".lua", ".luau")


def _sources(root: Path) -> list[Path]:
    out: list[Path] = []
    for suffix in LUA_SUFFIXES:
        out.extend(p for p in root.rglob(f"*{suffix}") if ".tmp" not in p.parts)
    return sorted(out)


def _strip_comments(text: str) -> str:
    """Blank out comments while preserving line numbers.

    Doc comments in this engine are full of illustrative `Net.on("Attack", …)`
    calls. Scanning them reported every example as an undeclared event, which
    is the kind of noise that trains you to ignore a check.
    """
    text = re.sub(r"--\[\[.*?\]\]", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    return re.sub(r"--[^\n]*", "", text)


def _lines(path: Path) -> list[str]:
    """Source lines with comments blanked out, line numbers intact.

    This used to return the file verbatim, and five checks matched against it.
    So a doc block explaining that `RenderStepped` is client-only was itself
    reported as an error for using RenderStepped on the server -- twice, once
    for the block comment and once for a line comment repeating it.

    A checker that flags its own documentation is a checker people stop
    reading. Anything that genuinely needs the comments can use `_raw_lines`;
    nothing does yet, which is the point.
    """
    return _strip_comments(
        path.read_text(encoding="utf-8", errors="replace")).splitlines()


def _raw_lines(path: Path) -> list[str]:
    """Source lines exactly as written, comments included."""
    return path.read_text(encoding="utf-8", errors="replace").splitlines()


# --------------------------------------------------------------------------
# individual checks
# --------------------------------------------------------------------------

# The closing brace may be indented: `Net.define` is often called inside a
# `start()` or `mount()` rather than at the top level of a file. Anchoring on a
# column-zero `}` missed every one of those and reported the events as
# undeclared.
_DEFINE_BLOCK = re.compile(r"Net\.define\s*\(\s*\{(.*?)\n[ \t]*\}\s*\)", re.S)
_DEFINE_KEY = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\{", re.M)
# `Net.define` handed a variable rather than a table literal.
#
# A game with a server and a client has to define the same channels in both
# VMs — `Net.on` errors on a name the local VM has never seen — and the only
# sane way to do that is one shared table both sides require. quarryline does
# exactly that, and this check then reported all fifteen of its channels as
# undeclared, because it only looked for a literal written inside the
# `Net.define(` call itself.
#
# Fifteen false errors is worse than no check: a doctor people learn to ignore
# is precisely the failure this tool exists to prevent. So it follows the
# indirection to wherever the table was actually written.
_DEFINE_INDIRECT = re.compile(r"Net\.define\s*\(\s*([A-Za-z_][A-Za-z0-9_.]*)\s*\)")
# The event name is not always the first argument — Net.fire takes the player
# first, Net.fireNear takes a position and a radius. So: capture the whole call
# and treat any string literal inside it as a candidate event name.
_NET_CALL = re.compile(r"Net\.[A-Za-z]+\s*\(([^()]*(?:\([^()]*\)[^()]*)*)\)")
_STRING_LITERAL = re.compile(r"[\"']([^\"']+)[\"']")


def check_net(root: Path, findings: list[Finding]) -> None:
    """An event nobody handles is either dead weight or a forgotten wiring."""
    declared: dict[str, tuple[Path, int]] = {}
    used: set[str] = set()
    handled: set[str] = set()

    for path in _sources(root):
        text = _strip_comments(path.read_text(encoding="utf-8", errors="replace"))

        blocks: list[tuple[str, int]] = [
            (block.group(1), text[: block.start()].count("\n"))
            for block in _DEFINE_BLOCK.finditer(text)
        ]

        # A variable passed to `Net.define` names a table written somewhere in
        # the project — usually a shared module both VMs require. Take the last
        # component (`Channels.definitions` → `definitions`) and find where it
        # was assigned a table, in this file or any other.
        for indirect in _DEFINE_INDIRECT.finditer(text):
            leaf = indirect.group(1).rsplit(".", 1)[-1]
            assignment = re.compile(
                r"^[ \t]*(?:local[ \t]+)?[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\."
                + re.escape(leaf) + r"[ \t]*=[ \t]*\{(.*?)\n[ \t]*\}",
                re.S | re.M)
            for other in _sources(root):
                other_text = _strip_comments(
                    other.read_text(encoding="utf-8", errors="replace"))
                for found in assignment.finditer(other_text):
                    blocks.append(
                        (found.group(1), other_text[: found.start()].count("\n")))

        for body, offset in blocks:
            for key in _DEFINE_KEY.finditer(body):
                line = offset + body[: key.start()].count("\n") + 1
                declared.setdefault(key.group(1), (path, line))

        for call in _NET_CALL.finditer(text):
            for literal in _STRING_LITERAL.finditer(call.group(1)):
                used.add(literal.group(1))

        for match in re.finditer(r"Net\.on\s*\(\s*[\"']([^\"']+)[\"']", text):
            handled.add(match.group(1))
            used.add(match.group(1))

    for name, (path, line) in sorted(declared.items()):
        if name not in used:
            findings.append(
                Finding("warning", str(path), line, f"net event '{name}' is declared but never used")
            )
        elif name not in handled:
            findings.append(
                Finding(
                    "warning",
                    str(path),
                    line,
                    f"net event '{name}' is sent but nothing calls Net.on for it",
                )
            )

    # Only flag undeclared names from call shapes where the first argument is
    # unambiguously the event name. Anything else would report every string
    # literal that happens to sit inside a Net call.
    for path in _sources(root):
        text = _strip_comments(path.read_text(encoding="utf-8", errors="replace"))
        for match in re.finditer(r"Net\.(on|send|request)\s*\(\s*[\"']([^\"']+)[\"']", text):
            name = match.group(2)
            if name not in declared:
                line = text[: match.start()].count("\n") + 1
                findings.append(
                    Finding("error", str(path), line, f"net event '{name}' is used but never declared in Net.define")
                )


_MARKER = re.compile(r"name\s*=\s*[\"']([a-z_]+)[\"']\s*\}")
_MARKER_LISTEN = re.compile(r"marker\s*==\s*[\"']([a-z_]+)[\"']|onMarker\s*\(")


def check_anim(root: Path, findings: list[Finding]) -> None:
    """A marker with no listener is a timing decision that does nothing."""
    markers: dict[str, tuple[Path, int]] = {}
    listened: set[str] = set()
    has_listener = False

    for path in _sources(root):
        lines = _lines(path)
        text = "\n".join(lines)

        if "markers" in text:
            for index, line in enumerate(lines, start=1):
                if "name =" in line and "t =" in line:
                    found = _MARKER.search(line)
                    if found:
                        markers.setdefault(found.group(1), (path, index))

        for match in re.finditer(r"[\"']([a-z_]+)[\"']", text):
            token = match.group(1)
            if token in {"hit", "trail_on", "trail_off", "telegraph", "release", "iframes_on", "iframes_off", "fall", "leap", "touch"}:
                listened.add(token)
        if "onMarker" in text:
            has_listener = True

    if markers and not has_listener:
        path, line = next(iter(markers.values()))
        findings.append(
            Finding(
                "warning",
                str(path),
                line,
                "clips define markers but nothing calls animator:onMarker — hit timing is inert",
            )
        )


def check_loops(root: Path, findings: list[Finding]) -> None:
    """`while true do` with no yield is the fastest way to hang a server."""
    for path in _sources(root):
        lines = _lines(path)
        for index, line in enumerate(lines):
            if re.search(r"while\s+true\s+do", line):
                window = "\n".join(lines[index : index + 12])
                # `return` and `break` terminate too. An iterator written as
                # `while true do … return nil end` is correct, and flagging it
                # taught nothing.
                if not re.search(
                    r"task\.wait|RunService|:Wait\(|task\.spawn|coroutine|\breturn\b|\bbreak\b",
                    window,
                ):
                    findings.append(
                        Finding("error", str(path), index + 1, "`while true do` with no yield in the next 12 lines")
                    )


def check_connections(root: Path, findings: list[Finding]) -> None:
    """Connections outnumbering cleanup by a wide margin is a leak in waiting."""
    for path in _sources(root):
        text = path.read_text(encoding="utf-8", errors="replace")
        connects = len(re.findall(r":Connect\(", text))
        cleanup = len(re.findall(r"Trove|:Disconnect\(|janitor|trove", text, re.I))
        if connects >= 6 and cleanup == 0:
            findings.append(
                Finding(
                    "warning",
                    str(path),
                    1,
                    f"{connects} :Connect calls and no Trove or :Disconnect anywhere in this file",
                )
            )


def check_context(root: Path, findings: list[Finding]) -> None:
    """Client-only API on the server, and the reverse. Both fail silently-ish."""
    for path in _sources(root):
        name = path.name
        text = path.read_text(encoding="utf-8", errors="replace")
        lines = _lines(path)

        server_side = ".server." in name or "/server/" in path.as_posix().lower()
        client_side = ".client." in name or "/client/" in path.as_posix().lower()

        if server_side:
            for index, line in enumerate(lines, start=1):
                if "LocalPlayer" in line:
                    findings.append(
                        Finding("error", str(path), index, "LocalPlayer referenced in a server script")
                    )
                if "RenderStepped" in line or "BindToRenderStep" in line:
                    findings.append(
                        Finding("error", str(path), index, "RenderStepped is client-only")
                    )
        if client_side:
            for index, line in enumerate(lines, start=1):
                if "DataStoreService" in line:
                    findings.append(
                        Finding("error", str(path), index, "DataStoreService is server-only")
                    )
                if re.search(r"\bHttpService\b", line) and "JSONEncode" not in line and "JSONDecode" not in line:
                    findings.append(
                        Finding(
                            "warning",
                            str(path),
                            index,
                            "HttpService requests are server-only (encode/decode are fine)",
                        )
                    )


_NET_HANDLER = re.compile(
    r"Net\.on\s*\(\s*[\"'][^\"']+[\"']\s*,\s*function\s*\(\s*[A-Za-z_][A-Za-z0-9_]*\s*,\s*([A-Za-z_][A-Za-z0-9_]*)"
)
_VALUABLE = "price|cost|amount|damage|gold|currency|quantity"


def check_authority(root: Path, findings: list[Finding]) -> None:
    """Server code reading a price or an amount straight off the wire.

    Scoped to the actual parameter of a `Net.on` handler. Matching `payload.x`
    anywhere flagged server-side `Events` payloads too, which are not attacker
    controlled — and a warning that cries wolf is a warning nobody reads.
    """
    for path in _sources(root):
        if ".client." in path.name:
            continue
        text = _strip_comments(path.read_text(encoding="utf-8", errors="replace"))
        lines = text.splitlines()

        for handler in _NET_HANDLER.finditer(text):
            name = handler.group(1)
            start = text[: handler.start()].count("\n")
            suspicious = re.compile(rf"\b{re.escape(name)}\.({_VALUABLE})\b")
            # a handler body of any sane length lives within ~40 lines
            for offset in range(0, min(40, len(lines) - start)):
                line = lines[start + offset]
                match = suspicious.search(line)
                if match and "check" not in line and "shape" not in line:
                    findings.append(
                        Finding(
                            "warning",
                            str(path),
                            start + offset + 1,
                            f"server reads '{match.group(1)}' from a client payload; "
                            "verify it against server data",
                        )
                    )
                    break


def check_requires(root: Path, findings: list[Finding]) -> None:
    """A require whose path does not exist on disk."""
    pattern = re.compile(r"require\s*\(\s*script\.Parent\.([A-Za-z0-9_.]+)\s*\)")
    for path in _sources(root):
        for index, line in enumerate(_lines(path), start=1):
            match = pattern.search(line)
            if not match:
                continue
            parts = match.group(1).split(".")
            # `script.Parent.Parent.X` walks up; consume the extra Parents
            # before resolving the rest against the filesystem.
            climb = 0
            while parts and parts[0] == "Parent":
                parts.pop(0)
                climb += 1

            # For `init.lua` the module *is* its folder, so `script.Parent` is
            # the folder above it. Both branches used to be `path.parent`,
            # which made every `require(script.Parent.X)` in the engine look
            # broken — the check was wrong, not the code.
            base = path.parent.parent if path.stem == "init" else path.parent
            for _ in range(climb):
                base = base.parent
            if not parts:
                continue  # `require(script.Parent)` — the folder itself
            target = base.joinpath(*parts)
            candidates = [
                target.with_suffix(".lua"),
                target.with_suffix(".luau"),
                target / "init.lua",
                target / "init.luau",
            ]
            if not any(c.exists() for c in candidates):
                findings.append(
                    Finding("error", str(path), index, f"require points at '{match.group(1)}' which does not exist")
                )


def check_module_graph(root: Path, findings: list[Finding]) -> None:
    """Resolve every `require(script...)` against the folder it really means.

    `check_requires` above only understands `script.Parent.X`. This walks the
    whole path — `Parent`, nested folders, `init.lua` families — and it exists
    because the narrower check missed a whole class that cost three run cycles
    to find one at a time.

    The semantics that trip people up: inside `Family/init.lua`, `script` *is*
    the family, so a sibling is `script.X`. Inside `Family/Thing.lua`, `script`
    is Thing, so a sibling is `script.Parent.X`. Four family indexes in this
    repository had it backwards, and every one of them compiled — Luau checks
    syntax, not whether an instance is there.
    """
    engine = root / "forge" / "luau" / "Forge"
    roots = [engine] if engine.exists() else []
    roots += [p for p in (root / "src",) if p.exists()]
    if not roots:
        roots = [root]

    pattern = re.compile(r"require\(script((?:\.[A-Za-z_][A-Za-z0-9_]*)+)\)")

    for base in roots:
        for path in sorted(base.rglob("*.lua")):
            text = _strip_comments(path.read_text(encoding="utf-8", errors="replace"))
            here = path.parent
            # `init.server.lua` and `init.client.lua` make the *folder* the
            # script exactly as `init.lua` does, so their children are
            # `script.X` too. Treating them as ordinary modules reported a
            # correct require as broken — this check finding its own bug.
            is_init = path.name in ("init.lua", "init.server.lua", "init.client.lua")
            for match in pattern.finditer(text):
                parts = match.group(1).lstrip(".").split(".")
                cursor = here if is_init else (here / path.stem)
                resolved = True
                for part in parts:
                    if part == "Parent":
                        cursor = cursor.parent
                        continue
                    if (cursor / f"{part}.lua").exists():
                        cursor = cursor / f"{part}.lua"
                    elif (cursor / part).is_dir():
                        # A plain folder is a Folder instance at runtime; only
                        # a family index needs `init.lua`. Demanding one turned
                        # `script.systems.Progress` — which is correct — into
                        # an error.
                        cursor = cursor / part
                    else:
                        resolved = False
                        break
                if not resolved:
                    line = text[: match.start()].count(chr(10)) + 1
                    findings.append(Finding(
                        "error", str(path), line,
                        f"require(script{match.group(1)}) resolves to nothing on disk",
                    ))


def check_family_exports(root: Path, findings: list[Finding]) -> None:
    """A module beside a family index that the index cannot reach.

    An unreachable module is inventory with an engine address. `Forge.Core.Boot`
    was nil for exactly this reason while `Boot.lua` sat next to `init.lua`,
    compiled and specced — and the first game written against it died on
    `attempt to index nil`.

    A lazy `__index` on the family counts: it resolves any sibling on demand,
    which is the whole point.
    """
    engine = root / "forge" / "luau" / "Forge"
    if not engine.exists():
        return

    for family in sorted(engine.iterdir()):
        index = family / "init.lua"
        if not family.is_dir() or not index.exists():
            continue
        text = index.read_text(encoding="utf-8", errors="replace")
        if "FindFirstChild(key)" in text:
            # A lazy resolver reaches everything; nothing to list.
            continue
        siblings = sorted(p.stem for p in family.glob("*.lua") if p.name != "init.lua")
        missing = [s for s in siblings if f"require(script.{s})" not in text]
        if missing:
            findings.append(Finding(
                "warning", str(index), 0,
                f"{family.name} does not expose {', '.join(missing[:6])}"
                + (f" and {len(missing) - 6} more" if len(missing) > 6 else ""),
            ))


def check_forge_wiring(root: Path, findings: list[Finding]) -> None:
    """Things Forge expects to be called once, that are easy to forget."""
    text = "\n".join(
        p.read_text(encoding="utf-8", errors="replace") for p in _sources(root)
    )
    if not text.strip():
        return

    if "Anim.new" in text and "stripDefaultAnimate" not in text:
        findings.append(
            Finding(
                "warning",
                str(root),
                0,
                "Anim.new is used but Rig.stripDefaultAnimate is never called — "
                "Roblox's default Animate script will fight the procedural pose",
            )
        )
    if "Feel." in text and "Feel.mount" not in text:
        findings.append(
            Finding("warning", str(root), 0, "Feel is used but Feel.mount() is never called — shake and hitstop are inert")
        )
    if "Save.get" in text and "Save.start" not in text:
        findings.append(
            Finding("error", str(root), 0, "Save.get is used but Save.start() is never called — no profile will ever load")
        )
    if "Telemetry." in text and "Telemetry.start" not in text:
        findings.append(
            Finding(
                "error",
                str(root),
                0,
                "Telemetry is used but Telemetry.start() is never called — events "
                "are counted into a buffer that nothing ever drains",
            )
        )
    # A sink can be registered directly or through one of the engine's ready
    # made ones. Matching only the direct call flagged both games in this
    # repository the moment they moved to `dataStoreSink`, which is the check
    # being wrong rather than the games.
    registers_sink = any(
        call in text
        for call in ("Telemetry.sink", "Telemetry.dataStoreSink", "Telemetry.printSink")
    )
    if "Telemetry.event" in text and not registers_sink:
        findings.append(
            Finding(
                "warning",
                str(root),
                0,
                "Telemetry.event is raised but no sink is registered — every event "
                "is buffered and discarded",
            )
        )
    if "Debug.expose" not in text:
        findings.append(
            Finding(
                "note",
                str(root),
                0,
                "Debug.expose() is never called — a validator will be able to measure geometry but not meaning",
            )
        )


def check_compiles(root: Path, findings: list[Finding]) -> None:
    """Actually parse the Luau.

    Rojo packages files, it does not compile them, so a place can build cleanly
    from source that never runs. The Quality Engine already pins a Luau
    compiler for exactly this reason — Forge borrows it rather than shipping a
    second one. This is the seam working in the useful direction: the
    validation half catching an authoring mistake before it reaches Studio.
    """
    try:
        import sys

        repo = Path(__file__).resolve().parent.parent.parent
        if str(repo) not in sys.path:
            sys.path.insert(0, str(repo))
        from rqe import luau_check  # type: ignore
    except Exception:
        findings.append(
            Finding("note", str(root), 0, "luau compiler unavailable; syntax was not verified")
        )
        return

    try:
        compiler = luau_check.ensure_compiler(repo, allow_download=False)
    except Exception as exc:
        findings.append(Finding("note", str(root), 0, f"luau compiler unavailable ({exc})"))
        return

    for path in _sources(root):
        failure = luau_check.compile_file(compiler, path)
        if failure:
            message = str(failure)
            line = 0
            marker = re.search(r"\((\d+),\d+\)", message)
            if marker:
                line = int(marker.group(1))
            detail = message.split("SyntaxError:")[-1].strip() if "SyntaxError:" in message else message
            findings.append(Finding("error", str(path), line, f"does not compile: {detail}"))


_TOP_LEVEL_LOCAL = re.compile(r"^local (?:function )?([A-Za-z_][A-Za-z0-9_]*)")


def check_use_before_declare(root: Path, findings: list[Finding]) -> None:
    """A top-level local referenced above its own declaration.

    Luau compiles this without complaint: the earlier reference silently
    resolves to a global, which is nil, and the failure appears at runtime in a
    function that looks correct. It cost a real bug in `Assets.build`, which
    called a pooling helper declared eighty lines further down.
    """
    for path in _sources(root):
        lines = _lines(path)

        declared: dict[str, int] = {}
        for index, line in enumerate(lines, start=1):
            match = _TOP_LEVEL_LOCAL.match(line)
            if match and match.group(1) not in declared:
                declared[match.group(1)] = index

        for name, declared_at in declared.items():
            # a bare identifier, not a field access and not its own declaration
            pattern = re.compile(rf"(?<![.:\w]){re.escape(name)}\s*\(")
            for index in range(declared_at - 1):
                line = lines[index]
                stripped = line.strip()
                if stripped.startswith("--") or not line.startswith((" ", "\t")):
                    continue
                if pattern.search(line):
                    findings.append(
                        Finding(
                            "error",
                            str(path),
                            index + 1,
                            f"'{name}' is used here but declared as a local on line {declared_at}; "
                            "at runtime this reads a nil global",
                        )
                    )
                    break



#: Roblox supplies these; `luau-analyze` has no type definitions for them and
#: reports every one as unknown. Filtering them is what turns a wall of noise
#: into the two findings that matter.
_ROBLOX_GLOBALS = {
    "game", "workspace", "script", "shared", "plugin", "require", "settings",
    "Enum", "Instance", "Vector2", "Vector3", "Vector3int16", "Vector2int16",
    "CFrame", "Color3", "ColorSequence", "ColorSequenceKeypoint", "BrickColor",
    "UDim", "UDim2", "Ray", "Rect", "Region3", "Region3int16", "Axes", "Faces",
    "NumberRange", "NumberSequence", "NumberSequenceKeypoint", "PhysicalProperties",
    "TweenInfo", "Random", "Font", "DateTime", "OverlapParams", "RaycastParams",
    "PathWaypoint", "task", "typeof", "warn", "tick", "time", "delay", "spawn",
    "wait", "elapsedTime", "gcinfo", "newproxy", "buffer", "vector",
    "print", "error", "assert", "pcall", "xpcall", "select", "tonumber",
    "tostring", "type", "unpack", "next", "ipairs", "pairs", "setmetatable",
    "getmetatable", "rawget", "rawset", "rawequal", "rawlen", "string", "table",
    "math", "os", "coroutine", "bit32", "utf8", "debug", "_G", "_VERSION",
}

_UNKNOWN_GLOBAL = re.compile(
    r"^(?P<file>.+?)\((?P<line>\d+),\d+\): TypeError: Unknown global '(?P<name>[^']+)'"
)


def check_unknown_globals(root: Path, findings: list[Finding]) -> None:
    """A name that is not a local, not a field and not a Roblox global.

    Almost always a rename that missed a site: the reference compiles, resolves
    to `nil` at runtime, and fails somewhere unrelated. Renaming Editor's
    `selection` to a list left four such sites, and only this pass found them.
    """
    import subprocess
    import sys

    repo = Path(__file__).resolve().parent.parent.parent
    analyzer = repo / ".tools" / "luau" / ("luau-analyze.exe" if sys.platform == "win32" else "luau-analyze")
    if not analyzer.exists():
        findings.append(
            Finding("note", str(root), 0, "luau-analyze not present; unknown globals were not checked")
        )
        return

    #[[
    #   The engine is analysed alongside the game, every run.
    #
    #   This check was written for exactly one failure -- a name that resolves
    #   to nil at runtime -- and then pointed only at `games/<name>`, so the
    #   232 modules every game depends on were never once passed through it.
    #   `ItchIcons.frame` read a `byRole` table that no line ever built; it
    #   killed the client on the first panel of a brand-new game, and the
    #   analyzer named it in one second the moment it was finally shown the
    #   file. A check aimed away from most of the code is not a check.
    #
    #   Engine findings surface in every game's report on purpose: a nil global
    #   in `forge/luau` breaks all of them, and attributing it to whichever
    #   game happened to run first is how it goes unfixed.
    #]]
    sources = _sources(root) + _sources(repo / "forge" / "luau")
    if not sources:
        return

    #: Analysed in batches. Windows caps a command line, and one over-long
    #: invocation fails as a missing-file error, which reads as "no analyzer"
    #: and quietly disables the whole check.
    output: list[str] = []
    try:
        for start in range(0, len(sources), 40):
            result = subprocess.run(
                [str(analyzer)] + [str(p) for p in sources[start:start + 40]],
                capture_output=True,
                text=True,
                timeout=180,
                cwd=repo,
            )
            output.append(result.stdout + result.stderr)
    except Exception as exc:  # noqa: BLE001
        findings.append(Finding("note", str(root), 0, f"luau-analyze failed: {exc}"))
        return

    for line in "".join(output).splitlines():
        match = _UNKNOWN_GLOBAL.match(line.strip())
        if not match:
            continue
        name = match.group("name")
        if name in _ROBLOX_GLOBALS:
            continue
        findings.append(
            Finding(
                "error",
                match.group("file"),
                int(match.group("line")),
                f"'{name}' is not defined anywhere; at runtime this reads nil",
            )
        )


#: `Net` functions that raise if the VM calling them is not the server, and
#: the client-side call that does the same job.
SERVER_ONLY_NET = {
    "fire": "Net.send(name, payload)",
    "fireAll": "Net.send(name, payload)",
    "fireExcept": "Net.send(name, payload)",
    "fireNear": "Net.send(name, payload)",
    "fireList": "Net.send(name, payload)",
}


_SELF_TYPE = re.compile(r"type Self = \{(.*?)\n\}", re.S)


def check_field_method_shadow(root: Path, findings: list[Finding]) -> None:
    """A field must never share a name with a method on the same table.

    `Thing.__index = Thing` makes an instance look at itself first, so an
    instance field named `hand` shadows `Thing.hand` and the method becomes
    permanently uncallable: `instance:hand()` finds the field and tries to call
    a table.

    Nothing else in this repository catches it. It compiles, the type checker
    is content, and unit specs call module functions directly rather than
    through an instance -- which is precisely the shape that never touches the
    shadow. It surfaced the first time a game called `cycle:hand()`, and a scan
    then found the same collision in four modules that had shipped for months.
    """
    #[[
    #   Scans the engine as well as the game.
    #
    #   Every check here takes a game root, which is right for the checks that
    #   are about a game. This one is about a Luau idiom, and all four instances
    #   ever found live in `Forge` -- a check that only looked at the game would
    #   have reported nothing while the defect sat in the shared library every
    #   game requires.
    #]]
    engine = Path(__file__).resolve().parents[1] / "luau" / "Forge"
    roots = [root] + ([engine] if engine.is_dir() and engine not in root.parents else [])

    seen: set[Path] = set()
    for where in roots:
        for path in sorted(where.rglob("*.lua")):
            if path in seen:
                continue
            seen.add(path)
            _shadow_one(path, findings)


def _shadow_one(path: Path, findings: list[Finding]) -> None:
    """One module's declared fields against its own instance methods."""
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return

    block = _SELF_TYPE.search(text)
    if not block:
        return

    fields = {
        line.strip().split(":")[0].strip()
        for line in block.group(1).splitlines()
        if ":" in line
    }
    methods = set(re.findall(
        r"function %s\.([A-Za-z_][A-Za-z0-9_]*)\(self" % re.escape(path.stem), text))

    for name in sorted(fields & methods):
        line = next((n for n, l in enumerate(text.splitlines(), 1)
                     if ("function %s.%s(self" % (path.stem, name)) in l), 0)
        findings.append(Finding(
            "error", str(path), line,
            f"the field '{name}' shadows the method '{path.stem}.{name}'; "
            f"instance:{name}() will try to call the field. Rename the field.",
        ))


def check_client_server_api(root: Path, findings: list[Finding]) -> None:
    """Client code must not call the server-only half of `Net`.

    `Net.fire` asserts it is on the server and errors otherwise. Called from a
    LocalScript it therefore does nothing except throw -- and because these
    calls live inside button handlers and key bindings, the throw happens on
    click, long after the script loaded cleanly.

    quarryline shipped every one of its controls that way. The Build buttons,
    the daily claim and the rebirth key all called `Net.fire`, all compiled,
    all passed the type checker, and none of them had ever sent a single
    message. The game looked finished and had no working input at all.

    Nothing else catches this: it is a runtime assertion in a closure nobody
    calls during a test, in a VM the test suite does not run in.
    """
    client_dir = root / "src" / "client"
    if not client_dir.is_dir():
        return

    for path in sorted(client_dir.rglob("*.lua")):
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        for number, line in enumerate(text.splitlines(), start=1):
            stripped = line.lstrip()
            if stripped.startswith("--"):
                continue
            for name, replacement in SERVER_ONLY_NET.items():
                if f"Net.{name}(" in line:
                    findings.append(Finding(
                        "error", str(path), number,
                        f"Net.{name} is server-only and errors in a LocalScript; "
                        f"use {replacement}",
                    ))


def check_asset_ids(root: Path, findings: list[Finding]) -> None:
    """Every asset id in this game must have been loaded successfully once.

    An invented id is the one class of mistake that passes every other gate
    here. It compiles, it sits in a well-formed table, no test asserts on it,
    and `rojo` writes it into the place without comment. The first thing that
    disagrees is a player's speakers.

    That is not hypothetical: three separate sets of ids in this project were
    written from memory and none of them worked. So the rule is that an id
    must appear in the verification registry, which is only written by actually
    loading the thing inside Studio.

        forge assets verify

    A game with no registry yet gets a warning rather than an error, because
    failing a fresh checkout that has never been near a Studio would make the
    check something people route around.
    """
    #: Absolute, not the bare `cli` this used to import.
    #:
    #: `from cli import ...` only resolves when `forge/` happens to be on the
    #: path, which is true when forge.py is the entry point and false whenever
    #: doctor is imported as `forge.cli.doctor` -- from a test, from another
    #: tool, from anything but the CLI. The check then failed with "No module
    #: named 'cli'" and was reported as a note, so a real asset check quietly
    #: never ran and said so in language nobody reads as "this did not run".
    from forge.cli import assetcheck

    registry = assetcheck.load_registry()
    references = assetcheck.scan([root])
    if not references:
        return

    if not registry:
        findings.append(Finding(
            "warning", str(root), 0,
            f"{len(references)} asset ids referenced and none verified; run 'forge assets verify'",
        ))
        return

    for ref, places in sorted(references.items()):
        record = registry.get(ref)
        where = places[0]
        if record is None:
            findings.append(Finding(
                "error", where, 0,
                f"{ref} has never been verified; run 'forge assets verify'",
            ))
        elif not record.get("ok"):
            reason = record.get("error") or "did not load"
            findings.append(Finding(
                "error", where, 0,
                f"{ref} fails to load ({reason})",
            ))


def check_reinvention(root: Path, findings: list[Finding]) -> None:
    """A game system named after something the engine already has.

    The most expensive defect in this repository is not a bug. It is writing
    something that already exists: in one session `Rig.grip`, `Camera.Viewmodel`
    and `Forge.Anim` were each reimplemented by hand, worse, because nobody
    asked whether they existed.

    A name collision is the cheapest possible signal for that. `Guns.lua` next
    to `Forge.Weapon` might be a game's own layer over the engine's -- that is
    normal and correct -- so this is a note rather than an error. It exists to
    make somebody type one command before they keep going.

    Matching is on the family and module names the engine actually exports, and
    only for files that do not require the thing they collide with: a system
    that already requires `Forge.Anim` has clearly found it.
    """
    engine = root.parent.parent / "forge" / "luau" / "Forge"
    if not engine.is_dir():
        engine = Path(__file__).resolve().parents[2] / "forge" / "luau" / "Forge"
    if not engine.is_dir():
        return

    #: Family directories and their modules, which is what an author would
    #: plausibly name a file after.
    known: dict[str, str] = {}
    for family in engine.iterdir():
        if family.is_dir():
            known[family.name.lower()] = f"Forge.{family.name}"
            for module in family.glob("*.lua"):
                if module.stem != "init":
                    known[module.stem.lower()] = f"Forge.{family.name}.{module.stem}"

    #: Words too generic to mean anything as a collision.
    ignore = {"init", "config", "state", "data", "core", "world", "match",
              "access", "events", "entity", "mark", "platform", "reference"}

    for path in sorted(root.rglob("*.lua")) + sorted(root.rglob("*.luau")):
        stem = path.stem.lower()
        if stem in ignore or stem not in known:
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        engine_name = known[stem]
        #: Already using it is the opposite of reinventing it.
        leaf = engine_name.split('.')[-1]
        if leaf in text:
            continue
        findings.append(Finding(
            "note", str(path), 1,
            f"'{path.stem}' shares its name with {engine_name}; "
            f"run `forge find {path.stem}` before writing more of it"))


CHECKS = (
    check_compiles,
    check_unknown_globals,
    check_use_before_declare,
    check_net,
    check_anim,
    check_loops,
    check_connections,
    check_context,
    check_authority,
    check_requires,
    check_module_graph,
    check_family_exports,
    check_forge_wiring,
    check_asset_ids,
    check_client_server_api,
    check_field_method_shadow,
    check_reinvention,
)


def run(root: Path) -> list[Finding]:
    findings: list[Finding] = []
    for check in CHECKS:
        try:
            check(root, findings)
        except Exception as exc:  # a broken check must not hide the others
            findings.append(Finding("note", str(root), 0, f"check {check.__name__} failed: {exc}"))
    order = {"error": 0, "warning": 1, "note": 2}
    return sorted(findings, key=lambda f: (order[f.severity], f.file, f.line))
