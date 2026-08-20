"""Screen templates.

`Ui.lua` has the primitives. What it does not have is a *screen* -- a named
arrangement that has to survive a phone, a notch, an empty list and a language
nobody wrote it in.

Composing by hand is not slow so much as silently device-specific: a shop laid
out at 1920 wide ships and puts its buy button under the status bar at 390 wide,
and the only way anybody finds out is a screenshot somebody happened to take.

Most of these tests are the checks firing. A validator that never fires is one
nobody can trust, so each failure mode is provoked deliberately: a button too
small to hit, content outside the safe area, an element with no area at all.
"""

from __future__ import annotations

import json
import unittest
from pathlib import Path

from rqe.ui import screens
from rqe.ui.screens import (
    DEVICES,
    MIN_TEXT_SIZE,
    REQUIRED_STATES,
    TEMPLATES,
    TOUCH_TARGET_MINIMUM,
    Device,
    Element,
    ScreenError,
    ScreenTemplate,
    catalogue,
    compose,
    compose_matrix,
    screens_for,
)

REPO = Path(__file__).resolve().parents[1]
TOKENS = json.loads((REPO / "tokens" / "brickfarm.json").read_text(encoding="utf-8"))


class TestTemplates(unittest.TestCase):
    def test_the_documents_screens_all_exist(self):
        for name in ("inventory", "shop", "quest_log", "upgrade_tree"):
            self.assertIn(name, TEMPLATES, name)

    def test_every_template_declares_an_empty_state(self):
        """The first session is the one where every list is empty, and a screen
        only ever designed populated is a screen the new player sees broken."""

        for template in TEMPLATES.values():
            for state in REQUIRED_STATES:
                self.assertIn(state, template.states, template.id)

    def test_every_template_writes_its_own_empty_message(self):
        """An unlabelled empty list reads to a player as a loading failure."""

        for template in TEMPLATES.values():
            self.assertTrue(template.empty_message.strip(), template.id)

    def test_a_template_without_an_empty_state_is_refused(self):
        with self.assertRaises(ScreenError):
            ScreenTemplate(id="x", title="X", states=("populated",),
                           elements=(Element("a", "text", "body"),),
                           empty_message="nothing")

    def test_a_template_without_an_empty_message_is_refused(self):
        with self.assertRaises(ScreenError) as caught:
            ScreenTemplate(id="x", title="X",
                           elements=(Element("a", "text", "body"),), empty_message="  ")
        self.assertIn("loading failure", str(caught.exception))

    def test_an_unknown_band_is_refused(self):
        with self.assertRaises(ScreenError):
            ScreenTemplate(id="x", title="X", empty_message="e",
                           elements=(Element("a", "text", "sidebar"),))


class TestTheDeviceMatrix(unittest.TestCase):
    def test_every_shipped_screen_survives_every_device(self):
        """The point of the layer. A screen checked on one device is a screen
        whose failure is waiting on somebody's phone."""

        for name in sorted(TEMPLATES):
            report = compose_matrix(name, tokens=TOKENS)
            self.assertTrue(report["ok"], f"{name}: {report['problems']}")

    def test_the_matrix_covers_touch_and_gamepad_and_mouse(self):
        modes = {device.input_mode for device in DEVICES.values()}
        self.assertIn("TOUCH", modes)
        self.assertIn("KEYBOARD_MOUSE", modes)
        self.assertIn("GAMEPAD", modes)

    def test_console_reserves_overscan(self):
        """The outer strip of a television may not be visible at all."""

        console = DEVICES["console"]
        self.assertGreater(console.safe_left, 0)
        self.assertGreater(console.safe_bottom, 0)

    def test_an_unknown_device_lists_the_real_ones(self):
        with self.assertRaises(ScreenError) as caught:
            compose("shop", device="fridge", tokens=TOKENS)
        self.assertIn("phone", str(caught.exception))

    def test_an_unknown_screen_lists_the_real_ones(self):
        with self.assertRaises(ScreenError) as caught:
            compose("leaderboards", device="phone", tokens=TOKENS)
        self.assertIn("inventory", str(caught.exception))


