#include "core_protocol_client.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cJSON.h"
#include "core_event_bus.h"
#include "core_storage_manager.h"
#include "esp_http_client.h"
#include "esp_log.h"

static const char *TAG = "core_protocol";
static core_protocol_config_t g_cfg;

esp_err_t core_protocol_client_init(const core_protocol_config_t *cfg) {
    g_cfg = *cfg;
    ESP_LOGI(TAG, "Protocol init: %s", g_cfg.backend_base_url);
    return ESP_OK;
}

static esp_err_t poll_state_snapshot(void) {
    char url[256];
    snprintf(url, sizeof(url), "%s%s", g_cfg.backend_base_url, g_cfg.http_state_path);

    esp_http_client_config_t http_cfg = {
        .url = url,
        .timeout_ms = 3000,
    };

    esp_http_client_handle_t client = esp_http_client_init(&http_cfg);
    if (esp_http_client_perform(client) != ESP_OK) {
        esp_http_client_cleanup(client);
        return ESP_FAIL;
    }

    int content_len = esp_http_client_get_content_length(client);
    if (content_len <= 0 || content_len > 4096) {
        esp_http_client_cleanup(client);
        return ESP_FAIL;
    }

    char *buf = calloc(1, (size_t)content_len + 1);
    int read = esp_http_client_read_response(client, buf, content_len);
    esp_http_client_cleanup(client);
    if (read <= 0) {
        free(buf);
        return ESP_FAIL;
    }

    cJSON *root = cJSON_Parse(buf);
    free(buf);
    if (!root) {
        return ESP_FAIL;
    }

    cJSON *screen = cJSON_GetObjectItem(root, "screen");
    cJSON *status = cJSON_GetObjectItem(root, "status_text");
    cJSON *face = cJSON_GetObjectItem(root, "face_state");

    core_app_state_event_t event = {
        .screen = cJSON_IsString(screen) ? screen->valuestring : "home",
        .status_text = cJSON_IsString(status) ? status->valuestring : "Ready",
        .face_state = cJSON_IsString(face) ? face->valuestring : "happy",
    };
    core_event_bus_emit(CORE_EVENT_APP_STATE, &event, sizeof(event));

    cJSON_Delete(root);
    return ESP_OK;
}

void core_protocol_client_pump(void) {
    static uint32_t last_ms = 0;
    uint32_t now = esp_log_timestamp();
    if (now - last_ms < 300) {
        return;
    }
    last_ms = now;
    if (poll_state_snapshot() != ESP_OK) {
        ESP_LOGW(TAG, "State poll failed");
    }
}

esp_err_t core_protocol_send_touch(int16_t x, int16_t y, const char *gesture) {
    ESP_LOGI(TAG, "Touch (%d,%d) gesture=%s", x, y, gesture ? gesture : "tap");
    return ESP_OK;
}

esp_err_t core_protocol_send_intent(const char *intent, const char *payload_json) {
    ESP_LOGI(TAG, "Intent=%s payload=%s", intent, payload_json ? payload_json : "{}");
    return ESP_OK;
}
