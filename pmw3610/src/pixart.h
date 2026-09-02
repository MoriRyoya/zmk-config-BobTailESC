#pragma once

/**
 * @file pixart.h
 *
 * @brief Common header file for all optical motion sensor by PIXART
 */

#include <zephyr/device.h>
#include <zephyr/drivers/spi.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/sensor.h>

#ifdef __cplusplus
extern "C" {
#endif

enum pixart_input_mode { MOVE = 0, SCROLL, SNIPE, BALL_ACTION };

/* device data structure */
struct pixart_data {
    const struct device *dev;

    enum pixart_input_mode curr_mode;
    uint32_t curr_cpi;
    int32_t scroll_delta_x;
    int32_t scroll_delta_y;
    int8_t scroll_axis_lock;
#ifdef CONFIG_PMW3610_SCROLL_MOMENTUM
    /* Coast state. Deliberately separate from scroll_delta_* / scroll_axis_lock
     * so that releasing the scroll layer, which resets those, leaves a flick
     * already in flight alone. */
    int64_t scroll_last_tick_time;    /* uptime ms of the last emitted tick */
    int32_t scroll_tick_interval_ms;  /* smoothed gap between emitted ticks */
    uint16_t scroll_burst_ticks;      /* ticks in the current hand-driven flick */
    uint16_t scroll_momentum_code;    /* INPUT_REL_WHEEL or INPUT_REL_HWHEEL */
    int8_t scroll_momentum_value;     /* the exact value that was emitted */
    int32_t scroll_momentum_interval_ms;
    uint16_t scroll_momentum_ticks;   /* emitted so far during the coast */
    bool scroll_momentum_active;
#endif
    int32_t ball_action_delta_x;
    int32_t ball_action_delta_y;
    int ball_action_pending_idx;

#ifdef CONFIG_PMW3610_POLLING_RATE_125_SW
    int64_t last_poll_time;
    int16_t last_x;
    int16_t last_y;
#endif

    // motion interrupt isr
    struct gpio_callback irq_gpio_cb;
    // the work structure holding the trigger job
    struct k_work trigger_work;

    // the work structure for delayable init steps
    struct k_work_delayable init_work;
    int async_init_step;

    //
    bool ready;           // whether init is finished successfully
    bool last_read_burst; // todo: needed?
    int err;              // error code during async init

    // for pmw3610 smart algorithm
    bool sw_smart_flag;
};

// ball action config data structure
struct ball_action_cfg {
    size_t bindings_len;
    struct zmk_behavior_binding *bindings;
    uint8_t layers[ZMK_KEYMAP_LAYERS_LEN];
    size_t layers_len;
    uint32_t tick;
    uint32_t wait_ms;
    uint32_t tap_ms;
};

// device config data structure
struct pixart_config {
    struct gpio_dt_spec irq_gpio;
    struct spi_dt_spec bus;
    struct gpio_dt_spec cs_gpio;
    size_t scroll_layers_len;
    int32_t *scroll_layers;
    size_t snipe_layers_len;
    int32_t *snipe_layers;
    struct ball_action_cfg **ball_actions;
    size_t ball_actions_len;
};

#ifdef __cplusplus
}
#endif

/**
 * @}
 */
