#include "core_ui_runtime.h"

#include <stdio.h>

#include "core_event_bus.h"
#include "core_protocol_client.h"
#include "core_storage_manager.h"
#include "esp_log.h"
#include "lvgl.h"

static const char *TAG = "core_ui";
static lv_obj_t *g_root;
static lv_obj_t *g_status;
static lv_obj_t *g_face;

static void on_tile_clicked(lv_event_t *e) {
    const char *intent = (const char *)lv_event_get_user_data(e);
    core_protocol_send_intent(intent, "{}");
}

static void on_state_event(void *handler_arg, esp_event_base_t base, int32_t id, void *event_data) {
    (void)handler_arg;
    (void)base;

    if (id != CORE_EVENT_APP_STATE || event_data == NULL) {
        return;
    }

    const core_app_state_event_t *e = (const core_app_state_event_t *)event_data;
    lv_label_set_text_fmt(g_status, "%s • %s", e->screen, e->status_text);
    lv_label_set_text_fmt(g_face, "Core: %s", e->face_state);
}

static lv_obj_t *make_app_tile(lv_obj_t *parent, const char *name, const char *intent, lv_coord_t x, lv_coord_t y) {
    lv_obj_t *btn = lv_btn_create(parent);
    lv_obj_set_size(btn, 120, 120);
    lv_obj_set_style_radius(btn, 28, 0);
    lv_obj_set_pos(btn, x, y);

    lv_obj_t *label = lv_label_create(btn);
    lv_label_set_text(label, name);
    lv_obj_center(label);

    lv_obj_add_event_cb(btn, on_tile_clicked, LV_EVENT_CLICKED, (void *)intent);

    return btn;
}

static void draw_sd_warning_if_needed(lv_obj_t *root) {
    const core_storage_health_t *health = core_storage_health();
    if (health->sd_present) {
        return;
    }

    lv_obj_t *warn = lv_obj_create(root);
    lv_obj_set_size(warn, 360, 80);
    lv_obj_align(warn, LV_ALIGN_BOTTOM_MID, 0, -18);

    lv_obj_t *text = lv_label_create(warn);
    lv_label_set_text(text, "SD unavailable: running minimal assets.");
    lv_obj_center(text);
}

esp_err_t core_ui_runtime_init(const core_ui_config_t *cfg) {
    ESP_LOGI(TAG, "UI init for %ux%u", cfg->width, cfg->height);

    lv_init();

    g_root = lv_obj_create(lv_scr_act());
    lv_obj_set_size(g_root, cfg->width, cfg->height);
    lv_obj_set_style_radius(g_root, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_color(g_root, lv_color_hex(0x050505), 0);
    lv_obj_center(g_root);

    g_face = lv_label_create(g_root);
    lv_label_set_text(g_face, "Core: happy");
    lv_obj_align(g_face, LV_ALIGN_TOP_MID, 0, 24);

    g_status = lv_label_create(g_root);
    lv_label_set_text(g_status, "home • Ready");
    lv_obj_align(g_status, LV_ALIGN_TOP_MID, 0, 50);

    make_app_tile(g_root, "Core", "open_core", 75, 110);
    make_app_tile(g_root, "Learning", "open_learning", 271, 110);
    make_app_tile(g_root, "Music", "open_music", 75, 250);
    make_app_tile(g_root, "Settings", "open_settings", 271, 250);

    draw_sd_warning_if_needed(g_root);

    core_event_bus_subscribe(CORE_EVENT_APP_STATE, on_state_event, NULL);
    return ESP_OK;
}

void core_ui_runtime_tick(void) {
    lv_timer_handler();
}
