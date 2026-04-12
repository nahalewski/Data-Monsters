#include "core_event_bus.h"
#include "freertos/FreeRTOS.h"

ESP_EVENT_DEFINE_BASE(CORE_EVENT_BASE);

esp_err_t core_event_bus_init(void) {
    esp_err_t err = esp_event_loop_create_default();
    if (err == ESP_ERR_INVALID_STATE) {
        return ESP_OK;
    }
    return err;
}

esp_err_t core_event_bus_emit(core_event_id_t id, const void *data, size_t size) {
    return esp_event_post(CORE_EVENT_BASE, id, data, size, portMAX_DELAY);
}

esp_err_t core_event_bus_subscribe(core_event_id_t id, esp_event_handler_t handler, void *handler_arg) {
    return esp_event_handler_register(CORE_EVENT_BASE, id, handler, handler_arg);
}
