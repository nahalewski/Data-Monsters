idf_component_register(
    SRCS "src/core_event_bus.c"
    INCLUDE_DIRS "include"
    REQUIRES esp_event esp_system
)
