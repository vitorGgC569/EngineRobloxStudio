"""Derive a game's palette and light from its brief.

Every game the factory has produced so far shipped wearing `tokens/brickfarm.json`
-- the farm's greens, the farm's cream pavement and the farm's deliberately
flat midday sun -- because that path is the hardcoded default in nine call
sites. A medieval siege and a neon runner came out the same colour, which is
most of what "pouca identidade" means, and the mood it inherited (`farm-noon`,
sun at 14:00 from latitude 12, ambient lifted to 118,132,148) was authored
specifically to keep shadows short so plot geometry reads from above. Correct
for a farm tycoon. For everything else it removes the single largest source of
large-scale value structure a 3D scene has.

Two things are derived here, and they are separate on purpose.

**Hue comes from the brief.** A key is chosen from the words the designer wrote,
and it moves the hue and chroma of every role at once. This is the part that
gives a game identity, and it is also the part that is safe to get wrong: a
siege in the wrong green is still a legible scene.

**Value does not come from the brief.** The luminance each role targets is fixed
in `VALUE_LADDER` and identical in every key, because value structure is not a
style choice -- it is what makes a frame read as a photograph of a place rather
than as a diagram. Ground sits dark, structures mid, and light is spent on the
few things a player must find. A palette that lets the designer's words decide
its values will eventually be handed words that flatten it.

The measurement that drove this: a capture of the best siegehold frame scored
`scaleCoherence` 0.039 -- 97,576 fine edges against 3,803 coarse ones. There was
detail everywhere and mass structure nowhere, because the three roles covering
most of the frame (ground 0.447, pavement 0.669, structurePrimary 0.460) all sat
in the top third of the value range under a shadowless sun. Nothing separated
one large form from another. The palette's own harmony contract passed it: it
checks `max - min` across all 24 roles, which stays wide while every role that
actually covers surface is clustered bright. `value_profile` weights by declared
coverage instead, which is the number that was lying.
"""

from __future__ import annotations

import colorsys
import copy
import math
import re
from dataclasses import dataclass
from typing import Any

from ..tokens import hue_family, relative_luminance


class ArtDirectionError(ValueError):
    """A token set could not be derived, or the one derived is not usable."""


# --------------------------------------------------------------- value ladder

#: Target relative luminance per palette role, shared by every art key.
#:
#: Read it top to bottom and it is a lighting plan: the ground the player walks
#: on is the darkest large surface, built form sits above it, and the only
#: values near white are the ones a player is supposed to look at. The gaps are
#: as deliberate as the values -- `pavement` at 0.235 against `ground` at 0.115
#: is a full stop of separation, which is what makes a path read as a path from
#: across the map without needing a different hue.
#:
#: The previous set of values is recorded beside each entry where it moved, so
#: the size of the correction stays visible rather than becoming folklore.
VALUE_LADDER: dict[str, float] = {
    # Ground: the largest surface in almost every frame, and therefore the one
    # that decides whether the scene has a floor or a backdrop. Was 0.447.
    "ground": 0.115,
    "groundAlt": 0.085,          # was 0.312
    # Circulation. Brighter than ground so routes read, nowhere near white.
    "pavement": 0.235,           # was 0.669 -- near-white, and 33% of one frame
    "pathPrimary": 0.300,        # was 0.244
    "pathAlt": 0.420,            # was 0.869
    # Built form.
    "structurePrimary": 0.330,   # was 0.460
    "structureSecondary": 0.140,
    "stonePrimary": 0.300,       # was 0.466
    "stoneSecondary": 0.175,
    "slate": 0.075,
    "ink": 0.022,
    "metal": 0.260,
    "metalDark": 0.055,
    # Timber and planting: the mid-dark band that lets structures read light.
    "woodPrimary": 0.115,
    "woodSecondary": 0.055,
    "vegetationLeaf": 0.265,     # was 0.446, then 0.160 -- see FOLIAGE_GROUND_GAP
    "vegetationLeafDark": 0.215,   # the darker crown, still clear of the ground
    "vegetationBark": 0.045,
    "water": 0.130,
    # The only near-white in the set, and it is for text.
    "neutralLight": 0.830,
    # Accents. Bright against a dark field is the whole point of a dark field.
    "accentGold": 0.600,
    "accentSuccess": 0.440,
    "accentDanger": 0.220,
    "accentRare": 0.200,
}

#: Which hue a role takes from the key. Roles sharing a family move together,
#: which is what keeps a re-keyed palette coherent instead of merely different.
ROLE_FAMILY: dict[str, str] = {
    "ground": "foliage",
    "groundAlt": "foliage",
    "vegetationLeaf": "foliage",
    "vegetationLeafDark": "foliage",
    "vegetationBark": "timber",
    "woodPrimary": "timber",
    "woodSecondary": "timber",
    "structureSecondary": "timber",
    "pavement": "stone",
    "pathPrimary": "earth",
    "pathAlt": "stone",
    "structurePrimary": "stone",
    "stonePrimary": "stone",
    "stoneSecondary": "stone",
    "slate": "stone",
    "ink": "stone",
    "metal": "metal",
    "metalDark": "metal",
    "water": "water",
    "neutralLight": "stone",
    "accentGold": "gold",
    "accentSuccess": "success",
    "accentDanger": "danger",
    "accentRare": "rare",
}

