"""Procedural audio and animation.

Both exist because these are the asset classes most bottlenecked on moderation
and on human hands. Both are deliberately honest about where they stop: audio
synthesises wav and says plainly that Roblox takes mp3 and ogg; animation writes
a KeyframeSequence and says plainly that Roblox processes animations on import,
so an externally authored file is a candidate for upload rather than a certainty.
"""

from __future__ import annotations

import tempfile
import unittest
import xml.dom.minidom as minidom
from pathlib import Path

from rqe.assets.animation_authoring import (
    Animation,
    AnimationAuthoringError,
    Keyframe,
    Pose,
    R15_JOINTS,
    idle_breath,
    wave,
)
from rqe.assets.audio_authoring import (
    AudioAuthoringError,
    click,
    denial,
    encode,
    encoder_available,
    machine_loop,
    reward,
    tone,
)


class TestAudioSynthesis(unittest.TestCase):
    def test_every_generator_produces_audible_length(self):
        for sound in (tone(880), click(), denial(), reward(), machine_loop(1.0)):
            self.assertGreater(len(sound.samples), 1000)
            self.assertGreater(len(sound.to_wav_bytes()), 2000)

    def test_generation_is_deterministic_for_a_seed(self):
        self.assertEqual(click(seed=7).sha256, click(seed=7).sha256)

    def test_a_different_seed_changes_the_waveform(self):
        self.assertNotEqual(click(seed=1).sha256, click(seed=2).sha256)

    def test_samples_stay_inside_the_representable_range(self):
        """Anything beyond ±1 clips on write and reads as distortion."""

        for sound in (tone(220), reward(), machine_loop(0.5)):
            peak = max(abs(value) for value in sound.samples)
            self.assertLessEqual(peak, 1.0, f"{sound.generator} clips at {peak:.3f}")

    def test_a_loop_closes_on_itself(self):
        """A loop that does not close clicks once per second, forever."""

        loop = machine_loop(1.0)
        self.assertLess(abs(loop.samples[0] - loop.samples[-1]), 0.05)

    def test_a_cue_starts_from_silence(self):
        """Without an attack, a sample starts at full amplitude and clicks."""

        for sound in (tone(440), reward(), denial()):
            self.assertLess(abs(sound.samples[0]), 0.05, sound.generator)

    def test_an_impossible_duration_is_refused(self):
        with self.assertRaises(AudioAuthoringError):
            tone(440, duration=0)
        with self.assertRaises(AudioAuthoringError):
            tone(440, duration=999)

    def test_a_negative_frequency_is_refused(self):
        with self.assertRaises(AudioAuthoringError):
            tone(-100)

    def test_the_wav_is_a_real_wav(self):
        import wave
        from io import BytesIO

        with wave.open(BytesIO(reward().to_wav_bytes()), "rb") as handle:
            self.assertEqual(handle.getnchannels(), 1)
            self.assertEqual(handle.getsampwidth(), 2)
            self.assertEqual(handle.getframerate(), 44100)

    def test_provenance_marks_it_as_generated_not_placeholder(self):
        provenance = reward().provenance()
        self.assertFalse(provenance["placeholder"])
        self.assertEqual(len(provenance["sha256"]), 64)

    def test_the_encoder_gap_is_named_rather_than_hidden(self):
        """Roblox takes mp3 and ogg. A wav quietly offered for upload would be
        rejected at the far end with nothing local to explain it."""

        capability = encoder_available()
        self.assertIn("acceptedByRoblox", capability)
        if not capability["available"]:
            self.assertTrue(capability["blockers"])
            self.assertIn("mp3", capability["blockers"][0])

    def test_encoding_to_an_unaccepted_format_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = reward().write_wav(root / "a.wav")
            result = encode(source, root / "a.flac")
            self.assertIn(result["status"], {"FAILED", "BLOCKED"})


