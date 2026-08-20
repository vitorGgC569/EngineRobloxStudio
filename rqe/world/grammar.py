"""World grammar: what a hub *is*, what a zone *is*, structurally.

The document's ask is one sentence: an agent says "zona vulcânica de dificuldade
4" and the engine knows what a zone requires. `world_plan` already validates a
layout, but only one somebody wrote -- it will happily approve a zone that is
one square room with a spawn in it, because nothing in the planner knows that a
zone without an entrance, a main path, something to do and something to aim at
is not a zone.

So the structure lives here, as a grammar. A `Hub` is a landmark plus shops plus
a social space plus one portal per zone it connects. A `Zone` is an entrance, a
main path, gameplay nodes, a landmark, and a transition out -- with secondary
paths and a secret appearing as difficulty rises, because that is what a harder
zone means spatially rather than numerically.

Two things keep this from being decoration:

**Sizes come from the token grammar.** `corridorWidth`, `roomMinDimension`,
`plotMinDimension` and `landmarkMinHeight` are already the numbers the rest of
the engine builds against. A grammar inventing its own would produce worlds that
validate here and fail the blockout, or worse, pass both and feel wrong beside
the rest of the game.

**The output is a real `WorldSpec`.** Not a description of one -- the same
dataclass `world_plan` takes, so an expanded zone goes straight through the
existing validator including its reachability walk. A grammar that emitted
something only it understood would be a third world format.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Any

from .authoring import Landmark, Region, Route, WorldSpec, WorldSpecError


#: What a zone is made of, in the order a player meets it. The counts scale with
#: difficulty; the *presence* of each does not, because a zone missing its
#: entrance or its landmark is not an easier zone, it is an unfinished one.
#: Topologies whose structure comes from the topology rather than from declared
#: zones. A game using one of these has a world even with no zone list.
ZONELESS_TOPOLOGIES = ("single_arena",)

ZONE_PARTS = ("entrance", "main_path", "gameplay", "landmark", "transition")

#: What a hub is made of. Portals are per connected zone rather than a fixed
#: count, so a hub always has a way to everywhere it claims to reach.
HUB_PARTS = ("landmark", "shops", "social")

#: Difficulty is spatial, not a number on a label. Each step adds something to
#: traverse and something to find; beyond this the zone stops being legible.
MAX_DIFFICULTY = 5


class GrammarError(WorldSpecError):
    """The grammar could not build the world that was asked for."""


@dataclass(frozen=True)
class Grammar:
    """The dimensions a world is built from, taken from the token set."""

    corridor_width: float
    room_min: float
    plot_min: float
    landmark_min_height: float
    avenue_width: float
    landmark_read_distance: float

    @classmethod
    def from_tokens(cls, tokens: dict[str, Any]) -> "Grammar":
        scale = (tokens.get("scale") or {}).get("grammar") or {}
        legibility = (tokens.get("scale") or {}).get("legibility") or {}
        missing = [
            key for key in
            ("corridorWidth", "roomMinDimension", "plotMinDimension",
             "landmarkMinHeight", "avenueWidth")
            if key not in scale
        ]
        if missing:
            # Refused rather than defaulted. A world built to invented
            # dimensions validates here and feels wrong beside the rest of the
            # game, which is the hardest kind of wrong to attribute later.
            raise GrammarError(
                "the token set has no " + ", ".join(missing)
                + " in scale.grammar; the world grammar builds to the game's own "
                "dimensions and will not invent them"
            )
        return cls(
            corridor_width=float(scale["corridorWidth"]),
            room_min=float(scale["roomMinDimension"]),
            plot_min=float(scale["plotMinDimension"]),
            landmark_min_height=float(scale["landmarkMinHeight"]),
            avenue_width=float(scale["avenueWidth"]),
            landmark_read_distance=float(legibility.get("landmarkReadDistance", 900.0)),
        )


def _counts_for(difficulty: int) -> dict[str, int]:
    """What a difficulty level means, spatially.

    Stated as a table rather than a formula so a designer can read what
    difficulty 4 will actually contain, and argue with it.
    """

    if not 1 <= difficulty <= MAX_DIFFICULTY:
        raise GrammarError(
            f"difficulty must be 1..{MAX_DIFFICULTY}; got {difficulty}. Past that a zone "
            "stops being legible rather than becoming harder"
        )
    return {
        "gameplay": 1 + difficulty,          # 2 at d1, 6 at d5
        "secondary_paths": max(difficulty - 1, 0),
        "secrets": difficulty // 2,          # first secret at d2, second at d4
    }


def expand_zone(
    zone_id: str,
    *,
    theme: str,
    difficulty: int,
    grammar: Grammar,
    origin: tuple[float, float, float] = (0.0, 0.0, 0.0),
    is_spawn: bool = False,
) -> tuple[list[Region], list[Route], list[Landmark]]:
    """One zone, as the regions a blockout can build.

    Laid out along +X from the entrance: the main path runs the length, gameplay
    nodes hang off it, the landmark sits at the far end where it is visible down
    the path, and the transition follows it. Deliberately simple geometry --
    interesting *shape* is the dresser's job, and a grammar that also tried to
    compose would make the two impossible to debug separately.
    """

    counts = _counts_for(difficulty)
    x, y, z = origin
    regions: list[Region] = []
    routes: list[Route] = []
    landmarks: list[Landmark] = []

    span = max(grammar.room_min, grammar.corridor_width * 2)
    path_length = span * (2 + counts["gameplay"])

    entrance = f"{zone_id}-entrance"
    regions.append(Region(
        id=entrance, kind="corridor", centre=(x, y, z),
        size=(span, span), spawn=is_spawn,
    ))

    main = f"{zone_id}-path"
    main_centre = (x + path_length / 2 + span / 2, y, z)
    # Both axes clear `roomMinDimension`. A path is a corridor conceptually, but
    # WorldKit checks every region's *shorter* side against the minimum usable
    # space -- and it is right to: a 12-wide strip is a place a player squeezes
    # through, not one they play in. Using corridorWidth here was the first
    # thing the real validator rejected.
    regions.append(Region(
        id=main, kind="street", centre=main_centre,
        size=(path_length, max(grammar.room_min, grammar.corridor_width)),
    ))
    routes.append(Route(entrance, main, width=grammar.corridor_width))

    # Gameplay nodes alternate sides of the path so a player crosses it rather
    # than walking a straight line past everything.
    for index in range(counts["gameplay"]):
        node = f"{zone_id}-node{index + 1}"
        offset = span * (1.0 if index % 2 == 0 else -1.0)
        regions.append(Region(
            id=node, kind="plot",
            centre=(x + span * (1.5 + index * 1.5), y, z + offset),
            size=(span, span),
        ))
        routes.append(Route(main, node, width=grammar.corridor_width))

    # Secondary paths connect nodes to each other, so a harder zone has more
    # than one way through rather than merely more to do.
    node_ids = [r.id for r in regions if r.id.startswith(f"{zone_id}-node")]
    for index in range(min(counts["secondary_paths"], max(len(node_ids) - 1, 0))):
        # Full corridor width, like every other route. Narrowing a secondary
        # path to signal "lesser" makes it untraversable -- the token grammar's
        # corridorWidth is a floor, not a suggestion. What makes these secondary
        # is that they join nodes to each other rather than to the main path.
        routes.append(Route(node_ids[index], node_ids[index + 1],
                            width=grammar.corridor_width))

    for index in range(counts["secrets"]):
        secret = f"{zone_id}-secret{index + 1}"
        regions.append(Region(
            id=secret, kind="decorative",
            centre=(x + span * (2.0 + index * 2.0), y, z + span * 2.2),
            size=(span, span),
        ))
        # Reached from a node rather than the main path: a secret on the main
        # route is not a secret, it is a room.
        routes.append(Route(node_ids[min(index, len(node_ids) - 1)], secret,
                            width=grammar.corridor_width))

    landmark_id = f"{zone_id}-landmark"
    landmark_x = x + path_length + span
    regions.append(Region(
        id=landmark_id, kind="landmark",
        centre=(landmark_x, y, z), size=(span * 1.5, span * 1.5),
    ))
    routes.append(Route(main, landmark_id, width=grammar.corridor_width))
    landmarks.append(Landmark(
        id=landmark_id,
        at=(landmark_x, y + grammar.landmark_min_height, z),
        height=grammar.landmark_min_height,
        # Visible from the entrance: a landmark you cannot see from where you
        # arrive is not orienting anybody.
        visible_from=(entrance, main),
    ))

    transition = f"{zone_id}-exit"
    regions.append(Region(
        id=transition, kind="corridor",
        centre=(landmark_x + span * 1.5, y, z), size=(span, span),
    ))
    routes.append(Route(landmark_id, transition, width=grammar.corridor_width))

    return regions, routes, landmarks


def expand_hub(
    *,
    grammar: Grammar,
    zone_ids: list[str],
    origin: tuple[float, float, float] = (0.0, 0.0, 0.0),
) -> tuple[list[Region], list[Route], list[Landmark]]:
    """The hub, with one portal per zone it claims to reach."""

    x, y, z = origin
    span = max(grammar.room_min, grammar.plot_min / 3)
    regions: list[Region] = []
    routes: list[Route] = []

    regions.append(Region(id="hub", kind="plaza", centre=(x, y, z),
                          size=(span * 2, span * 2), spawn=True))
    regions.append(Region(id="hub-shops", kind="shop",
                          centre=(x - span * 1.5, y, z), size=(span, span)))
    regions.append(Region(id="hub-social", kind="plaza",
                          centre=(x, y, z - span * 1.5), size=(span, span)))
    routes.append(Route("hub", "hub-shops", width=grammar.avenue_width))
    routes.append(Route("hub", "hub-social", width=grammar.avenue_width))

    landmark = Landmark(
        id="hub-landmark", at=(x, y + grammar.landmark_min_height, z),
        height=grammar.landmark_min_height,
        visible_from=("hub", "hub-shops", "hub-social"),
    )
    regions.append(Region(id="hub-landmark", kind="landmark",
                          centre=(x, y, z + span * 1.5), size=(span, span)))
    routes.append(Route("hub", "hub-landmark", width=grammar.avenue_width))

    # One portal per zone. A hub that claims to reach four zones and has three
    # doors leaves one zone reachable only by falling into it.
    angle_step = (2 * math.pi) / max(len(zone_ids), 1)
    for index, zone_id in enumerate(zone_ids):
        angle = angle_step * index
        portal = f"portal-{zone_id}"
        regions.append(Region(
            id=portal, kind="corridor",
            centre=(x + math.cos(angle) * span * 3.0, y, z + math.sin(angle) * span * 3.0),
            size=(max(grammar.room_min, grammar.corridor_width * 2),
                  max(grammar.room_min, grammar.corridor_width * 2)),
        ))
        routes.append(Route("hub", portal, width=grammar.avenue_width))

    return regions, routes, [landmark]


def build_world(
    world_id: str,
    *,
    tokens: dict[str, Any],
    zones: list[dict[str, Any]],
    topology: str = "hub_and_zones",
) -> WorldSpec:
    """A whole world, from zone descriptions the game model already carries.

    Takes the same `{id, theme, difficulty}` shape the Game IR declares, so a
    model's zones expand without being restated.
    """

    grammar = Grammar.from_tokens(tokens)
    if topology not in ("hub_and_zones", "linear_levels", "single_arena",
                        "open_world"):
        raise GrammarError(
            f"the grammar builds hub_and_zones, linear_levels, single_arena "
            f"and open_world; "
            f"{topology!r} has no structure declared"
        )
    if not zones and topology != "single_arena":
        raise GrammarError(f"{topology} needs at least one zone")

    regions: list[Region] = []
    routes: list[Route] = []
    landmarks: list[Landmark] = []

    span = max(grammar.room_min, grammar.plot_min / 3)
    zone_ids = [str(zone["id"]) for zone in zones]

    if topology == "open_world":
        # No hub and no chain: zones ring a shared centre and every one of them
        # connects to its neighbours, so a player picks a direction rather than
        # a level.
        #
        # Added because the regression corpus asked for it. `tidewatch` -- an
        # island survival brief -- was the one entry of twenty that would not
        # build, and the reason was that this factory had only ever been asked
        # for the three topologies a tower defense and a tycoon need. One game
        # cannot show you the shape of that gap; twenty did it on the first run.
        import math as _math

        count = max(len(zone_ids), 1)
        radius = span * 9.0
        for index, zone in enumerate(zones):
            zone_id = str(zone["id"])
            angle = (index / count) * _math.tau
            origin = (_math.cos(angle) * radius, 0.0, _math.sin(angle) * radius)
            zone_regions, zone_routes, zone_landmarks = expand_zone(
                zone_id,
                theme=str(zone.get("theme", "")),
                difficulty=int(zone.get("difficulty", 1)),
                grammar=grammar,
                origin=origin,
                is_spawn=(index == 0),
            )
            regions.extend(zone_regions)
            routes.extend(zone_routes)
            landmarks.extend(zone_landmarks)
            # Ring roads: neighbour to neighbour, closing the loop. A world you
            # can only cross through the middle is a hub wearing a disguise.
            following = zone_ids[(index + 1) % count]
            if following != zone_id:
                routes.append(Route(f"{zone_id}-exit", f"{following}-entrance",
                                    width=grammar.corridor_width))
        return WorldSpec(
            id=world_id,
            regions=tuple(regions),
            circulation=tuple(routes),
            landmarks=tuple(landmarks),
        )

    if topology == "hub_and_zones":
        hub_regions, hub_routes, hub_landmarks = expand_hub(
            grammar=grammar, zone_ids=zone_ids)
        regions.extend(hub_regions)
        routes.extend(hub_routes)
        landmarks.extend(hub_landmarks)

    for index, zone in enumerate(zones):
        zone_id = str(zone["id"])
        # Zones are laid out well clear of each other and of the hub. Overlap is
        # a blockout problem, not a grammar one, and spacing here costs nothing.
        origin = (span * 12.0 * (index + 1), 0.0, span * 6.0 * index)
        zone_regions, zone_routes, zone_landmarks = expand_zone(
            zone_id,
            theme=str(zone.get("theme", "")),
            difficulty=int(zone.get("difficulty", 1)),
            grammar=grammar,
            origin=origin,
            is_spawn=(topology != "hub_and_zones" and index == 0),
        )
        regions.extend(zone_regions)
        routes.extend(zone_routes)
        landmarks.extend(zone_landmarks)

        if topology == "hub_and_zones":
            routes.append(Route(f"portal-{zone_id}", f"{zone_id}-entrance",
                                width=grammar.corridor_width))
        elif index > 0:
            # Linear levels: the previous zone's exit is this one's way in.
            routes.append(Route(f"{zone_ids[index - 1]}-exit", f"{zone_id}-entrance",
                                width=grammar.corridor_width))

    if topology == "single_arena":
        # An arena is not one square. A defense or a survival round needs
        # somewhere the player stands, somewhere the threat walks, somewhere it
        # is heading, and room to build beside the route -- and naming those
        # separately is what lets the asset director budget for them and the
        # dressing tell them apart. One undifferentiated box downstream is why
        # every arena game came out as a plate.
        span = grammar.plot_min
        lane = grammar.corridor_width * 3
        regions.extend([
            Region(id="staging", kind="plaza", centre=(0.0, 0.0, span * 0.6),
                   size=(span * 0.5, span * 0.35), spawn=True),
            Region(id="arena", kind="arena", centre=(0.0, 0.0, 0.0),
                   size=(span, span)),
            Region(id="lane", kind="corridor", centre=(0.0, 0.0, 0.0),
                   size=(lane, span * 1.4)),
            Region(id="objective", kind="landmark", centre=(0.0, 0.0, -span * 0.6),
                   size=(span * 0.3, span * 0.3)),
            Region(id="build_west", kind="plot", centre=(-span * 0.45, 0.0, 0.0),
                   size=(span * 0.35, span * 0.8)),
            Region(id="build_east", kind="plot", centre=(span * 0.45, 0.0, 0.0),
                   size=(span * 0.35, span * 0.8)),
        ])
        routes.extend([
            Route("staging", "arena", width=grammar.corridor_width),
            Route("arena", "lane", width=grammar.corridor_width),
            Route("lane", "objective", width=grammar.corridor_width),
            Route("arena", "build_west", width=grammar.corridor_width),
            Route("arena", "build_east", width=grammar.corridor_width),
        ])
        landmarks.append(Landmark(
            id="objective-core", at=(0.0, grammar.landmark_min_height / 2, -span * 0.6),
            height=grammar.landmark_min_height,
            visible_from=("staging", "arena", "lane"),
        ))

    return WorldSpec(
        id=world_id,
        regions=tuple(regions),
        circulation=tuple(routes),
        landmarks=tuple(landmarks),
    )


def describe(zones: list[dict[str, Any]], *, tokens: dict[str, Any]) -> dict[str, Any]:
    """What the grammar *would* build, without building it.

    So an agent can see that difficulty 4 means six gameplay nodes and two
    secrets before committing to a world, rather than counting regions
    afterwards.
    """

    grammar = Grammar.from_tokens(tokens)
    return {
        "schemaVersion": 1,
        "zoneParts": list(ZONE_PARTS),
        "hubParts": list(HUB_PARTS),
        "maxDifficulty": MAX_DIFFICULTY,
        "dimensions": {
            "corridorWidth": grammar.corridor_width,
            "roomMinDimension": grammar.room_min,
            "plotMinDimension": grammar.plot_min,
            "landmarkMinHeight": grammar.landmark_min_height,
            "avenueWidth": grammar.avenue_width,
            "source": "scale.grammar in the token set, not invented here",
        },
        "zones": [
            {
                "id": zone["id"],
                "difficulty": int(zone.get("difficulty", 1)),
                **_counts_for(int(zone.get("difficulty", 1))),
            }
            for zone in zones
        ],
    }