#: The surface each role is made of.
#:
#: Roblox ships PBR materials -- Cobblestone, Slate, WoodPlanks, LeafyGrass and
#: a dozen more -- with real normal and roughness maps, available to every place
#: at no cost, no download and no upload. The base token set declares `Plastic`
#: for sixteen of its twenty-four roles and `SmoothPlastic` for six more, so
#: every world this factory has produced is built entirely of untextured
#: plastic. That is measured, not inferred: the scene critic reported 34% of an
#: aerial frame as "large flat untextured rectangles", and it was reading a
#: world whose every surface genuinely is one.
#:
#: This is the cheapest visual correction available anywhere in the pipeline. It
#: is one field per role and it changes every surface in every game.
#:
#: Chosen by what the role *is*, not by what looks nicest: ground is ground,
#: paving is cobblestone, a keep is brick over slate. Nothing here is in the
#: harmony contract's forbidden list -- Neon, ForceField and Glass stay out,
#: because a world that solves flatness with emissive surfaces has replaced one
#: greybox tell with a worse one.
ROLE_MATERIAL: dict[str, str] = {
    "ground": "Grass",
    "groundAlt": "LeafyGrass",
    "pavement": "Cobblestone",
    "pathPrimary": "Ground",
    "pathAlt": "Concrete",
    "structurePrimary": "Brick",
    "structureSecondary": "WoodPlanks",
    "stonePrimary": "Slate",
    "stoneSecondary": "Concrete",
    "slate": "Slate",
    "ink": "Basalt",
    "metal": "Metal",
    "metalDark": "CorrodedMetal",
    "woodPrimary": "WoodPlanks",
    "woodSecondary": "Wood",
    "vegetationLeaf": "LeafyGrass",
    "vegetationLeafDark": "LeafyGrass",
    "vegetationBark": "Wood",
    "water": "Sand",
    # Interface and accents stay smooth. A texture on a currency swatch reads as
    # dirt on the HUD, and these are the roles that appear at 20 pixels.
    "neutralLight": "SmoothPlastic",
    "accentGold": "SmoothPlastic",
    "accentSuccess": "SmoothPlastic",
    "accentDanger": "SmoothPlastic",
    "accentRare": "SmoothPlastic",
}

# A key may change what a surface *is* when the brief makes the base material
# semantically wrong.  This is intentionally narrow: most keys only recolour
# the shared material grammar.  Horror is the measured exception because a
# moonlit abbey whose dominant surface is still LeafyGrass keeps reading as a
# farm after every hue has been desaturated.
KEY_MATERIAL_OVERRIDES: dict[str, dict[str, str]] = {
    "vigil": {
        "ground": "Slate",
        "groundAlt": "Ground",
        "pathPrimary": "Cobblestone",
        "vegetationLeaf": "Grass",
        "vegetationLeafDark": "Grass",
    },
}

#: Roles whose coverage dominates a frame. Named rather than inferred, because
#: the check that matters -- "do the surfaces the player actually sees span a
#: range of values" -- is about these and not about the accent on a button.
DOMINANT_SURFACES = (
    "ground", "groundAlt", "pavement", "pathPrimary", "pathAlt",
    "structurePrimary", "stonePrimary", "stoneSecondary", "vegetationLeaf",
)

#: Bounds for `value_profile`, and what each was set from.
#:
#: The ceiling is the one that found the defect: `tokens/brickfarm.json` measures
#: a coverage-weighted mean of 0.365, which is a world made mostly of light
#: surfaces. Set at 0.300 -- below the failing set, above the derived ones, and
#: at the point where a 0.60 gold accent still has most of a stop of headroom
#: over the field it sits on.
WEIGHTED_MEAN_CEILING = 0.300
#: The floor is not a diagnosis of anything measured. The base set passes it
#: comfortably at 0.224 and so does every key here. It guards the opposite
#: failure -- a palette that solves the mean by making everything mid-grey --
#: and it is set well below the lowest derived value rather than tuned to
#: anything, because no palette has yet failed it and a threshold with no
#: failing example should not pretend to precision.
WEIGHTED_SPREAD_FLOOR = 0.085
WEIGHTED_MEAN_FLOOR = 0.070

#: How high the sun may be in the mood a game is played under.
#:
#: Shadow length is `height / tan(elevation)`: at 45 degrees a shadow is exactly
#: as long as the thing casting it, and above that it shrinks under the object
#: and stops separating one mass from the next. `farm-noon` -- the mood every
#: game the factory produced inherited -- puts the sun at 58 degrees, which is
#: what its own description says it is for ("shadows short so plot geometry
#: stays readable from above") and exactly wrong for a scene viewed from
#: standing height.
#: How far foliage must sit from the ground it stands on, in luminance.
#:
#: The defect this exists to stop: `vegetationLeaf` was placed at 0.160 and
#: `ground` at 0.115, both written by hand into the ladder above and never
#: compared to each other. Every generated world then grew 179 trees the same
#: colour as the grass under them -- correct geometry, correct size, correct
#: placement, and invisible. Three sessions of captures read that as "the map is
#: empty" and went looking for missing props.
#:
#: 0.10 is roughly one stop. Foliage is the case that matters because it is the
#: only role guaranteed to be adjacent to the ground in every frame.
FOLIAGE_GROUND_GAP = 0.10