class TestChecksActuallyFire(unittest.TestCase):
    """A validator that never fires is one nobody can trust."""

    def tearDown(self) -> None:
        for name in ("probe-tiny", "probe-squeeze"):
            TEMPLATES.pop(name, None)
        DEVICES.pop("probe-sliver", None)

    def test_a_button_too_small_to_hit_is_caught(self):
        """The player concludes the button is broken rather than that they
        missed."""

        TEMPLATES["probe-tiny"] = ScreenTemplate(
            id="probe-tiny", title="T", empty_message="e",
            elements=(Element("title", "text", "header", text_step="title", height=48),
                      Element("ok", "button", "footer", text_step="label",
                              interactive=True, height=18)))
        layout = compose("probe-tiny", device="phone", tokens=TOKENS)
        self.assertFalse(layout.ok)
        self.assertTrue(any("finger reliably hits" in p for p in layout.problems()))

    def test_content_outside_the_safe_area_is_caught(self):
        """Drawn and unreachable is the failure only a phone shows."""

        DEVICES["probe-sliver"] = Device("probe-sliver", 320, 120, "TOUCH",
                                         safe_top=60, safe_bottom=50)
        layout = compose("shop", device="probe-sliver", tokens=TOKENS)
        self.assertFalse(layout.ok)
        self.assertTrue(any("safe area" in p for p in layout.problems()))

    def test_an_element_squeezed_to_nothing_is_caught(self):
        """It exists in the tree and not on the screen, which is the hardest
        kind of missing to find."""

        TEMPLATES["probe-squeeze"] = ScreenTemplate(
            id="probe-squeeze", title="S", empty_message="e",
            elements=tuple(
                [Element(f"h{i}", "text", "header", text_step="body", height=200)
                 for i in range(4)]
                + [Element("body", "scroller", "body", weight=1.0)]))
        layout = compose("probe-squeeze", device="phone", tokens=TOKENS)
        self.assertFalse(layout.ok)

    def test_a_device_with_no_usable_area_is_refused(self):
        DEVICES["probe-sliver"] = Device("probe-sliver", 200, 80, "TOUCH",
                                         safe_top=60, safe_bottom=40)
        with self.assertRaises(ScreenError):
            compose("shop", device="probe-sliver", tokens=TOKENS)


class TestLayout(unittest.TestCase):
    def test_touch_footers_stack_rather_than_shrink(self):
        """Five buttons across a 390-wide phone would give each 68px. Stacking
        is the answer; shrinking below the touch minimum is not."""

        TEMPLATES["probe-row"] = ScreenTemplate(
            id="probe-row", title="R", empty_message="e",
            elements=tuple(
                [Element("title", "text", "header", text_step="title", height=48)]
                + [Element(f"b{i}", "button", "footer", text_step="label",
                           interactive=True, height=TOUCH_TARGET_MINIMUM)
                   for i in range(5)]))
        try:
            layout = compose("probe-row", device="phone", tokens=TOKENS)
            self.assertTrue(layout.ok, layout.problems())
            widths = {layout.rects[f"b{i}"].width for i in range(5)}
            self.assertEqual(len(widths), 1)
            self.assertGreaterEqual(min(widths), TOUCH_TARGET_MINIMUM)
        finally:
            TEMPLATES.pop("probe-row", None)

    def test_type_scales_down_on_a_phone_but_never_below_legibility(self):
        """Small-and-unreadable is worse than large-and-cramped."""

        desktop = compose("inventory", device="desktop", tokens=TOKENS)
        phone = compose("inventory", device="phone", tokens=TOKENS)
        self.assertLess(phone.text_sizes["title"], desktop.text_sizes["title"])
        for size in phone.text_sizes.values():
            self.assertGreaterEqual(size, MIN_TEXT_SIZE)

    def test_sizes_come_from_the_token_set(self):
        """A screen laid out against sizes chosen here would look right alone
        and wrong beside the game."""

        with self.assertRaises(ScreenError) as caught:
            compose("shop", device="phone", tokens={"spacing": {"steps": {}}})
        self.assertIn("typography", str(caught.exception))

    def test_everything_sits_inside_the_safe_area(self):
        for name in sorted(TEMPLATES):
            for device_name, device in DEVICES.items():
                layout = compose(name, device=device_name, tokens=TOKENS)
                for element_id, rect in layout.rects.items():
                    self.assertGreaterEqual(rect.y, device.safe_top,
                                            f"{name}/{device_name}/{element_id}")


class TestScreensForAModel(unittest.TestCase):
    def test_a_shop_screen_follows_a_shop_system(self):
        """A shop screen in a game with no shop is a button that opens an empty
        panel; a shop with no screen is a system nobody can reach."""

        from rqe.recipes import apply

        with_shop = apply("tycoon", id="a", theme="t", pitch="p",
                          extra_verbs=["buy"], extra_systems=["shop"])
        without = apply("tycoon", id="b", theme="t", pitch="p")
        self.assertIn("shop", screens_for(with_shop))
        self.assertNotIn("shop", screens_for(without))

    def test_every_game_gets_a_hud_and_settings(self):
        from rqe.recipes import apply

        model = apply("racing", id="r", theme="t", pitch="p")
        self.assertIn("hud", screens_for(model))
        self.assertIn("settings", screens_for(model))

    def test_every_screen_a_model_needs_composes(self):
        from rqe.recipes import apply

        model = apply("tycoon", id="a", theme="t", pitch="p",
                      extra_verbs=["buy"], extra_systems=["shop"])
        for name in screens_for(model):
            report = compose_matrix(name, tokens=TOKENS)
            self.assertTrue(report["ok"], f"{name}: {report['problems']}")


class TestCatalogue(unittest.TestCase):
    def test_the_catalogue_names_the_thresholds(self):
        report = catalogue()
        self.assertEqual(report["touchTargetMinimum"], TOUCH_TARGET_MINIMUM)
        self.assertEqual(report["minTextSize"], MIN_TEXT_SIZE)

    def test_every_device_reports_its_safe_area(self):
        for entry in catalogue()["devices"].values():
            self.assertIn("safeArea", entry)


if __name__ == "__main__":
    unittest.main()
