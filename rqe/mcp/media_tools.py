"""Audio and animation generation, exposed to an agent.

Completes the asset family. Image and mesh were already reachable; these are the
two classes most bottlenecked on moderation and human hands, and the two where
being honest about the limit matters most.

Neither tool publishes. Both write a file and a provenance receipt, and both
state the constraint that cannot be resolved locally: Roblox takes mp3 and ogg
rather than wav, and it processes animations on import so an externally authored
KeyframeSequence is a candidate for upload rather than a certainty.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from .server import EngineMcpServer, Tool, ToolError


def _inside(root: Path, relative: str, label: str) -> Path:
    path = (root / relative).resolve()
    try:
        path.relative_to(root.resolve())
    except ValueError as exc:
        raise ToolError(f"{label} must stay inside the project root") from exc
    return path


def register_media_tools(server: EngineMcpServer) -> EngineMcpServer:
    root = server.root

    def asset_generate_audio(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..assets.audio_authoring import (
            GENERATORS,
            AudioAuthoringError,
            encode,
            encoder_available,
        )

        name = arguments["generator"]
        generator = GENERATORS.get(name)
        if generator is None:
            raise ToolError(
                f"unknown audio generator {name!r}; available: " + ", ".join(sorted(GENERATORS))
            )

        options: dict[str, Any] = {}
        for key in ("duration", "seed", "frequency", "harmonics"):
            if key in arguments:
                options[key] = arguments[key]
        try:
            sound = generator(**options)
        except (AudioAuthoringError, TypeError) as exc:
            raise ToolError(f"{name}: {exc}") from exc

        output_dir = _inside(root, arguments.get("outputDir", ".tmp/audio"), "outputDir")
        wav_path = sound.write_wav(output_dir / f"{arguments.get('id', name)}.wav")

        payload: dict[str, Any] = {
            "generator": name,
            "wav": str(wav_path.relative_to(root)),
            "bytes": wav_path.stat().st_size,
            "provenance": sound.provenance(),
            "encoder": encoder_available(),
        }
        if arguments.get("encodeTo"):
            target = output_dir / f"{arguments.get('id', name)}.{arguments['encodeTo']}"
            payload["encoded"] = encode(wav_path, target)
        else:
            # Said even when nobody asked, because a wav offered for upload is
            # rejected at the far end with nothing local to explain it.
            payload["uploadable"] = False
            payload["note"] = (
                "Roblox's Assets API accepts mp3 and ogg; pass encodeTo to convert"
            )
        return payload

    server.register(Tool(
        name="asset_generate_audio",
        description=(
            "Synthesise a functional sound cue -- click, confirm, denial, reward, machine "
            "loop -- deterministically from a seed. Removes moderation from the critical "
            "path for the sounds a game needs most and cares about least."
        ),
        input_schema={
            "type": "object",
            "required": ["generator"],
            "additionalProperties": False,
            "properties": {
                "generator": {"enum": ["tone", "click", "denial", "reward", "machine_loop"]},
                "id": {"type": "string", "minLength": 1},
                "duration": {"type": "number", "exclusiveMinimum": 0, "maximum": 30},
                "frequency": {"type": "number", "exclusiveMinimum": 0},
                "harmonics": {"type": "integer", "minimum": 1, "maximum": 12},
                "seed": {"type": "integer"},
                "outputDir": {"type": "string"},
                "encodeTo": {"enum": ["mp3", "ogg"]},
            },
        },
        handler=asset_generate_audio,
    ))

    def asset_generate_animation(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..assets.animation_authoring import (
            GENERATORS,
            R15_JOINTS,
            AnimationAuthoringError,
            Animation,
            Keyframe,
            Pose,
        )

        if arguments.get("keyframes"):
            frames = []
            for index, raw in enumerate(arguments["keyframes"]):
                poses = tuple(
                    Pose(
                        joint=item["joint"],
                        rotation=tuple(item.get("rotation", (0, 0, 0))),
                        offset=tuple(item.get("offset", (0, 0, 0))),
                    )
                    for item in raw.get("poses", [])
                )
                try:
                    frames.append(Keyframe(time=float(raw["time"]), poses=poses))
                except AnimationAuthoringError as exc:
                    raise ToolError(f"keyframes[{index}]: {exc}") from exc
            try:
                animation = Animation(
                    id=arguments.get("id", "authored"),
                    keyframes=tuple(frames),
                    looped=bool(arguments.get("looped", False)),
                    priority=arguments.get("priority", "Action"),
                )
            except AnimationAuthoringError as exc:
                raise ToolError(str(exc)) from exc
        else:
            name = arguments.get("generator")
            generator = GENERATORS.get(name or "")
            if generator is None:
                raise ToolError(
                    "supply either keyframes or a generator; generators: "
                    + ", ".join(sorted(GENERATORS))
                )
            animation = generator()

        output_dir = _inside(root, arguments.get("outputDir", ".tmp/animation"), "outputDir")
        path = animation.write(output_dir / f"{animation.id}.rbxmx")
        return {
            "animation": animation.id,
            "file": str(path.relative_to(root)),
            "bytes": path.stat().st_size,
            "durationSeconds": animation.duration,
            "joints": list(animation.joints),
            "looped": animation.looped,
            "provenance": animation.provenance(),
            "addressableJoints": list(R15_JOINTS),
        }

    server.register(Tool(
        name="asset_generate_animation",
        description=(
            "Author an R15 KeyframeSequence as .rbxmx, from explicit keyframes or a "
            "built-in generator. RegisterKeyframeSequence is Studio-only and is not used; "
            "for most motion, driving Motor6D from code needs no asset at all."
        ),
        input_schema={
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "id": {"type": "string", "minLength": 1},
                "generator": {"enum": ["idle_breath", "wave"]},
                "looped": {"type": "boolean"},
                "priority": {"enum": ["Idle", "Movement", "Action", "Core"]},
                "outputDir": {"type": "string"},
                "keyframes": {
                    "type": "array",
                    "minItems": 1,
                    "items": {
                        "type": "object",
                        "required": ["time", "poses"],
                        "additionalProperties": False,
                        "properties": {
                            "time": {"type": "number", "minimum": 0},
                            "poses": {
                                "type": "array",
                                "minItems": 1,
                                "items": {
                                    "type": "object",
                                    "required": ["joint"],
                                    "additionalProperties": False,
                                    "properties": {
                                        "joint": {"type": "string"},
                                        "rotation": {
                                            "type": "array", "minItems": 3, "maxItems": 3,
                                            "items": {"type": "number"},
                                        },
                                        "offset": {
                                            "type": "array", "minItems": 3, "maxItems": 3,
                                            "items": {"type": "number"},
                                        },
                                    },
                                },
                            },
                        },
                    },
                },
            },
        },
        handler=asset_generate_animation,
    ))

    return server
