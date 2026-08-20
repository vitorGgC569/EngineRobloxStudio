"""Execute a modelling program inside Blender and write an asset package.

This is the interpreter for the vocabulary defined in `rqe/geometry/program.py`.
The agent never writes any of the `bpy` below; it writes the program, and the
program is validated before this script ever starts.

Two habits run through every operation:

**Modifiers are applied immediately.** An unapplied modifier does not export, so
a bevel that looks right in the viewport is simply absent from the `.glb`. Every
modifier this script adds is applied on the next line.

**The selection is set explicitly before every operator.** Almost all of
`bpy.ops` reads the selection rather than taking a target, so an operation that
appears to act on one object will act on whatever else was left selected.
"""

import math
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _runtime  # noqa: E402


def _vector(values):
    from mathutils import Vector

    return Vector((float(values[0]), float(values[1]), float(values[2])))


def _radians(values):
    return [math.radians(float(item)) for item in values]


# ------------------------------------------------------------- primitives


def op_box(step):
    import bpy

    size = step["size"]
    bpy.ops.mesh.primitive_cube_add(size=1, location=step.get("location", (0, 0, 0)))
    obj = bpy.context.active_object
    obj.name = step["name"]
    obj.scale = _vector(size)
    _runtime.select_only(obj)
    # Scale baked into the mesh rather than left on the object: an object-level
    # scale exports as a transform, and a non-uniform one wrecks normals.
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    if "rotation" in step:
        obj.rotation_euler = _radians(step["rotation"])
        bpy.ops.object.transform_apply(location=False, rotation=True, scale=False)
    return obj


def op_plane(step):
    import bpy

    size = step["size"]
    bpy.ops.mesh.primitive_plane_add(size=1, location=step.get("location", (0, 0, 0)))
    obj = bpy.context.active_object
    obj.name = step["name"]
    obj.scale = (float(size[0]), float(size[1]), 1.0)
    _runtime.select_only(obj)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    if "rotation" in step:
        obj.rotation_euler = _radians(step["rotation"])
        bpy.ops.object.transform_apply(location=False, rotation=True, scale=False)
    return obj


def op_cylinder(step):
    import bpy

    bpy.ops.mesh.primitive_cylinder_add(
        radius=float(step["radius"]),
        depth=float(step["depth"]),
        vertices=int(step.get("vertices", 24)),
        location=step.get("location", (0, 0, 0)),
    )
    obj = bpy.context.active_object
    obj.name = step["name"]
    if "rotation" in step:
        _runtime.select_only(obj)
        obj.rotation_euler = _radians(step["rotation"])
        bpy.ops.object.transform_apply(location=False, rotation=True, scale=False)
    return obj


def op_cone(step):
    import bpy

    bpy.ops.mesh.primitive_cone_add(
        radius1=float(step["radius"]),
        radius2=float(step.get("radiusTop", 0.0)),
        depth=float(step["depth"]),
        vertices=int(step.get("vertices", 24)),
        location=step.get("location", (0, 0, 0)),
    )
    obj = bpy.context.active_object
    obj.name = step["name"]
    if "rotation" in step:
        _runtime.select_only(obj)
        obj.rotation_euler = _radians(step["rotation"])
        bpy.ops.object.transform_apply(location=False, rotation=True, scale=False)
    return obj


def op_sphere(step):
    import bpy

    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=float(step["radius"]),
        segments=int(step.get("segments", 24)),
        ring_count=int(step.get("rings", 12)),
        location=step.get("location", (0, 0, 0)),
    )
    obj = bpy.context.active_object
    obj.name = step["name"]
    return obj


def op_torus(step):
    import bpy

    bpy.ops.mesh.primitive_torus_add(
        major_radius=float(step["majorRadius"]),
        minor_radius=float(step["minorRadius"]),
        major_segments=int(step.get("majorSegments", 24)),
        minor_segments=int(step.get("minorSegments", 12)),
        location=step.get("location", (0, 0, 0)),
    )
    obj = bpy.context.active_object
    obj.name = step["name"]
    if "rotation" in step:
        _runtime.select_only(obj)
        obj.rotation_euler = _radians(step["rotation"])
        bpy.ops.object.transform_apply(location=False, rotation=True, scale=False)
    return obj


