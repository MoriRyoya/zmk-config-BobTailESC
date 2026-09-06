/* BobTail Bar layer telemetry. Consumer 0x01D6 is reserved and has no OS shortcut. */
#include <zephyr/kernel.h>
#include <zephyr/sys/atomic.h>
#include "bobtail_status.h"
#include <zmk/event_manager.h>
#include <zmk/events/layer_state_changed.h>
#include <zmk/events/endpoint_changed.h>
#include <zmk/keymap.h>
#include <zmk/hid.h>
#include <zmk/endpoints.h>
#include <dt-bindings/zmk/hid_usage_pages.h>

#define BOBTAIL_MOUSE_LAYER 1
#define BOBTAIL_AML_USAGE 0x01D6
#define BOBTAIL_MOTION_USAGE 0x01D7
#define BOBTAIL_MOTION_IDLE_MS 40

/* Reserved consumer usage: no keyboard shortcut and no cursor displacement.
 * Send an onset once per physical roll, including motion below one wheel tick.
 * All HID mutations run on the system work queue, like AML telemetry. */
static atomic_t last_motion_ms;
static bool motion_held;

static void publish_motion(struct k_work *work) {
    ARG_UNUSED(work);
    if (!motion_held) {
        zmk_hid_consumer_press(BOBTAIL_MOTION_USAGE);
        zmk_endpoints_send_report(HID_USAGE_CONSUMER);
        motion_held = true;
    }
}
static K_WORK_DEFINE(motion_report_work, publish_motion);

static void release_motion(struct k_work *work);
static K_WORK_DELAYABLE_DEFINE(motion_release_work, release_motion);

static void release_motion(struct k_work *work) {
    ARG_UNUSED(work);
    uint32_t elapsed = k_uptime_get_32() - (uint32_t)atomic_get(&last_motion_ms);
    if (elapsed < BOBTAIL_MOTION_IDLE_MS) {
        k_work_reschedule(&motion_release_work, K_MSEC(BOBTAIL_MOTION_IDLE_MS - elapsed));
        return;
    }
    if (motion_held) {
        zmk_hid_consumer_release(BOBTAIL_MOTION_USAGE);
        zmk_endpoints_send_report(HID_USAGE_CONSUMER);
        motion_held = false;
    }
}

void bobtail_scroll_motion(void) {
    atomic_set(&last_motion_ms, (atomic_val_t)k_uptime_get_32());
    k_work_submit(&motion_report_work);
    k_work_reschedule(&motion_release_work, K_MSEC(BOBTAIL_MOTION_IDLE_MS));
}

static void publish_aml(struct k_work *work) {
    ARG_UNUSED(work);
    if (zmk_keymap_layer_active(BOBTAIL_MOUSE_LAYER)) {
        zmk_hid_consumer_press(BOBTAIL_AML_USAGE);
    } else {
        zmk_hid_consumer_release(BOBTAIL_AML_USAGE);
    }
    zmk_endpoints_send_report(HID_USAGE_CONSUMER);
}

static K_WORK_DEFINE(aml_report_work, publish_aml);

static int bobtail_status_listener(const zmk_event_t *event) {
    const struct zmk_layer_state_changed *layer = as_zmk_layer_state_changed(event);
    if ((layer && layer->layer == BOBTAIL_MOUSE_LAYER) || as_zmk_endpoint_changed(event)) {
        k_work_submit(&aml_report_work);
    }
    return ZMK_EV_EVENT_BUBBLE;
}

ZMK_LISTENER(bobtail_status, bobtail_status_listener);
ZMK_SUBSCRIPTION(bobtail_status, zmk_layer_state_changed);
ZMK_SUBSCRIPTION(bobtail_status, zmk_endpoint_changed);
