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

        for block in _DEFINE_BLOCK.finditer(text):
            body = block.group(1)
            offset = text[: block.start()].count("\n")
            for key in _DEFINE_KEY.finditer(body):
                line = offset + body[: key.start()].count("\n") + 1
                declared[key.group(1)] = (path, line)

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

    sources = _sources(root)
    if not sources:
        return

    try:
        result = subprocess.run(
            [str(analyzer)] + [str(p) for p in sources],
            capture_output=True,
            text=True,
            timeout=180,
            cwd=repo,
        )
    except Exception as exc:  # noqa: BLE001
        findings.append(Finding("note", str(root), 0, f"luau-analyze failed: {exc}"))
        return

    for line in (result.stdout + result.stderr).splitlines():
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
    from cli import assetcheck

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
    check_forge_wiring,
    check_asset_ids,
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
