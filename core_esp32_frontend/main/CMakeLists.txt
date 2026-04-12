idf_component_register(
    SRCS "main.c"
    INCLUDE_DIRS "."
    REQUIRES core_ui core_protocol core_storage core_platform nvs_flash
)
