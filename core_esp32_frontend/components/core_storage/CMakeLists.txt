idf_component_register(
    SRCS "src/core_storage_manager.c"
    INCLUDE_DIRS "include"
    REQUIRES fatfs sdmmc nvs_flash
)
