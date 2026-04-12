#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

typedef struct {
    uint16_t width;
    uint16_t height;
    bool double_buffer;
} core_ui_config_t;

esp_err_t core_ui_runtime_init(const core_ui_config_t *cfg);
void core_ui_runtime_tick(void);
