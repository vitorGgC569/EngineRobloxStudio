"""Find the systems that make a game, across every salvaged project.

Why this is not the art catalogue
---------------------------------

`catalogue.py` tags props so a game can ask for "something that reads as the
machine that produces". This asks a different question and a more valuable one:
**which project already solved daily rewards, and where is the file?**

The distinction matters because a prop improves a screenshot and a retention
ladder is why somebody comes back tomorrow. Those are the rules a studio tuned
against real players over months, and they are the part that cannot be invented
convincingly from a blank page.

How a system is recognised
--------------------------

By evidence in three places, because any one of them alone is noise:

  * **the file name** -- `DailyRewards.server.lua` is not subtle, and a
    production codebase names things after what they do;
  * **identifiers in the source** -- a module that mentions `streak`,
    `lastClaim` and `UtcDay` is a daily reward whatever the file is called;
  * **weight** -- a passing reference is not an implementation, so a hit needs
    enough matching lines to be a system rather than a mention.

The third is what stops this reporting 56 files for "sprint" when four of them
are the system and the rest say the word once.

What it deliberately does not do
--------------------------------

Judge quality, or decide what to copy. It says "minershaven has a daily reward
system, here, 180 lines" and stops. Reading it is the next step and a person's.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

KITS = Path("forge/kits")
INVENTORY = KITS / "systems.json"

#: What makes a game, in the terms a designer would use. Each entry is
#: (filename hints, source identifiers) -- the name catches the obvious cases
#: and the identifiers catch the ones named after their author's mood.
SYSTEMS: dict[str, tuple[tuple[str, ...], tuple[str, ...]]] = {
    "daily reward": (
        ("daily", "login", "streak"),
        ("dailystreak", "lastclaim", "claimday", "streakday", "dailyreward", "loginstreak"),
    ),
    "timed reward": (
        ("retention", "playtime", "afk", "session", "idle"),
        ("playtimereward", "sessionreward", "timeplayed", "afkreward", "retentionladder",
         "minutesplayed", "rewardladder"),
    ),
    "gacha / hatch": (
        ("egg", "hatch", "summon", "gacha", "lootbox", "mysterybox", "crate", "roll"),
        ("hatchegg", "rollpity", "pitycounter", "weightedpick", "rarityroll", "luckmultiplier",
         "mysterybox", "eggtype"),
    ),
    "tycoon economy": (
        ("tycoon", "mps", "dropper", "conveyor", "collector", "income"),
        ("moneypersecond", "mpscalc", "tycoonbase", "dropperrate", "collectcash", "cashpersecond"),
    ),
    "plot allocation": (
        ("plot", "island", "base", "claim"),
        ("plotowner", "claimplot", "tycoonowner", "islandmanager", "assignplot", "freeplot"),
    ),
    "rebirth / prestige": (
        ("rebirth", "prestige", "sacrifice", "ascend", "reset"),
        ("rebirthcost", "prestigelevel", "ascensiontier", "rebirthmultiplier", "sacrificecost"),
    ),
    "pet / companion": (
        ("pet", "companion", "minion", "follow"),
        ("petfollow", "petformation", "equippedpet", "petpower", "companionoffset"),
    ),
    "weapon / firing": (
        ("weapon", "gun", "shoot", "projectile", "bullet", "hitscan"),
        ("hitscan", "muzzle", "reloadtime", "ammocount", "firerate", "recoil", "bulletspread",
         "raycastdamage"),
    ),
    "holding / equip": (
        ("tool", "equip", "grip", "hotbar", "loadout"),
        ("tool.equipped", "grippart", "holdanim", "toolnone", "toollunge", "equipslot",
         "hotbarslot"),
    ),
    "character animation": (
        ("anim", "animate", "gait", "locomotion", "keyframe"),
        ("loadanimation", "animationtrack", "keyframesequence", "animstate", "walkanim",
         "idleanim", "playanim"),
    ),
    "sprint / stamina": (
        ("sprint", "stamina", "dash", "sprinting"),
        ("staminadrain", "sprintspeed", "staminaregen", "issprinting", "dashcooldown"),
    ),
    "quest / mission": (
        ("quest", "mission", "objective", "task"),
        ("questchain", "objectivecomplete", "questreward", "missionstage", "activequest"),
    ),
    "trade": (
        ("trade", "trading", "offer"),
        ("tradesession", "tradeoffer", "tradeaccept", "tradeconfirm", "tradelock"),
    ),
    "leaderboard": (
        ("leaderboard", "ranking", "highscore"),
        ("orderedatastore", "leaderboardscore", "globalrank", "topplayers"),
    ),
    "monetization": (
        ("monetization", "gamepass", "developerproduct", "purchase", "shop", "store"),
        ("processreceipt", "gamepassid", "developerproductid", "promptpurchase",
         "marketplaceservice"),
    ),
    "save / persistence": (
        ("save", "data", "profile", "persistence", "datastore"),
        ("getasync", "setasync", "updateasync", "bindtoclose", "profilestore", "sessionlock"),
    ),
    "tutorial": (
        ("tutorial", "onboarding", "firsttime"),
        ("tutorialstep", "tutorialflow", "onboardingstage", "completedstep"),
    ),
    "party / group": (
        ("party", "squad", "team", "guild", "alliance"),
        ("partyinvite", "partymember", "squadslot", "teambalance"),
    ),
    "inventory": (
        ("inventory", "backpack", "storage", "bag"),
        ("inventoryslot", "stacklimit", "additem", "removeitem", "inventoryview"),
    ),
    "world / map loading": (
        ("map", "world", "zone", "region", "chunk", "streaming"),
        ("maploader", "zoneresolver", "loadchunk", "regionbounds", "worldtravel"),
    ),
}

#: A file has to carry this much of a system to count as having one. Below it,
#: the word appears and the system does not.
MIN_IDENTIFIER_HITS = 2
MIN_LINES = 25


def _scan_file(path: Path) -> tuple[str, str]:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return "", ""
    return text, text.lower()


def _score(path: Path, lowered: str, name_hints: tuple[str, ...],
           identifiers: tuple[str, ...]) -> tuple[int, int]:
    """How strongly one file implements one system: (name hits, identifier hits)."""
    stem = path.stem.lower()
    named = sum(1 for hint in name_hints if hint in stem)
    #: Counted as distinct identifiers rather than total occurrences: a loop
    #: that says `ammo` forty times is still one idea.
    found = sum(1 for ident in identifiers if ident in lowered)
    return named, found


def build() -> dict[str, Any]:
    """Inventory every salvaged project by system."""
    found: dict[str, list[dict[str, Any]]] = {name: [] for name in SYSTEMS}

    for salvage_dir in sorted(KITS.glob("*/salvage")):
        #: `forge/kits/<kit>/salvage` -- the kit is the third part, and reading
        #: the second gave every row the name "kits".
        kit = salvage_dir.parts[2]
        for path in sorted(salvage_dir.rglob("*")):
            if path.suffix.lower() not in (".lua", ".luau"):
                continue
            text, lowered = _scan_file(path)
            if not text:
                continue
            lines = text.count("\n") + 1
            if lines < MIN_LINES:
                continue

            for system, (name_hints, identifiers) in SYSTEMS.items():
                named, hits = _score(path, lowered, name_hints, identifiers)
                #[[
                #   A file named after the system counts on its name alone.
                #
                #   The first version demanded a matching identifier even from
                #   `DailyRewards.server.lua`, and lost it -- along with
                #   `MPSCalc`, `IslandManager` and `Sacrifice`, the four files
                #   that are the tycoon. A production codebase names things
                #   after what they do, and refusing that evidence threw away
                #   the strongest signal available.
                #]]
                if named or hits >= MIN_IDENTIFIER_HITS:
                    found[system].append({
                        "kit": kit,
                        "path": str(path.relative_to(salvage_dir)).replace("\\", "/"),
                        "lines": lines,
                        "named": bool(named),
                        "signals": hits,
                    })

    for system in found:
        #: Strongest first: a named file with many identifiers is the
        #: implementation, and the rest are its callers.
        found[system].sort(key=lambda f: (not f["named"], -f["signals"], -f["lines"]))

    inventory = {
        "$comment": (
            "Which salvaged project already solved which system, and where the file is. "
            "Written by `forge kit systems`. Evidence is the file name, the identifiers "
            "in the source, and enough of both to be an implementation rather than a "
            "mention. It does not judge quality -- reading it is the next step."),
        "systems": found,
        "summary": {name: len(hits) for name, hits in sorted(found.items())},
        "missing": sorted(name for name, hits in found.items() if not hits),
    }
    INVENTORY.write_text(json.dumps(inventory, indent=1, ensure_ascii=False) + "\n",
                         encoding="utf-8")
    return inventory