# -------------------------------------------------------------- transforms


def op_translate(step):
    import bpy

    obj = _runtime.require_object(step["target"])
    _runtime.select_only(obj)
    obj.location = obj.location + _vector(step["offset"])
    bpy.ops.object.transform_apply(location=True, rotation=False, scale=False)
    return obj


def op_rotate(step):
    import bpy

    obj = _runtime.require_object(step["target"])
    _runtime.select_only(obj)
    obj.rotation_euler = _radians(step["angles"])
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=False)
    return obj


def op_scale(step):
    import bpy

    obj = _runtime.require_object(step["target"])
    _runtime.select_only(obj)
    obj.scale = _vector(step["factor"])
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return obj


def op_origin(step):
    import bpy

    obj = _runtime.require_object(step["target"])
    _runtime.select_only(obj)
    mode = step.get("mode", "geometry")
    if mode == "geometry":
        bpy.ops.object.origin_set(type="ORIGIN_GEOMETRY", center="MEDIAN")
    elif mode == "bounds":
        bpy.ops.object.origin_set(type="ORIGIN_GEOMETRY", center="BOUNDS")
    elif mode == "cursor":
        bpy.ops.object.origin_set(type="ORIGIN_CURSOR")
    elif mode == "point":
        bpy.context.scene.cursor.location = _vector(step["location"])
        bpy.ops.object.origin_set(type="ORIGIN_CURSOR")
        bpy.context.scene.cursor.location = (0, 0, 0)
    return obj


# ---------------------------------------------------------------- topology


def op_bevel(step):
    import bpy

    obj = _runtime.require_object(step["target"])
    _runtime.select_only(obj)
    modifier = obj.modifiers.new(name="Bevel", type="BEVEL")
    modifier.width = float(step["width"])
    modifier.segments = int(step.get("segments", 2))
    modifier.limit_method = "ANGLE"
    modifier.angle_limit = math.radians(float(step.get("angleLimit", 30.0)))
    # Clamping stops a bevel wider than the shortest edge from folding the mesh
    # inside out, which reads as a modelling mistake rather than a bad parameter.
    modifier.use_clamp_overlap = True
    _runtime.apply_modifier(obj, modifier)
    return obj


def _select_faces_by_normal(obj, axis, direction, threshold=0.7):
    """Select the faces pointing along an axis, for extrude and inset.

    An agent says "extrude the top", not "extrude faces 12, 13 and 27". This
    turns the first into the second.
    """

    import bmesh
    import bpy
    from mathutils import Vector

    index = {"X": 0, "Y": 1, "Z": 2}[axis]
    sign = 1.0 if direction >= 0 else -1.0
    target = Vector((0.0, 0.0, 0.0))
    target[index] = sign

    bpy.ops.object.mode_set(mode="EDIT")
    mesh = bmesh.from_edit_mesh(obj.data)
    mesh.faces.ensure_lookup_table()
    selected = 0
    for face in mesh.faces:
        face.select = face.normal.normalized().dot(target) >= threshold
        if face.select:
            selected += 1
    bmesh.update_edit_mesh(obj.data)
    if selected == 0:
        bpy.ops.object.mode_set(mode="OBJECT")
        raise RuntimeError(
            "no face on {!r} points along {}{}; nothing to extrude or inset".format(
                obj.name, "+" if sign > 0 else "-", axis
            )
        )
    return selected


def op_extrude(step):
    import bpy

    obj = _runtime.require_object(step["target"])
    _runtime.select_only(obj)
    axis = step.get("faceAxis", "Z")
    direction = float(step.get("faceDirection", 1))
    _select_faces_by_normal(obj, axis, direction)
    offset = step["offset"]
    bpy.ops.mesh.extrude_region_move(
        TRANSFORM_OT_translate={"value": (float(offset[0]), float(offset[1]), float(offset[2]))}
    )
    bpy.ops.object.mode_set(mode="OBJECT")
    return obj


