"""Typing safety, OS fallback and physical-order regressions (no ZMK runtime required)."""

import contextlib
import io
import json
import re
import unittest

from check_keymap import KEYMAP, LAYOUT, SHIELD, layer_blocks, preprocess, rows_of, validate, validate_layout


class KeymapSafetyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = KEYMAP.read_text()
        cls.text = preprocess(cls.source)
        cls.layers = {
            name: [binding for row in rows_of(body) for binding in row]
            for name, body in layer_blocks(cls.text)
        }
        cls.order = list(cls.layers)

    def effective(self, names, position):
        for name in reversed(self.order):
            if name in names and self.layers[name][position] != "&trans":
                return self.layers[name][position]
        return None

    def test_typing_and_enter_cannot_emit_modifiers_or_activate_layers(self):
        for os_layers in ({"base_layer"}, {"base_layer", "win_layer"}):
            for position in list(range(10)) + [10, 11, 12, 13, 14, 16] + list(range(17, 34)) + [40]:
                binding = self.effective(os_layers, position)
                with self.subTest(os_layers=os_layers, position=position):
                    self.assertRegex(binding, r"^&kp [A-Z][A-Z0-9_]*$")
            self.assertEqual(self.effective(os_layers, 40), "&kp ENTER")
            self.assertEqual(self.effective(os_layers, 16), "&kp QMARK")

    def test_dedicated_modifiers_survive_all_layers(self):
        for overlay in self.order:
            for windows in (False, True):
                if not windows and overlay in ("win_layer", "numw_layer", "gestw_layer"):
                    continue
                active = {"base_layer", overlay} | ({"win_layer"} if windows else set())
                for position, code in ((34, "LSHFT"), (35, "LGUI" if windows else "LCTRL"),
                                       (36, "LCTRL" if windows else "LGUI")):
                    with self.subTest(overlay=overlay, windows=windows, position=position):
                        self.assertEqual(self.effective(active, position), f"&kp {code}")

    def test_tab_and_num_lock_are_accessible_in_both_os_modes(self):
        for windows in (False, True):
            for locked in (False, True):
                active = {"base_layer", "gest_layer"}
                if windows:
                    active |= {"win_layer", "gestw_layer"}
                if locked:
                    active.add("num_layer")
                    if windows:
                        active.add("numw_layer")
                self.assertEqual(self.effective(active, 10), "&kp TAB")
                self.assertEqual(self.effective(active, 39), "&num_lock")

    def test_digits_and_function_keys_use_the_same_fingers(self):
        for digit in range(1, 10):
            self.assertEqual(self.layers["num_layer"].index(f"&kp N{digit}"),
                             self.layers["fn_layer"].index(f"&kp F{digit}"))
        self.assertEqual(self.layers["num_layer"][22], "&kp N0")

    def test_encoder_falls_back_to_the_selected_os_in_every_layer(self):
        sensor_bindings = dict(re.findall(
            r"([\w]+_layer)\s*\{[^{}]*?sensor-bindings\s*=\s*<(.*?)>;", self.text, re.S))
        for overlay in self.order:
            for windows in (False, True):
                if not windows and overlay in ("win_layer", "numw_layer", "gestw_layer"):
                    continue
                active = {"base_layer", overlay} | ({"win_layer"} if windows else set())
                resolved = next(sensor_bindings[name].strip() for name in reversed(self.order)
                                if name in active and name in sensor_bindings)
                self.assertEqual(resolved, "&enc_zoom_win" if windows else "&enc_zoom_mac")
        for os_name, modifier in (("mac", "LG"), ("win", "LC")):
            self.assertRegex(self.source, rf"enc_zoom_{os_name}:[^{{]+\{{[^}}]+"
                             rf"bindings = <&kp {modifier}\(EQUAL\)>, <&kp {modifier}\(MINUS\)>;")

    def test_layouts_match_and_missing_placeholder_is_detected(self):
        metadata = json.loads(LAYOUT.read_text())
        self.assertEqual(validate_layout(metadata, SHIELD.read_text()), [])
        self.assertTrue(metadata["sensors"][0]["enabled"])
        keys = next(iter(metadata["layouts"].values()))["layout"]
        self.assertIn("no switch", keys[15]["label"])
        del keys[15]
        self.assertTrue(validate_layout(metadata, SHIELD.read_text()))

    def test_structural_checker_catches_custom_hold_tap_argument_loss(self):
        bad = self.text.replace("&lt_sym 5 LANG1", "&lt_sym 5", 1)
        self.assertNotEqual(bad, self.text)
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertTrue(any("引数不足" in p for p in validate(bad)))


if __name__ == "__main__":
    unittest.main()
