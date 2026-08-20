"""Procedural audio, synthesised in pure Python.

Audio is the asset class most bottlenecked on moderation: every upload needs an
ID-verified account and clears review on Roblox's schedule, not ours. So the
value here is leverage rather than volume -- a handful of synthesised sources,
routed through the `Sound.graph` mixer with filters and pitch, covers a whole
game's worth of cues, and none of them has to wait on a queue.

Pure standard library on purpose. `wave` and `array` ship with Python, so this
runs in CI, in a container and in an Open Cloud task with nothing to install. A
synthesiser that needs numpy is unavailable exactly where the pipeline runs.

**Where this stops is stated rather than hidden.** Roblox's Assets API accepts
mp3 and ogg; it does not accept wav. A wav quietly offered for upload is
rejected at the far end with nothing local to explain it, so `encoder_available`
names the gap and `encode` refuses a format Roblox will not take.
"""

from __future__ import annotations

import array
import hashlib
import io
import math
import shutil
import subprocess
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Sequence


SAMPLE_RATE = 44_100
CHANNELS = 1
SAMPLE_WIDTH = 2  # 16-bit PCM

#: Longer than this is a music bed rather than a cue, and Roblox treats the two
#: differently on upload.
MAX_SECONDS = 20.0

#: Headroom below full scale. Synthesised waveforms clip hard and audibly at
#: 1.0, and a clipped cue sounds broken rather than loud.
PEAK = 0.89

#: What Roblox's Assets API will actually take. Held as data so the refusal in
#: `encode` and the message in `encoder_available` cannot drift apart.
ROBLOX_AUDIO_FORMATS = ("mp3", "ogg")


class AudioAuthoringError(ValueError):
    """The sound could not be synthesised, written or encoded."""


@dataclass(frozen=True)
class Sound:
    """One rendered cue, plus what it takes to trust and reproduce it."""

    samples: tuple[float, ...]
    generator: str
    seed: int
    sample_rate: int = SAMPLE_RATE

    @property
    def duration(self) -> float:
        return len(self.samples) / self.sample_rate

    @property
    def peak(self) -> float:
        return max((abs(value) for value in self.samples), default=0.0)

    def to_wav_bytes(self) -> bytes:
        buffer = io.BytesIO()
        with wave.open(buffer, "wb") as handle:
            handle.setnchannels(CHANNELS)
            handle.setsampwidth(SAMPLE_WIDTH)
            handle.setframerate(self.sample_rate)
            frames = array.array(
                "h", (int(max(-1.0, min(1.0, value)) * 32767) for value in self.samples)
            )
            handle.writeframes(frames.tobytes())
        return buffer.getvalue()

    def write_wav(self, path: Path) -> Path:
        path = Path(path)
        if path.suffix.lower() != ".wav":
            raise AudioAuthoringError("this synthesiser writes wav; use encode() to convert")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(self.to_wav_bytes())
        return path

    @property
    def sha256(self) -> str:
        return hashlib.sha256(self.to_wav_bytes()).hexdigest()

    def provenance(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "generator": self.generator,
            "seed": self.seed,
            "sampleRate": self.sample_rate,
            "durationSeconds": round(self.duration, 4),
            "peak": round(self.peak, 4),
            "sha256": self.sha256,
            "placeholder": False,
            "uploadCaveat": (
                "Roblox accepts mp3 and ogg; this wav is a candidate for encoding "
                "rather than an uploadable asset"
            ),
        }


# ------------------------------------------------------------------ helpers


class _Rng:
    """A local deterministic generator.

    Seeding `random` from several call sites is how two "deterministic" sounds
    stop matching between runs. Local state cannot be disturbed by anything
    else.
    """

    def __init__(self, seed: int) -> None:
        self._state = (seed * 2654435761 + 1) & 0xFFFFFFFF

    def __call__(self) -> float:
        self._state = (1103515245 * self._state + 12345) & 0x7FFFFFFF
        return (self._state / 0x7FFFFFFF) * 2.0 - 1.0

    def between(self, low: float, high: float) -> float:
        return low + (self() * 0.5 + 0.5) * (high - low)


def _frames(seconds: float) -> int:
    if not isinstance(seconds, (int, float)) or not 0 < seconds <= MAX_SECONDS:
        raise AudioAuthoringError(
            f"duration must be greater than 0 and at most {MAX_SECONDS} seconds"
        )
    return int(seconds * SAMPLE_RATE)


