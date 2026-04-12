idf_component_register(
    SRCS "src/core_ui_runtime.c"
    INCLUDE_DIRS "include"
    REQUIRES lvgl esp_lcd core_platform core_protocol core_storage
)
