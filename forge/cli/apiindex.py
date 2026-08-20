"""Describe the engine in a form a machine can read.

Why
---

The intended user of this engine is an agent, and until now the only way for
one to learn what the engine offers was to read 32,000 lines of Luau or run
`forge engine` and receive a text dump. That is not a description, it is a
haystack, and the cost was paid repeatedly in this project: capabilities were
rebuilt because nobody knew they existed, and calls were invented because the
real signature was three files away.

So the engine gets an index: every module, every public function, its
signature, its documented purpose and its usage examples, as JSON. Generated
from the source rather than maintained by hand, because a hand-written index
is a document that starts accurate and ends fictional.

    forge api                 write forge/catalog/api.json
    forge api --module Anim   print one module's surface

What is extracted
-----------------

Luau has no runtime reflection worth using here, so this is a parser over the
source. It reads three things per function: the signature line, the doc
comment immediately above it, and any indented code block inside that comment,
which by this codebase's convention is a usage example. Module-level headers
are read the same way and become the module's summary.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
ENGINE = REPO / "forge" / "luau" / "Forge"
OUT = REPO / "forge" / "catalog" / "api.json"

FUNCTION = re.compile(r"^function\s+([A-Za-z_][\w]*)([.:])([A-Za-z_][\w]*)\s*\((.*?)\)\s*(?::\s*(.+?))?\s*$")
BLOCK_OPEN = re.compile(r"^\s*--\[\[")
BLOCK_CLOSE = re.compile(r"\]\]\s*$")
LINE_COMMENT = re.compile(r"^\s*--(?!\[\[)\s?(.*)$")


@dataclass
class Function:
    name: str
    signature: str
    kind: str            # "function" or "method"
    returns: str | None
    summary: str
    examples: list[str] = field(default_factory=list)
    line: int = 0


@dataclass
class Module:
    name: str
    file: str
    lines: int
    summary: str
    examples: list[str] = field(default_factory=list)
    functions: list[Function] = field(default_factory=list)
    describes: bool = False


def _clean(text: str) -> str:
    """Strip the leading tab-and-dashes a doc comment carries."""
    return text.replace("\t", "    ").rstrip()


def _split_doc(block: list[str]) -> tuple[str, list[str]]:
    """Separate prose from indented example blocks.

    The convention throughout this engine is that an indented run of lines
    inside a doc comment is code you can paste. Keeping them apart means an
    agent can be handed a working call rather than a paragraph about one.
    """
    prose: list[str] = []
    examples: list[str] = []
    current: list[str] = []

    for raw in block:
        line = _clean(raw)
        stripped = line.strip()
        indented = line.startswith("        ") and stripped != ""
        if indented:
            current.append(stripped)
            continue
        if current:
            examples.append("\n".join(current))
            current = []
        if stripped:
            prose.append(stripped)

    if current:
        examples.append("\n".join(current))

    # The first paragraph is the summary; the rest is rationale, which is
    # valuable to a human reading the file and noise in an index.
    summary_lines: list[str] = []
    for line in prose:
        if not line:
            break
        summary_lines.append(line)
    return " ".join(summary_lines), examples


def _doc_above(lines: list[str], index: int) -> list[str]:
    """The comment block immediately above a declaration, if any."""
    cursor = index - 1
    while cursor >= 0 and lines[cursor].strip() == "":
        cursor -= 1
    if cursor < 0:
        return []

    if BLOCK_CLOSE.search(lines[cursor]):
        end = cursor
        start = end
        while start >= 0 and not BLOCK_OPEN.match(lines[start]):
            start -= 1
        if start < 0:
            return []
        body = lines[start + 1:end]
        return body

    collected: list[str] = []
    while cursor >= 0:
        match = LINE_COMMENT.match(lines[cursor])
        if not match:
            break
        collected.insert(0, match.group(1))
        cursor -= 1
    return collected


def read_module(path: Path) -> Module:
    text = path.read_text(encoding="utf-8", errors="ignore")
    lines = text.split("\n")

    name = path.parent.name if path.name == "init.lua" else path.stem
    header = _doc_above(lines, next(
        (i for i, l in enumerate(lines) if l.strip() and not l.startswith("--")), 1))
    if not header and BLOCK_OPEN.match(lines[1] if len(lines) > 1 else ""):
        end = next((i for i, l in enumerate(lines) if BLOCK_CLOSE.search(l)), 1)
        header = lines[2:end]

    summary, examples = _split_doc(header)

    module = Module(
        name=name,
        file=str(path.relative_to(REPO)).replace("\\", "/"),
        lines=len(lines),
        summary=summary,
        examples=examples,
        describes="function %s.describe" % name in text,
    )

    for index, line in enumerate(lines):
        match = FUNCTION.match(line)
        if not match:
            continue
        owner, separator, fname, params, returns = match.groups()
        # Locals and internal classes are not the public surface. `Module.fn`
        # is; `Class:method` is only public when the class is handed out.
        if owner != name and separator == ".":
            continue

        doc_summary, doc_examples = _split_doc(_doc_above(lines, index))
        module.functions.append(Function(
            name=f"{owner}{separator}{fname}",
            signature=f"{owner}{separator}{fname}({params})",
            kind="method" if separator == ":" else "function",
            returns=(returns or "").strip() or None,
            summary=doc_summary,
            examples=doc_examples,
            line=index + 1,
        ))

    return module


def build() -> dict:
    modules: list[Module] = []
    for path in sorted(ENGINE.rglob("*.lua")):
        if path.name == "init.lua" and path.parent == ENGINE:
            continue  # the loader itself has no API of its own
        modules.append(read_module(path))

    modules = [m for m in modules if m.functions or m.summary]
    total = sum(len(m.functions) for m in modules)

    return {
        "generatedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "engine": "Forge",
        "modules": len(modules),
        "functions": total,
        "index": [
            {"name": m.name, "summary": m.summary.split(".")[0][:160],
             "functions": len(m.functions)}
            for m in sorted(modules, key=lambda m: m.name)
        ],
        "detail": [asdict(m) for m in sorted(modules, key=lambda m: m.name)],
    }


def write() -> tuple[Path, dict]:
    data = build()
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
    return OUT, data


def render_module(name: str) -> str:
    data = build()
    for module in data["detail"]:
        if module["name"].lower() != name.lower():
            continue
        out = [f"{module['name']}  ({module['lines']} lines, "
               f"{len(module['functions'])} public)", ""]
        if module["summary"]:
            out += [module["summary"], ""]
        for example in module["examples"][:2]:
            out += ["    " + line for line in example.split("\n")] + [""]
        for fn in module["functions"]:
            signature = fn["signature"]
            if fn["returns"]:
                signature += " -> " + fn["returns"]
            out.append("  " + signature)
            if fn["summary"]:
                out.append("      " + fn["summary"][:150])
        return "\n".join(out)
    return f"no module named '{name}'"
