#pragma once

#include <stdbool.h>
#include "esp_err.h"

typedef struct {
    const char *mount_point;
    bool safe_mode_ro;
} core_storage_config_t;

typedef struct {
    bool sd_present;
    bool using_builtin_assets;
    bool read_only_mode;
} core_storage_health_t;

esp_err_t core_storage_init(const core_storage_config_t *cfg);
const core_storage_health_t *core_storage_health(void);
const char *core_storage_manifest_path(void);
esp_err_t core_storage_cache_put(const char *key, const uint8_t *data, size_t len);
esp_err_t core_storage_cache_evict_if_needed(void);
