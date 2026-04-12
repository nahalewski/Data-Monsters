#include <stdint.h>
#pragma once

#include "esp_err.h"

typedef struct {
    const char *backend_base_url;
    const char *ws_path;
    const char *http_state_path;
} core_protocol_config_t;

esp_err_t core_protocol_client_init(const core_protocol_config_t *cfg);
void core_protocol_client_pump(void);
esp_err_t core_protocol_send_touch(int16_t x, int16_t y, const char *gesture);
esp_err_t core_protocol_send_intent(const char *intent, const char *payload_json);
