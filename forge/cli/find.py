"""Answer "does this already exist" in one command.

Why this exists
---------------

The engine has 232 modules and 1617 public functions, three games' worth of
systems, and a shelf of kits salvaged from finished projects. All of it is
indexed, versioned and readable, and none of that helped: in one session an
agent hand-wrote a hand-grip welder, a first-person viewmodel and a joint poser
that all already existed, and then started writing a zombie system while a
complete, running zombie game sat in `forge/kits/infected/`.

The information was available. What was missing was a way to *ask*, in the
five seconds before writing something, whether it was already written -- and
the honest reason nobody asked is that asking meant three greps and knowing the
right nouns in advance. `Camera.Viewmodel` does not contain the word "gun".
`Rig.grip` does not contain the word "weld".

So this searches names, summaries and bodies across all three shelves at once,
and ranks by where the hit landed rather than how many times it occurred. A
name match is somebody having named a thing after your problem; a body match is
a coincidence until proven otherwise.

What it deliberately does not do
--------------------------------

It does not try to be clever about relevance. There is no stemming, no synonym
table, no embedding. Those all fail in the same direction -- confidently
returning something adjacent while the exact thing sits two rows down -- and
the cost of a slightly noisy list is one second of reading. The cost of a
falsely confident empty result is a day of rewriting `Rig.grip`.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

#: Where a hit landed, and what that is worth. A module named after your
#: problem is a different kind of answer from a file that mentions it once.
SCORE_NAME = 100
SCORE_SUMMARY = 40
SCORE_FUNCTION = 30
SCORE_BODY = 4

#: Body hits are capped so a 1300-line service does not outrank a module that
#: is literally called what you searched for.
BODY_CAP = 20

#[[
#   Words that match everything and mean nothing.
#
#   A query is written as a sentence -- "grip a weapon in the hand" -- because
#   that is how somebody describes a problem they have not found the noun for
#   yet. Without this, "the" is a three-letter word that appears in every file
#   in the repository, and the top result for that query was a clock.
#
#   Portuguese as well as English: this repository is worked in both, and a
#   search that only understands one of them is a search that silently ranks
#   worse for half its queries.
#]]
STOPWORDS = {
    "the", "and", "for", "with", "that", "this", "from", "into", "onto", "not",
    "are", "was", "were", "has", "have", "had", "its", "his", "her", "their",
    "you", "your", "our", "any", "all", "how", "why", "what", "when", "who",
    "does", "did", "can", "will", "would", "should", "there", "here", "them",
    "get", "set", "new", "one", "two", "use", "using", "make", "made",
    "que", "com", "para", "uma", "dos", "das", "por", "mais", "como", "nao",
    "não", "isso", "esse", "essa", "pelo", "pela", "num", "numa", "sobre",
    "onde", "quando", "tem", "ter", "fazer", "faz", "ser", "sao", "são",
}


@dataclass
class Hit:
    shelf: str
    name: str
    where: str
    summary: str
    score: int
    detail: list[str] = field(default_factory=list)


def _first_doc_block(text: str) -> str:
    """The module's own opening explanation, flattened to one line.

    Luau block comments are the convention across this repo -- every module
    opens with `--[[ ... ]]` saying what it is for. That sentence is the only
    human-written description of intent anywhere, so it is what a search should
    match against and what it should print.
    """
    match = re.search(r"--\[\[(.*?)\]\]", text[:4000], re.S)
    body = match.group(1) if match else ""
    if not body:
        #: Fall back to a run of leading line comments, which is the older
        #: style and still used in the salvaged games.
        lines = []
        for line in text.splitlines()[:12]:
            stripped = line.strip()
            if stripped.startswith("--") and not stripped.startswith("--!"):
                lines.append(stripped.lstrip("-").strip())
            elif lines:
                break
        body = " ".join(lines)
    body = re.sub(r"\s+", " ", body).strip()
    #: Cut at the first blank-line paragraph break, which in this repo is
    #: reliably the end of the one-sentence "what this is".
    for marker in (" ---", " ===", " Why ", " What "):
        cut = body.find(marker)
        if cut > 40:
            body = body[:cut]
            break
    return body.strip()


#: Cache the compiled patterns; a search walks every file in the repo and
#: recompiling per file is most of the runtime.
_PATTERNS: dict[str, re.Pattern[str]] = {}


def _pattern(needle: str) -> re.Pattern[str]:
    """A word, not a substring, and camelCase counts as a word break.

    Plain `str.count` looked right and ranked a mining game above `Rig.grip`
    for "weld weapon hand grip", because `RebirthHandler` contains "hand" and a
    143-file kit contains it many times. Requiring a boundary on both sides
    kills that: "hand" no longer matches `Handler` (followed by a lowercase
    letter) but still matches `RightHand`, `hand.CFrame` and `HandGenerator`,
    which are all genuinely about a hand.

    This is the whole relevance model, and it is deliberately this small --
    see the module docstring on why cleverness fails in the wrong direction.
    """
    found = _PATTERNS.get(needle)
    if found is None:
        found = re.compile(r"(?<![a-z])" + re.escape(needle) + r"(?![a-z])",
                           re.IGNORECASE)
        _PATTERNS[needle] = found
    return found


def _count(needles: list[str], haystack: str) -> int:
    return sum(len(_pattern(n).findall(haystack)) for n in needles)


def _search_engine(needles: list[str]) -> list[Hit]:
    """Modules and public functions, from the index `forge api` already writes."""
    from forge.cli import apiindex

    try:
        data = apiindex.build()
    except Exception:  # noqa: BLE001 - a broken index must not break the search
        return []

    hits: list[Hit] = []
    for module in data.get("detail", []):
        name = module.get("name", "")
        summary = module.get("summary", "") or ""
        score = 0
        detail: list[str] = []

        if _count(needles, name):
            score += SCORE_NAME
        score += SCORE_SUMMARY * min(2, _count(needles, summary))

        for fn in module.get("functions", []):
            signature = fn.get("signature", "")
            fn_summary = fn.get("summary", "") or ""
            if _count(needles, signature) or _count(needles, fn_summary):
                score += SCORE_FUNCTION
                if len(detail) < 4:
                    detail.append(signature)

        path = REPO / module.get("file", "")
        if path.exists():
            try:
                score += min(BODY_CAP,
                             SCORE_BODY * _count(needles, path.read_text(
                                 encoding="utf-8", errors="ignore")))
            except OSError:
                pass

        if score:
            hits.append(Hit("engine", name, module.get("file", ""),
                            summary, score, detail))
    return hits


def _lua_files(root: Path) -> list[Path]:
    out: list[Path] = []
    for pattern in ("**/*.lua", "**/*.luau"):
        out.extend(root.glob(pattern))
    return out


def _search_games(needles: list[str]) -> list[Hit]:
    """Systems written inside games, which is where most gameplay actually is.

    The engine holds what is general; a game's `systems/` folder holds the
    working example of it. Somebody solving a shooter's hit registration wants
    `provingground/systems/Fight.lua` at least as much as `Forge.Combat`.
    """
    hits: list[Hit] = []
    games = REPO / "games"
    if not games.is_dir():
        return hits

    for game_dir in sorted(games.iterdir()):
        src = game_dir / "src"
        if not src.is_dir():
            continue
        for path in _lua_files(src):
            try:
                text = path.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                continue
            rel = path.relative_to(game_dir).as_posix()
            stem = path.stem
            score = 0
            if _count(needles, stem):
                score += SCORE_NAME
            summary = _first_doc_block(text)
            score += SCORE_SUMMARY * min(2, _count(needles, summary))
            score += min(BODY_CAP, SCORE_BODY * _count(needles, text))
            if score:
                lines = text.count("\n") + 1
                hits.append(Hit("games", game_dir.name, rel,
                                summary, score, [f"{lines} lines"]))
    return hits


def kit_description(kit_dir: Path) -> tuple[str, list[str]]:
    """What a kit actually is, derived from what is in it.

    `forge/kits/index.json` lists kit names and nothing else, so a shelf
    holding a complete, running zombie game reads exactly like a shelf holding
    four textures. Rather than hand-writing descriptions that go stale, this
    reports what is on the shelf: how much source, which subsystems, how many
    models, whether it builds.
    """
    salvage = kit_dir / "salvage"
    notes: list[str] = []
    parts: list[str] = []

    if salvage.is_dir():
        sources = _lua_files(salvage)
        if sources:
            parts.append(f"{len(sources)} source files")
        #: The subsystem folders are the honest table of contents.
        for label, probe in (
            ("maps", "Maps"), ("services", "Services"), ("bots", "Bots"),
            ("controllers", "Controllers"), ("ui", "UI"), ("systems", "systems"),
        ):
            found = list(salvage.glob(f"**/{probe}"))
            if found:
                children = [c for c in found[0].iterdir() if c.is_file()]
                notes.append(f"{label}: {len(children)}")
        if (salvage / "default.project.json").exists():
            parts.append("buildable")

    models = list(kit_dir.glob("**/*.rbxmx")) + list(kit_dir.glob("**/*.rbxm"))
    if models:
        parts.append(f"{len(models)} models")
    uploads = list((kit_dir / "upload").glob("**/*")) if (kit_dir / "upload").is_dir() else []
    uploads = [u for u in uploads if u.is_file()]
    if uploads:
        parts.append(f"{len(uploads)} uploadable assets")

    manifest = kit_dir / "kit.json"
    if manifest.exists():
        try:
            data = json.loads(manifest.read_text(encoding="utf-8"))
            source = data.get("source")
            if source:
                parts.append(f"from {Path(source).name}")
        except (OSError, json.JSONDecodeError):
            pass

    return ", ".join(parts) or "no salvage", notes


def _search_kits(needles: list[str]) -> list[Hit]:
    """Whole finished projects, which is the shelf nobody looks at.

    A kit is a game somebody already shipped. Missing one costs more than
    missing a module: the session that prompted this file spent an afternoon
    writing a zombie system with a complete zombie game sitting one directory
    away, because the only listing of kits was a column of names.
    """
    hits: list[Hit] = []
    kits = REPO / "kits"
    if not kits.is_dir():
        kits = REPO / "forge" / "kits"
    if not kits.is_dir():
        return hits

    for kit_dir in sorted(kits.iterdir()):
        if not kit_dir.is_dir():
            continue
        score = SCORE_NAME if _count(needles, kit_dir.name) else 0

        #: Names of files inside a kit are the cheapest strong signal: a kit
        #: with `Zombie.rbxmx` in it is about zombies.
        matched_files: list[str] = []
        for path in kit_dir.rglob("*"):
            if not path.is_file():
                continue
            if _count(needles, path.name):
                score += SCORE_FUNCTION
                if len(matched_files) < 5:
                    matched_files.append(path.relative_to(kit_dir).as_posix())

        #: And the source, capped, so a large kit cannot drown a small exact one.
        body = 0
        for path in _lua_files(kit_dir):
            try:
                body += _count(needles, path.read_text(encoding="utf-8",
                                                       errors="ignore"))
            except OSError:
                continue
        score += min(BODY_CAP, SCORE_BODY * body)

        if score:
            summary, notes = kit_description(kit_dir)
            hits.append(Hit("kits", kit_dir.name, f"forge/kits/{kit_dir.name}",
                            summary, score, notes + matched_files))
    return hits


def search(query: str, limit: int = 8) -> dict[str, list[Hit]]:
    needles = [w.lower() for w in re.split(r"[\s,._-]+", query)
               if len(w) > 2 and w.lower() not in STOPWORDS]
    if not needles:
        return {}
    everything = _search_engine(needles) + _search_games(needles) + _search_kits(needles)
    by_shelf: dict[str, list[Hit]] = {}
    for hit in everything:
        by_shelf.setdefault(hit.shelf, []).append(hit)
    for shelf, hits in by_shelf.items():
        hits.sort(key=lambda h: -h.score)
        by_shelf[shelf] = hits[:limit]
    return by_shelf


SHELF_TITLES = {
    "kits": "KITS - whole projects already built",
    "engine": "ENGINE - modules in forge/luau/Forge",
    "games": "GAMES - working examples in games/*/src",
}


def render(query: str, results: dict[str, list[Hit]]) -> str:
    if not results:
        return (f"forge find: nothing matches '{query}'.\n\n"
                "  That is a real answer and it is worth trusting: nothing in the\n"
                "  engine, the games or the kits mentions it. Write the thing.")

    out = [f"forge find: {query}", ""]
    #: Kits first, deliberately. They are whole games and the most expensive
    #: thing to miss, and they are the shelf an agent is least likely to check.
    for shelf in ("kits", "engine", "games"):
        hits = results.get(shelf)
        if not hits:
            continue
        out.append(f"  {SHELF_TITLES[shelf]}")
        for hit in hits:
            out.append(f"    {hit.name:<22} {hit.where}")
            if hit.summary:
                out.append(f"      {hit.summary[:150]}")
            for line in hit.detail[:4]:
                out.append(f"        - {line}")
        out.append("")

    out += [
        "  Before writing something that appears above, read it. Three systems",
        "  in this repo were written twice because this list was never asked for.",
    ]
    return plain("\n".join(out))


def render_kits() -> str:
    """Every kit, with what is actually in it.

    `forge kit` harvests and never shows, so the shelf was a column of names.
    """
    kits = REPO / "forge" / "kits"
    if not kits.is_dir():
        return "no kits directory"
    out = ["forge kits", ""]
    for kit_dir in sorted(kits.iterdir()):
        if not kit_dir.is_dir():
            continue
        summary, notes = kit_description(kit_dir)
        out.append(f"  {kit_dir.name:<18} {summary}")
        if notes:
            out.append(f"    {'  '.join(notes)}")
    out += ["", "  A kit is a finished project. Read one before rebuilding what it holds."]
    return plain("\n".join(out))

#[[
#   The console this runs on is Windows, and it is not UTF-8.
#
#   Module summaries are written with em dashes and typographic quotes, and
#   printing one to a cp1252 console turns it into a replacement character in
#   the middle of the sentence a reader is trying to skim. Sanitising at the
#   edge keeps the source files properly typeset and the output readable.
#]]
_ASCII = {
    "—": "-", "–": "-", "‘": "'", "’": "'",
    "“": '"', "”": '"', "…": "...", " ": " ",
    "→": "->", "•": "*",
}


def plain(text: str) -> str:
    for fancy, flat in _ASCII.items():
        text = text.replace(fancy, flat)
    return text.encode("ascii", "replace").decode("ascii")


# ================================ the map ===================================
#[[
#   Every module the engine has, in one page.
#
#   `forge find` answers "does this exist"; this answers the question that
#   comes before it, which is "what is there at all". An agent that has read
#   this once knows that posing is `Anim`, that weapons in hands are `Rig`, and
#   that there is a `Progression` family -- and will not write any of them
#   again. That is the whole return.
#
#   Generated rather than written, so it cannot drift from the engine. The
#   summaries are the modules' own opening sentences.
#]]
def render_map(family: str | None = None, width: int = 96) -> str:
    from forge.cli import apiindex

    data = apiindex.build()
    families: dict[str, list[dict]] = {}
    for module in data.get("detail", []):
        rel = module.get("file", "")
        parts = Path(rel).parts
        #: forge/luau/Forge/<Family>/...
        group = parts[3] if len(parts) > 4 else Path(rel).stem
        if group.endswith(".lua"):
            group = Path(group).stem
        families.setdefault(group, []).append(module)

    if family:
        wanted = family.lower()
        families = {k: v for k, v in families.items() if k.lower() == wanted}
        if not families:
            return f"no family named '{family}'"

    total_modules = sum(len(v) for v in families.values())
    total_functions = sum(len(m.get("functions", [])) for v in families.values()
                          for m in v)
    out = [
        "FORGE ENGINE MAP",
        f"{len(families)} families, {total_modules} modules, "
        f"{total_functions} public functions",
        "",
        "Run `forge find <concept>` before writing a system. It searches this,",
        "the games, and the kits at once.",
        "",
    ]

    for group in sorted(families):
        modules = sorted(families[group], key=lambda m: m.get("name", ""))
        out.append(f"{group}")
        for module in modules:
            name = module.get("name", "")
            summary = plain(module.get("summary", "") or "").strip()
            #: One sentence. The rest is in the file, and the point of a map is
            #: to be readable in one pass.
            sentence = summary.split(". ")[0][: width - 26]
            count = len(module.get("functions", []))
            out.append(f"  {name:<22} {sentence}" + (f"  [{count}]" if count else ""))
        out.append("")

    out += [
        "[n] is the count of public functions. `forge api --module <Name>`",
        "prints one module's full surface.",
    ]
    return plain("\n".join(out))
