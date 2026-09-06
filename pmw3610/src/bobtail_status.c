/* BobTail Bar layer telemetry. Consumer 0x01D6 is reserved and has no OS shortcut. */
#include <zephyr/kernel.h>
#include <zmk/event_manager.h>
#include <zmk/events/layer_state_changed.h>
#include <zmk/events/endpoint_changed.h>
#include <zmk/keymap.h>
#include <zmk/hid.h>
#include <zmk/endpoints.h>
#include <dt-bindings/zmk/hid_usage_pages.h>

#define BOBTAIL_MOUSE_LAYER 1
#define BOBTAIL_AML_USAGE 0x01D6

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