def op_inset(step):
    import bpy

    obj = _runtime.require_object(step["target"])
    _runtime.select_only(obj)
    axis = step.get("faceAxis", "Z")
    direction = float(step.get("faceDirection", 1))
    _select_faces_by_normal(obj, axis, direction)
    bpy.ops.mesh.inset_faces(
        thickness=float(step["thickness"]),
        depth=float(step.get("depth", 0.0)),
    )
    bpy.ops.object.mode_set(mode="OBJECT")
    return obj


def op_solidify(step):
    obj = _runtime.require_object(step["target"])
    _runtime.select_only(obj)
    modifier = obj.modifiers.new(name="Solidify", type="SOLIDIFY")
    modifier.thickness = float(step["thickness"])
    modifier.offset = float(step.get("offset", -1.0))
    _runtime.apply_modifier(obj, modifier)
    return obj


def op_subdivide(step):
    obj = _runtime.require_object(step["target"])
    _runtime.select_only(obj)
    modifier = obj.modifiers.new(name="Subsurf", type="SUBSURF")
    modifier.levels = int(step["cuts"])
    modifier.render_levels = int(step["cuts"])
    if not step.get("smooth", True):
        modifier.subdivision_type = "SIMPLE"
    _runtime.apply_modifier(obj, modifier)
    return obj


def op_remesh(step):
    obj = _runtime.require_object(step["target"])
    _runtime.select_only(obj)
    modifier = obj.modifiers.new(name="Remesh", type="REMESH")
    modifier.mode = "VOXEL"
    modifier.voxel_size = float(step["voxelSize"])
    modifier.adaptivity = float(step.get("adaptivity", 0.0))
    _runtime.apply_modifier(obj, modifier)
    return obj


def op_smooth_shade(step):
    import bpy

    obj = _runtime.require_object(step["target"])
    _runtime.select_only(obj)
    bpy.ops.object.shade_smooth()
    # Auto-smooth keeps hard edges hard. Without it a shade-smooth turns a
    # machined box into a blob.
    angle = math.radians(float(step.get("angle", 30.0)))
    if hasattr(obj.data, "use_auto_smooth"):
        obj.data.use_auto_smooth = True
        obj.data.auto_smooth_angle = angle
    else:
        # Blender 4.1 replaced auto-smooth with a modifier.
        try:
            bpy.ops.object.shade_auto_smooth(angle=angle)
        except Exception:  # noqa: BLE001 - older or newer API
            pass
    return obj


def op_triangulate(step):
    obj = _runtime.require_object(step["target"])
    _runtime.select_only(obj)
    modifier = obj.modifiers.new(name="Triangulate", type="TRIANGULATE")
    modifier.quad_method = "SHORTEST_DIAGONAL"
    _runtime.apply_modifier(obj, modifier)
    return obj


# ------------------------------------------------------------- composition


def op_weld(step):
    """Merge vertices that sit on top of each other.

    The missing primitive. Subdividing and displacing a box produced 9788
    coincident vertices and 11790 boundary edges -- a mesh the validator
    correctly called "a surface rather than a solid", because every duplicate
    splits an edge that used to join two faces.

    Duplicates are not cosmetic. They double the vertex count, break the
    smooth-shading normals along every seam, and make `decimate` collapse a
    solid into triangle soup. Any program that subdivides, displaces or joins
    should weld before it finishes.
    """

    import bmesh

    obj = _runtime.require_object(step["target"])
    _runtime.select_only(obj)

    mesh = bmesh.new()
    mesh.from_mesh(obj.data)
    bmesh.ops.remove_doubles(
        mesh, verts=mesh.verts[:], dist=float(step.get("distance", 0.0005)))
    mesh.to_mesh(obj.data)
    mesh.free()
    obj.data.update()
    return obj


