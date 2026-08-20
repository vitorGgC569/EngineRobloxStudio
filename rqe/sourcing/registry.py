"""Where a thing should come from, before anyone builds it.

The factory generates everything. That was defensible while nothing else could
reach a place, and it stopped being defensible the day `WorldKit.Mesh` landed:
external geometry now enters through exactly the same door as Blender output --
`mesh.json`, a Luau module, an EditableMesh at runtime. No upload, no
moderation, no credential. Importing a CC0 tree is now cheaper than modelling
one.

And modelling one went badly. The kit's tree took a Blender program, a decimate
budget, an exporter and three debugging cycles, and then shipped invisible
because its palette role sat 0.046 in luminance from the ground it stood on. It
is the least authorial object in the entire kit. Quaternius publishes hundreds
of them under CC0.

So the decision this module makes is `REUSE > ADAPT > GENERATE`, and the reason
it is a module rather than a habit is that the tie-breaker is *licence*, which
is not something to decide per asset in a hurry.

**What this does not do yet.** It does not fetch anything. There are no network
calls here and no credentials. It decides, records why, and names the source --
which is the part that has to be right before any connector is worth writing,
because a downloader with no licence gate is a liability rather than a feature.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Iterable


class SourcingError(ValueError):
    """A need could not be sourced under the policy."""


@dataclass(frozen=True)
class Licence:
    """What a licence lets a generated game do, in the game's own terms."""

    id: str
    #: Usable in a published Roblox place at all.
    commercial: bool
    #: Requires a visible credit *inside the shipped game*, not in a README.
    attribution: bool
    note: str = ""

    @property
    def tier(self) -> str:
        if not self.commercial:
            return "refused"
        return "attribution" if self.attribution else "clear"


LICENCES: dict[str, Licence] = {
    "CC0": Licence("CC0", True, False, "public domain; no credit required"),
    "CC-BY-3.0": Licence(
        "CC-BY-3.0", True, True,
        "credit must appear in the running game, which makes it a UI requirement "
        "and not a packaging one"),
    "CC-BY-4.0": Licence("CC-BY-4.0", True, True, "as CC-BY-3.0"),
    "MIT": Licence("MIT", True, True, "notice must ship with the work"),
    "roblox-template": Licence(
        "roblox-template", False, False,
        "Roblox's own reference places are for learning from. Patterns and "
        "structure are unrestricted; redistributing their content inside a "
        "generated place is a separate question with its own terms, and this "
        "registry refuses it until somebody has actually read them"),
    "unknown": Licence(
        "unknown", False, False,
        "an asset whose licence nobody checked is an asset that cannot ship"),
}


@dataclass(frozen=True)
class Source:
    """A place things can come from, and what it is good for."""

    id: str
    kind: str            # geometry | material | icon | audio | code | reference
    licence: str
    formats: tuple[str, ...] = ()
    note: str = ""

    @property
    def usable(self) -> bool:
        return LICENCES[self.licence].commercial


#: The catalogue of sources, with what each is actually for.
#:
#: Ordered by preference within a kind. `internal` first everywhere: a thing the
#: factory already built and validated beats an equivalent thing it would have
#: to fetch, check and adapt.
SOURCES: tuple[Source, ...] = (
    Source("internal", "geometry", "CC0", ("mesh.json",),
           "the kit this factory has already built and scored"),
    Source("quaternius", "geometry", "CC0", ("glb", "fbx"),
           "stylised low-poly, close to Roblox's own idiom and budget"),
    Source("kenney", "geometry", "CC0", ("glb", "obj"),
           "broad and consistent; weaker on nature than Quaternius"),
    Source("polyhaven", "material", "CC0", ("exr", "png"),
           "PBR sets and HDRIs at resolutions that need downscaling for Roblox"),
    Source("ambientcg", "material", "CC0", ("png",), "thousands of PBR materials"),
    Source("kenney-ui", "icon", "CC0", ("png", "svg"),
           "no attribution, which keeps the release gate simple"),
    Source("game-icons", "icon", "CC-BY-3.0", ("svg", "png"),
           "4,000+ game icons, and every one of them puts a credit in the game"),
    Source("kenney-audio", "audio", "CC0", ("ogg", "wav"),
           "UI sounds: confirm, cancel, purchase, error. The gap that made every "
           "generated game silent"),
    Source("wally", "code", "MIT", ("lua",),
           "the Roblox package index; adopting from here gives a generated place "
           "a dependency tree it does not currently have"),
    Source("roblox-reference", "reference", "roblox-template", (),
           "official reference places. Read for structure, never copied from"),
)


#: What the factory should still author itself, whatever is available outside.
#:
#: The rule is authorship, not difficulty. A landmark is the thing a player
#: remembers a game by; a barrel is a barrel. Buying the landmark is how every
#: generated game ends up looking like every other one built from the same
#: free pack -- which is the failure mode of `REUSE > GENERATE` taken too far,
#: and it is worth naming before anyone wires a downloader.
AUTHORED_ROLES = frozenset({
    "hero", "objective", "landmark", "machine", "boss", "brand",
})

#: Roles where a mature external asset is almost always better than a generated
#: one. Repetitive, recognisable, and carrying no identity of their own.
SOURCEABLE_ROLES = frozenset({
    "vegetation", "rock", "prop", "collectible", "debris", "furniture",
    # Short interface cues carry interaction meaning, not product identity.
    # Rebuilding click/denial/reward sounds per game is exactly the kind of
    # commodity work REUSE is meant to remove. Music, voice and branded sonic
    # motifs remain unclassified and therefore authored by the safe default.
    "feedback",
})

