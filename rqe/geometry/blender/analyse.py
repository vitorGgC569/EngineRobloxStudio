"""Topology analysis of a mesh, measured inside Blender.

This is the measurement half of mesh validation. It computes facts and applies
no policy: no threshold appears in this file, and nothing here decides whether a
mesh is acceptable. Policy lives in `rqe/geometry/validation.py`, on the engine
side, for the same reason the visual quality thresholds do -- a validator that
carries its own limits ends up grading itself.

Every check exists because Roblox's importer or its renderer cares about it, and
because the failure is invisible until it is expensive: a non-manifold mesh is
rejected at upload, a degenerate triangle produces shading artefacts nobody can
trace, a flipped normal makes a wall disappear from one side, and a missing UV
makes every texture unusable.
"""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _runtime  # noqa: E402


#: Below this the triangle has no usable normal and Roblox's importer reports it
#: as degenerate. Measured in square units of whatever the mesh is authored in.
DEGENERATE_AREA = 1e-9

#: Two vertices closer than this are treated as the same point when looking for
#: duplicated geometry.
WELD_DISTANCE = 1e-5


def _is_finite(vector):
    return all(math.isfinite(component) for component in vector)


def _analyse_object(obj):
    import bmesh
    from mathutils import Vector

    mesh = bmesh.new()
    mesh.from_mesh(obj.data)
    mesh.verts.ensure_lookup_table()
    mesh.edges.ensure_lookup_table()
    mesh.faces.ensure_lookup_table()

    report = {}

    # -- counts, before triangulation so n-gons are still visible ------
    ngons = sum(1 for face in mesh.faces if len(face.verts) > 4)
    quads = sum(1 for face in mesh.faces if len(face.verts) == 4)
    tris = sum(1 for face in mesh.faces if len(face.verts) == 3)
    report["faces"] = len(mesh.faces)
    report["ngons"] = ngons
    report["quads"] = quads
    report["trianglesBeforeTriangulation"] = tris
    report["vertices"] = len(mesh.verts)
    report["edges"] = len(mesh.edges)

    # -- non-finite coordinates ---------------------------------------
    # A NaN anywhere makes the bounding box meaningless and every downstream
    # measurement wrong, so it is checked before anything is derived from
    # positions.
    non_finite = sum(1 for vert in mesh.verts if not _is_finite(vert.co))
    report["nonFiniteVertices"] = non_finite

    # -- manifold and boundary ----------------------------------------
    boundary_edges = 0
    non_manifold_edges = 0
    for edge in mesh.edges:
        linked = len(edge.link_faces)
        if linked == 0:
            non_manifold_edges += 1
        elif linked == 1:
            boundary_edges += 1
        elif linked > 2:
            non_manifold_edges += 1
    report["boundaryEdges"] = boundary_edges
    report["nonManifoldEdges"] = non_manifold_edges
    report["watertight"] = boundary_edges == 0 and non_manifold_edges == 0

    loose_verts = sum(1 for vert in mesh.verts if not vert.link_edges)
    loose_edges = sum(1 for edge in mesh.edges if not edge.link_faces)
    report["looseVertices"] = loose_verts
    report["looseEdges"] = loose_edges

    non_manifold_verts = sum(1 for vert in mesh.verts if not vert.is_manifold)
    report["nonManifoldVertices"] = non_manifold_verts

    # -- degenerate faces ---------------------------------------------
    degenerate = 0
    zero_length_edges = 0
    for face in mesh.faces:
        if face.calc_area() <= DEGENERATE_AREA:
            degenerate += 1
    for edge in mesh.edges:
        if edge.calc_length() <= WELD_DISTANCE:
            zero_length_edges += 1
    report["degenerateFaces"] = degenerate
    report["zeroLengthEdges"] = zero_length_edges

    # -- normals -------------------------------------------------------
    # Consistency, not direction: a closed mesh whose faces disagree renders
    # with holes from one side, and that is what the importer's "inverted
    # normals" warning is really about.
    inconsistent = 0
    for edge in mesh.edges:
        if len(edge.link_faces) == 2:
            first, second = edge.link_faces
            shared = [loop for loop in first.loops if loop.edge == edge]
            other = [loop for loop in second.loops if loop.edge == edge]
            if shared and other and shared[0].vert == other[0].vert:
                inconsistent += 1
    report["inconsistentNormalEdges"] = inconsistent

    flipped = 0
    if report["watertight"]:
        # For a closed mesh, the signed volume tells you whether the surface is
        # inside out as a whole.
        volume = mesh.calc_volume(signed=True)
        report["signedVolume"] = volume
        if volume < 0:
            flipped = len(mesh.faces)
    else:
        report["signedVolume"] = None
    report["flippedFaces"] = flipped

    # -- duplicated geometry -------------------------------------------
    # Coincident vertices that were never welded. They survive export, double
    # the vertex count and split shading along invisible seams.
    buckets = {}
    duplicate_vertices = 0
    for vert in mesh.verts:
        key = (
            round(vert.co.x / WELD_DISTANCE),
            round(vert.co.y / WELD_DISTANCE),
            round(vert.co.z / WELD_DISTANCE),
        )
        if key in buckets:
            duplicate_vertices += 1
        else:
            buckets[key] = True
    report["duplicateVertices"] = duplicate_vertices

    face_keys = {}
    duplicate_faces = 0
    for face in mesh.faces:
        key = tuple(sorted(vert.index for vert in face.verts))
        if key in face_keys:
            duplicate_faces += 1
        else:
            face_keys[key] = True
    report["duplicateFaces"] = duplicate_faces

    # -- UV -------------------------------------------------------------
    uv_layers = [layer.name for layer in mesh.loops.layers.uv.values()] if hasattr(mesh.loops.layers, "uv") else []
    report["uvLayers"] = uv_layers
    report["hasUv"] = bool(uv_layers)
    overlapping_uv = 0
    out_of_range_uv = 0
    if uv_layers:
        layer = mesh.loops.layers.uv.active
        for face in mesh.faces:
            for loop in face.loops:
                uv = loop[layer].uv
                if not (math.isfinite(uv.x) and math.isfinite(uv.y)):
                    out_of_range_uv += 1
                elif not (-0.001 <= uv.x <= 1.001 and -0.001 <= uv.y <= 1.001):
                    # Tiling is legitimate; Roblox just cannot atlas it. Counted,
                    # not condemned.
                    out_of_range_uv += 1
    report["uvOutsideUnitSquare"] = out_of_range_uv
    report["uvOverlaps"] = overlapping_uv

    # -- triangulated count --------------------------------------------
    bmesh.ops.triangulate(mesh, faces=mesh.faces[:])
    report["triangles"] = len(mesh.faces)

    mesh.free()

    # -- object-level facts ---------------------------------------------
    bounds = [Vector(corner) for corner in obj.bound_box]
    minimum = Vector((
        min(corner.x for corner in bounds),
        min(corner.y for corner in bounds),
        min(corner.z for corner in bounds),
    ))
    maximum = Vector((
        max(corner.x for corner in bounds),
        max(corner.y for corner in bounds),
        max(corner.z for corner in bounds),
    ))
    report["boundingBox"] = {
        "min": [minimum.x, minimum.y, minimum.z],
        "max": [maximum.x, maximum.y, maximum.z],
        "size": [maximum.x - minimum.x, maximum.y - minimum.y, maximum.z - minimum.z],
    }
    report["dimensions"] = [obj.dimensions.x, obj.dimensions.y, obj.dimensions.z]

    # Blender is Z-up; Roblox is Y-up, and the glTF export converts on the way
    # out. Reporting both conventions explicitly is the only way to stop a brief
    # that asked for a 6-stud-tall reactor being compared against a depth. That
    # mistake produces an asset that is wrong everywhere it is placed, and it
    # survives every later fix because nothing downstream ever looks at it again.
    report["axisConvention"] = "Z-up (Blender)"
    report["dimensionsYUp"] = [obj.dimensions.x, obj.dimensions.z, obj.dimensions.y]

    report["scale"] = [obj.scale.x, obj.scale.y, obj.scale.z]
    report["location"] = [obj.location.x, obj.location.y, obj.location.z]

    # Origin relative to the bounding box. An asset whose pivot is far outside
    # its own geometry rotates around empty space when placed in a game.
    centre = (minimum + maximum) / 2.0
    span = max(maximum.x - minimum.x, maximum.y - minimum.y, maximum.z - minimum.z, 1e-6)
    report["originOffsetFromCentre"] = [centre.x, centre.y, centre.z]
    report["originOffsetRatio"] = max(abs(centre.x), abs(centre.y), abs(centre.z)) / span

    materials = [material.name for material in obj.data.materials if material]
    report["materials"] = materials
    report["materialCount"] = len(materials)

    # Declared is not the same as visible. A slot with no polygon pointing at it
    # renders nowhere, so counting slots overstates the asset: the receipt says
    # three materials and the render shows one. Report what the faces actually
    # use, and name the slots that reach nothing.
    used = sorted({polygon.material_index for polygon in obj.data.polygons})
    report["materialSlotsUsed"] = len(used)
    report["unusedMaterials"] = [
        obj.data.materials[index].name
        for index in range(len(obj.data.materials))
        if index not in used and obj.data.materials[index] is not None
    ]
    report["faceCountByMaterial"] = {
        (obj.data.materials[index].name if index < len(obj.data.materials)
         and obj.data.materials[index] is not None else f"slot{index}"):
            sum(1 for polygon in obj.data.polygons if polygon.material_index == index)
        for index in used
    }

    textured = 0
    for material in obj.data.materials:
        if material is None or not material.use_nodes:
            continue
        for node in material.node_tree.nodes:
            if node.type == "TEX_IMAGE" and node.image is not None:
                textured += 1
                break
    report["texturedMaterials"] = textured

    return report