def op_screw(step):
    """Lathe a profile around an axis: the turned shapes nothing could make.

    Balusters, vases, bowls, columns with a real profile -- every one of them
    was previously faked as stacked cylinders, which reads as a stack of
    cylinders. This is the operation that makes a profile into a solid of
    revolution.

    The profile is the object's existing geometry, so the usual shape is a
    plane or a thin box positioned off-axis, screwed 360 degrees.
    """

    obj = _runtime.require_object(step["target"])
    _runtime.select_only(obj)
    modifier = obj.modifiers.new(name="Screw", type="SCREW")
    modifier.axis = step.get("axis", "Z")
    modifier.angle = math.radians(float(step.get("angle", 360.0)))
    modifier.steps = int(step.get("segments", 16))
    modifier.render_steps = modifier.steps
    # A full revolution must close, or the mesh has a seam of doubled vertices
    # that survives export and shows as a crease under any lighting.
    modifier.use_merge_vertices = True
    modifier.merge_threshold = float(step.get("merge", 0.001))
    modifier.screw_offset = float(step.get("rise", 0.0))
    _runtime.apply_modifier(obj, modifier)
    return obj


def op_displace(step):
    """Push vertices by a procedural texture: cliffs, erosion, rough ground.

    Everything organic. A subdivided sphere is a ball however hard you look at
    it; displacement is what makes rock read as rock.

    **Subdivide first.** Displacement moves existing vertices, so a box with
    eight of them displaces into a wonky box. The operation refuses when there
    is too little geometry to move rather than silently doing nothing, which is
    how this fails in every tutorial.
    """

    import bpy

    obj = _runtime.require_object(step["target"])
    minimum = int(step.get("minimumVertices", 64))
    if len(obj.data.vertices) < minimum:
        raise ValueError(
            "displace needs geometry to move: %s has %d vertices and at least "
            "%d are needed. Subdivide first."
            % (obj.name, len(obj.data.vertices), minimum))

    _runtime.select_only(obj)
    texture = bpy.data.textures.new(name="RQEDisplace", type="CLOUDS")
    texture.noise_scale = float(step.get("scale", 0.6))
    texture.noise_depth = int(step.get("detail", 2))
    # Deterministic: the same program must produce the same rock, or a scene
    # cannot be reproduced and a critique cannot be acted on.
    texture.nabla = 0.025

    modifier = obj.modifiers.new(name="Displace", type="DISPLACE")
    modifier.texture = texture
    modifier.strength = float(step.get("strength", 1.0))
    modifier.mid_level = float(step.get("midLevel", 0.5))
    _runtime.apply_modifier(obj, modifier)
    bpy.data.textures.remove(texture)
    return obj


def op_sweep(step):
    """Sweep a round section along a path: pipes, cables, handrails, track.

    The most limiting absence in the vocabulary. Anything that follows a line
    rather than sitting at a point -- a cable between two poles, a banked curve
    on a race track, a handrail down a stair -- had no way to exist.

    Built as a curve with a bevel depth and converted to a mesh, because a
    curve object cannot be exported, joined or booleaned. The conversion is the
    part that is easy to forget and produces an empty export when you do.
    """

    import bpy

    points = step["points"]
    if len(points) < 2:
        raise ValueError("a sweep needs at least two points to run between")

    curve = bpy.data.curves.new(name=step["name"], type="CURVE")
    curve.dimensions = "3D"
    curve.resolution_u = int(step.get("smoothness", 6))
    curve.bevel_depth = float(step.get("radius", 0.25))
    curve.bevel_resolution = int(step.get("sides", 4))
    curve.use_fill_caps = bool(step.get("caps", True))

    spline = curve.splines.new("BEZIER")
    spline.bezier_points.add(len(points) - 1)
    for index, point in enumerate(points):
        handle = spline.bezier_points[index]
        handle.co = (float(point[0]), float(point[1]), float(point[2]))
        # Auto handles give a fair curve through the points without asking the
        # caller to supply tangents they do not have.
        handle.handle_left_type = "AUTO"
        handle.handle_right_type = "AUTO"
    spline.use_cyclic_u = bool(step.get("closed", False))

    obj = bpy.data.objects.new(step["name"], curve)
    bpy.context.collection.objects.link(obj)
    _runtime.select_only(obj)
    # To mesh, or nothing downstream can touch it.
    bpy.ops.object.convert(target="MESH")
    return bpy.context.view_layer.objects.active


