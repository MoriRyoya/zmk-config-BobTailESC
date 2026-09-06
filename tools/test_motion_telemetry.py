"""Exercise the real telemetry source with a deterministic work-queue/HID seam.

This tests its state machine, not the ARM/Zephyr link or actual BLE delivery.
"""
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]


class MotionTelemetryTests(unittest.TestCase):
    def test_onset_release_renewal_and_timer_wrap(self):
        support = r'''
#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <assert.h>
#define ARG_UNUSED(x) (void)(x)
typedef uint32_t atomic_t;
typedef uint32_t atomic_val_t;
static inline uint32_t atomic_get(atomic_t *a) { return *a; }
static inline void atomic_set(atomic_t *a, uint32_t v) { *a = v; }
static uint32_t clock_ms;
static inline uint32_t k_uptime_get_32(void) { return clock_ms; }
struct k_work { void (*fn)(struct k_work *); };
struct k_work_delayable { struct k_work work; uint32_t delay; };
#define K_WORK_DEFINE(n, f) struct k_work n = {f}
#define K_WORK_DELAYABLE_DEFINE(n, f) struct k_work_delayable n = {{f}, 0}
#define K_MSEC(n) (n)
static struct k_work *queued;
static inline void k_work_submit(struct k_work *w) { queued = w; }
static inline void k_work_reschedule(struct k_work_delayable *w, uint32_t d) { w->delay = d; }
static unsigned sent, usage_held;
static inline void zmk_hid_consumer_press(unsigned u) { usage_held = u; }
static inline void zmk_hid_consumer_release(unsigned u) { assert(usage_held == u); usage_held = 0; }
static inline void zmk_endpoints_send_report(unsigned page) { assert(page == 12); sent++; }
#define HID_USAGE_CONSUMER 12
typedef int zmk_event_t;
struct zmk_layer_state_changed { unsigned layer; };
static inline const struct zmk_layer_state_changed *as_zmk_layer_state_changed(const zmk_event_t *e) { (void)e; return NULL; }
static inline bool as_zmk_endpoint_changed(const zmk_event_t *e) { (void)e; return false; }
static inline bool zmk_keymap_layer_active(unsigned l) { (void)l; return false; }
#define ZMK_EV_EVENT_BUBBLE 0
#define ZMK_LISTENER(n, f) int (*n##_listener_ref)(const zmk_event_t *) = f
#define ZMK_SUBSCRIPTION(n, e)
'''
        source = r'''
#include "bobtail_status.c"
static void drain(void) { if (queued) { struct k_work *w = queued; queued = NULL; w->fn(w); } }
int main(void) {
    clock_ms = 100;
    bobtail_scroll_motion();
    assert(sent == 0); // sensor callback never mutates HID directly
    drain();
    assert(sent == 1 && usage_held == 0x01D7);
    clock_ms = 120; bobtail_scroll_motion(); drain();
    assert(sent == 1); // same physical roll does not repeatedly brake input
    clock_ms = 140; release_motion(NULL);
    assert(sent == 1 && motion_release_work.delay == 20); // renewed motion wins timer race
    clock_ms = 160; release_motion(NULL);
    assert(sent == 2 && usage_held == 0);
    clock_ms = 200; bobtail_scroll_motion(); drain();
    assert(sent == 3 && usage_held == 0x01D7); // next tiny movement sends a fresh onset
    clock_ms = 240; release_motion(NULL);
    clock_ms = UINT32_MAX - 10; bobtail_scroll_motion(); drain();
    clock_ms = 10; release_motion(NULL);
    assert(usage_held == 0x01D7); // uptime rollover is unsigned
    clock_ms = 40; release_motion(NULL);
    assert(usage_held == 0);
    return 0;
}
'''
        with tempfile.TemporaryDirectory(prefix='bobtail-motion-test-') as directory:
            root = Path(directory)
            (root / 'support.h').write_text(support)
            for name in ['zephyr/kernel.h', 'zephyr/sys/atomic.h',
                         'zmk/event_manager.h', 'zmk/events/layer_state_changed.h',
                         'zmk/events/endpoint_changed.h', 'zmk/keymap.h', 'zmk/hid.h',
                         'zmk/endpoints.h', 'dt-bindings/zmk/hid_usage_pages.h']:
                header = root / name
                header.parent.mkdir(parents=True, exist_ok=True)
                header.write_text('#include "support.h"\n')
            (root / 'test.c').write_text(source)
            subprocess.run(['clang', '-std=c11', '-Wall', '-Wextra', '-Werror',
                            '-I', str(root), '-I', str(REPO / 'pmw3610/src'),
                            str(root / 'test.c'), '-o', str(root / 'test')], check=True)
            subprocess.run([str(root / 'test')], check=True)


if __name__ == '__main__':
    unittest.main()