SUN_ELEVATION_CEILING = 45.0
#: Below this the frame is more shadow than lit, which is a hero-shot mood
#: rather than one a player can read a battlefield in.
SUN_ELEVATION_FLOOR = 20.0
#: Ambient above this fills the shadows back in. `farm-noon` sits at 0.225.
OUTDOOR_AMBIENT_CEILING = 0.18

#: `Atmosphere.Density` times `Haze`, as one number for how much air the scene
#: is seen through.
#:
#: Set from an aerial capture: at 0.34 x 1.9 = 0.65 the map from 300 studs up
#: measured 2 distinct hues and a luminance spread of 23.4, and the scene critic
#: called it greybox -- correctly, because everything past the middle distance
#: really had become one flat blue. The first pass tuned this from a
#: ground-level frame, where thick air reads as depth and costs nothing.
HAZE_CEILING = 0.35

#: The daylight names the emitter's mood picker recognises. Kept here so the
#: check runs on the mood a game will actually be played under rather than on
#: every mood in the file -- a golden-hour preset is meant to have a low sun,
#: and failing it for that would be scoring the wrong thing.
DAYLIGHT_NAMES = ("noon", "day", "bright", "dia")


# ------------------------------------------------------------------- the keys


@dataclass(frozen=True)
class Key:
    """A hue scheme: what colour each role family takes.

    `hues` maps a role family to (hue in degrees, saturation 0-1). Saturation is
    per-family because a palette where stone is as chromatic as the accents has
    no accents.
    """

    name: str
    description: str
    words: tuple[str, ...]
    hues: dict[str, tuple[float, float]]
    sky_top: tuple[int, int, int]
    sky_bottom: tuple[int, int, int]
    atmosphere: tuple[int, int, int]

    def hue_for(self, family: str) -> tuple[float, float]:
        if family not in self.hues:
            raise ArtDirectionError(
                f"art key {self.name!r} has no hue for role family {family!r}; "
                f"families it covers: {', '.join(sorted(self.hues))}"
            )
        return self.hues[family]


#: The keys, in the order `key_for` considers them. Each is a real direction
#: rather than a hue rotation: the saturations differ, so a siege reads sober
#: and a neon runner reads loud from the palette alone.
KEYS: tuple[Key, ...] = (
    Key(
        name="vigil",
        description=(
            "Moon-cold masonry, dead vegetation and candle amber. Large surfaces "
            "stay nearly achromatic so warm ritual light and crimson danger are "
            "the only colours that can command the frame."
        ),
        words=(
            "horror", "terror", "haunted", "occult", "ritual", "nightmare",
            "faceless", "ghost", "abbey", "cemetery", "assombrado", "ritual",
            "pesadelo", "fantasma", "abadia", "cemiterio", "sem rosto",
        ),
        hues={
            "foliage": (194.0, 0.08), "timber": (30.0, 0.20),
            "stone": (226.0, 0.10), "earth": (32.0, 0.14),
            "metal": (218.0, 0.10), "water": (194.0, 0.26),
            "gold": (36.0, 0.88), "success": (194.0, 0.42),
            "danger": (354.0, 0.76), "rare": (274.0, 0.48),
        },
        sky_top=(106, 118, 148), sky_bottom=(54, 62, 84),
        atmosphere=(92, 104, 132),
    ),
    Key(
        name="siege",
        description=(
            "Cold quarried stone, deep moss, heraldic gold. Chroma kept low "
            "everywhere except the accents so banners and objectives are the "
            "only saturated things in frame."
        ),
        words=("medieval", "siege", "castle", "fortress", "knight", "tower defense",
               "tower defence", "kingdom", "castelo", "medieval", "cerco", "torre"),
        hues={
            "foliage": (104.0, 0.34), "timber": (26.0, 0.42), "stone": (212.0, 0.07),
            "earth": (22.0, 0.30), "metal": (208.0, 0.06), "water": (198.0, 0.36),
            "gold": (44.0, 0.78), "success": (128.0, 0.52), "danger": (4.0, 0.68),
            "rare": (280.0, 0.48),
        },
        sky_top=(206, 220, 238), sky_bottom=(158, 176, 198),
        atmosphere=(186, 202, 220),
    ),
    Key(
        name="grove",
        description=(
            "Warm agricultural greens over red clay. The farm direction, kept "
            "because it is right for what it was authored for -- but on this "
            "value ladder rather than the flat one."
        ),
        words=("farm", "garden", "grove", "harvest", "tycoon", "ranch", "meadow",
               "fazenda", "jardim", "colheita"),
        hues={
            "foliage": (98.0, 0.52), "timber": (28.0, 0.50), "stone": (38.0, 0.12),
            "earth": (14.0, 0.46), "metal": (34.0, 0.08), "water": (196.0, 0.44),
            "gold": (46.0, 0.82), "success": (120.0, 0.58), "danger": (6.0, 0.70),
            "rare": (286.0, 0.52),
        },
        sky_top=(226, 234, 246), sky_bottom=(180, 200, 220),
        atmosphere=(214, 228, 242),
    ),
    Key(
        name="circuit",
        description=(
            "Graphite and cyan with a magenta rare. Built for interiors and "
            "night exteriors, where the emissive accents carry the frame."
        ),
        words=("sci-fi", "scifi", "space", "cyber", "neon", "robot", "tech",
               "station", "futur", "espacial", "espaco", "nave"),
        hues={
            "foliage": (168.0, 0.30), "timber": (208.0, 0.18), "stone": (216.0, 0.10),
            "earth": (212.0, 0.14), "metal": (206.0, 0.09), "water": (188.0, 0.55),
            "gold": (188.0, 0.85), "success": (150.0, 0.62), "danger": (348.0, 0.72),
            "rare": (300.0, 0.66),
        },
        sky_top=(180, 198, 224), sky_bottom=(120, 138, 168),
        atmosphere=(150, 178, 210),
    ),
    Key(
        name="ember",
        description=(
            "Volcanic rock and ash under a hot sky. The dark end of the ladder "
            "does most of the work here; almost nothing is allowed to be light."
        ),
        words=("volcano", "lava", "desert", "wasteland", "ruin", "dungeon",
               "inferno", "deserto", "ruina", "masmorra", "vulcao"),
        hues={
            "foliage": (72.0, 0.30), "timber": (20.0, 0.44), "stone": (26.0, 0.09),
            "earth": (18.0, 0.48), "metal": (24.0, 0.10), "water": (176.0, 0.34),
            "gold": (38.0, 0.84), "success": (96.0, 0.52), "danger": (8.0, 0.78),
            "rare": (286.0, 0.50),
        },
        sky_top=(238, 222, 202), sky_bottom=(196, 168, 148),
        atmosphere=(226, 202, 180),
    ),
)

