/*
 * Copyright (c) 2021 The ZMK Contributors
 * SPDX-License-Identifier: MIT
 */

#include <stdint.h>

/*
 * The XIAO ADC driver has already undone the resistor divider before calling
 * lithium_ion_mv_to_pct(). The keyboard's ZMK fork instead applies a 1.95-2.35 V
 * curve to that full battery voltage. Use ZMK's standard LiPo approximation.
 *
 * GNU ld --wrap redirects the driver's external reference to this function;
 * battery_channel_get() and the rest of the upstream driver remain untouched.
 * See docs/battery.md for the source audit and validation commands.
 */
uint8_t __wrap_lithium_ion_mv_to_pct(int16_t battery_mv) {
    if (battery_mv >= 4200) {
        return 100;
    }
    if (battery_mv <= 3450) {
        return 0;
    }
    return (uint8_t)(battery_mv * 2 / 15 - 459);
}