def envelope(count: int, attack: float, decay: float, sustain: float, release: float) -> list[float]:
    """ADSR over `count` frames, as fractions of the whole.

    The single most important part of a synthesised cue. A tone without an
    attack starts at full amplitude and clicks, and that click is what makes
    generated audio sound generated.
    """

    total = attack + decay + release
    if total > 1.0:
        attack, decay, release = (value / total for value in (attack, decay, release))
    attack_frames = max(int(count * attack), 1)
    decay_frames = max(int(count * decay), 1)
    release_frames = max(int(count * release), 1)
    sustain_frames = max(count - attack_frames - decay_frames - release_frames, 0)

    shape: list[float] = []
    for index in range(attack_frames):
        shape.append(index / attack_frames)
    for index in range(decay_frames):
        shape.append(1.0 - (1.0 - sustain) * (index / decay_frames))
    shape.extend([sustain] * sustain_frames)
    for index in range(release_frames):
        shape.append(sustain * (1.0 - index / release_frames))
    while len(shape) < count:
        shape.append(0.0)
    return shape[:count]


def _lowpass(samples: Sequence[float], cutoff: float) -> list[float]:
    """One-pole low-pass. Takes the edge off a square or noise source."""

    if cutoff <= 0 or cutoff >= SAMPLE_RATE / 2:
        return list(samples)
    alpha = math.exp(-2.0 * math.pi * cutoff / SAMPLE_RATE)
    output: list[float] = []
    previous = 0.0
    for value in samples:
        previous = value * (1 - alpha) + previous * alpha
        output.append(previous)
    return output


def _normalise(samples: Sequence[float]) -> tuple[float, ...]:
    peak = max((abs(value) for value in samples), default=0.0)
    if peak == 0:
        return tuple(samples)
    return tuple(value * (PEAK / peak) for value in samples)


# --------------------------------------------------------------- generators


def tone(
    frequency: float,
    *,
    duration: float = 0.3,
    shape: str = "sine",
    sweep_to: float | None = None,
    attack: float = 0.02,
    decay: float = 0.2,
    sustain: float = 0.6,
    release: float = 0.35,
    lowpass: float | None = None,
    seed: int = 0,
) -> Sound:
    """One enveloped tone, optionally swept.

    The seed applies a small detune and phase offset. Two plays of the same cue
    at different seeds are recognisably the same sound without being byte
    identical, which is what stops a repeated effect turning into a machine gun.
    """

    if not isinstance(frequency, (int, float)) or frequency <= 0:
        raise AudioAuthoringError("frequency must be positive")
    count = _frames(duration)
    random = _Rng(seed)

    detune = random.between(0.985, 1.015)
    phase = random.between(0.0, 2.0 * math.pi)
    start = frequency * detune
    end = (sweep_to if sweep_to is not None else frequency) * detune

    raw: list[float] = []
    for index in range(count):
        position = index / count
        current = max(start + (end - start) * position, 1.0)
        phase += 2.0 * math.pi * current / SAMPLE_RATE
        if shape == "sine":
            raw.append(math.sin(phase))
        elif shape == "square":
            raw.append(1.0 if math.sin(phase) >= 0 else -1.0)
        elif shape == "saw":
            raw.append(((phase / math.pi) % 2.0) - 1.0)
        elif shape == "triangle":
            raw.append(2.0 * abs(((phase / math.pi) % 2.0) - 1.0) - 1.0)
        elif shape == "noise":
            raw.append(random())
        else:
            raise AudioAuthoringError(f"unknown waveform {shape!r}")

    if lowpass is not None:
        raw = _lowpass(raw, lowpass)

    shaped = [
        value * gain
        for value, gain in zip(raw, envelope(count, attack, decay, sustain, release))
    ]
    return Sound(_normalise(shaped), f"tone:{shape}:{int(frequency)}", seed)


def _mix(voices: Sequence[Sound], generator: str, seed: int) -> Sound:
    length = min(len(voice.samples) for voice in voices)
    summed = [
        sum(voice.samples[index] for voice in voices) / len(voices)
        for index in range(length)
    ]
    return Sound(_normalise(summed), generator, seed)


def click(*, duration: float = 0.07, seed: int = 0) -> Sound:
    """A short bright tick. Buttons, toggles, selection."""

    random = _Rng(seed)
    body = tone(
        random.between(840, 960), duration=duration, shape="sine",
        attack=0.03, decay=0.35, sustain=0.15, release=0.55, seed=seed,
    )
    edge = tone(
        2400, duration=duration * 0.5, shape="noise", lowpass=6000,
        attack=0.02, decay=0.4, sustain=0.1, release=0.5, seed=seed + 1,
    )
    padded = tuple(edge.samples) + (0.0,) * (len(body.samples) - len(edge.samples))
    summed = [a * 0.75 + b * 0.25 for a, b in zip(body.samples, padded)]
    return Sound(_normalise(summed), "click", seed)