def op_loopcut(step):
    """Add edge rings so later bevels and displacements have somewhere to land.

    Not a shape by itself. It is what makes a bevel fall where you meant it on
    anything more complex than a box, and what gives `displace` vertices to
    move.

    Implemented with bmesh rather than `bpy.ops.mesh.loopcut_slide`, which needs
    an interactive editor context and does nothing headless -- silently.
    """

    import bmesh

    obj = _runtime.require_object(step["target"])
    _runtime.select_only(obj)

    mesh = bmesh.new()
    mesh.from_mesh(obj.data)
    cuts = int(step.get("cuts", 1))
    axis = str(step.get("axis", "Z")).upper()
    index = {"X": 0, "Y": 1, "Z": 2}.get(axis, 2)

    # Rings perpendicular to the axis: the edges whose two ends differ along it.
    ring = [
        edge for edge in mesh.edges
        if abs(edge.verts[0].co[index] - edge.verts[1].co[index]) > 1e-5
    ]
    if not ring:
        mesh.free()
        raise ValueError(
            "no edges run along %s on %s, so there is no ring to cut"
            % (axis, obj.name))

    bmesh.ops.subdivide_edges(mesh, edges=ring, cuts=cuts, use_grid_fill=True)
    mesh.to_mesh(obj.data)
    mesh.free()
    obj.data.update()
    return obj


def op_boolean(step):
    import bpy

    target = _runtime.require_object(step["target"])
    tool = _runtime.require_object(step["tool"])
    _runtime.select_only(target)
    modifier = target.modifiers.new(name="Boolean", type="BOOLEAN")
    modifier.operation = {
        "union": "UNION", "difference": "DIFFERENCE", "intersect": "INTERSECT",
    }[step["operation"]]
    modifier.object = tool
    # Exact rather than fast: the fast solver produces non-manifold results that
    # pass here and fail Roblox's own import validation.
    modifier.solver = "EXACT"
    _runtime.apply_modifier(target, modifier)
    if not step.get("keepTool", False):
        bpy.data.objects.remove(tool, do_unlink=True)
    return target


def op_array_linear(step):
    obj = _runtime.require_object(step["target"])
    _runtime.select_only(obj)
    modifier = obj.modifiers.new(name="Array", type="ARRAY")
    modifier.count = int(step["count"])
    modifier.use_relative_offset = False
    modifier.use_constant_offset = True
    modifier.constant_offset_displace = _vector(step["offset"])
    _runtime.apply_modifier(obj, modifier)
    return obj


def op_array_radial(step):
    import bpy

    obj = _runtime.require_object(step["target"])
    count = int(step["count"])
    axis = step.get("axis", "Z")
    centre = _vector(step.get("centre", (0, 0, 0)))

    # An Array modifier rotates around an empty. Creating one, applying, then
    # removing it keeps the radial pattern out of the object list, which the
    # program validator would otherwise flag as surviving scaffolding.
    pivot = bpy.data.objects.new("__radial_pivot", None)
    bpy.context.collection.objects.link(pivot)
    # The pivot must sit at the object's own coordinate along the rotation axis.
    #
    # An object-offset Array uses the pivot's transform *relative to the object*,
    # which includes the translation between them. With the pivot at the origin
    # and the object raised, every copy stepped down as well as around: a
    # 22-stud buttress became a 106-stud helix, and the only symptom was a
    # dimension check reporting a landmark three times taller than its brief.
    axis_index = {"X": 0, "Y": 1, "Z": 2}[step.get("axis", "Z")]
    location = list(centre)
    location[axis_index] = obj.location[axis_index]
    pivot.location = location
    index = {"X": 0, "Y": 1, "Z": 2}[axis]
    rotation = [0.0, 0.0, 0.0]
    rotation[index] = 2 * math.pi / count
    pivot.rotation_euler = rotation

    _runtime.select_only(obj)
    modifier = obj.modifiers.new(name="RadialArray", type="ARRAY")
    modifier.count = count
    modifier.use_relative_offset = False
    modifier.use_object_offset = True
    modifier.offset_object = pivot
    _runtime.apply_modifier(obj, modifier)

    bpy.data.objects.remove(pivot, do_unlink=True)
    return obj


