"""Geometry and asset authoring: the layer that lets an agent actually model.

An LLM should not be building meshes vertex by vertex through text, and it
should not be limited to what Studio can assemble out of parts. This package
turns Blender into a headless modelling runtime the engine commands, and returns
an inspectable asset package rather than a bare file.

    brief  ->  program  ->  Blender  ->  analysis  ->  validation  ->  renders
                  ^                                                      |
                  +---------------- revision --------------------------- +

The agent writes a *program* -- base box, bevel, extrude the reactor, array the
vents radially, join, unwrap, assign materials, decimate to budget -- and never
sees `bpy`. It gets back geometry it can look at, topology it can check against
Roblox's rules, and a verdict, all before anything is published.

Three backends exist because one tool does not suit every asset: a crate is a
procedural model, a modular building is WorldKit, a rock is an editable mesh, a
stylised machine or a statue is Blender. `brief.choose_backend` decides and says
why.
"""

from .brief import (
    AssetBrief,
    BriefError,
    Reference,
    choose_backend,
    load_brief,
)
from .package import AssetPackage, PackageError
from .pipeline import BuildOutcome, GeometryPipeline, PipelineError
from .program import (
    OPERATIONS,
    Program,
    ProgramError,
    compile_program,
    vocabulary,
)
from .validation import (
    Budget,
    Finding,
    MeshValidation,
    TRIANGLE_LIMIT,
    validate,
    validate_analysis,
)
from .worker import (
    BlenderInstall,
    BlenderUnavailable,
    GeometryWorker,
    JobResult,
    WorkerError,
    capabilities,
    locate,
)

__all__ = [
    "AssetBrief",
    "AssetPackage",
    "BlenderInstall",
    "BlenderUnavailable",
    "BriefError",
    "Budget",
    "BuildOutcome",
    "Finding",
    "GeometryPipeline",
    "GeometryWorker",
    "JobResult",
    "MeshValidation",
    "OPERATIONS",
    "PackageError",
    "PipelineError",
    "Program",
    "ProgramError",
    "Reference",
    "TRIANGLE_LIMIT",
    "WorkerError",
    "capabilities",
    "choose_backend",
    "compile_program",
    "load_brief",
    "locate",
    "validate",
    "validate_analysis",
    "vocabulary",
]
