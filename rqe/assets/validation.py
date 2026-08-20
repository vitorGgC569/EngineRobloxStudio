"""Deterministic local validation before any remote upload is attempted."""

from __future__ import annotations

import hashlib
import json
import struct
import wave
import xml.etree.ElementTree as ET
from dataclasses import replace
from pathlib import Path
from typing import Any

from PIL import Image, UnidentifiedImageError

from .models import (
    AssetKind,
    AssetRecord,
    AssetState,
    CheckStatus,
    ValidationCheck,
    ValidationReport,
)


MAX_ASSET_BYTES = 20 * 1024 * 1024
MAX_AUDIO_SECONDS = 7 * 60
MAX_AUDIO_SAMPLE_RATE = 48_000
ALLOWED_AUDIO_CHANNELS = {1, 2, 3, 6}
MAX_IMAGE_DIMENSION = 7_999  # Official requirement is strictly below 8000.

_EXTENSIONS = {
    AssetKind.MESH: {".fbx", ".gltf", ".glb", ".rbxm", ".rbxmx"},
    AssetKind.AUDIO: {".mp3", ".ogg", ".wav", ".flac"},
    AssetKind.ANIMATION: {".rbxm", ".rbxmx"},
    AssetKind.ICON: {".png", ".jpg", ".jpeg", ".bmp", ".tga"},
}

_CONTENT_TYPES = {
    ".fbx": "model/fbx",
    ".gltf": "model/gltf+json",
    ".glb": "model/gltf-binary",
    ".rbxm": "model/x-rbxm",
    ".rbxmx": "model/x-rbxm",
    ".mp3": "audio/mpeg",
    ".ogg": "audio/ogg",
    ".wav": "audio/wav",
    ".flac": "audio/flac",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".bmp": "image/bmp",
    ".tga": "image/tga",
}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _check(code: str, status: CheckStatus, message: str, **details: Any) -> ValidationCheck:
    return ValidationCheck(code, status, message, details)


def image_dimensions(path: Path) -> tuple[int, int]:
    expected_format = {
        ".png": "PNG",
        ".jpg": "JPEG",
        ".jpeg": "JPEG",
        ".bmp": "BMP",
        ".tga": "TGA",
    }.get(path.suffix.lower())
    if expected_format is None:
        raise ValueError(f"unsupported image extension: {path.suffix.lower()}")
    try:
        with Image.open(path) as image:
            if image.format != expected_format:
                raise ValueError(
                    f"image payload is {image.format}, expected {expected_format}"
                )
            dimensions = image.size
            image.verify()
    except UnidentifiedImageError as exc:
        raise ValueError("image payload is not decodable") from exc
    return dimensions


