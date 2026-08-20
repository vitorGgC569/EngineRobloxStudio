"""The modelling program: what an agent writes instead of `bpy`.

A program is an ordered list of operations over named objects. It is data, so it
can be validated before Blender starts, diffed between revisions, stored in an
asset package as the thing that produced the mesh, and re-executed to get the
identical result.

That last property is the reason this exists rather than letting an agent emit
Python. A generated `bpy` script is opaque: nothing can check it before it runs,
a revision cannot be diffed meaningfully, and an asset whose provenance is
"some script we no longer have" cannot be reproduced. A program can be all
three.

The vocabulary is deliberately small and shaped like how a modeller describes
work -- base box, bevel, extrude the reactor, array the vents radially, join,
unwrap, assign materials, decimate to budget. Anything Blender can do that is
not in this list is not reachable by an agent, and that is intentional: the
surface is the contract.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any, Iterable


class ProgramError(ValueError):
    """The program is not executable."""


#: Every operation, its required parameters, and whether it creates a new object.
#: Held as data so the vocabulary can be reported to an agent and validated
#: without a second copy in the Blender-side interpreter.
OPERATIONS: dict[str, dict[str, Any]] = {
    # -- primitives ----------------------------------------------------
    "box": {"creates": True, "required": ("name", "size"), "optional": ("location", "rotation")},
    "cylinder": {"creates": True, "required": ("name", "radius", "depth"),
                 "optional": ("location", "rotation", "vertices")},
    "cone": {"creates": True, "required": ("name", "radius", "depth"),
             "optional": ("location", "rotation", "radiusTop", "vertices")},
    "sphere": {"creates": True, "required": ("name", "radius"),
               "optional": ("location", "segments", "rings")},
    "torus": {"creates": True, "required": ("name", "majorRadius", "minorRadius"),
              "optional": ("location", "rotation", "majorSegments", "minorSegments")},
    "plane": {"creates": True, "required": ("name", "size"), "optional": ("location", "rotation")},

    # -- transforms ----------------------------------------------------
    "translate": {"creates": False, "required": ("target", "offset"), "optional": ()},
    "rotate": {"creates": False, "required": ("target", "angles"), "optional": ()},
    "scale": {"creates": False, "required": ("target", "factor"), "optional": ()},
    "origin": {"creates": False, "required": ("target",), "optional": ("mode", "location")},

    # -- topology ------------------------------------------------------
    "bevel": {"creates": False, "required": ("target", "width"), "optional": ("segments", "angleLimit")},
    "extrude": {"creates": False, "required": ("target", "offset"), "optional": ("faceAxis", "faceDirection")},
    "inset": {"creates": False, "required": ("target", "thickness"), "optional": ("depth", "faceAxis", "faceDirection")},
    "solidify": {"creates": False, "required": ("target", "thickness"), "optional": ("offset",)},
    "subdivide": {"creates": False, "required": ("target", "cuts"), "optional": ("smooth",)},

    # The four that were missing, and what each unblocks. Every "Blocked" row
    # in the parts manifest traced back to one of them.
    #
    # `sweep` creates: it is the only op here that builds an object, because a
    # path through space has no primitive to start from.
    "weld": {"creates": False, "required": ("target",), "optional": ("distance",)},
    "screw": {"creates": False, "required": ("target",),
              "optional": ("axis", "angle", "segments", "rise", "merge")},
    "displace": {"creates": False, "required": ("target",),
                 "optional": ("strength", "scale", "detail", "midLevel",
                              "minimumVertices")},
    "sweep": {"creates": True, "required": ("name", "points"),
              "optional": ("radius", "sides", "smoothness", "closed", "caps")},
    "loopcut": {"creates": False, "required": ("target",),
                "optional": ("cuts", "axis")},
    "remesh": {"creates": False, "required": ("target", "voxelSize"), "optional": ("adaptivity",)},
    "smooth_shade": {"creates": False, "required": ("target",), "optional": ("angle",)},
    "triangulate": {"creates": False, "required": ("target",), "optional": ()},

    # -- composition ---------------------------------------------------
    "boolean": {"creates": False, "required": ("target", "tool", "operation"), "optional": ("keepTool",)},
    "array_linear": {"creates": False, "required": ("target", "count", "offset"), "optional": ()},
    "array_radial": {"creates": False, "required": ("target", "count"), "optional": ("axis", "radius", "centre")},
    "mirror": {"creates": False, "required": ("target", "axis"), "optional": ("centre",)},
    "duplicate": {"creates": True, "required": ("name", "source"), "optional": ("location", "rotation", "factor")},
    "join": {"creates": True, "required": ("name", "targets"), "optional": ()},
    "delete": {"creates": False, "required": ("target",), "optional": ()},

    # -- surface -------------------------------------------------------
    "uv_unwrap": {"creates": False, "required": ("target",), "optional": ("method", "angleLimit", "islandMargin")},
    "material": {"creates": False, "required": ("target", "slots"), "optional": ("assign",)},

    # -- budget --------------------------------------------------------
    "decimate": {"creates": False, "required": ("target",), "optional": ("triangleBudget", "ratio")},
}

BOOLEAN_OPERATIONS = frozenset({"union", "difference", "intersect"})
UV_METHODS = frozenset({"smart", "cube", "cylinder", "sphere", "unwrap"})
AXES = frozenset({"X", "Y", "Z"})
ORIGIN_MODES = frozenset({"geometry", "bounds", "cursor", "point"})

#: Roblox's documented ceiling for one mesh. A program that asks for more is
#: refused here rather than after Blender has spent two minutes producing it.
ROBLOX_TRIANGLE_LIMIT = 20_000


@dataclass(frozen=True)
class MaterialSlot:
    """One material on a mesh.

    Roblox imports a mesh with its material slots, and every extra slot is a
    separate draw call. The count is capped in `validation`, not here, because
    an intermediate program may legitimately hold more before a merge.
    """

    name: str
    base_color: tuple[int, int, int]
    metallic: float = 0.0
    roughness: float = 0.6
    emissive: tuple[int, int, int] | None = None
    emissive_strength: float = 0.0

    def to_dict(self) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "name": self.name,
            "baseColor": list(self.base_color),
            "metallic": self.metallic,
            "roughness": self.roughness,
        }
        if self.emissive is not None:
            payload["emissive"] = list(self.emissive)
            payload["emissiveStrength"] = self.emissive_strength
        return payload


@dataclass(frozen=True)
class Program:
    id: str
    steps: tuple[dict[str, Any], ...]
    #: The object the package exports. Named explicitly so a program with
    #: leftover scaffolding still exports the right thing.
    result: str
    units: str = "studs"
    metadata: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "id": self.id,
            "units": self.units,
            "result": self.result,
            "steps": [dict(step) for step in self.steps],
            "metadata": self.metadata,
        }

    def to_json(self) -> str:
        return json.dumps(self.to_dict(), indent=2, ensure_ascii=False)

    @property
    def object_names(self) -> tuple[str, ...]:
        names: list[str] = []
        for step in self.steps:
            if OPERATIONS[step["op"]]["creates"]:
                names.append(str(step["name"]))
        return tuple(names)


def _numbers(value: Any, count: int, label: str) -> tuple[float, ...]:
    if not isinstance(value, (list, tuple)) or len(value) != count:
        raise ProgramError(f"{label} must be {count} numbers")
    for item in value:
        if isinstance(item, bool) or not isinstance(item, (int, float)):
            raise ProgramError(f"{label} must be {count} numbers")
    return tuple(float(item) for item in value)


def _positive(value: Any, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value <= 0:
        raise ProgramError(f"{label} must be a positive number")
    return float(value)


def _name(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value or not value.replace("_", "").replace("-", "").isalnum():
        raise ProgramError(f"{label} must be an alphanumeric name")
    return value


def _validate_step(step: dict[str, Any], index: int, live: set[str]) -> None:
    label = f"steps[{index}]"
    op = step.get("op")
    if op not in OPERATIONS:
        raise ProgramError(
            f"{label} has unknown operation {op!r}; available: " + ", ".join(sorted(OPERATIONS))
        )
    spec = OPERATIONS[op]

    unknown = set(step) - {"op"} - set(spec["required"]) - set(spec["optional"])
    if unknown:
        raise ProgramError(f"{label} ({op}) has unknown parameters: {', '.join(sorted(unknown))}")
    missing = [key for key in spec["required"] if key not in step]
    if missing:
        raise ProgramError(f"{label} ({op}) is missing: {', '.join(missing)}")

    # An operation on an object that does not exist yet is the most common
    # program bug and the one that produces the most confusing Blender error, so
    # it is caught here with the step index and the live object list.
    for key in ("target", "source", "tool"):
        if key in step:
            referenced = _name(step[key], f"{label}.{key}")
            if referenced not in live:
                raise ProgramError(
                    f"{label} ({op}) references {referenced!r}, which does not exist at that point; "
                    f"live objects: {', '.join(sorted(live)) or 'none'}"
                )
    if "targets" in step:
        targets = step["targets"]
        if not isinstance(targets, list) or len(targets) < 2:
            raise ProgramError(f"{label} ({op}) needs at least two targets")
        for item in targets:
            referenced = _name(item, f"{label}.targets")
            if referenced not in live:
                raise ProgramError(f"{label} ({op}) joins {referenced!r}, which does not exist at that point")

    if spec["creates"]:
        name = _name(step["name"], f"{label}.name")
        if name in live:
            raise ProgramError(f"{label} ({op}) creates {name!r}, which already exists")

    # -- per-operation checks -----------------------------------------
    if op in {"box", "plane"}:
        size = _numbers(step["size"], 3 if op == "box" else 2, f"{label}.size")
        if any(item <= 0 for item in size):
            raise ProgramError(f"{label}.size must be positive on every axis")
    elif op in {"cylinder", "cone"}:
        _positive(step["radius"], f"{label}.radius")
        _positive(step["depth"], f"{label}.depth")
    elif op == "sphere":
        _positive(step["radius"], f"{label}.radius")
    elif op == "torus":
        major = _positive(step["majorRadius"], f"{label}.majorRadius")
        minor = _positive(step["minorRadius"], f"{label}.minorRadius")
        if minor >= major:
            raise ProgramError(f"{label} minorRadius must be smaller than majorRadius")
    elif op == "boolean":
        if step["operation"] not in BOOLEAN_OPERATIONS:
            raise ProgramError(f"{label}.operation must be one of {sorted(BOOLEAN_OPERATIONS)}")
        if step["target"] == step["tool"]:
            raise ProgramError(f"{label} cannot boolean an object with itself")
    elif op == "bevel":
        _positive(step["width"], f"{label}.width")
        segments = step.get("segments", 1)
        if not isinstance(segments, int) or not 1 <= segments <= 12:
            raise ProgramError(f"{label}.segments must be an integer between 1 and 12")
    elif op in {"array_linear", "array_radial"}:
        count = step["count"]
        if not isinstance(count, int) or not 2 <= count <= 128:
            raise ProgramError(f"{label}.count must be an integer between 2 and 128")
        if op == "array_linear":
            _numbers(step["offset"], 3, f"{label}.offset")
        elif "axis" in step and step["axis"] not in AXES:
            raise ProgramError(f"{label}.axis must be X, Y or Z")
    elif op == "mirror":
        if step["axis"] not in AXES:
            raise ProgramError(f"{label}.axis must be X, Y or Z")
    elif op == "uv_unwrap":
        method = step.get("method", "smart")
        if method not in UV_METHODS:
            raise ProgramError(f"{label}.method must be one of {sorted(UV_METHODS)}")
    elif op == "material":
        slots = step["slots"]
        if not isinstance(slots, list) or not slots:
            raise ProgramError(f"{label}.slots must be a non-empty array")
        for position, slot in enumerate(slots):
            if not isinstance(slot, dict):
                raise ProgramError(f"{label}.slots[{position}] must be an object")
            _name(slot.get("name"), f"{label}.slots[{position}].name")
            colour = slot.get("baseColor")
            if not isinstance(colour, (list, tuple)) or len(colour) != 3:
                raise ProgramError(f"{label}.slots[{position}].baseColor must be three 0..255 channels")
            for channel in colour:
                if not isinstance(channel, int) or not 0 <= channel <= 255:
                    raise ProgramError(f"{label}.slots[{position}].baseColor must be three 0..255 channels")
        assign = step.get("assign", 0)
        if not isinstance(assign, int) or isinstance(assign, bool) or not 0 <= assign < len(slots):
            raise ProgramError(
                f"{label}.assign must be an index into slots (0..{len(slots) - 1}); it is the "
                "slot the target's faces are put in, and a slot no face points at renders nowhere"
            )
    elif op == "decimate":
        budget = step.get("triangleBudget")
        ratio = step.get("ratio")
        if budget is None and ratio is None:
            raise ProgramError(f"{label} needs triangleBudget or ratio")
        if budget is not None:
            if not isinstance(budget, int) or budget < 4:
                raise ProgramError(f"{label}.triangleBudget must be an integer of at least 4")
            if budget > ROBLOX_TRIANGLE_LIMIT:
                raise ProgramError(
                    f"{label}.triangleBudget {budget} exceeds Roblox's {ROBLOX_TRIANGLE_LIMIT}-triangle "
                    "ceiling for a single mesh"
                )
        if ratio is not None and not (0 < float(ratio) <= 1):
            raise ProgramError(f"{label}.ratio must be between 0 and 1")
    elif op == "remesh":
        _positive(step["voxelSize"], f"{label}.voxelSize")
    elif op == "subdivide":
        cuts = step["cuts"]
        if not isinstance(cuts, int) or not 1 <= cuts <= 6:
            raise ProgramError(f"{label}.cuts must be an integer between 1 and 6")
    elif op == "origin":
        mode = step.get("mode", "geometry")
        if mode not in ORIGIN_MODES:
            raise ProgramError(f"{label}.mode must be one of {sorted(ORIGIN_MODES)}")
        if mode == "point" and "location" not in step:
            raise ProgramError(f"{label} origin mode 'point' needs a location")

    for key in ("location", "offset", "angles", "centre"):
        if key in step and op != "array_linear":
            _numbers(step[key], 3, f"{label}.{key}")
    if "rotation" in step:
        _numbers(step["rotation"], 3, f"{label}.rotation")
    if "factor" in step and op in {"scale", "duplicate"}:
        _numbers(step["factor"], 3, f"{label}.factor")


def compile_program(document: dict[str, Any]) -> Program:
    """Validate a program and return it ready to execute."""

    if not isinstance(document, dict):
        raise ProgramError("a program must be an object")
    if document.get("schemaVersion", 1) != 1:
        raise ProgramError("unsupported program schemaVersion")

    identifier = _name(document.get("id"), "id")
    steps = document.get("steps")
    if not isinstance(steps, list) or not steps:
        raise ProgramError("a program needs at least one step")

    live: set[str] = set()
    normalised: list[dict[str, Any]] = []
    for index, raw in enumerate(steps):
        if not isinstance(raw, dict):
            raise ProgramError(f"steps[{index}] must be an object")
        step = dict(raw)
        _validate_step(step, index, live)
        spec = OPERATIONS[step["op"]]
        if spec["creates"]:
            live.add(str(step["name"]))
        if step["op"] == "join":
            # A join consumes its inputs. Leaving them live would let a later
            # step reference geometry that no longer exists as its own object.
            for consumed in step["targets"]:
                live.discard(str(consumed))
        if step["op"] == "delete":
            live.discard(str(step["target"]))
        if step["op"] == "boolean" and step.get("keepTool") is not True:
            live.discard(str(step["tool"]))
        normalised.append(step)

    result = document.get("result")
    if result is None:
        if len(live) != 1:
            raise ProgramError(
                "a program with more than one surviving object must name its result; "
                f"surviving: {', '.join(sorted(live)) or 'none'}"
            )
        result = next(iter(live))
    result = _name(result, "result")
    if result not in live:
        raise ProgramError(
            f"result {result!r} does not survive the program; surviving: "
            f"{', '.join(sorted(live)) or 'none'}"
        )

    if len(live) > 1:
        # Scaffolding left behind is exported too, and a mesh that quietly
        # contains a cutting tool is a defect nobody notices until it is in the
        # game. Deleting it is the author's job; saying so is ours.
        leftovers = sorted(live - {result})
        raise ProgramError(
            "these objects survive the program but are not the result, so they would be "
            f"exported as part of it: {', '.join(leftovers)}. Delete or join them."
        )

    return Program(
        id=identifier,
        steps=tuple(normalised),
        result=result,
        units=str(document.get("units", "studs")),
        metadata=dict(document.get("metadata") or {}),
    )


def vocabulary() -> dict[str, Any]:
    """The operation surface, for an agent to read before writing a program."""

    return {
        "schemaVersion": 1,
        "triangleLimit": ROBLOX_TRIANGLE_LIMIT,
        "booleanOperations": sorted(BOOLEAN_OPERATIONS),
        "uvMethods": sorted(UV_METHODS),
        "operations": {
            name: {
                "creates": spec["creates"],
                "required": list(spec["required"]),
                "optional": list(spec["optional"]),
            }
            for name, spec in sorted(OPERATIONS.items())
        },
    }