def denial(*, duration: float = 0.3, seed: int = 0) -> Sound:
    """A downward buzz. Refusal, insufficient funds, locked."""

    random = _Rng(seed)
    root = random.between(210, 235)
    return tone(
        root, duration=duration, shape="square", sweep_to=root * 0.55,
        lowpass=1300, attack=0.02, decay=0.25, sustain=0.45, release=0.45, seed=seed,
    )


def reward(*, duration: float = 0.7, seed: int = 0) -> Sound:
    """A rising major arpeggio. Anything the player earned."""

    random = _Rng(seed)
    root = random.between(515, 530)
    voices = [
        tone(
            root * ratio, duration=duration, shape="triangle",
            attack=0.02 + index * 0.06, decay=0.2, sustain=0.55, release=0.5,
            seed=seed + index,
        )
        for index, ratio in enumerate((1.0, 1.26, 1.5, 2.0))
    ]
    return _mix(voices, "reward", seed)


def machine_loop(duration: float = 1.5, *, frequency: float = 110.0, harmonics: int = 3, seed: int = 0) -> Sound:
    """A seamless machinery hum.

    Built from an integer number of cycles so the waveform ends where it began.
    A loop that does not close clicks once per iteration, forever -- which reads
    as a bug in the game rather than in the asset.
    """

    if harmonics < 1:
        raise AudioAuthoringError("a loop needs at least one harmonic")
    count = _frames(duration)
    random = _Rng(seed)
    base = frequency * random.between(0.97, 1.03)

    # Snap each partial to a whole number of cycles across the buffer, so every
    # component is periodic over exactly the loop length.
    raw = [0.0] * count
    for harmonic in range(1, harmonics + 1):
        cycles = max(round(base * harmonic * duration), 1)
        amplitude = 1.0 / harmonic
        offset = random.between(0.0, 2.0 * math.pi)
        for index in range(count):
            raw[index] += amplitude * math.sin(
                2.0 * math.pi * cycles * (index / count) + offset
            )

    # No envelope: an ADSR would fade the ends and break the seam. A loop is
    # faded by the mixer when it starts and stops, not baked in.
    return Sound(_normalise(raw), "machine_loop", seed)


#: Every generator, by intent rather than by waveform. A caller should not have
#: to know that a denial is a downward square sweep.
GENERATORS: dict[str, Callable[..., Sound]] = {
    "tone": tone,
    "click": click,
    "denial": denial,
    "reward": reward,
    "machine_loop": machine_loop,
}


# ----------------------------------------------------------------- encoding


def encoder_available() -> dict[str, Any]:
    """Whether wav can be converted into something Roblox will accept.

    Named rather than assumed. Without an encoder the pipeline still produces
    correct audio, and the honest report is that it stops one step short of
    uploadable.
    """

    ffmpeg = shutil.which("ffmpeg")
    return {
        "available": ffmpeg is not None,
        "encoder": ffmpeg,
        "acceptedByRoblox": list(ROBLOX_AUDIO_FORMATS),
        "produces": "wav",
        "blockers": [] if ffmpeg else [
            "no ffmpeg on PATH; Roblox accepts mp3 and ogg, so a wav cannot be "
            "uploaded as-is. Install ffmpeg, or encode the wav elsewhere."
        ],
    }


def encode(source: Path, target: Path) -> dict[str, Any]:
    """Convert a wav into an upload-acceptable format."""

    source, target = Path(source), Path(target)
    suffix = target.suffix.lower().lstrip(".")

    if suffix not in ROBLOX_AUDIO_FORMATS:
        # Refused locally rather than attempted. A flac that encodes perfectly
        # and is then rejected by Roblox has wasted the round trip and taught
        # the caller nothing.
        return {
            "status": "FAILED",
            "reason": (
                f"Roblox accepts {' and '.join(ROBLOX_AUDIO_FORMATS)}; {suffix or 'that format'} "
                "would be rejected on upload"
            ),
            "acceptedByRoblox": list(ROBLOX_AUDIO_FORMATS),
        }
    if not source.is_file():
        return {"status": "FAILED", "reason": f"source not found: {source}"}

    capability = encoder_available()
    if not capability["available"]:
        return {
            "status": "BLOCKED",
            "reason": "no encoder is installed",
            "blockers": capability["blockers"],
        }

    target.parent.mkdir(parents=True, exist_ok=True)
    process = subprocess.run(
        [capability["encoder"], "-y", "-loglevel", "error", "-i", str(source), str(target)],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=120,
    )
    if process.returncode != 0 or not target.is_file():
        return {
            "status": "FAILED",
            "reason": (process.stderr or "the encoder failed").strip().splitlines()[-1:] or ["unknown"],
        }

    return {
        "status": "ENCODED",
        "path": str(target),
        "bytes": target.stat().st_size,
        "format": suffix,
        "sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
        # Encoded is not uploaded, and uploaded is not approved.
        "note": "acceptable to the Assets API; moderation still applies after upload",
    }
