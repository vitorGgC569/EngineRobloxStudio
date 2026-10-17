"""Bounded, atomic filesystem operations for untrusted-facing surfaces."""

from __future__ import annotations

import os
import tempfile
from pathlib import Path


class SafeIoError(ValueError):
    pass


def read_bytes_limited(path: Path, maximum: int, *, label: str = "file") -> bytes:
    if maximum < 1:
        raise ValueError("maximum must be positive")
    try:
        declared = path.stat().st_size
    except OSError as exc:
        raise SafeIoError(f"cannot stat {label}: {exc}") from exc
    if declared > maximum:
        raise SafeIoError(f"{label} exceeds the {maximum}-byte limit")
    try:
        with path.open("rb") as handle:
            payload = handle.read(maximum + 1)
    except OSError as exc:
        raise SafeIoError(f"cannot read {label}: {exc}") from exc
    if len(payload) > maximum:
        raise SafeIoError(f"{label} exceeds the {maximum}-byte limit")
    return payload


def read_text_limited(
    path: Path,
    maximum: int,
    *,
    label: str = "file",
    encoding: str = "utf-8",
) -> str:
    payload = read_bytes_limited(path, maximum, label=label)
    try:
        return payload.decode(encoding)
    except UnicodeDecodeError as exc:
        raise SafeIoError(f"{label} must be valid {encoding}") from exc


def atomic_write_text(
    path: Path,
    text: str,
    *,
    overwrite: bool = False,
    accept_identical: bool = True,
    encoding: str = "utf-8",
) -> str:
    """Publish complete bytes atomically and never overwrite by accident.

    Returns ``created``, ``unchanged`` or ``replaced``.  Without ``overwrite``,
    an existing different file is an error even under a concurrent writer.
    """

    payload = text.encode(encoding)
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        if overwrite:
            existed = path.exists()
            os.replace(temporary, path)
            return "replaced" if existed else "created"
        try:
            os.link(temporary, path)
            return "created"
        except FileExistsError as exc:
            try:
                existing = path.read_bytes()
            except OSError as read_exc:
                raise SafeIoError(f"cannot compare existing file {path}: {read_exc}") from read_exc
            # Text written by Path.write_text on Windows may contain CRLF even
            # when the logical document was constructed with LF. Treat that as
            # the same text, while preserving the existing bytes.
            same_text = existing.replace(b"\r\n", b"\n") == payload.replace(b"\r\n", b"\n")
            if accept_identical and (existing == payload or same_text):
                return "unchanged"
            raise SafeIoError(f"refusing to overwrite existing file: {path}") from exc
    finally:
        temporary.unlink(missing_ok=True)