def op_mirror(step):
    import bpy

    obj = _runtime.require_object(step["target"])
    _runtime.select_only(obj)
    modifier = obj.modifiers.new(name="Mirror", type="MIRROR")
    index = {"X": 0, "Y": 1, "Z": 2}[step["axis"]]
    modifier.use_axis = tuple(position == index for position in range(3))
    # Merging the seam is what makes a mirrored half watertight; without it the
    # centre line stays two coincident surfaces and fails manifold validation.
    modifier.use_mirror_merge = True
    modifier.merge_threshold = 0.0005
    if "centre" in step:
        pivot = bpy.data.objects.new("__mirror_pivot", None)
        bpy.context.collection.objects.link(pivot)
        pivot.location = _vector(step["centre"])
        modifier.mirror_object = pivot
        _runtime.apply_modifier(obj, modifier)
        bpy.data.objects.remove(pivot, do_unlink=True)
    else:
        _runtime.apply_modifier(obj, modifier)
    return obj


def op_duplicate(step):
    import bpy

    source = _runtime.require_object(step["source"])
    copy = source.copy()
    copy.data = source.data.copy()
    copy.name = step["name"]
    bpy.context.collection.objects.link(copy)
    _runtime.select_only(copy)
    if "location" in step:
        copy.location = _vector(step["location"])
    if "rotation" in step:
        copy.rotation_euler = _radians(step["rotation"])
    if "factor" in step:
        copy.scale = _vector(step["factor"])
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    return copy


def op_join(step):
    import bpy

    targets = [_runtime.require_object(name) for name in step["targets"]]
    bpy.ops.object.select_all(action="DESELECT")
    for obj in targets:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = targets[0]
    bpy.ops.object.join()
    joined = bpy.context.active_object
    joined.name = step["name"]
    return joined


def op_delete(step):
    import bpy

    obj = _runtime.require_object(step["target"])
    bpy.data.objects.remove(obj, do_unlink=True)
    return None


# ----------------------------------------------------------------- surface


def op_uv_unwrap(step):
    import bpy

    obj = _runtime.require_object(step["target"])
    _runtime.select_only(obj)
    method = step.get("method", "smart")
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    margin = float(step.get("islandMargin", 0.02))
    if method == "smart":
        bpy.ops.uv.smart_project(
            angle_limit=math.radians(float(step.get("angleLimit", 66.0))),
            island_margin=margin,
        )
    elif method == "cube":
        bpy.ops.uv.cube_project(cube_size=1.0)
    elif method == "cylinder":
        bpy.ops.uv.cylinder_project()
    elif method == "sphere":
        bpy.ops.uv.sphere_project()
    else:
        bpy.ops.uv.unwrap(margin=margin)
    bpy.ops.object.mode_set(mode="OBJECT")
    return obj


def op_material(step):
    import bpy

    obj = _runtime.require_object(step["target"])
    obj.data.materials.clear()
    for slot in step["slots"]:
        material = bpy.data.materials.new(name=slot["name"])
        material.use_nodes = True
        principled = material.node_tree.nodes.get("Principled BSDF")
        colour = slot["baseColor"]
        # sRGB in, linear out. Assigning the 0..255 value straight through is
        # how every generated asset comes back washed out.
        linear = [_srgb_to_linear(channel / 255.0) for channel in colour]
        if principled is not None:
            principled.inputs["Base Color"].default_value = (linear[0], linear[1], linear[2], 1.0)
            principled.inputs["Metallic"].default_value = float(slot.get("metallic", 0.0))
            principled.inputs["Roughness"].default_value = float(slot.get("roughness", 0.6))
            if "emissive" in slot:
                emissive = [_srgb_to_linear(channel / 255.0) for channel in slot["emissive"]]
                if "Emission Color" in principled.inputs:
                    principled.inputs["Emission Color"].default_value = (
                        emissive[0], emissive[1], emissive[2], 1.0
                    )
                elif "Emission" in principled.inputs:
                    principled.inputs["Emission"].default_value = (
                        emissive[0], emissive[1], emissive[2], 1.0
                    )
                if "Emission Strength" in principled.inputs:
                    principled.inputs["Emission Strength"].default_value = float(
                        slot.get("emissiveStrength", 1.0)
                    )
        obj.data.materials.append(material)

    # Assign the faces. Appending a slot does not put anything in it: every
    # polygon keeps material_index 0, so a step declaring three materials
    # renders entirely in the first one while the manifest reports three. The
    # asset then looks flat for a reason nothing in the receipt explains.
    #
    # The default of 0 is what a single-material part wants. Multi-material
    # assets assign per part before `join`, and Blender remaps the indices when
    # the parts merge.
    index = int(step.get("assign", 0))
    if not 0 <= index < len(obj.data.materials):
        raise RuntimeError(
            "material.assign {} is out of range for {} slot(s) on {!r}".format(
                index, len(obj.data.materials), step["target"]
            )
        )
    for polygon in obj.data.polygons:
        polygon.material_index = index
    return obj