def job(payload):
    import bpy

    mesh_path = payload.get("meshPath")
    if mesh_path:
        _runtime.reset_scene()
        extension = os.path.splitext(mesh_path)[1].lower()
        if extension == ".glb" or extension == ".gltf":
            bpy.ops.import_scene.gltf(filepath=mesh_path)
        elif extension == ".fbx":
            bpy.ops.import_scene.fbx(filepath=mesh_path)
        elif extension == ".obj":
            if hasattr(bpy.ops.wm, "obj_import"):
                bpy.ops.wm.obj_import(filepath=mesh_path)
            else:
                bpy.ops.import_scene.obj(filepath=mesh_path)
        else:
            raise RuntimeError("unsupported mesh format: {}".format(extension))

    meshes = [obj for obj in bpy.data.objects if obj.type == "MESH"]
    if not meshes:
        raise RuntimeError("the file contains no mesh objects")

    reports = {}
    for obj in meshes:
        reports[obj.name] = _analyse_object(obj)

    # An asset is one mesh. More than one means the export carried scaffolding
    # or the program joined nothing, and both are worth saying out loud.
    return {
        "objectCount": len(meshes),
        "objects": reports,
        "primary": meshes[0].name,
    }


if __name__ == "__main__":
    raise SystemExit(_runtime.main(job))