#: What a game gets when its brief matches nothing. `siege` rather than `grove`
#: because a sober low-chroma key is the one that survives being wrong.
DEFAULT_KEY = "siege"


def key_for(text: str) -> Key:
    """Pick the art key a brief implies.

    Word-boundary matching, not substring: `"ruina"` inside a longer word is a
    coincidence, and a key chosen by coincidence is how a tower defense ended up
    lit as a farm at noon in the first place.
    """

    key, _ = key_for_with_provenance(text)
    return key


def key_for_with_provenance(text: str) -> tuple[Key, bool]:
    """The art key a brief implies, and whether the brief actually implied it.

    Why the second value exists
    ---------------------------

    There are five art keys, and `siege` is the fallback. Measured across the
    briefs this factory is given, the fallback is not an edge case -- it is the
    common path:

        "gacha de eggs de anime"          -> siege   (nothing matched)
        "sobrevivencia zumbi noturna"     -> siege   (nothing matched)
        "torre de defesa medieval"        -> siege   (matched)

    An anime gacha and a zombie survival were lit as a medieval siege, and the
    output was indistinguishable from a brief that genuinely asked for one.
    Nineteen generated games in this repository share a palette for exactly this
    reason, and the stage that produced them says in its own docstring that
    deriving the key per game "is what makes two games look like two games".

    A fallback is a legitimate answer. A fallback that cannot be told apart from
    a decision is not, so this returns both the key and whether it was chosen.
    """

    lowered = _fold(text)
    best: tuple[int, Key] | None = None
    for key in KEYS:
        hits = sum(1 for word in key.words if _mentions(lowered, _fold(word)))
        if hits and (best is None or hits > best[0]):
            best = (hits, key)
    if best is not None:
        return best[1], True
    return next(key for key in KEYS if key.name == DEFAULT_KEY), False


def _fold(text: str) -> str:
    """Lowercase and strip the accents Portuguese briefs are written with."""

    table = str.maketrans("áàâãäéèêëíìîïóòôõöúùûüçñ", "aaaaaeeeeiiiiooooouuuucn")
    return text.lower().translate(table)


def _mentions(haystack: str, needle: str) -> bool:
    """Whole word, with an optional plural.

    A bare substring test would match `"ruina"` inside `"ruinable"` and pick a
    volcanic key for a brief about robust software. An exact-word test would
    miss `"castles"` and `"torres"`, which is how most briefs are actually
    written -- so one trailing `s` is allowed and nothing else.
    """

    return re.search(
        rf"(?<![a-z0-9]){re.escape(needle)}s?(?![a-z0-9])", haystack
    ) is not None


# ------------------------------------------------------------------ the colour


def _luminance_of(hue: float, saturation: float, lightness: float) -> float:
    red, green, blue = colorsys.hls_to_rgb(hue / 360.0, lightness, saturation)
    return relative_luminance((round(red * 255), round(green * 255), round(blue * 255)))