#: Roles that no external asset can answer, whatever it costs.
#:
#: Not about quality and not about licence -- about shape. A building is sized
#: to its plot and assembled from a kit; a downloaded mesh of one is a mesh of
#: exactly one building at exactly one size, and the first time the world
#: grammar asks for a wider plot it has nothing. Ground and paving are surfaces
#: rather than objects, and a mesh is a very expensive way to draw a floor.
#:
#: Caught on the first run of the wiring: `structure` and `ground` both routed
#: to an external source because neither was named anywhere, and the generic
#: branch took them. A default that silently sources everything unnamed is the
#: same class of bug as one that silently generates everything.
STRUCTURAL_ROLES = frozenset({
    "structure", "wall", "tower", "terrace", "building", "room",
    "ground", "paving", "floor", "road", "terrain",
})


@dataclass
class Decision:
    """What to do about one need, and why."""

    need: str
    role: str
    action: str                      # reuse | adapt | generate | refuse
    source: str
    licence: str
    reason: str
    attribution_required: bool = False
    alternatives: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "need": self.need,
            "role": self.role,
            "action": self.action,
            "source": self.source,
            "licence": self.licence,
            "reason": self.reason,
            "attributionRequired": self.attribution_required,
            "alternatives": self.alternatives,
        }


def sources_for(kind: str) -> list[Source]:
    """Usable sources for a kind, in preference order."""

    return [source for source in SOURCES if source.kind == kind and source.usable]


def decide(need: str, *, role: str, kind: str,
           available: Iterable[str] = ()) -> Decision:
    """Reuse, adapt, generate or refuse -- and say which, and why.

    `available` is what a connector reported it can actually supply. Empty means
    nothing was found or nothing was asked, and the answer is to generate --
    never to refuse, because a factory that stops when a download fails is worse
    than one that builds its own barrel.
    """

    have = {item for item in available}

    if role in STRUCTURAL_ROLES:
        return Decision(
            need, role, "generate", "internal", "CC0",
            "modular or a surface: sized to its plot and assembled from a kit, "
            "so a downloaded mesh of one is a mesh of exactly one at exactly "
            "one size",
        )

    if role in AUTHORED_ROLES:
        return Decision(
            need, role, "generate", "internal", "CC0",
            "this role carries the game's identity. Sourcing it is how every "
            "game built from the same free pack ends up looking like the same "
            "game",
        )

    if "internal" in have:
        return Decision(
            need, role, "reuse", "internal", "CC0",
            "already built, validated and scored here; nothing external beats "
            "an asset that has passed this pipeline's own critic",
        )

    # Only roles named as sourceable are bought. An unknown role is built.
    #
    # The first version fell through to "adapt" for anything with a matching
    # kind, so a role nobody had classified went shopping -- which is the same
    # bug as the structural one, and the comment above it claimed to have fixed
    # it while the code below still did the wrong thing. A test caught it.
    #
    # Both defaults now point the same way: unknown means the factory builds it.
    # That is the cheap, visible failure. Silently sourcing an unclassified role
    # is the expensive, invisible one.
    if role not in SOURCEABLE_ROLES:
        return Decision(
            need, role, "generate", "internal", "CC0",
            f"role {role!r} is not classified as sourceable; an unclassified "
            "role is built rather than bought, because a wrong purchase is "
            "harder to notice than a wrong build",
        )

    for source in sources_for(kind):
        if source.id == "internal" or source.id not in have:
            continue
        licence = LICENCES[source.licence]
        return Decision(
            need, role, "reuse", source.id, licence.id,
            f"{source.note}; {licence.note}",
            attribution_required=licence.attribution,
            alternatives=[other.id for other in sources_for(kind)
                          if other.id != source.id],
        )

    return Decision(
        need, role, "generate", "internal", "CC0",
        "no usable source offered this; the factory builds it, which is the "
        "path that always works",
    )


def attributions(decisions: Iterable[Decision]) -> list[dict[str, str]]:
    """Credits that must appear inside the shipped game.

    Returned as data rather than text because this has to reach a screen. A
    CC-BY asset whose credit sits in a repository file is a licence breach with
    a tidy commit history.
    """

    seen: dict[str, dict[str, str]] = {}
    for decision in decisions:
        if not decision.attribution_required:
            continue
        seen[decision.source] = {
            "source": decision.source,
            "licence": decision.licence,
            "note": LICENCES[decision.licence].note,
        }
    return list(seen.values())


def policy() -> dict[str, Any]:
    """The whole policy, for a report or a gate to read."""

    return {
        "schemaVersion": 1,
        "order": ["reuse", "adapt", "generate"],
        "rule": "reuse beats adapt beats generate when quality is equivalent, "
                "except for roles that carry the game's identity",
        "authoredRoles": sorted(AUTHORED_ROLES),
        "structuralRoles": sorted(STRUCTURAL_ROLES),
        "sourceableRoles": sorted(SOURCEABLE_ROLES),
        "sources": [
            {"id": s.id, "kind": s.kind, "licence": s.licence,
             "usable": s.usable, "note": s.note}
            for s in SOURCES
        ],
        "refused": [
            {"licence": key, "why": value.note}
            for key, value in LICENCES.items() if not value.commercial
        ],
        "note": "decides and records; fetches nothing. A downloader without a "
                "licence gate in front of it is a liability, so the gate is "
                "what got written first",
    }
