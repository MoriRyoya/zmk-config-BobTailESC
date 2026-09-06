#!/usr/bin/env python3
"""Verify the battery curve natively and GNU --wrap interception where supported."""

import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "pmw3610/src/battery_percentage.c"
CC = shlex.split(os.environ.get("CC", "cc"))


class BatteryPercentageTests(unittest.TestCase):
    def compile_and_run(self, files, flags=()):
        with tempfile.TemporaryDirectory(prefix="bobtail-battery-") as temporary:
            directory = Path(temporary)
            paths = []
            for name, content in files.items():
                path = directory / name
                path.write_text(content)
                paths.append(str(path))
            binary = directory / "test"
            command = CC + ["-std=c11", "-Wall", "-Wextra", "-Werror", "-O2"]
            subprocess.run(command + [str(SOURCE)] + paths + list(flags) +
                           ["-o", str(binary)], check=True, capture_output=True, text=True)
            subprocess.run([str(binary)], check=True, capture_output=True, text=True)

    def test_lipo_range_and_monotonicity(self):
        self.compile_and_run({"curve.c": r'''
#include <assert.h>
#include <stdint.h>
extern uint8_t __wrap_lithium_ion_mv_to_pct(int16_t);
int main(void) {
    assert(__wrap_lithium_ion_mv_to_pct(1950) == 0);
    assert(__wrap_lithium_ion_mv_to_pct(2350) == 0);
    assert(__wrap_lithium_ion_mv_to_pct(3450) == 0);
    assert(__wrap_lithium_ion_mv_to_pct(3600) == 21);
    assert(__wrap_lithium_ion_mv_to_pct(3700) == 34);
    assert(__wrap_lithium_ion_mv_to_pct(3900) == 61);
    assert(__wrap_lithium_ion_mv_to_pct(4200) == 100);
    int previous = 0;
    for (int mv = INT16_MIN; mv <= INT16_MAX; ++mv) {
        int current = __wrap_lithium_ion_mv_to_pct((int16_t)mv);
        assert(current >= previous && current <= 100);
        previous = current;
    }
    /* Every invocation is independent: reconnect/sample history cannot bias it. */
    assert(__wrap_lithium_ion_mv_to_pct(3700) == 34);
    return 0;
}
'''})

    @unittest.skipIf(sys.platform == "darwin", "Apple ld has no GNU --wrap; run this case on Linux")
    def test_gnu_linker_intercepts_driver_call(self):
        # The real driver and battery_common.c are separate translation units too.
        # Keeping the original present proves interception, not just symbol absence.
        self.compile_and_run({
            "driver.c": r'''
#include <assert.h>
#include <stdint.h>
extern uint8_t lithium_ion_mv_to_pct(int16_t);
extern uint8_t __real_lithium_ion_mv_to_pct(int16_t);
int main(void) {
    assert(__real_lithium_ion_mv_to_pct(3700) == 100);
    assert(lithium_ion_mv_to_pct(3700) == 34);
    assert(lithium_ion_mv_to_pct(4200) == 100);
    return 0;
}
''',
            "fork.c": r'''
#include <stdint.h>
uint8_t lithium_ion_mv_to_pct(int16_t mv) { return mv >= 2350 ? 100 : 0; }
''',
        }, flags=["-Wl,--wrap=lithium_ion_mv_to_pct"])


if __name__ == "__main__":
    unittest.main()