class TestAnimationAuthoring(unittest.TestCase):
    def test_the_shipped_generators_produce_valid_xml(self):
        for animation in (idle_breath(), wave()):
            minidom.parseString(animation.to_rbxmx())

    def test_generation_is_deterministic(self):
        self.assertEqual(idle_breath().sha256, idle_breath().sha256)

    def test_an_unknown_joint_is_refused_with_the_real_list(self):
        """A misspelled joint silently animates nothing, which is
        indistinguishable from a keyframe nobody authored."""

        with self.assertRaises(AnimationAuthoringError) as caught:
            Pose("Tentacle")
        self.assertIn("UpperTorso", str(caught.exception))

    def test_a_keyframe_that_animates_nothing_is_refused(self):
        with self.assertRaises(AnimationAuthoringError):
            Keyframe(0.0, ())

    def test_posing_a_joint_twice_in_one_keyframe_is_refused(self):
        with self.assertRaises(AnimationAuthoringError):
            Keyframe(0.0, (Pose("Head"), Pose("Head")))

    def test_keyframes_must_be_ordered(self):
        with self.assertRaises(AnimationAuthoringError):
            Animation("x", (Keyframe(1.0, (Pose("Head"),)), Keyframe(0.0, (Pose("Head"),))))

    def test_two_keyframes_cannot_share_a_time(self):
        with self.assertRaises(AnimationAuthoringError):
            Animation("x", (Keyframe(0.5, (Pose("Head"),)), Keyframe(0.5, (Pose("Head"),))))

    def test_a_loop_whose_ends_pose_different_joints_is_refused(self):
        """It snaps visibly at the loop point, which reads as a bug in the game
        rather than in the asset."""

        with self.assertRaises(AnimationAuthoringError) as caught:
            Animation(
                "x",
                (Keyframe(0.0, (Pose("Head"),)), Keyframe(1.0, (Pose("LeftHand"),))),
                looped=True,
            )
        self.assertIn("snap at the loop point", str(caught.exception))

    def test_an_empty_animation_is_refused(self):
        with self.assertRaises(AnimationAuthoringError):
            Animation("x", ())

    def test_only_roblox_animation_formats_are_written(self):
        with tempfile.TemporaryDirectory() as directory:
            animation = idle_breath()
            animation.write(Path(directory) / "a.rbxmx")
            with self.assertRaises(AnimationAuthoringError) as caught:
                animation.write(Path(directory) / "a.fbx")
            self.assertIn(".rbxm", str(caught.exception))

    def test_euler_angles_become_a_cframe_matrix(self):
        """Emitting Euler angles directly would be silently ignored by the
        loader, producing an animation that imports and does nothing."""

        xml = Animation("x", (Keyframe(0.0, (Pose("Head", rotation=(0, 90, 0)),)),)).to_rbxmx()
        self.assertIn("<R00>", xml)
        self.assertIn("<R22>", xml)
        self.assertIn("CoordinateFrame", xml)

    def test_a_child_joint_nests_under_its_parent(self):
        """A Pose applies to the joint between itself and its parent, so a flat
        list moves the wrong limbs."""

        xml = wave().to_rbxmx()
        upper = xml.index("RightUpperArm")
        lower = xml.index("RightLowerArm")
        self.assertLess(upper, lower)

    def test_every_declared_joint_is_addressable(self):
        for joint in R15_JOINTS:
            Pose(joint)

    def test_provenance_carries_the_upload_caveat(self):
        """The one thing about this pipeline that cannot be settled locally."""

        provenance = idle_breath().provenance()
        self.assertFalse(provenance["placeholder"])
        self.assertIn("candidate for upload", provenance["uploadCaveat"])

    def test_an_over_long_animation_is_refused(self):
        with self.assertRaises(AnimationAuthoringError):
            Animation("x", (
                Keyframe(0.0, (Pose("Head"),)),
                Keyframe(99.0, (Pose("Head"),)),
            ))


if __name__ == "__main__":
    unittest.main()
