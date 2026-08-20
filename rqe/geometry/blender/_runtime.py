"""Shared plumbing for scripts that run *inside* Blender.

Imported by `build.py`, `analyse.py` and `render.py`, all of which are executed
by `blender --background --python`. Nothing here may import from the rest of the
engine: this file lives in Blender's interpreter, which has `bpy` and the
standard library and nothing else.

The contract with the outside is one JSON file in and one JSON file out, chosen
because Blender writes plugin chatter, render progress and driver warnings to
stdout. Parsing results out of that stream works on the machine it was written
on and fails on the next one.
"""

import json
import sys
import traceback


def arguments():
    """The two paths after `--` on the Blender command line."""

    if "--" not in sys.argv:
        raise RuntimeError("worker scripts require `-- <input.json> <output.json>`")
    tail = sys.argv[sys.argv.index("--") + 1:]
    if len(tail) < 2:
        raise RuntimeError("worker scripts require an input and an output path")
    return tail[0], tail[1]


def read_input(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def write_output(path, payload):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)


def main(job):
    """Run `job(payload)` and report the outcome as JSON, never as an exception.

    A traceback on stderr is not a result. The engine has to be able to tell a
    modelling failure from a crashed process from a Blender that never started,
    and only a written result file distinguishes the first from the other two.
    """

    input_path, output_path = arguments()
    try:
        payload = read_input(input_path)
    except Exception as error:  # noqa: BLE001
        write_output(output_path, {
            "ok": False,
            "error": "could not read the job payload: {}".format(error),
        })
        return 1

    try:
        data = job(payload)
    except Exception as error:  # noqa: BLE001
        write_output(output_path, {
            "ok": False,
            "error": "{}: {}".format(type(error).__name__, error),
            "traceback": traceback.format_exc(),
        })
        return 1

    write_output(output_path, {"ok": True, "data": data or {}})
    return 0


# ---------------------------------------------------------------- scene


def reset_scene():
    """Empty the file completely.

    `--factory-startup` still opens the default scene, which has a cube, a
    camera and a light in it. A program that assumed an empty world would
    silently export the default cube joined to its own geometry.
    """

    import bpy

    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)

    for collection in (
        bpy.data.meshes, bpy.data.materials, bpy.data.objects,
        bpy.data.cameras, bpy.data.lights, bpy.data.images,
    ):
        for item in list(collection):
            try:
                collection.remove(item)
            except Exception:  # noqa: BLE001 - already unlinked
                pass


def select_only(obj):
    """Make `obj` the single selected and active object.

    Nearly every `bpy.ops` call reads the selection rather than taking an
    argument, so an operation that looks like it targets one object will happily
    apply to whatever else was left selected.
    """

    import bpy

    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj


def require_object(name):
    import bpy

    obj = bpy.data.objects.get(name)
    if obj is None:
        raise RuntimeError("object {!r} does not exist".format(name))
    return obj


def apply_modifier(obj, modifier):
    """Apply a modifier and leave the mesh real.

    Modifiers left unapplied do not export, so a bevel that looks correct in the
    viewport disappears from the `.glb`. Everything this worker adds is applied
    immediately.
    """

    import bpy

    select_only(obj)
    bpy.ops.object.modifier_apply(modifier=modifier.name)


def triangle_count(obj):
    import bmesh

    mesh = bmesh.new()
    try:
        mesh.from_mesh(obj.data)
        bmesh.ops.triangulate(mesh, faces=mesh.faces[:])
        return len(mesh.faces)
    finally:
        mesh.free()
