"""Reading the SDK the way a programmer needs to read it.

Finding out what a function takes has been `grep`, and it has been wrong four
times in one day: `Palette.theme` does not exist, `Nature.scatter` takes a
`Vector2` rather than a radius, `Ui.meterSet` takes tokens first, and
`Enum.ReverbType.Concerthall` is spelled `ConcertHall`. Each cost a round trip
through a Studio restart, and one of them took a whole module down with an error
that named nothing.

So this parses the Luau and answers three questions directly: what does this
function take, what is there for a job I can describe, and what does the source
actually say.

**It reads the files, not a hand-written manifest.** A manifest drifts the first
time somebody edits a signature and forgets; this cannot, because there is
nothing to forget.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path
from typing import Any

#: Where the SDK lives, in the order a caller is likely to mean them.
LIBRARY_ROOTS = ("Core", "Behaviours", "GameKit", "WorldKit")

_FUNCTION = re.compile(
    r"^function\s+(?P<module>[A-Z][A-Za-z0-9_]*)[.:](?P<name>[A-Za-z_][A-Za-z0-9_]*)"
    r"\s*\((?P<params>.*?)\)\s*(?::\s*(?P<returns>.+?))?\s*$",
    re.MULTILINE | re.DOTALL,
)
_TYPE = re.compile(
    r"^export\s+type\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?P<body>.*?)(?=\n\n|\nexport|\nlocal|\nfunction)",
    re.MULTILINE | re.DOTALL,
)
_ASSIGNED = re.compile(
    r"^(?P<module>[A-Z][A-Za-z0-9_]*)\.(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*function"
    r"\s*\((?P<params>.*?)\)",
    re.MULTILINE | re.DOTALL,
)


@dataclass
class Entry:
    """One callable, and everything the source says about it."""

    module: str
    name: str
    params: str
    returns: str
    doc: str
    file: str
    line: int

    @property
    def qualified(self) -> str:
        return f"{self.module}.{self.name}"

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.qualified,
            "signature": f"{self.qualified}({self.params})"
            + (f": {self.returns}" if self.returns else ""),
            "parameters": _split_params(self.params),
            "returns": self.returns or "nothing declared",
            "doc": self.doc,
            "file": self.file,
            "line": self.line,
        }


def _split_params(raw: str) -> list[dict[str, str]]:
    """Split a Luau parameter list, respecting nested braces and generics."""

    out: list[dict[str, str]] = []
    depth = 0
    current = ""
    for character in raw:
        if character in "({[<":
            depth += 1
        elif character in ")}]>":
            depth -= 1
        if character == "," and depth == 0:
            if current.strip():
                out.append(_one_param(current))
            current = ""
        else:
            current += character
    if current.strip():
        out.append(_one_param(current))
    return out


def _one_param(raw: str) -> dict[str, str]:
    text = " ".join(raw.split())
    if ":" in text:
        name, kind = text.split(":", 1)
        kind = kind.strip()
        optional = kind.endswith("?")
        return {
            "name": name.strip(),
            "type": kind.rstrip("?").strip(),
            "optional": "yes" if optional else "no",
        }
    return {"name": text, "type": "any", "optional": "no"}


def _doc_above(lines: list[str], index: int) -> str:
    """The `---` block immediately above a definition.

    Luau's doc convention, and the only place the *why* of a function lives.
    Signature without intent is half an answer.
    """

    collected: list[str] = []
    cursor = index - 1
    while cursor >= 0:
        text = lines[cursor].strip()
        if text.startswith("---"):
            collected.append(text[3:].strip())
        elif text == "" and collected:
            break
        elif text.startswith("--"):
            pass
        else:
            break
        cursor -= 1
    collected.reverse()
    return "\n".join(collected).strip()


@lru_cache(maxsize=1)
def _index(root_key: str) -> tuple[list[Entry], dict[str, list[str]]]:
    root = Path(root_key)
    entries: list[Entry] = []
    types: dict[str, list[str]] = {}

    for library in LIBRARY_ROOTS:
        base = root / "roblox" / "lib" / library
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*.lua")):
            try:
                text = path.read_text(encoding="utf-8")
            except OSError:
                continue
            lines = text.splitlines()
            relative = str(path.relative_to(root)).replace("\\", "/")

            for pattern in (_FUNCTION, _ASSIGNED):
                for match in pattern.finditer(text):
                    line = text[: match.start()].count("\n")
                    entries.append(
                        Entry(
                            module=match.group("module"),
                            name=match.group("name"),
                            params=" ".join(match.group("params").split()),
                            returns=" ".join((match.groupdict().get("returns") or "").split()),
                            doc=_doc_above(lines, line),
                            file=relative,
                            line=line + 1,
                        )
                    )

            for match in _TYPE.finditer(text):
                types.setdefault(match.group("name"), []).append(
                    " ".join(match.group("body").split())[:400]
                )

    # Deduplicate: a name assigned and then declared shows up twice.
    seen: set[tuple[str, str]] = set()
    unique: list[Entry] = []
    for entry in entries:
        key = (entry.qualified, entry.file)
        if key not in seen:
            seen.add(key)
            unique.append(entry)
    return unique, types


def refresh() -> None:
    """Forget the cache. Called after `code_write` touches a library file."""

    _index.cache_clear()


def signature(root: Path, name: str) -> dict[str, Any]:
    """What one function takes, returns, and is for."""

    entries, _ = _index(str(root))
    wanted = name.strip()
    lowered = wanted.lower()

    exact = [entry for entry in entries if entry.qualified.lower() == lowered]
    if exact:
        found = exact[0]
        return {
            "found": True,
            **found.to_dict(),
            "example": _example_for(found),
        }

    # Bare name: `build` should find `Threat.build`.
    partial = [entry for entry in entries if entry.name.lower() == lowered]
    if len(partial) == 1:
        found = partial[0]
        return {"found": True, **found.to_dict(), "example": _example_for(found)}
    if partial:
        return {
            "found": False,
            "reason": f"{wanted} is ambiguous",
            "candidates": sorted(entry.qualified for entry in partial),
        }

    near = sorted(
        (entry.qualified for entry in entries if lowered in entry.qualified.lower())
    )[:12]
    return {
        "found": False,
        "reason": f"no function named {wanted}",
        "candidates": near,
        "hint": "call sdk_search with what you are trying to do",
    }


def _example_for(entry: Entry) -> str:
    """A call with the parameter names filled in.

    Not executable and not pretending to be — it is the shape, which is what is
    actually forgotten: the order, and which arguments are tables.
    """

    parts = []
    for param in _split_params(entry.params):
        kind = param["type"]
        if kind.startswith("{") or kind.endswith("}"):
            parts.append("{ --[[ " + param["name"] + " ]] }")
        elif kind == "Vector3":
            parts.append("Vector3.new(0, 0, 0)")
        elif kind == "Vector2":
            parts.append("Vector2.new(0, 0)")
        elif kind == "CFrame":
            parts.append("CFrame.new()")
        elif kind == "string":
            parts.append(f'"{param["name"]}"')
        elif kind == "number":
            parts.append("0")
        elif kind == "boolean":
            parts.append("true")
        else:
            parts.append(param["name"])
    return f"{entry.qualified}({', '.join(parts)})"


#: Portuguese for the same jobs.
#:
#: The doc comments are English, so a question asked in Portuguese matched
#: nothing and returned whatever happened to score above zero -- which reads
#: exactly like an answer. Each word here is folded to its English partner
#: before scoring.
SYNONYMS: dict[str, str] = {
    "zona": "zone", "gatilho": "trigger", "volume": "zone",
    "temporizador": "timer", "tempo": "timer", "espera": "timer",
    "evento": "event", "sinal": "event", "escutar": "event",
    "estado": "state", "maquina": "state",
    "limpeza": "cleanup", "limpar": "cleanup",
    "raio": "raycast", "colisao": "raycast", "ver": "raycast",
    "caminho": "path", "rota": "path", "navegacao": "path",
    "perseguir": "chase", "persegue": "chase", "cacar": "chase",
    "animar": "animate", "animacao": "animate", "movimento": "animate",
    "terreno": "terrain", "chao": "terrain", "relevo": "terrain",
    "porta": "door", "portao": "door",
    "coletar": "pickup", "apanhar": "pickup", "moeda": "money",
    "dinheiro": "money", "economia": "money", "preco": "money",
    "loja": "shop", "comprar": "shop", "vender": "shop",
    "dano": "damage", "vida": "damage", "morte": "damage",
    "onda": "wave", "inimigo": "chase", "criatura": "chase",
    "interface": "ui", "ecra": "ui", "tela": "ui", "botao": "ui",
    "som": "sound", "audio": "sound", "musica": "sound",
    "luz": "light", "iluminacao": "light", "sombra": "light",
    "fisica": "physics", "corda": "physics", "mola": "physics",
    "aleatorio": "random", "sorteio": "random",
    "curva": "curve", "progressao": "curve",
    "checkpoint": "checkpoint", "salvar": "save", "guardar": "save",
}


def _fold(word: str) -> str:
    """One search word, in whatever language, as the word the index knows."""

    # Accents are stripped rather than mapped: `posicao` and `posição` are the
    # same question, and a caller should not have to guess which spelling the
    # table happens to hold.
    plain = (
        word.replace("ç", "c").replace("ã", "a").replace("õ", "o")
        .replace("á", "a").replace("é", "e").replace("í", "i")
        .replace("ó", "o").replace("ú", "u").replace("â", "a")
        .replace("ê", "e").replace("ô", "o").replace("à", "a")
    )
    return SYNONYMS.get(plain, plain)


#: Words that describe a job, mapped to what in the SDK does it. Search reads
#: the docs first; this catches the cases where the doc uses different words
#: from the person asking.
INTENT: dict[str, tuple[str, ...]] = {
    "trigger": ("Zone", "Events.onTouch", "Events.onEnter", "Events.onPrompt"),
    "zone": ("Zone.new", "Events.zone", "Events.onEnter"),
    "timer": ("Timer.after", "Timer.every", "Timer.countdown"),
    "cooldown": ("Timer.cooldown", "Timer.throttle", "Timer.debounce"),
    "cleanup": ("Trove.new", "Trove.add", "Trove.clean"),
    "event": ("Signal.new", "Events.custom", "Events.on", "Events.emit"),
    "state": ("StateMachine.new", "Actions.set", "Actions.get"),
    "raycast": ("Spatial.ray", "Spatial.between", "Spatial.ground"),
    "path": ("Spatial.path", "Pursuit.start"),
    "chase": ("Pursuit.start", "Life.guard"),
    "animate": ("Motion.play", "Curve.ease", "Actions.glide"),
    "terrain": ("Land.heightfield", "Land.fill", "Land.paint"),
    "door": ("World.door",),
    "pickup": ("Play.pickup", "Play.chest"),
    "checkpoint": ("Play.checkpoint", "Play.respawnAtCheckpoints"),
    "wave": ("Life.spawner",),
    "shop": ("Play.shop", "Shop"),
    "money": ("Actions.spend", "Actions.add", "Economy"),
    "damage": ("Actions.damage", "Life.health"),
    "ui": ("Compose.build", "Ui.panel", "Ui.meter"),
    "sound": ("Actions.sound", "Audio.play", "Acoustics.install"),
    "light": ("Vfx.light", "Mood.apply", "World.dayNight"),
    "physics": ("Physics.rope", "Physics.spring", "Physics.ragdoll"),
    "random": ("Curve.stream",),
    "curve": ("Curve.ease", "Curve.geometric", "Curve.ladder"),
}


def search(root: Path, query: str, limit: int = 12) -> dict[str, Any]:
    """Find something by describing the job rather than naming the function."""

    entries, _ = _index(str(root))
    words = [
        _fold(word)
        for word in re.split(r"\W+", query.lower())
        if len(word) > 2
    ]
    if not words:
        return {"query": query, "matches": [], "hint": "say what you want to do"}

    scored: list[tuple[float, Entry]] = []
    for entry in entries:
        haystack = f"{entry.qualified} {entry.doc}".lower()
        score = 0.0
        for word in words:
            if word in entry.name.lower():
                score += 3.0
            elif word in entry.module.lower():
                score += 2.0
            if word in entry.doc.lower():
                score += 1.0
            # The intent table is the bridge between the words a person uses
            # and the words the source happens to use.
            for hint, targets in INTENT.items():
                if word.startswith(hint) or hint.startswith(word):
                    if any(entry.qualified.startswith(target) for target in targets):
                        score += 4.0
        if score > 0:
            scored.append((score, entry))

    scored.sort(key=lambda pair: (-pair[0], pair[1].qualified))
    return {
        "query": query,
        "matches": [
            {
                "name": entry.qualified,
                "signature": f"{entry.qualified}({entry.params})",
                "doc": entry.doc.split("\n")[0] if entry.doc else "",
                "file": entry.file,
                "score": round(score, 1),
            }
            for score, entry in scored[:limit]
        ],
        "searched": len(entries),
    }


def source(root: Path, name: str, around: int | None = None) -> dict[str, Any]:
    """The actual code, to read and to copy.

    Reading the source is how you find out what a library really does, and the
    intended response to "this does not fit" is to take it and change it.
    """

    entries, _ = _index(str(root))
    wanted = name.strip().lower()

    # A module name: hand back the whole file.
    for library in LIBRARY_ROOTS:
        base = root / "roblox" / "lib" / library
        for candidate in (
            base / f"{name.split('.')[-1]}.lua",
            base / name.split(".")[-1] / "init.lua",
        ):
            if candidate.is_file() and name.split(".")[-1].lower() in candidate.stem.lower() + "init":
                text = candidate.read_text(encoding="utf-8")
                return {
                    "found": True,
                    "kind": "module",
                    "file": str(candidate.relative_to(root)).replace("\\", "/"),
                    "lines": text.count("\n") + 1,
                    "source": text,
                }

    for entry in entries:
        if entry.qualified.lower() == wanted:
            path = root / entry.file
            lines = path.read_text(encoding="utf-8").splitlines()
            start = max(entry.line - 1 - (around or 6), 0)
            end = min(entry.line + (around or 60), len(lines))
            return {
                "found": True,
                "kind": "function",
                "file": entry.file,
                "line": entry.line,
                "source": "\n".join(lines[start:end]),
            }

    return {
        "found": False,
        "reason": f"nothing called {name}",
        "modules": sorted(
            {entry.module for entry in entries}
        ),
    }


def surface(root: Path) -> dict[str, Any]:
    """Every module and what is in it. The map of the library."""

    entries, types = _index(str(root))
    modules: dict[str, list[str]] = {}
    for entry in entries:
        modules.setdefault(entry.module, []).append(entry.name)
    for names in modules.values():
        names.sort()
    return {
        "modules": dict(sorted(modules.items())),
        "functions": len(entries),
        "types": sorted(types),
    }
