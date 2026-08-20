"""Gameplay recipes: a genre stated once, so a game is a configuration of it.

The document's point is about scale, and it is worth stating precisely: CardTycoon,
MiningTycoon and RestaurantTycoon are not three projects. They are one recipe and
three configurations, and treating them as three projects is how the second one
takes as long as the first.

A recipe declares what a genre *requires* -- the systems, the loop verbs, the
world shape, the scenarios anyone would expect to measure. `apply` turns a small
configuration into a complete `GameModel`; `check` asks whether a model claiming
a genre actually delivers it.

Two properties make this more than a template folder.

**Applying a recipe produces a coherent model.** Not a starting point somebody
then fixes -- `apply` fills in what the genre implies, so the result passes the
IR's own coherence check without a second pass. A recipe that emitted an
incoherent model would have moved the work rather than removed it.

**Claiming a genre is checkable.** `check` catches a "tycoon" with no economy and
a "tower_defense" whose loop never defends. Genre is the word every downstream
decision keys off -- the template, the scenario classes, the asset roles -- so a
game mislabelled at the top is a game measured against the wrong bar all the way
down.

Nothing here invents a theme, a pitch or a name. Those are the whole of what
distinguishes CardTycoon from MiningTycoon, and a recipe that supplied them
would be generating games rather than genres.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Sequence


class RecipeError(ValueError):
    """The recipe could not be applied, and the message says what is missing."""


@dataclass(frozen=True)
class Recipe:
    """What a genre requires, stated once."""

    genre: str
    #: The loop a game of this genre must contain. Extra verbs are welcome; a
    #: missing one means the game is something else wearing the label.
    core_verbs: tuple[str, ...]
    #: Systems the genre cannot work without, beyond what the verbs imply.
    required_systems: tuple[str, ...]
    #: Systems that make the genre better and are not required. Listed so an
    #: agent can see the choice rather than discovering it later.
    optional_systems: tuple[str, ...] = ()
    topology: str = "grid_plots"
    progression_kind: str = "tiered"
    default_tiers: int = 8
    default_first_tier_seconds: float = 45.0
    default_session_minutes: float = 15.0
    #: Roles the world needs modelled. Feeds the art director rather than being
    #: rediscovered per game.
    asset_roles: tuple[str, ...] = ("structure", "prop")
    summary: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {
            "genre": self.genre,
            "coreVerbs": list(self.core_verbs),
            "requiredSystems": list(self.required_systems),
            "optionalSystems": list(self.optional_systems),
            "topology": self.topology,
            "progression": {
                "kind": self.progression_kind,
                "tiers": self.default_tiers,
                "firstTierSeconds": self.default_first_tier_seconds,
                "sessionMinutes": self.default_session_minutes,
            },
            "assetRoles": list(self.asset_roles),
            "summary": self.summary,
        }


#: One recipe per genre the Game IR accepts. A genre with no recipe would
#: validate as a model and have nothing to build it from.
RECIPES: dict[str, Recipe] = {
    "tycoon": Recipe(
        genre="tycoon",
        core_verbs=("collect", "process", "upgrade", "sell", "unlock"),
        required_systems=("economy", "progression", "save", "inventory", "analytics"),
        optional_systems=("shop", "offline_income", "tutorial", "leaderboard"),
        topology="grid_plots",
        progression_kind="tiered",
        asset_roles=("machine", "structure", "prop"),
        summary="a plot the player fills with machines that turn time into money, "
                "and money into faster machines",
    ),
    "simulator": Recipe(
        genre="simulator",
        core_verbs=("collect", "sell", "upgrade", "unlock"),
        required_systems=("economy", "progression", "save", "inventory", "analytics"),
        optional_systems=("shop", "pets", "gacha", "leaderboard"),
        topology="hub_and_zones",
        progression_kind="tiered",
        default_first_tier_seconds=25.0,
        asset_roles=("collectible", "structure", "prop", "hero"),
        summary="a short loop repeated fast, with zones gating the next multiplier",
    ),
    "tower_defense": Recipe(
        genre="tower_defense",
        core_verbs=("build", "defend", "upgrade"),
        required_systems=("economy", "progression", "save", "tower", "analytics"),
        optional_systems=("shop", "leaderboard"),
        topology="single_arena",
        progression_kind="wave",
        default_tiers=12,
        default_session_minutes=12.0,
        asset_roles=("machine", "structure", "character"),
        summary="a fixed arena, a path, and waves that make the last placement "
                "look wrong",
    ),
    "roguelite": Recipe(
        genre="roguelite",
        core_verbs=("explore", "fight", "collect", "unlock"),
        required_systems=("progression", "save", "inventory", "analytics"),
        optional_systems=("shop", "crafting", "economy"),
        topology="linear_levels",
        progression_kind="checkpoint",
        default_session_minutes=20.0,
        asset_roles=("character", "structure", "prop", "hero"),
        summary="a run that ends, and a ladder that does not",
    ),
    "collection": Recipe(
        genre="collection",
        core_verbs=("collect", "unlock", "upgrade"),
        # `economy` is required, not optional: the loop promises `upgrade`, and
        # an upgrade with no currency to pay for it is a button that does
        # nothing. Listing it as optional produced a recipe that could not build
        # its own loop, and the IR's coherence check caught it the first time
        # every genre was applied.
        required_systems=("inventory", "progression", "save", "economy", "analytics"),
        optional_systems=("gacha", "trading", "shop"),
        topology="hub_and_zones",
        progression_kind="unlock_graph",
        asset_roles=("collectible", "structure", "hero"),
        summary="the set is the goal; everything else exists to make the gaps "
                "visible",
    ),
    "survival": Recipe(
        genre="survival",
        core_verbs=("explore", "collect", "craft", "survive"),
        required_systems=("inventory", "crafting", "save", "progression", "analytics"),
        optional_systems=("economy", "trading", "shop"),
        topology="open_world",
        progression_kind="checkpoint",
        default_session_minutes=25.0,
        asset_roles=("structure", "vegetation", "prop", "terrain-feature"),
        summary="scarcity as the whole design; the world is the antagonist",
    ),
    "racing": Recipe(
        genre="racing",
        core_verbs=("race", "unlock", "upgrade"),
        required_systems=("progression", "save", "economy", "analytics"),
        optional_systems=("shop", "leaderboard"),
        topology="linear_levels",
        progression_kind="tiered",
        default_first_tier_seconds=90.0,
        default_session_minutes=10.0,
        asset_roles=("machine", "terrain-feature", "structure"),
        summary="one track learned, then the same track faster",
    ),
}


def recipe_for(genre: str) -> Recipe:
    if genre not in RECIPES:
        raise RecipeError(
            f"no recipe for genre {genre!r}; known genres: " + ", ".join(sorted(RECIPES))
        )
    return RECIPES[genre]


def apply(
    recipe: Recipe | str,
    *,
    id: str,
    theme: str,
    pitch: str,
    currencies: Sequence[dict[str, Any]] = (),
    zones: Sequence[dict[str, Any]] = (),
    extra_verbs: Sequence[str] = (),
    extra_systems: Sequence[str] = (),
    tiers: int | None = None,
    first_tier_seconds: float | None = None,
    session_minutes: float | None = None,
    token_set: str = "tokens/brickfarm.json",
    monetization: Sequence[str] = (),
    concurrent_players: int = 1,
    private_space: bool = False,
) -> Any:
    """A configuration becomes a whole, coherent game model.

    What the caller supplies is exactly what distinguishes one game of a genre
    from another: a theme, a pitch, the currency names, the zones. Everything
    else the genre already implied.
    """

    from ..ir import GameModel, load_model

    recipe = recipe_for(recipe) if isinstance(recipe, str) else recipe

    verbs = list(recipe.core_verbs)
    for verb in extra_verbs:
        if verb not in verbs:
            verbs.append(verb)

    systems = list(recipe.required_systems)
    for system in extra_systems:
        if system not in systems:
            systems.append(system)

    # A currency is the one thing a recipe cannot supply: what the game is
    # *about* determines what it is denominated in. But a genre that needs an
    # economy and is handed none would produce an incoherent model, so the
    # default is named after the game rather than left empty.
    if not currencies and "economy" in systems:
        earners = [v for v in verbs if v in ("sell", "process", "defend", "race", "collect")]
        spenders = [v for v in verbs if v in ("upgrade", "build", "unlock", "buy")]
        currencies = [{
            "id": "cash",
            "displayName": "Cash",
            "earnedBy": earners or ["collect"],
            "spentOn": spenders or ["upgrade"],
        }]

    document = {
        "id": id,
        "genre": recipe.genre,
        "theme": theme,
        "pitch": pitch,
        "coreLoop": verbs,
        "world": {
            "topology": recipe.topology,
            "zones": [dict(zone) for zone in zones],
        },
        "progression": {
            "kind": recipe.progression_kind,
            "tiers": recipe.default_tiers if tiers is None else tiers,
            "firstTierSeconds": (recipe.default_first_tier_seconds
                                 if first_tier_seconds is None else first_tier_seconds),
            "sessionMinutes": (recipe.default_session_minutes
                               if session_minutes is None else session_minutes),
        },
        "economy": {"currencies": [dict(currency) for currency in currencies]},
        "systems": systems,
        "monetization": list(monetization),
        "tokenSet": token_set,
        "concurrentPlayers": concurrent_players,
        "privateSpace": private_space,
    }

    model = load_model(document)
    problems = model.problems()
    if problems:
        # A recipe that emitted an incoherent model would have moved the work
        # rather than removed it. Raised here so the failure names the recipe
        # rather than surfacing three layers down as a validation error.
        raise RecipeError(
            f"the {recipe.genre} recipe produced an incoherent model for {id!r}:\n  - "
            + "\n  - ".join(problems)
            + "\n(pass the missing pieces as currencies, zones or extra_systems)"
        )
    return model


def check(model: Any) -> list[str]:
    """Does this model deliver the genre it claims.

    Genre is the word every downstream decision keys off -- the template, the
    scenario classes, the asset roles -- so a game mislabelled at the top is
    measured against the wrong bar all the way down.
    """

    try:
        recipe = recipe_for(model.genre)
    except RecipeError as exc:
        return [str(exc)]

    found: list[str] = []
    verbs = set(model.core_loop)
    systems = set(model.systems)

    missing_verbs = [verb for verb in recipe.core_verbs if verb not in verbs]
    if missing_verbs:
        found.append(
            f"a {recipe.genre} without {', '.join(missing_verbs)} in its loop is "
            f"something else wearing the label -- the genre is: "
            f"{' -> '.join(recipe.core_verbs)}"
        )

    missing_systems = [name for name in recipe.required_systems if name not in systems]
    if missing_systems:
        found.append(
            f"the {recipe.genre} recipe requires {', '.join(missing_systems)}, which "
            "this model does not declare"
        )

    if model.topology != recipe.topology:
        # A note rather than a defect: a tycoon in a hub is unusual and not
        # wrong, and refusing it would make the recipe a cage.
        found.append(
            f"note: {recipe.genre} usually uses {recipe.topology}; this model uses "
            f"{model.topology}, which is unusual rather than wrong"
        )

    if model.progression.kind != recipe.progression_kind:
        found.append(
            f"note: {recipe.genre} usually progresses by {recipe.progression_kind}; "
            f"this model uses {model.progression.kind}"
        )

    return found


def conforms(model: Any) -> bool:
    """Whether the model satisfies its genre, ignoring the notes."""

    return not [item for item in check(model) if not item.startswith("note:")]


def catalogue() -> dict[str, Any]:
    """Every recipe, and what each requires."""

    return {
        "schemaVersion": 1,
        "count": len(RECIPES),
        "recipes": [RECIPES[genre].to_dict() for genre in sorted(RECIPES)],
        "note": (
            "a recipe supplies what a genre implies; the theme, the pitch and the "
            "currencies are what distinguish one game of that genre from another, and "
            "a recipe that supplied those would be generating games rather than genres"
        ),
    }


def variants(recipe: Recipe | str, configurations: Sequence[dict[str, Any]]) -> dict[str, Any]:
    """Several games from one recipe, to show they are configurations.

    The document's own claim, made checkable: CardTycoon and MiningTycoon share
    a loop, a system set and a pipeline, and differ in exactly what a designer
    typed.
    """

    recipe = recipe_for(recipe) if isinstance(recipe, str) else recipe
    models = [apply(recipe, **configuration) for configuration in configurations]

    loops = {tuple(model.core_loop) for model in models}
    systems = {tuple(sorted(model.systems)) for model in models}
    return {
        "schemaVersion": 1,
        "genre": recipe.genre,
        "count": len(models),
        "games": [
            {"id": model.id, "theme": model.theme, "sha256": model.sha256[:16]}
            for model in models
        ],
        "sharedLoop": len(loops) == 1,
        "sharedSystems": len(systems) == 1,
        "distinct": len({model.sha256 for model in models}) == len(models),
        "note": (
            "one recipe, several games: the loop and the system set are shared, and "
            "the models differ -- which is what makes the second game a configuration "
            "rather than a project"
        ),
    }
