#pragma once

#include "esp_err.h"
#include "esp_event.h"

typedef enum {
    CORE_EVENT_APP_STATE = 1,
    CORE_EVENT_TOUCH,
    CORE_EVENT_STORAGE_HEALTH,
    CORE_EVENT_PROTOCOL_STATUS,
} core_event_id_t;

typedef struct {
    const char *screen;
    const char *status_text;
    const char *face_state;
} core_app_state_event_t;

ESP_EVENT_DECLARE_BASE(CORE_EVENT_BASE);

esp_err_t core_event_bus_init(void);
esp_err_t core_event_bus_emit(core_event_id_t id, const void *data, size_t size);
esp_err_t core_event_bus_subscribe(core_event_id_t id, esp_event_handler_t handler, void *handler_arg);
