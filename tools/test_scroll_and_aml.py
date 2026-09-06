"""Cross-file AML contract and native tests for accumulated sensor displacement."""
import re
import subprocess
import tempfile
import unittest
from pathlib import Path
from check_keymap import KEYMAP, REPO, layer_blocks, preprocess, rows_of


class ScrollAndAMLTests(unittest.TestCase):
    def test_aml_exemptions_match_mouse_bindings(self):
        layers = {name: [b for row in rows_of(body) for b in row]
                  for name, body in layer_blocks(preprocess(KEYMAP.read_text()))}
        mouse_keys = {i for i, binding in enumerate(layers['mouse_layer'])
                      if binding not in ('&none', '&trans')}
        overlay = (REPO / 'config/boards/shields/Test/BobTail_R.overlay').read_text()
        excluded = set(map(int, re.search(r'excluded-positions\s*=\s*<([^>]+)>', overlay)[1].split()))
        self.assertEqual(excluded, mouse_keys)
        self.assertEqual(excluded, {17, 18, 19, 20, 21})
        self.assertRegex(overlay, r'input-processors\s*=\s*<&zip_temp_layer 1 10000>')
        self.assertRegex(overlay, r'automouse-layer\s*=\s*<0>')
        self.assertIn('CONFIG_PMW3610_SCROLL_MOMENTUM=n',
                      (REPO / 'config/boards/shields/Test/BobTail_R.conf').read_text())

    def test_scroll_quantization_preserves_motion(self):
        source = r'''
#include <assert.h>
#include "scroll_quantize.h"
int main(void) {
    int32_t a = 94;
    assert(bobtail_scroll_take_ticks(&a, 28) == 3 && a == 10);
    a = -94;
    assert(bobtail_scroll_take_ticks(&a, 28) == -3 && a == -10);
    a = 28;
    assert(bobtail_scroll_take_ticks(&a, 28) == 1 && a == 0);
    a = 100000;
    assert(bobtail_scroll_take_ticks(&a, 28) == 127 && a == 100000 - 127 * 28);
    int32_t input = 0, output = 0;
    a = 0;
    for (int i = 0; i < 10000; i++) {
        int32_t movement = (i * 97 % 205) - 102;
        a += movement; input += movement;
        output += bobtail_scroll_take_ticks(&a, 28);
        assert(input == output * 28 + a);
    }
    return 0;
}
'''
        with tempfile.TemporaryDirectory(prefix='bobtail-scroll-test-') as work:
            work = Path(work)
            (work / 'test.c').write_text(source)
            subprocess.run(['clang', '-std=c11', '-Wall', '-Wextra', '-Werror',
                            '-I', str(REPO / 'pmw3610/src'), str(work / 'test.c'),
                            '-o', str(work / 'test')], check=True)
            subprocess.run([str(work / 'test')], check=True)


if __name__ == '__main__':
    unittest.main()