def solve(hue: float, saturation: float, target: float) -> tuple[int, int, int]:
    """The sRGB triple at this hue and chroma whose luminance is `target`.

    Bisection on HLS lightness rather than a formula, because relative luminance
    is not monotonic in anything convenient once saturation is involved -- a
    saturated blue cannot reach 0.6 at any lightness below white, and a solver
    that pretends otherwise silently returns a colour that is not the one the
    ladder asked for. Thirty-two steps lands within a quantisation step of 8-bit
    sRGB, and `verify` below re-measures the result rather than trusting it.
    """

    if not 0.0 <= saturation <= 1.0:
        raise ArtDirectionError(f"saturation {saturation} outside 0..1")
    low, high = 0.0, 1.0
    for _ in range(32):
        middle = (low + high) / 2
        if _luminance_of(hue, saturation, middle) < target:
            low = middle
        else:
            high = middle
    lightness = (low + high) / 2
    red, green, blue = colorsys.hls_to_rgb(hue / 360.0, lightness, saturation)
    return (round(red * 255), round(green * 255), round(blue * 255))


def _reachable(hue: float, saturation: float, target: float) -> bool:
    return _luminance_of(hue, saturation, 1.0) >= target - 1e-4


# ------------------------------------------------------------------- the light


def _moods(key: Key) -> dict[str, dict[str, Any]]:
    """Four lightings for one key, all of them with a direction.

    The sun sits at 15:00 from latitude 41 rather than 14:00 from latitude 12.
    That is a 32-degree elevation instead of 58 -- a shadow twice the height of
    what casts it instead of two thirds of it, and it is the whole
    difference between a scene with cast shadows across it and a scene lit like
    a product photograph. Ambient drops with it, because a shadow under a lifted
    ambient is a slightly different shade of the same value and contributes no
    mass structure at all.
    """

    top, bottom = key.sky_top, key.sky_bottom
    haze = key.atmosphere

    #: How much the world's own lamps must compensate for this mood's darkness.
    #:
    #: A prop light tuned for noon is invisible at midnight, and one tuned for
    #: midnight blows out a farm. The number lives with the mood because the
    #: mood is the only thing that knows how dark it made the world.
    boost = {"day": 1.0, "golden": 1.5, "overcast": 1.1, "night": 1.8}

    def post(contrast: float, saturation: float, tint: tuple[int, int, int],
             bloom: float, threshold: float, rays: float) -> dict[str, Any]:
        return {
            "bloom": {"intensity": bloom, "size": 22, "threshold": threshold},
            "colorCorrection": {"brightness": 0.0, "contrast": contrast,
                                "saturation": saturation, "tintColor": list(tint)},
            "sunRays": {"intensity": rays, "spread": 0.9},
        }

    return {
        f"{key.name}-day": {
            "lightBoost": boost["day"],
            "description": (
                "Mid-afternoon with the sun off the shoulder. The default, and "
                "chosen for gameplay: long enough shadows to separate one mass "
                "from the next, high enough sun that nothing important is in "
                "the dark."
            ),
            "lighting": {
                "technology": "Future", "brightness": 3.0, "clockTime": 15.0,
                "geographicLatitude": 41, "ambient": [26, 30, 40],
                "outdoorAmbient": [58, 66, 80],
                "colorShiftTop": list(top), "colorShiftBottom": list(bottom),
                "exposureCompensation": -0.1, "environmentDiffuseScale": 0.35,
                "environmentSpecularScale": 0.5, "shadowSoftness": 0.14,
            },
            # Measured from above, not chosen. At density 0.34 and haze 1.9 an
            # aerial capture of the whole map came back with two distinct hues
            # and a luminance spread of 23 -- the world dissolved into one blue
            # wash somewhere past 200 studs, and no amount of building fixes a
            # scene the air has erased. These values keep aerial perspective at
            # ground level and let the far side of the map keep its colour.
            "atmosphere": {"density": 0.2, "offset": 0.14, "haze": 0.95, "glare": 0.16,
                           "color": list(haze), "decay": [104, 122, 148]},
            "clouds": {"cover": 0.62, "density": 0.62, "color": [252, 252, 255]},
            "sky": {"starCount": 0, "sunAngularSize": 11, "moonAngularSize": 8},
            "post": post(0.22, 0.05, (255, 252, 248), 0.45, 1.5, 0.08),
        },
        f"{key.name}-golden": {
            "lightBoost": boost["golden"],
            "description": (
                "Low warm sun for hero shots. Not for gameplay: at this angle "
                "half the play space is in shadow and a player cannot read it."
            ),
            "lighting": {
                "technology": "Future", "brightness": 2.6, "clockTime": 17.4,
                "geographicLatitude": 34, "ambient": [34, 32, 44],
                "outdoorAmbient": [96, 82, 76],
                "colorShiftTop": [255, 226, 186], "colorShiftBottom": [188, 166, 178],
                "exposureCompensation": -0.2, "environmentDiffuseScale": 0.6,
                "environmentSpecularScale": 0.7, "shadowSoftness": 0.3,
            },
            "atmosphere": {"density": 0.28, "offset": 0.22, "haze": 1.15, "glare": 0.5,
                           "color": [246, 216, 178], "decay": [136, 110, 112]},
            "clouds": {"cover": 0.66, "density": 0.66, "color": [255, 236, 210]},
            "sky": {"starCount": 0, "sunAngularSize": 16, "moonAngularSize": 8},
            "post": post(0.18, 0.08, (255, 244, 228), 0.6, 1.5, 0.16),
        },
        f"{key.name}-overcast": {
            "lightBoost": boost["overcast"],
            "description": (
                "Flat sky, wet ground. The one mood here with no cast shadow, "
                "kept because some games want it -- and marked so nothing "
                "reaches for it by accident."
            ),
            "lighting": {
                "technology": "Future", "brightness": 1.5, "clockTime": 13.4,
                "geographicLatitude": 52, "ambient": [58, 62, 70],
                "outdoorAmbient": [92, 100, 110],
                "colorShiftTop": [212, 218, 226], "colorShiftBottom": [176, 184, 194],
                "exposureCompensation": 0.05, "environmentDiffuseScale": 0.9,
                "environmentSpecularScale": 0.35, "shadowSoftness": 0.8,
            },
            "atmosphere": {"density": 0.32, "offset": 0.26, "haze": 1.05, "glare": 0.05,
                           "color": [206, 212, 220], "decay": [138, 146, 158]},
            "clouds": {"cover": 0.92, "density": 0.78, "color": [226, 230, 236]},
            "sky": {"starCount": 0, "sunAngularSize": 8, "moonAngularSize": 8},
            "post": post(0.1, -0.04, (248, 250, 252), 0.25, 1.6, 0.0),
        },
        f"{key.name}-night": {
            "lightBoost": boost["night"],
            "description": (
                "Moonlit, with the world's own lamps doing the work. Ambient is "
                "far below the others so a lamp is worth standing near."
            ),
            "lighting": {
                "technology": "Future", "brightness": 0.9, "clockTime": 22.4,
                "geographicLatitude": 41, "ambient": [16, 18, 28],
                "outdoorAmbient": [34, 40, 58],
                "colorShiftTop": [72, 88, 128], "colorShiftBottom": [40, 48, 72],
                "exposureCompensation": 0.15, "environmentDiffuseScale": 0.4,
                "environmentSpecularScale": 0.6, "shadowSoftness": 0.45,
            },
            "atmosphere": {"density": 0.26, "offset": 0.24, "haze": 1.2, "glare": 0.1,
                           "color": [78, 92, 122], "decay": [30, 38, 58]},
            "clouds": {"cover": 0.44, "density": 0.5, "color": [126, 140, 168]},
            "sky": {"starCount": 3200, "sunAngularSize": 11, "moonAngularSize": 12},
            "post": post(0.2, -0.02, (232, 238, 255), 0.9, 1.05, 0.0),
        },
    }


