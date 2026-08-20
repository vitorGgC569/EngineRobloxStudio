"""Preview renders, so an agent can see what it modelled before publishing it.

This is what closes the modelling loop. Without images, an agent revising a mesh
is editing numbers and hoping; with five fixed angles it can be handed to the
visual critic, told the base reads too heavy and the rear face is undetailed,
and asked for revision two.

The setup is deliberately neutral and deliberately fixed:

**Same camera framing every time**, derived from the object's own bounding
sphere rather than a hand-placed position, so revision one and revision two are
comparable and a diff means something.

**Same three-point lighting**, because a critique of "the silhouette is weak" is
worthless if the lighting changed between renders. Key, fill and rim, with a
grey world so nothing is judged against black.

**Orthographic for the four elevations**, perspective only for the hero angle.
An elevation in perspective cannot be compared to the next revision's.
"""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _runtime  # noqa: E402


#: Azimuth and elevation in degrees, and whether the view is orthographic.
VIEWS = {
    "front": (0.0, 0.0, True),
    "back": (180.0, 0.0, True),
    "left": (90.0, 0.0, True),
    "right": (270.0, 0.0, True),
    "top": (0.0, 89.0, True),
    "perspective": (35.0, 25.0, False),
}

DEFAULT_VIEWS = ("front", "back", "left", "right", "perspective")


def _bounding_sphere(objects):
    from mathutils import Vector

    minimum = Vector((float("inf"),) * 3)
    maximum = Vector((float("-inf"),) * 3)
    for obj in objects:
        for corner in obj.bound_box:
            world = obj.matrix_world @ Vector(corner)
            minimum = Vector((min(minimum[i], world[i]) for i in range(3)))
            maximum = Vector((max(maximum[i], world[i]) for i in range(3)))
    centre = (minimum + maximum) / 2.0
    radius = max((maximum - minimum).length / 2.0, 1e-4)
    return centre, radius


def _build_lighting():
    import bpy

    world = bpy.data.worlds.new("PreviewWorld")
    world.use_nodes = True
    background = world.node_tree.nodes.get("Background")
    if background is not None:
        # Mid grey rather than black. A dark silhouette on black cannot be
        # judged, and that is exactly what the critic is being asked to judge.
        background.inputs["Color"].default_value = (0.18, 0.19, 0.21, 1.0)
        background.inputs["Strength"].default_value = 1.0
    bpy.context.scene.world = world

    def lamp(name, location, energy, size):
        data = bpy.data.lights.new(name=name, type="AREA")
        data.energy = energy
        data.size = size
        obj = bpy.data.objects.new(name, data)
        obj.location = location
        bpy.context.collection.objects.link(obj)
        return obj

    return [
        lamp("Key", (4.0, -4.0, 5.0), 900.0, 6.0),
        lamp("Fill", (-5.0, -2.0, 2.0), 250.0, 8.0),
        lamp("Rim", (0.0, 5.0, 3.0), 500.0, 5.0),
    ]


def _aim(obj, target):
    from mathutils import Vector

    direction = target - obj.location
    obj.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()


def job(payload):
    import bpy
    from mathutils import Vector

    output_dir = payload["outputDir"]
    requested = payload.get("views") or list(DEFAULT_VIEWS)
    samples = int(payload.get("samples", 32))
    resolution = int(payload.get("resolution", 768))

    unknown = [name for name in requested if name not in VIEWS]
    if unknown:
        raise RuntimeError("unknown view(s): {}; available: {}".format(
            ", ".join(unknown), ", ".join(sorted(VIEWS))
        ))

    meshes = [obj for obj in bpy.data.objects if obj.type == "MESH"]
    if not meshes:
        raise RuntimeError("the file contains no mesh objects to render")

    centre, radius = _bounding_sphere(meshes)

    scene = bpy.context.scene
    # EEVEE by name differs across 4.x; ask for what exists rather than pinning
    # a string that silently falls back to Cycles and takes a hundred times
    # longer.
    for engine in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE"):
        try:
            scene.render.engine = engine
            break
        except TypeError:
            continue
    try:
        scene.eevee.taa_render_samples = samples
    except AttributeError:
        pass

    scene.render.resolution_x = resolution
    scene.render.resolution_y = resolution
    scene.render.resolution_percentage = 100
    # Transparent film, opaque world. The world still lights the asset -- only
    # the backdrop is alpha -- so the shading is unchanged and the critic gets
    # an exact mask instead of guessing one by colour distance. Keying a grey
    # asset off a grey background punches holes through its own shadowed faces,
    # and the critic then measures the holes: a bare cube came back with a more
    # "complex" silhouette than a ribbed, vented machine.
    scene.render.film_transparent = True
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"

    lights = _build_lighting()

    camera_data = bpy.data.cameras.new("PreviewCamera")
    camera = bpy.data.objects.new("PreviewCamera", camera_data)
    bpy.context.collection.objects.link(camera)
    scene.camera = camera

    os.makedirs(output_dir, exist_ok=True)
    written = []

    for name in requested:
        azimuth, elevation, orthographic = VIEWS[name]
        theta = math.radians(azimuth)
        phi = math.radians(elevation)
        distance = radius * 3.2

        camera.location = centre + Vector((
            math.sin(theta) * math.cos(phi) * distance,
            -math.cos(theta) * math.cos(phi) * distance,
            math.sin(phi) * distance,
        ))
        _aim(camera, centre)

        if orthographic:
            camera_data.type = "ORTHO"
            # A fixed margin around the bounding sphere, so an object that grows
            # between revisions stays framed the same way.
            camera_data.ortho_scale = radius * 2.4
        else:
            camera_data.type = "PERSP"
            camera_data.lens = 50.0

        path = os.path.join(output_dir, "{}.png".format(name))
        scene.render.filepath = path
        bpy.ops.render.render(write_still=True)
        written.append({"view": name, "path": path})

    return {
        "views": written,
        "resolution": resolution,
        "samples": samples,
        "engine": scene.render.engine,
        "boundingRadius": radius,
        "centre": [centre.x, centre.y, centre.z],
    }


if __name__ == "__main__":
    raise SystemExit(_runtime.main(job))
