"""Guarding the eye that judges the games.

`corpus_visual` decides whether a built game looks like anything, and it shipped
with two measurement bugs that both *looked like they worked*:

  1. It captured in edit context. Three different games scored 82.7 with
     byte-identical findings, because these games assemble their worlds at
     runtime and the editor viewport is empty sky -- so the critic was measuring
     Studio's own UI chrome.
  2. It did not pass `viewport`. `critique_scene` has always taken one and its
     docstring has always said why, and no caller in the repository passed it.
     Cropped, one game went from 13% clipped to 0.1%: the clipping was the
     toolbar.

Neither failed loudly. Both produced confident numbers, and the first produced
*identical* ones for different games, which is the only reason it was caught.

So the tests below encode the two failures as assertions rather than as a
paragraph in a skill file. They build their own frames rather than reading
captures out of `.tmp`, which is a scratch directory and is deleted.
"""

from __future__ import annotations

import inspect
from pathlib import Path

import pytest

from rqe import corpus_visual

Image = pytest.importorskip("PIL.Image")

REPO = Path(__file__).resolve().parent.parent


def studio_like(tmp_path: Path, *, world: tuple[int, int, int]) -> Path:
    """A frame shaped like a Studio screenshot: dark chrome round a viewport.

    The proportions are the ones `STUDIO_VIEWPORT` describes, so cropping to it
    leaves only the `world` colour and keeping the whole frame mixes in the
    chrome. That is exactly the confound the viewport exists to remove.

    The surround is **pure black**, which is what the real captures contain: the
    screenshot canvas is larger than the Studio window, so there are letterbox
    bands at 0, and the property panel beside them is nearly as dark. A first
    version of this fixture used (18, 20, 24) and measured nothing -- a grey
    that dark still reads as detail, and the test passed while proving nothing.
    """

    width, height = 400, 300
    left, top, right, bottom = corpus_visual.STUDIO_VIEWPORT
    image = Image.new("RGB", (width, height), (0, 0, 0))
    for y in range(int(top * height), int(bottom * height)):
        for x in range(int(left * width), int(right * width)):
            image.putpixel((x, y), world)

    path = tmp_path / "frame.png"
    image.save(path)
    return path


# -- the viewport bug ---------------------------------------------------------


def test_the_viewport_changes_what_is_measured(tmp_path):
    """Chrome in the frame is chrome in the numbers.

    If cropping makes no difference then the crop is not being applied, which is
    the state the repository was in: a parameter that existed, was documented,
    and reached nothing.
    """

    from rqe.scene.critic import critique_scene

    frame = studio_like(tmp_path, world=(120, 130, 140))
    whole = critique_scene({"f": frame})
    cropped = critique_scene({"f": frame}, viewport=corpus_visual.STUDIO_VIEWPORT)

    assert whole.measurements["f"] != cropped.measurements["f"], (
        "cropping to the viewport changed nothing, so it is not being applied")


def test_dark_chrome_is_counted_as_dark_without_the_crop(tmp_path):
    """The specific confound: Studio's panels are black and the game is not."""

    from rqe.scene.dimensions import crushed_fraction

    frame = studio_like(tmp_path, world=(140, 150, 160))
    image = Image.open(frame).convert("RGB")

    left, top, right, bottom = corpus_visual.STUDIO_VIEWPORT
    box = (int(left * image.width), int(top * image.height),
           int(right * image.width), int(bottom * image.height))

    assert crushed_fraction(image) > crushed_fraction(image.crop(box)), (
        "the dark chrome must show up in the uncropped frame; if it does not, "
        "this fixture no longer reproduces the bug it guards")


def test_native_corpus_does_not_crop_studio_chrome_by_default():
    """Native StudioCaptureService frames contain no Studio ribbon/panels.

    Applying the old window-grab crop to a native viewport would crop the game
    itself, so the default must be no crop.
    """

    signature = inspect.signature(corpus_visual.sweep)
    assert signature.parameters["viewport"].default is None

    signature = inspect.signature(corpus_visual.look_at)
    assert signature.parameters["viewport"].default is None


# -- the edit-context bug -----------------------------------------------------


def test_running_the_game_is_the_default():
    """An editor frame of a runtime-assembled world is a photograph of nothing."""

    assert inspect.signature(corpus_visual.look_at).parameters["run"].default is True
    assert inspect.signature(corpus_visual.sweep).parameters["run"].default is True


def test_a_frame_that_never_ran_is_not_counted_as_scored():
    """`ran` exists so an edit capture cannot be mistaken for evidence.

    Without this the sweep reports a mean score built from frames of an empty
    editor, which is how three different games came back at 82.7.
    """

    source = inspect.getsource(corpus_visual.sweep)
    assert "look.ran" in source or "ran if run else opened" in source, (
        "the sweep must count only frames from a game that actually ran")


def test_the_session_is_repinned_after_play_solo():
    """The pinned session before Play Solo is the editor, not the game.

    Every bridge call kept landing in the editor while the game ran beside it,
    and only the capture's own integrity check noticed.
    """

    source = inspect.getsource(corpus_visual.look_at)
    assert "pin_to_running" in source


# -- failures must come back as data ------------------------------------------


def test_a_game_that_was_never_built_is_a_finding_not_a_crash():
    look = corpus_visual.look_at(REPO, "no-such-game-exists")
    assert look.opened is False
    assert "no built place" in look.error
    assert look.score is None


def test_place_for_finds_a_built_place_and_admits_when_there_is_none():
    assert corpus_visual.place_for(REPO, "no-such-game-exists") is None
    built = [
        path.name for path in (REPO / "games").iterdir()
        if path.is_dir() and any(path.glob("*.rbx*"))
    ]
    if built:
        found = corpus_visual.place_for(REPO, built[0])
        assert found is not None and found.is_file()


def test_a_sweep_of_nothing_reports_rather_than_dividing_by_zero():
    report = corpus_visual.sweep(REPO, [], sample=0)
    assert report["asked"] == 0
    assert report["meanScore"] is None
    assert report["worst"] is None


def test_the_sample_is_deterministic():
    """Two runs must open the same games, or every change looks like noise."""

    games = [(f"game-{index}", "") for index in range(20)]
    first = corpus_visual.sweep(REPO, games, sample=4, seed=7)
    second = corpus_visual.sweep(REPO, games, sample=4, seed=7)
    assert [look["id"] for look in first["looks"]] == \
           [look["id"] for look in second["looks"]]

    other = corpus_visual.sweep(REPO, games, sample=4, seed=8)
    assert [look["id"] for look in first["looks"]] != \
           [look["id"] for look in other["looks"]], (
        "a different seed must choose differently, or the seed does nothing")


def test_corpus_uses_native_capture_and_fail_closed_session_reuse():
    source = inspect.getsource(corpus_visual.look_at)
    assert "capture_native_viewpoint" in source
    assert "ensure_studio_session" in source
    assert "allow_cold_launch=allow_cold_launch" in source
    assert "allow_foreground_fallback=False" in source
    assert "capture_viewpoint(" not in source
    assert "restart_for_bridge(" not in source