# ------------------------------------------------------------------ the report


@dataclass
class ValueProfile:
    """What the palette's values look like once coverage is taken into account."""

    luminances: dict[str, float]
    weights: dict[str, float]
    weighted_mean: float
    weighted_spread: float
    dominant_spread: float
    hue_families: int

    def to_dict(self) -> dict[str, Any]:
        return {
            "weightedMean": round(self.weighted_mean, 4),
            "weightedSpread": round(self.weighted_spread, 4),
            "dominantSpread": round(self.dominant_spread, 4),
            "hueFamilies": self.hue_families,
            "floors": {
                "weightedSpread": WEIGHTED_SPREAD_FLOOR,
                "weightedMean": [WEIGHTED_MEAN_FLOOR, WEIGHTED_MEAN_CEILING],
            },
            "luminances": {k: round(v, 4) for k, v in sorted(self.luminances.items())},
        }


def value_profile(document: dict[str, Any]) -> ValueProfile:
    """Measure the value structure a palette will actually put on screen.

    Weighted by `maxSurfaceCoverage`, which is the palette's own declaration of
    how much of a frame each role is allowed to occupy. The unweighted spread
    the harmony contract checks is `max - min` over all roles, and it passed the
    frame that measured 0.039 on scale coherence -- because `ink` at 0.028 and
    `neutralLight` at 0.919 span the range while covering almost no pixels.
    """

    roles = document["palette"]["roles"]
    luminances = {name: relative_luminance(role["srgb"]) for name, role in roles.items()}
    weights = {
        name: float(role.get("maxSurfaceCoverage") or role.get("minSurfaceCoverage") or 0.01)
        for name, role in roles.items()
    }
    total = sum(weights.values()) or 1.0
    mean = sum(luminances[n] * weights[n] for n in roles) / total
    variance = sum(((luminances[n] - mean) ** 2) * weights[n] for n in roles) / total
    dominant = [luminances[n] for n in DOMINANT_SURFACES if n in luminances]
    families = {hue_family(role["srgb"]) for role in roles.values()}
    families.discard(-1)
    return ValueProfile(
        luminances=luminances,
        weights=weights,
        weighted_mean=mean,
        weighted_spread=math.sqrt(variance),
        dominant_spread=(max(dominant) - min(dominant)) if dominant else 0.0,
        hue_families=len(families),
    )


