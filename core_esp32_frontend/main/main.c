#include "esp_err.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "nvs_flash.h"

#include "core_event_bus.h"
#include "core_protocol_client.h"
#include "core_storage_manager.h"
#include "core_ui_runtime.h"

static const char *TAG = "core_main";

static void init_nvs(void) {
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ESP_ERROR_CHECK(nvs_flash_init());
    }
}

void app_main(void) {
    ESP_LOGI(TAG, "Core ESP32 frontend booting");

    init_nvs();
    ESP_ERROR_CHECK(core_event_bus_init());

    core_storage_config_t storage_cfg = {
        .mount_point = "/sdcard",
        .safe_mode_ro = false,
    };
    ESP_ERROR_CHECK(core_storage_init(&storage_cfg));

    core_protocol_config_t proto_cfg = {
        .backend_base_url = "http://core.local:8080",
        .ws_path = "/esp32/ws",
        .http_state_path = "/esp32/state",
    };
    ESP_ERROR_CHECK(core_protocol_client_init(&proto_cfg));

    core_ui_config_t ui_cfg = {
        .width = 466,
        .height = 466,
        .double_buffer = true,
    };
    ESP_ERROR_CHECK(core_ui_runtime_init(&ui_cfg));

    ESP_LOGI(TAG, "Runtime initialized");

    while (true) {
        core_protocol_client_pump();
        core_ui_runtime_tick();
        vTaskDelay(pdMS_TO_TICKS(10));
    }
}