def _srgb_to_linear(channel):
    if channel <= 0.04045:
        return channel / 12.92
    return ((channel + 0.055) / 1.055) ** 2.4


def op_decimate(step):
    obj = _runtime.require_object(step["target"])
    budget = step.get("triangleBudget")
    ratio = step.get("ratio")

    if budget is not None:
        current = _runtime.triangle_count(obj)
        if current <= budget:
            # Already inside budget. Decimating anyway would throw away detail
            # for nothing and is the most common way a generated asset comes out
            # softer than the program asked for.
            return obj
        ratio = float(budget) / float(current)

    _runtime.select_only(obj)
    modifier = obj.modifiers.new(name="Decimate", type="DECIMATE")
    modifier.decimate_type = "COLLAPSE"
    modifier.ratio = max(min(float(ratio), 1.0), 0.001)
    _runtime.apply_modifier(obj, modifier)
    return obj


HANDLERS = {
    "box": op_box, "plane": op_plane, "cylinder": op_cylinder, "cone": op_cone,
    "sphere": op_sphere, "torus": op_torus,
    "translate": op_translate, "rotate": op_rotate, "scale": op_scale, "origin": op_origin,
    "bevel": op_bevel, "extrude": op_extrude, "inset": op_inset, "solidify": op_solidify,
    "subdivide": op_subdivide, "remesh": op_remesh, "smooth_shade": op_smooth_shade,
    "triangulate": op_triangulate,
    "boolean": op_boolean, "array_linear": op_array_linear, "array_radial": op_array_radial,
    "weld": op_weld, "screw": op_screw, "displace": op_displace, "sweep": op_sweep, "loopcut": op_loopcut,
    "mirror": op_mirror, "duplicate": op_duplicate, "join": op_join, "delete": op_delete,
    "uv_unwrap": op_uv_unwrap, "material": op_material, "decimate": op_decimate,
}