def problems(document: dict[str, Any]) -> list[str]:
    """Everything wrong with a derived token set, in the words of the defect.

    Runs on the derived document rather than on the key, so a hand-edited token
    file is held to the same standard as a generated one.
    """

    found: list[str] = []
    profile = value_profile(document)

    if profile.weighted_spread < WEIGHTED_SPREAD_FLOOR:
        found.append(
            f"coverage-weighted value spread {profile.weighted_spread:.3f} is below "
            f"{WEIGHTED_SPREAD_FLOOR}; the surfaces that cover the frame all sit at "
            "one value, which is what makes a scene read as a diagram"
        )
    if profile.weighted_mean > WEIGHTED_MEAN_CEILING:
        found.append(
            f"coverage-weighted mean value {profile.weighted_mean:.3f} is above "
            f"{WEIGHTED_MEAN_CEILING}; a frame this light has nowhere for an accent "
            "to be brighter and clips under any bloom"
        )
    if profile.weighted_mean < WEIGHTED_MEAN_FLOOR:
        found.append(
            f"coverage-weighted mean value {profile.weighted_mean:.3f} is below "
            f"{WEIGHTED_MEAN_FLOOR}; the world is too dark to read"
        )

    # Adjacency, not just spread. Two roles can both sit well inside the band
    # and still be indistinguishable from each other where they touch.
    luminances = profile.luminances
    for leaf in ("vegetationLeaf", "vegetationLeafDark"):
        if leaf not in luminances or "ground" not in luminances:
            continue
        gap = abs(luminances[leaf] - luminances["ground"])
        if gap < FOLIAGE_GROUND_GAP:
            found.append(
                f"{leaf} is {gap:.3f} from ground in luminance, under "
                f"{FOLIAGE_GROUND_GAP}; foliage that close to the ground it "
                "stands on disappears into it, and a world full of invisible "
                "trees reads as an empty one"
            )

    harmony = document["palette"]["harmony"]
    if profile.hue_families > int(harmony["maxHueFamilies"]):
        found.append(
            f"palette uses {profile.hue_families} hue families against a declared "
            f"maximum of {harmony['maxHueFamilies']}"
        )

    daylight = [
        (name, mood) for name, mood in document["moods"].items()
        if any(word in name for word in DAYLIGHT_NAMES)
    ]
    if not daylight:
        found.append(
            "no daylight mood; the emitter picks one by name from "
            + ", ".join(DAYLIGHT_NAMES)
            + ", and a game with none is played under whichever mood sorts first"
        )
    for name, mood in daylight:
        lighting = mood["lighting"]
        elevation = _sun_elevation(lighting["clockTime"], lighting["geographicLatitude"])
        if elevation > SUN_ELEVATION_CEILING:
            found.append(
                f"moods.{name} puts the sun {elevation:.0f} degrees up; above "
                f"{SUN_ELEVATION_CEILING:.0f} a shadow is shorter than the thing "
                "casting it and stops separating one mass from the next"
            )
        elif elevation < SUN_ELEVATION_FLOOR:
            found.append(
                f"moods.{name} puts the sun {elevation:.0f} degrees up; below "
                f"{SUN_ELEVATION_FLOOR:.0f} most of the play space is in shadow, which "
                "is a hero shot rather than a mood to play in"
            )

    for name, mood in document["moods"].items():
        atmosphere = mood.get("atmosphere") or {}
        thickness = float(atmosphere.get("density", 0)) * float(atmosphere.get("haze", 0))
        if thickness > HAZE_CEILING:
            found.append(
                f"moods.{name} has density x haze of {thickness:.2f}; above "
                f"{HAZE_CEILING} the far half of a map washes out to one colour, "
                "and an overview capture of it measures as greybox"
            )
        if "night" in name:
            continue
        ambient = relative_luminance(mood["lighting"]["outdoorAmbient"])
        if ambient > OUTDOOR_AMBIENT_CEILING:
            found.append(
                f"moods.{name} lifts outdoor ambient to luminance {ambient:.3f}; above "
                f"{OUTDOOR_AMBIENT_CEILING} a cast shadow is a slightly different shade "
                "of the same value and contributes no mass structure"
            )
    return found


def _sun_elevation(clock_time: float, latitude: float) -> float:
    """Roughly how high Roblox will put the sun. Enough to catch a flat noon.

    Roblox derives the sun from ClockTime and GeographicLatitude with its own
    model; this is the standard solar-position approximation at equinox, which
    agrees with it closely enough to tell 35 degrees from 75 -- which is the
    only distinction this check needs to make.
    """

    hour_angle = math.radians((clock_time - 12.0) * 15.0)
    phi = math.radians(latitude)
    sin_elevation = math.cos(phi) * math.cos(hour_angle)
    return math.degrees(math.asin(max(-1.0, min(1.0, sin_elevation))))


# ------------------------------------------------------------------- the stage


