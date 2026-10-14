cmake_minimum_required(VERSION 3.22)
project(terra_core VERSION 0.1.0 LANGUAGES C CXX)

option(TERRA_BUILD_TESTS "Build native unit and replay tests" OFF)
set(TERRA_THIRD_PARTY_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../third_party"
    CACHE PATH "Directory populated by tooling/fetch_third_party.sh")

if(MSVC)
  message(FATAL_ERROR
    "nrsc5 uses C99 complex types, which MSVC does not support. "
    "Build with MinGW-w64 (gcc or clang); see the README.")
endif()

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_EXTENSIONS ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_C_VISIBILITY_PRESET hidden)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)

include(cmake/third_party.cmake)

# ---------------------------------------------------------------------------
# terra_core
# ---------------------------------------------------------------------------
add_library(terra_core_static STATIC
  src/events.cpp
  src/dsp/fir.cpp
  src/dsp/resampler.cpp
  src/dsp/rds.cpp
  src/dsp/fm_receiver.cpp
  src/dsp/signal_meter.cpp
  src/hd/hd_decoder.cpp
  src/audio/mixer.cpp
  src/audio/audio_output.cpp
  src/gain/gain_controller.cpp
  src/sources/rtlsdr_source.cpp
  src/sources/rtltcp_source.cpp
  src/sources/file_source.cpp
  src/pipeline.cpp
  src/engine.cpp)
target_include_directories(terra_core_static PUBLIC include src)
target_link_libraries(terra_core_static PUBLIC
  terra_nrsc5 terra_rtlsdr terra_miniaudio terra_fft Threads::Threads)
target_compile_definitions(terra_core_static PUBLIC TERRA_VERSION="${PROJECT_VERSION}")
target_compile_options(terra_core_static PRIVATE
  -Wall -Wextra -Wno-unused-parameter
  $<$<CONFIG:Release,RelWithDebInfo>:-O3>
  -fno-math-errno)
if(WIN32)
  target_link_libraries(terra_core_static PUBLIC ws2_32)
endif()

add_library(terra_core SHARED src/api.cpp)
target_link_libraries(terra_core PRIVATE terra_core_static)
target_include_directories(terra_core PUBLIC include)
# Export only the terra_* C API (third-party headers mark their own symbols
# visible).
set(TERRA_VERSION_SCRIPT "${CMAKE_CURRENT_SOURCE_DIR}/terra_core.map")
if(ANDROID)
  target_link_options(terra_core PRIVATE
    -Wl,-z,max-page-size=16384 -Wl,--gc-sections
    "-Wl,--version-script=${TERRA_VERSION_SCRIPT}")
elseif(APPLE)
  target_link_options(terra_core PRIVATE -Wl,-dead_strip "-Wl,-exported_symbol,_terra_*")
  set_target_properties(terra_core PROPERTIES INSTALL_NAME_DIR "@rpath")
elseif(WIN32)
  set_target_properties(terra_core PROPERTIES PREFIX "")
  target_link_options(terra_core PRIVATE
    -static -static-libgcc -static-libstdc++ -Wl,--gc-sections -Wl,--exclude-all-symbols)
else()
  target_link_options(terra_core PRIVATE
    -Wl,--gc-sections "-Wl,--version-script=${TERRA_VERSION_SCRIPT}")
endif()
set_property(TARGET terra_core APPEND PROPERTY LINK_DEPENDS "${TERRA_VERSION_SCRIPT}")

install(TARGETS terra_core
  LIBRARY DESTINATION lib
  RUNTIME DESTINATION lib
  ARCHIVE DESTINATION lib)

if(TERRA_BUILD_TESTS)
  enable_testing()
  add_subdirectory(tests)
endif()
