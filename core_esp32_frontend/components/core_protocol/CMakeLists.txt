idf_component_register(
    SRCS "src/core_protocol_client.c"
    INCLUDE_DIRS "include"
    REQUIRES esp_http_client esp_websocket_client esp-tls cjson core_platform core_storage
)
