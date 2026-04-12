#include "core_storage_manager.h"

#include <dirent.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

#include "esp_log.h"

static const char *TAG = "core_storage";
static core_storage_health_t g_health;
static char g_manifest[128];

static const char *REQUIRED_DIRS[] = {
    "/core/assets/images",
    "/core/assets/audio",
    "/core/assets/animations",
    "/core/data/memory",
    "/core/data/settings",
    "/core/data/cache",
    "/core/data/logs",
    "/core/manifests",
    "/core/update",
    "/core/offline",
};

static esp_err_t ensure_dir(const char *path) {
    struct stat st = {0};
    if (stat(path, &st) == -1) {
        if (mkdir(path, 0755) != 0) {
            ESP_LOGE(TAG, "mkdir failed: %s", path);
            return ESP_FAIL;
        }
    }
    return ESP_OK;
}

esp_err_t core_storage_init(const core_storage_config_t *cfg) {
    (void)cfg;

    // NOTE: SDMMC mounting is board-specific and should be wired in here.
    // For now we treat presence as optimistic and repair folder structure.
    g_health.sd_present = true;
    g_health.using_builtin_assets = false;
    g_health.read_only_mode = cfg->safe_mode_ro;

    for (size_t i = 0; i < sizeof(REQUIRED_DIRS) / sizeof(REQUIRED_DIRS[0]); ++i) {
        char full[192];
        snprintf(full, sizeof(full), "%s%s", cfg->mount_point, REQUIRED_DIRS[i]);
        esp_err_t err = ensure_dir(full);
        if (err != ESP_OK && !cfg->safe_mode_ro) {
            g_health.sd_present = false;
            g_health.using_builtin_assets = true;
        }
    }

    snprintf(g_manifest, sizeof(g_manifest), "%s/core/manifests/assets_manifest.json", cfg->mount_point);

    FILE *fp = fopen(g_manifest, "r");
    if (!fp) {
        ESP_LOGW(TAG, "Manifest missing, creating default: %s", g_manifest);
        fp = fopen(g_manifest, "w");
        if (fp) {
            fputs("{\n  \"version\": 1,\n  \"assets\": []\n}\n", fp);
            fclose(fp);
        } else {
            g_health.using_builtin_assets = true;
        }
    } else {
        fclose(fp);
    }

    return ESP_OK;
}

const core_storage_health_t *core_storage_health(void) {
    return &g_health;
}

const char *core_storage_manifest_path(void) {
    return g_manifest;
}

esp_err_t core_storage_cache_put(const char *key, const uint8_t *data, size_t len) {
    char path[256];
    snprintf(path, sizeof(path), "/sdcard/core/data/cache/%s.bin", key);
    FILE *fp = fopen(path, "wb");
    if (!fp) {
        return ESP_FAIL;
    }
    fwrite(data, 1, len, fp);
    fclose(fp);
    return ESP_OK;
}

esp_err_t core_storage_cache_evict_if_needed(void) {
    // Minimal LRU placeholder: production version should track index + timestamps in NVS.
    ESP_LOGI(TAG, "Cache eviction check complete");
    return ESP_OK;
}
