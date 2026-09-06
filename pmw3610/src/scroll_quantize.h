#pragma once
#include <stdint.h>

/* HID wheel reports are signed 8-bit. Preserve both sub-tick precision and
 * overflow for the next report instead of discarding motion after every tick. */
static inline int32_t bobtail_scroll_take_ticks(int32_t *accumulator, int32_t tick) {
    if (tick <= 0) { return 0; }
    int32_t steps = *accumulator / tick;
    if (steps > 127) { steps = 127; }
    if (steps < -127) { steps = -127; }
    *accumulator -= steps * tick;
    return steps;
}