def job(payload):
    import bpy

    program = payload["program"]
    output_dir = payload["outputDir"]

    _runtime.reset_scene()

    trace = []
    for index, step in enumerate(program["steps"]):
        operation = step["op"]
        handler = HANDLERS.get(operation)
        if handler is None:
            raise RuntimeError("no handler for operation {!r}".format(operation))
        try:
            handler(step)
        except Exception as error:
            raise RuntimeError(
                "step {} ({}) failed: {}: {}".format(index, operation, type(error).__name__, error)
            )
        trace.append({"index": index, "op": operation})

    result = _runtime.require_object(program["result"])

    # Everything but the result is scaffolding the program validator already
    # refused to leave behind; this is belt and braces against a handler that
    # created something the vocabulary did not declare.
    for obj in list(bpy.data.objects):
        if obj is not result:
            bpy.data.objects.remove(obj, do_unlink=True)

    _runtime.select_only(result)
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)

    project_dir = os.path.join(output_dir, "project")
    export_dir = os.path.join(output_dir, "export")
    for directory in (project_dir, export_dir):
        os.makedirs(directory, exist_ok=True)

    blend_path = os.path.join(project_dir, "{}.blend".format(program["id"]))
    bpy.ops.wm.save_as_mainfile(filepath=blend_path)

    glb_path = os.path.join(export_dir, "{}.glb".format(program["id"]))
    bpy.ops.export_scene.gltf(
        filepath=glb_path,
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_yup=True,
    )

    fbx_path = os.path.join(export_dir, "{}.fbx".format(program["id"]))
    bpy.ops.export_scene.fbx(
        filepath=fbx_path,
        use_selection=True,
        apply_unit_scale=True,
        bake_space_transform=True,
        mesh_smooth_type="FACE",
    )


    # Mesh data, for the backend that can actually load it at runtime.
    #
    # Triangulated here rather than trusted: `AddTriangle` takes three vertices
    # and a quad silently becomes nothing. Normals come from the loops so hard
    # edges survive; a mesh rebuilt from vertex normals alone comes out smooth
    # everywhere, which turns authored bevels back into the soft blobs the whole
    # program exists to avoid.
    import bmesh

    bm = bmesh.new()
    bm.from_mesh(result.data)
    bmesh.ops.triangulate(bm, faces=bm.faces[:])
    triangulated = bpy.data.meshes.new("{}_rt".format(program["id"]))
    bm.to_mesh(triangulated)
    bm.free()
    # `calc_normals_split` was removed in Blender 4.1. From there on split
    # normals are computed on demand and read from `corner_normals`, so calling
    # it raises AttributeError on any current install -- 5.2 here. Both spellings
    # are tried because the worker locates whatever Blender the machine has.
    corner_normals = None
    if hasattr(triangulated, "calc_normals_split"):
        triangulated.calc_normals_split()
    if hasattr(triangulated, "corner_normals"):
        corner_normals = triangulated.corner_normals

    uv_layer = triangulated.uv_layers.active
    positions = []
    normals = []
    uvs = []
    indices = []
    slots = []
    index_of = {}

    for polygon in triangulated.polygons:
        for loop_index in polygon.loop_indices:
            loop = triangulated.loops[loop_index]
            vertex = triangulated.vertices[loop.vertex_index]
            if corner_normals is not None:
                normal = corner_normals[loop_index].vector
            else:
                normal = loop.normal
            # Blender Z-up to Roblox Y-up, and the handedness flip that goes
            # with it. Done once, here.
            key = (
                round(vertex.co.x, 5), round(vertex.co.z, 5), round(-vertex.co.y, 5),
                round(normal.x, 4), round(normal.z, 4), round(-normal.y, 4),
                polygon.material_index,
            )
            existing = index_of.get(key)
            if existing is None:
                existing = len(positions) // 3
                index_of[key] = existing
                positions.extend([key[0], key[1], key[2]])
                normals.extend([key[3], key[4], key[5]])
                if uv_layer is not None:
                    uv = uv_layer.data[loop_index].uv
                    uvs.extend([round(uv.x, 4), round(uv.y, 4)])
                else:
                    uvs.extend([0.0, 0.0])
            indices.append(existing)
        slots.append(polygon.material_index)

    bpy.data.meshes.remove(triangulated)

    mesh_path = os.path.join(export_dir, "{}.mesh.json".format(program["id"]))
    with open(mesh_path, "w") as handle:
        json.dump({
            "schemaVersion": 1,
            "id": program["id"],
            "units": "studs",
            "axis": "roblox-y-up",
            "positions": positions,
            "normals": normals,
            "uvs": uvs,
            "indices": indices,
            "materialSlots": slots,
            "materials": [m.name for m in result.data.materials if m],
        }, handle, separators=(",", ":"))

    dimensions = result.dimensions
    return {
        "program": program["id"],
        "result": result.name,
        "steps": trace,
        "blend": blend_path,
        "glb": glb_path,
        "fbx": fbx_path,
        "meshData": mesh_path,
        "runtimeTriangles": len(indices) // 3,
        "runtimeVertices": len(positions) // 3,
        "triangles": _runtime.triangle_count(result),
        "vertices": len(result.data.vertices),
        "materials": [material.name for material in result.data.materials if material],
        "dimensions": [dimensions.x, dimensions.y, dimensions.z],
        "hasUv": bool(result.data.uv_layers),
    }


if __name__ == "__main__":
    raise SystemExit(_runtime.main(job))
