zephyr_library()

zephyr_library_sources_ifdef(CONFIG_PMW3610 src/pmw3610.c)
zephyr_include_directories(${APPLICATION_SOURCE_DIR}/include)

# Both halves use the XIAO ADC's state-of-charge channel. Correct the fork's
# voltage curve without editing downloaded ZMK sources or its other drivers.
if(CONFIG_ZMK_BATTERY_REPORTING AND CONFIG_ZMK_BATTERY_REPORTING_FETCH_MODE_STATE_OF_CHARGE)
  zephyr_library_sources(src/battery_percentage.c)
  zephyr_link_libraries(-Wl,--wrap=lithium_ion_mv_to_pct)
endif()

zephyr_library_sources_ifdef(CONFIG_PMW3610 src/bobtail_status.c)
