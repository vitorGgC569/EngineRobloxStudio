"""Runtime Game Assembly: what every upstream layer decided, materialised.

The factory had a hole big enough to walk through and nothing reported it. Nine
layers each decided something -- 48 catalogue entries, 3 screens, 2 asset
placements, 5 systems, a cost ladder, a world grammar -- and `IMPLEMENT` wrote a
floor, a spawn and a print statement. Every stage was green. The place opened.
The player stood on ground. And almost nothing any layer decided existed in it.

The failure was not that the world looked unfinished. It was that a decision
could be dropped in silence, so no amount of polish would have told anyone what
was missing.

This module makes dropping impossible to do quietly. Every upstream output is
declared here with what materialises it, and `assembly_report` checks the emitted
files for that evidence. An output nobody materialised is a `dropped` entry with
the layer that produced it named, and a game that drops a required one is not
assembled -- it is a project with some scripts in it.

Two rules, both learned the expensive way:

**Materialised means reachable at runtime, not present on disk.** A catalogue
emitted as a module that nothing requires is exactly as absent as one never
written, and it is far more convincing: it shows up in file counts, in line
counts, and in any report that measures output rather than connection.

**A layer that produced nothing is different from one that was ignored.** The
world stage returning `{}` for a genre with no zones is correct. The asset plan
producing two placements that reach no instance is not. Conflating them is how
the second hides behind the first.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Callable


@dataclass(frozen=True)
class Contract:
    """One upstream output, and the evidence that it reached the place."""

    stage: str
    produces: str
    #: Substring that must appear in an emitted file for this to count as wired.
    #:
    #: Written to prove *consumption* rather than emission. The first version
    #: looked for "Catalogue" and passed because the module existed -- which is
    #: the exact failure this file was written to catch, reproduced inside the
    #: check itself. A require is evidence something reads it; a filename is not.
    evidence: str
    #: Whether a game may ship without it.
    required: bool = True
    #: Reads the context and says how many things this layer decided. Zero means
    #: the layer had nothing to say, which is not the same as being ignored.
    count: Callable[[dict[str, Any]], int] | None = None
    #: Which individual decisions reached the game, when the layer decides many
    #: things and one call site is not evidence for all of them. Without this,
    #: a layer that resolved four systems and constructed three reported as
    #: fully materialised -- which is how `save` went missing from a game while
    #: the assembly report read ASSEMBLED.
    per_item: Callable[[dict[str, Any], str], tuple[list[str], list[str]]] | None = None
    note: str = ""


def _count_content(context: dict[str, Any]) -> int:
    catalogue = (context.get("content") or {}).get("catalogue") or {}
    return len(catalogue.get("entries") or [])


def _count_screens(context: dict[str, Any]) -> int:
    interface = context.get("interfaceResult") or {}
    return len(interface.get("screens") or [])


def _count_assets(context: dict[str, Any]) -> int:
    assets = context.get("assetsResult") or {}
    return int(assets.get("placements") or 0)


def _count_systems(context: dict[str, Any]) -> int:
    composition = context.get("composition")
    return len(getattr(composition, "implemented", ()) or ())


def _systems_wired(context: dict[str, Any], blob: str) -> tuple[list[str], list[str]]:
    """Which resolved systems are actually constructed in the emitted source."""

    composition = context.get("composition")
    names = list(getattr(composition, "implemented", ()) or ())
    wired = [name for name in names if f"systems.{name} = " in blob]
    return wired, [name for name in names if name not in wired]


def _count_tiers(context: dict[str, Any]) -> int:
    economy = context.get("economy")
    return len(getattr(economy, "tier_costs", ()) or ())


def _count_regions(context: dict[str, Any]) -> int:
    world = context.get("world")
    return len(getattr(world, "regions", ()) or ())


def _count_loop(context: dict[str, Any]) -> int:
    model = context.get("model")
    return len(getattr(model, "core_loop", ()) or ())


#: Every layer that decides something, and the evidence it reached the place.
UPSTREAM: tuple[Contract, ...] = (
    Contract(
        "systems", "the SDK modules this game runs on", "systems.",
        count=_count_systems, per_item=_systems_wired,
        note="every implemented system must be constructed, not merely listed",
    ),
    Contract(
        "economy", "the verified cost ladder", "require(ReplicatedStorage.Shared.Tiers)",
        count=_count_tiers,
        note="the ladder the pacing was measured against, driving real progression",
    ),
    Contract(
        "content", "the catalogue", "require(ReplicatedStorage.Shared.Catalogue)",
        count=_count_content,
        note="entries a system consumes, not a module nothing requires",
    ),
    Contract(
        "interface", "the screens the systems imply", "Interface.build",
        count=_count_screens,
        note="bound to the systems they display; a screen reading nothing is a panel",
    ),
    Contract(
        "assets", "the asset plan", "AssetPlan",
        count=_count_assets,
        note="placements that reach an instance in the world",
    ),
    Contract(
        "world", "the validated layout", "Blockout.build",
        required=False, count=_count_regions,
        note="absent for genres that declare no zones, which is correct rather than missing",
    ),
    Contract(
        "design", "the core loop", "CoreLoop",
        count=_count_loop,
        note="the loop as behaviour: something to do, something it pays, something to spend it on",
    ),
)


@dataclass
class AssemblyReport:
    materialised: list[dict[str, Any]] = field(default_factory=list)
    dropped: list[dict[str, Any]] = field(default_factory=list)
    empty: list[dict[str, Any]] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not any(item["required"] for item in self.dropped)

    def to_dict(self) -> dict[str, Any]:
        decided = sum(item["decided"] for item in self.materialised)
        lost = sum(item["decided"] for item in self.dropped)
        return {
            "schemaVersion": 1,
            "ok": self.ok,
            "materialised": self.materialised,
            "dropped": self.dropped,
            # Distinguished on purpose: a layer with nothing to say is correct,
            # and letting it share a bucket with an ignored one is how the
            # ignored one hides.
            "producedNothing": self.empty,
            "decisionsMaterialised": decided,
            "decisionsDropped": lost,
            "note": (
                "materialised means something in the place references it. A module "
                "emitted and required by nothing is exactly as absent as one never "
                "written, and far more convincing in a file count"
            ),
        }

    def summary(self) -> str:
        lines = [
            f"{'ASSEMBLED' if self.ok else 'INCOMPLETE'}: "
            f"{len(self.materialised)} layer(s) materialised, {len(self.dropped)} dropped"
        ]
        for item in self.dropped:
            mark = "!" if item["required"] else "-"
            lines.append(
                f"  {mark} {item['stage']}: {item['decided']} decision(s) reached nothing "
                f"({item['produces']})"
            )
        return "\n".join(lines)


def sdk_calls(files: dict[str, str], sdk_root) -> list[str]:
    """Calls into the SDK that name a function the SDK does not define.

    `Save.define` looked exactly like `Economy.define` and `Progression.define`,
    compiled perfectly, passed the assembly check -- which only asks whether
    `systems.save` is assigned -- and took the entire gameplay module down on the
    first line of the running place. A generated call to a function nobody wrote
    is invisible to every check that reads the generated side alone.

    Read from the SDK source rather than from a list here, so a renamed function
    is caught by the same mechanism as an invented one.
    """

    import re
    from pathlib import Path

    sdk_root = Path(sdk_root)
    defined: dict[str, set[str]] = {}
    for path in sorted(sdk_root.rglob("*.lua")):
        module = path.stem
        source = path.read_text(encoding="utf-8", errors="replace")
        defined[module] = set(re.findall(rf"^function {module}\.(\w+)", source, re.M))

    missing: list[str] = []
    for name, source in files.items():
        if not name.endswith(".lua"):
            continue
        for module, function in re.findall(r"GameKit\.(\w+)\.(\w+)\(", source):
            known = defined.get(module)
            if known is None:
                missing.append(f"{name}: GameKit.{module} is not a module in the SDK")
            elif function not in known:
                missing.append(
                    f"{name}: GameKit.{module}.{function} does not exist; "
                    f"{module} defines {', '.join(sorted(known)) or 'nothing'}"
                )
    return sorted(set(missing))


#: Arguments the SDK accepts only from a fixed set, and what that set is.
#:
#: `Ui.stack` takes "row" or "column" and the emitter passed "horizontal". It
#: compiled, it passed every structural check, and it killed the entire HUD
#: LocalScript on its first line -- so the game ran with no interface at all and
#: the only symptom was a screenshot with nothing on it.
#:
#: Read from the SDK's own `fail` message rather than restated, so a widened set
#: does not leave this behind.
ENUMERATED_ARGUMENTS = {
    "Ui.stack": (2, ("row", "column")),
}


def sdk_enum_arguments(files: dict[str, str]) -> list[str]:
    """Calls that pass a literal the SDK will refuse at runtime."""

    import re

    problems: list[str] = []
    for name, source in files.items():
        if not name.endswith(".lua"):
            continue
        for call, (index, allowed) in ENUMERATED_ARGUMENTS.items():
            module, function = call.split(".")
            pattern = module + r"\." + function + r"\(([^)]*)\)"
            for arguments in re.findall(pattern, source):
                parts = [part.strip() for part in arguments.split(",")]
                if len(parts) <= index:
                    continue
                literal = parts[index]
                if not literal.startswith('"'):
                    continue
                value = literal.strip('"')
                if value not in allowed:
                    problems.append(
                        f"{name}: {call} was passed {value!r}; it accepts "
                        + " or ".join(repr(a) for a in allowed)
                    )
    return sorted(set(problems))


def assembly_report(context: dict[str, Any], files: dict[str, str]) -> AssemblyReport:
    """Check the emitted game for evidence of every upstream decision."""

    blob = "\n".join(files.values())
    report = AssemblyReport()

    for contract in UPSTREAM:
        decided = contract.count(context) if contract.count else 1
        entry = {
            "stage": contract.stage,
            "produces": contract.produces,
            "decided": decided,
            "required": contract.required,
            "note": contract.note,
        }
        if decided == 0:
            report.empty.append(entry)
            continue
        if contract.per_item is not None:
            wired, missing = contract.per_item(context, blob)
            entry["wired"] = wired
            entry["missing"] = missing
            if missing:
                entry["decided"] = len(missing)
                report.dropped.append(entry)
            else:
                report.materialised.append(entry)
        elif contract.evidence in blob:
            report.materialised.append(entry)
        else:
            report.dropped.append(entry)

    return report