class LocalAssetValidator:
    """Validate formats Roblox documents as uploadable through Assets API.

    Validation is intentionally conservative.  When the standard library
    cannot inspect a property (for example MP3 duration), the draft must carry
    measured metadata from an upstream tool; the check becomes BLOCKED instead
    of guessing.
    """

    def validate(self, asset: AssetRecord) -> ValidationReport:
        checks: list[ValidationCheck] = []

        if asset.state not in {AssetState.DRAFT, AssetState.VALIDATED}:
            checks.append(
                _check(
                    "state.accepts_validation",
                    CheckStatus.FAIL,
                    f"asset in state {asset.state.value} cannot be validated",
                )
            )

        if not asset.display_name.strip() or not asset.description.strip():
            checks.append(
                _check(
                    "metadata.named_and_described",
                    CheckStatus.FAIL,
                    "display name and description are required",
                )
            )
        else:
            checks.append(
                _check(
                    "metadata.named_and_described",
                    CheckStatus.PASS,
                    "display name and description are present",
                )
            )

        if (
            asset.license is None
            or not asset.license.verified
            or not asset.license.name.strip()
            or not asset.license.terms_url.strip()
            or not asset.license.usage_scope.strip()
            or not (asset.license.evidence or "").strip()
        ):
            checks.append(
                _check(
                    "rights.verified",
                    CheckStatus.BLOCKED,
                    "upload requires verified legal rights or an acquired Creator Store license",
                )
            )
        else:
            checks.append(
                _check(
                    "rights.verified",
                    CheckStatus.PASS,
                    "license evidence is marked verified",
                    termsUrl=asset.license.terms_url,
                )
            )

        if (
            asset.provenance is None
            or not asset.provenance.provider.strip()
            or not asset.provenance.source_uri.strip()
            or not asset.provenance.retrieved_at.strip()
        ):
            checks.append(
                _check(
                    "provenance.present",
                    CheckStatus.BLOCKED,
                    "source provenance is required before publication",
                )
            )
        else:
            checks.append(
                _check(
                    "provenance.present",
                    CheckStatus.PASS,
                    "source provenance is present",
                )
            )

        if not asset.previews and asset.requirement.value == "production-required":
            checks.append(
                _check(
                    "preview.present",
                    CheckStatus.BLOCKED,
                    "production-required assets need a preview before publication",
                )
            )
        elif not asset.previews:
            checks.append(
                _check(
                    "preview.present",
                    CheckStatus.WARN,
                    "no preview is attached; production manifests will block this asset",
                )
            )
        else:
            checks.append(
                _check(
                    "preview.present",
                    CheckStatus.PASS,
                    f"{len(asset.previews)} preview(s) attached",
                )
            )

        path = Path(asset.local_path) if asset.local_path else None
        if path is None or not path.is_file():
            checks.append(
                _check(
                    "file.exists",
                    CheckStatus.FAIL,
                    "local asset file does not exist",
                    path=asset.local_path,
                )
            )
            return self._finish(asset, checks, None)

        checks.append(_check("file.exists", CheckStatus.PASS, "local asset file exists"))
        suffix = path.suffix.lower()
        if suffix not in _EXTENSIONS[asset.kind]:
            checks.append(
                _check(
                    "file.extension_supported",
                    CheckStatus.FAIL,
                    f"{suffix or '<none>'} is not supported for {asset.kind.value}",
                    allowed=sorted(_EXTENSIONS[asset.kind]),
                )
            )
        else:
            checks.append(
                _check(
                    "file.extension_supported",
                    CheckStatus.PASS,
                    f"{suffix} is supported for {asset.kind.value}",
                )
            )

        try:
            size = path.stat().st_size
        except OSError as exc:
            checks.append(_check("file.size", CheckStatus.FAIL, str(exc)))
            return self._finish(asset, checks, None)
        checks.append(
            _check(
                "file.size",
                CheckStatus.PASS if 0 < size <= MAX_ASSET_BYTES else CheckStatus.FAIL,
                f"file size is {size} bytes",
                maximumBytes=MAX_ASSET_BYTES,
            )
        )

        expected_type = _CONTENT_TYPES.get(suffix)
        if expected_type and asset.content_type not in {None, expected_type}:
            checks.append(
                _check(
                    "file.content_type",
                    CheckStatus.FAIL,
                    f"content type {asset.content_type!r} does not match {expected_type}",
                )
            )
        elif expected_type:
            checks.append(
                _check(
                    "file.content_type",
                    CheckStatus.PASS,
                    f"content type resolves to {expected_type}",
                )
            )

        if suffix in _EXTENSIONS[AssetKind.ICON]:
            self._validate_icon(path, checks)
        if asset.kind == AssetKind.AUDIO:
            self._validate_audio(path, asset.metadata, checks)
        if asset.kind == AssetKind.MESH:
            self._validate_mesh(path, checks)
        if asset.kind == AssetKind.ANIMATION:
            self._validate_animation(path, asset.metadata, checks)

        try:
            digest = sha256_file(path)
        except OSError as exc:
            checks.append(_check("file.hash", CheckStatus.FAIL, str(exc)))
            return self._finish(asset, checks, None, expected_type)
        return self._finish(asset, checks, digest, expected_type)

    def _validate_icon(self, path: Path, checks: list[ValidationCheck]) -> None:
        try:
            width, height = image_dimensions(path)
        except (Image.DecompressionBombError, OSError, SyntaxError, ValueError) as exc:
            checks.append(
                _check("image.dimensions", CheckStatus.FAIL, str(exc))
            )
            return
        valid = 0 < width <= MAX_IMAGE_DIMENSION and 0 < height <= MAX_IMAGE_DIMENSION
        checks.append(
            _check(
                "image.dimensions",
                CheckStatus.PASS if valid else CheckStatus.FAIL,
                f"image is {width}x{height}",
                maximumExclusive=8000,
            )
        )

    def _validate_audio(
        self,
        path: Path,
        metadata: Any,
        checks: list[ValidationCheck],
    ) -> None:
        duration: float | None = None
        sample_rate: int | None = None
        channels: int | None = None
        if path.suffix.lower() == ".wav":
            try:
                with wave.open(str(path), "rb") as stream:
                    sample_rate = stream.getframerate()
                    channels = stream.getnchannels()
                    duration = stream.getnframes() / max(1, sample_rate)
            except (wave.Error, OSError) as exc:
                checks.append(_check("audio.readable", CheckStatus.FAIL, str(exc)))
                return
        else:
            duration = _number(metadata.get("durationSeconds"))
            sample_rate = _integer(metadata.get("sampleRateHz"))
            channels = _integer(metadata.get("channels"))
            if duration is None or sample_rate is None or channels is None:
                checks.append(
                    _check(
                        "audio.measured_metadata",
                        CheckStatus.BLOCKED,
                        "non-WAV audio needs measured durationSeconds, sampleRateHz, and channels",
                    )
                )
                return
            if not isinstance(metadata.get("measurementEvidence"), str) or not metadata[
                "measurementEvidence"
            ].strip():
                checks.append(
                    _check(
                        "audio.measurement_evidence",
                        CheckStatus.BLOCKED,
                        "non-WAV measured metadata requires a measurementEvidence reference",
                    )
                )
                return

        checks.append(
            _check(
                "audio.duration",
                CheckStatus.PASS
                if duration is not None and 0 < duration <= MAX_AUDIO_SECONDS
                else CheckStatus.FAIL,
                f"audio duration is {duration:.3f}s"
                if duration is not None
                else "audio duration is unavailable",
                maximumSeconds=MAX_AUDIO_SECONDS,
            )
        )
        checks.append(
            _check(
                "audio.sample_rate",
                CheckStatus.PASS
                if sample_rate is not None and 0 < sample_rate <= MAX_AUDIO_SAMPLE_RATE
                else CheckStatus.FAIL,
                f"audio sample rate is {sample_rate}",
                maximumHz=MAX_AUDIO_SAMPLE_RATE,
            )
        )
        checks.append(
            _check(
                "audio.channels",
                CheckStatus.PASS if channels in ALLOWED_AUDIO_CHANNELS else CheckStatus.FAIL,
                f"audio channel count is {channels}",
                allowed=sorted(ALLOWED_AUDIO_CHANNELS),
            )
        )

    def _validate_mesh(self, path: Path, checks: list[ValidationCheck]) -> None:
        suffix = path.suffix.lower()
        try:
            size = path.stat().st_size
            with path.open("rb") as stream:
                head = stream.read(256)
            if suffix == ".glb":
                if len(head) < 12:
                    valid = False
                else:
                    magic, version, declared_size = struct.unpack("<4sII", head[:12])
                    valid = magic == b"glTF" and version == 2 and declared_size == size
            elif suffix == ".gltf":
                payload = json.loads(path.read_text(encoding="utf-8"))
                valid = payload.get("asset", {}).get("version") == "2.0"
            elif suffix == ".fbx":
                valid = head.startswith(b"Kaydara FBX Binary") or b"FBXHeaderExtension" in head
            elif suffix == ".rbxmx":
                valid = ET.parse(path).getroot().tag.casefold().endswith("roblox")
            else:  # Binary .rbxm.
                valid = head.startswith(b"<roblox!")
        except (OSError, UnicodeError, json.JSONDecodeError, ET.ParseError) as exc:
            checks.append(_check("mesh.container", CheckStatus.FAIL, str(exc)))
            return
        checks.append(
            _check(
                "mesh.container",
                CheckStatus.PASS if valid else CheckStatus.FAIL,
                "mesh/model container signature is valid"
                if valid
                else "mesh/model container signature is invalid",
            )
        )

    def _validate_animation(
        self,
        path: Path,
        metadata: Any,
        checks: list[ValidationCheck],
    ) -> None:
        authored = metadata.get("studioAuthored") is True
        checks.append(
            _check(
                "animation.studio_authored",
                CheckStatus.PASS if authored else CheckStatus.BLOCKED,
                "animation is recorded as Studio-authored"
                if authored
                else (
                    "Roblox warns that animation files edited outside Studio "
                    "might not upload or function"
                ),
            )
        )
        try:
            with path.open("rb") as stream:
                head = stream.read(64)
            valid = (
                b"<roblox" in head.lower()
                if path.suffix.lower() == ".rbxmx"
                else head.startswith(b"<roblox!")
            )
        except OSError as exc:
            checks.append(_check("animation.container", CheckStatus.FAIL, str(exc)))
            return
        checks.append(
            _check(
                "animation.container",
                CheckStatus.PASS if valid else CheckStatus.FAIL,
                "animation container signature is valid"
                if valid
                else "animation container signature is invalid",
            )
        )

    def _finish(
        self,
        asset: AssetRecord,
        checks: list[ValidationCheck],
        digest: str | None,
        content_type: str | None = None,
    ) -> ValidationReport:
        has_fail = any(check.status == CheckStatus.FAIL for check in checks)
        has_blocker = any(check.status == CheckStatus.BLOCKED for check in checks)
        result = asset
        if asset.provenance is not None and digest is not None:
            result = replace(
                result,
                provenance=replace(asset.provenance, content_sha256=digest),
                content_type=content_type or asset.content_type,
            )
        if has_fail and result.state in {AssetState.DRAFT, AssetState.VALIDATED}:
            result = result.transition(AssetState.REJECTED)
        elif not has_fail and not has_blocker and result.state == AssetState.DRAFT:
            result = result.transition(AssetState.VALIDATED)
        return ValidationReport(result, tuple(checks))


def _number(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    return None


def _integer(value: Any) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    return value