def direct(
    base: dict[str, Any],
    *,
    game_id: str,
    brief: str,
    key: str | None = None,
) -> dict[str, Any]:
    """Derive a token set for one game from a base set and its brief.

    The base supplies everything that is not colour or light -- character scale,
    door widths, type ramp, motion curves, camera profiles, audio buses. Those
    are ergonomics, not style, and a game that re-derives them per brief would
    get a different door height every time for no reason.

    What is replaced: every palette role's `srgb`, and the whole mood set.
    """

    if key:
        chosen = next((entry for entry in KEYS if entry.name == key), None)
        inferred = True
    else:
        chosen, inferred = key_for_with_provenance(brief)
    if chosen is None:
        raise ArtDirectionError(
            f"unknown art key {key!r}; keys: {', '.join(entry.name for entry in KEYS)}"
        )

    document = copy.deepcopy(base)
    roles = document["palette"]["roles"]

    missing = sorted(set(roles) - set(VALUE_LADDER))
    if missing:
        raise ArtDirectionError(
            "the base token set declares roles the value ladder does not place: "
            + ", ".join(missing)
            + ". A role with no declared value would keep the base palette's, which "
            "is how one game's art direction leaks into every other game's"
        )

    forbidden = set(document["palette"]["harmony"].get("forbiddenMaterials", []))
    for name, role in roles.items():
        family = ROLE_FAMILY[name]
        hue, saturation = chosen.hue_for(family)
        target = VALUE_LADDER[name]
        # A saturated hue cannot reach every luminance. Desaturate until it can,
        # rather than silently returning a colour off the ladder: value is the
        # part that is not allowed to drift.
        while saturation > 0.02 and not _reachable(hue, saturation, target):
            saturation -= 0.04
        role["srgb"] = list(solve(hue, saturation, target))
        surface = KEY_MATERIAL_OVERRIDES.get(chosen.name, {}).get(
            name, ROLE_MATERIAL.get(name)
        )
        if surface is not None and surface not in forbidden:
            role["material"] = surface

    document["moods"] = _moods(chosen)
    document["tokenSetId"] = f"{game_id}-{chosen.name}"
    document["revision"] = int(base.get("revision", 1))
    document["description"] = (
        f"Art direction for {game_id}: {chosen.description} "
        f"Values from the shared ladder; hues from the {chosen.name} key"
        + ("." if inferred else ", which is the fallback -- the brief matched no key.")
    )
    # `art-direction-decision` is the honest one of the four the schema allows.
    # Not `external-reference`: nothing here was read off a reference frame.
    # Not `platform-metrics`: no telemetry decided a hue. These are choices, and
    # the note says whose and on what grounds.
    #
    # The schema refuses unknown properties in provenance, so the art key and
    # the base set are written into the note rather than into fields of their
    # own -- a token set that carries its own lineage in prose is still auditable,
    # and widening the schema for one producer's bookkeeping is not.
    document["provenance"] = {
        "derivation": "art-direction-decision",
        "authoredBy": "rqe.art.direction",
        "authoredAt": str(base.get("provenance", {}).get("authoredAt", "")),
        "note": (
            (f"Art key {chosen.name!r}, selected from the brief. "
             if inferred else
             f"Art key {chosen.name!r}, WHICH THE BRIEF DID NOT ASK FOR: no word "
             f"in it matched any of the {len(KEYS)} keys, so this game was given "
             f"the fallback. Two games that both fall through here are lit "
             f"identically, and nothing downstream can tell that apart from two "
             f"games that were each decided. ")
            + f"Derived from base "
            f"token set {base.get('tokenSetId', 'unknown')!r}, whose scale, spacing, "
            "typography, motion, cameras and audio come through unchanged; only the "
            "palette colours and the moods are re-decided. Role luminances come from "
            "rqe.art.direction.VALUE_LADDER, which is shared by every art key and "
            "was set from reference measurements -- never from a capture of the game "
            "this set governs."
        ),
    }

    remaining = problems(document)
    if remaining:
        raise ArtDirectionError(
            "the derived token set does not meet its own art direction: "
            + "; ".join(remaining)
        )
    return document


def summary(document: dict[str, Any]) -> str:
    profile = value_profile(document)
    lines = [
        f"{document['tokenSetId']}",
        f"  weighted mean   {profile.weighted_mean:.3f}  "
        f"(band {WEIGHTED_MEAN_FLOOR}-{WEIGHTED_MEAN_CEILING})",
        f"  weighted spread {profile.weighted_spread:.3f}  "
        f"(floor {WEIGHTED_SPREAD_FLOOR})",
        f"  dominant spread {profile.dominant_spread:.3f}",
        f"  hue families    {profile.hue_families}",
    ]
    for name, mood in sorted(document["moods"].items()):
        lighting = mood["lighting"]
        lines.append(
            f"  {name:<20s} sun {_sun_elevation(lighting['clockTime'], lighting['geographicLatitude']):4.0f} deg"
            f"  ambient {relative_luminance(lighting['outdoorAmbient']):.3f}"
        )
    return "\n".join(lines)
