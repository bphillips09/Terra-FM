# Compiles the pinned third-party sources (see tooling/fetch_third_party.sh)
# as static libraries with hidden visibility, so libterra_core only exports
# the terra_* C API.

set(TP "${TERRA_THIRD_PARTY_DIR}")
foreach(dep nrsc5 faad2 libusb rtl-sdr miniaudio)
  if(NOT EXISTS "${TP}/${dep}/.terra-stamp")
    message(FATAL_ERROR
      "third_party/${dep} is missing. Run tooling/fetch_third_party.sh first.")
  endif()
endforeach()

include(CheckSymbolExists)
find_package(Threads REQUIRED)

set(TERRA_ARCH_ARM OFF)
set(TERRA_ARCH_X86 OFF)
if(CMAKE_OSX_ARCHITECTURES)
  set(_terra_arch "${CMAKE_OSX_ARCHITECTURES}")
elseif(ANDROID_ABI)
  set(_terra_arch "${ANDROID_ABI}")
else()
  set(_terra_arch "${CMAKE_SYSTEM_PROCESSOR}")
endif()
if(_terra_arch MATCHES "^(arm64|aarch64|ARM64|arm64-v8a|armeabi-v7a|armv7.*)$")
  set(TERRA_ARCH_ARM ON)
elseif(_terra_arch MATCHES "^(x86_64|AMD64|amd64|x86|i[3-6]86)$")
  set(TERRA_ARCH_X86 ON)
endif()

# ---------------------------------------------------------------------------
# FAAD2 2.11.2 with nrsc5's HDC patch (the HE-AAC variant used for HD).
# ---------------------------------------------------------------------------
file(GLOB TERRA_FAAD2_SOURCES "${TP}/faad2/libfaad/*.c")
add_library(terra_faad2 STATIC ${TERRA_FAAD2_SOURCES})
target_include_directories(terra_faad2
  PUBLIC "${TP}/faad2/include"
  PRIVATE "${TP}/faad2/libfaad")
target_compile_definitions(terra_faad2 PRIVATE
  HAVE_INTTYPES_H=1 HAVE_MEMCPY=1 HAVE_STRING_H=1 HAVE_STRINGS_H=1
  HAVE_SYS_STAT_H=1 HAVE_SYS_TYPES_H=1 HAVE_LRINTF=1
  PACKAGE_VERSION="2.11.2" APPLY_DRC HDC_SUPPORT)
if(NOT MSVC)
  target_compile_options(terra_faad2 PRIVATE -O2 -w)
endif()

# ---------------------------------------------------------------------------
# libusb 1.0.30
# ---------------------------------------------------------------------------
set(LIBUSB_SRC "${TP}/libusb/libusb")
set(TERRA_LIBUSB_SOURCES
  "${LIBUSB_SRC}/core.c" "${LIBUSB_SRC}/descriptor.c" "${LIBUSB_SRC}/hotplug.c"
  "${LIBUSB_SRC}/io.c" "${LIBUSB_SRC}/strerror.c" "${LIBUSB_SRC}/sync.c")
if(ANDROID)
  list(APPEND TERRA_LIBUSB_SOURCES
    "${LIBUSB_SRC}/os/linux_usbfs.c" "${LIBUSB_SRC}/os/linux_netlink.c"
    "${LIBUSB_SRC}/os/events_posix.c" "${LIBUSB_SRC}/os/threads_posix.c")
  set(TERRA_LIBUSB_CONFIG_DIR "${TP}/libusb/android")
elseif(APPLE)
  list(APPEND TERRA_LIBUSB_SOURCES
    "${LIBUSB_SRC}/os/darwin_usb.c"
    "${LIBUSB_SRC}/os/events_posix.c" "${LIBUSB_SRC}/os/threads_posix.c")
  set(TERRA_LIBUSB_CONFIG_DIR "${TP}/libusb/Xcode")
elseif(WIN32)
  list(APPEND TERRA_LIBUSB_SOURCES
    "${LIBUSB_SRC}/os/windows_common.c" "${LIBUSB_SRC}/os/windows_usbdk.c"
    "${LIBUSB_SRC}/os/windows_winusb.c" "${LIBUSB_SRC}/os/windows_hotplug.c"
    "${LIBUSB_SRC}/os/events_windows.c" "${LIBUSB_SRC}/os/threads_windows.c")
  set(TERRA_LIBUSB_CONFIG_DIR "${CMAKE_CURRENT_LIST_DIR}/../compat/libusb/windows")
else()
  list(APPEND TERRA_LIBUSB_SOURCES
    "${LIBUSB_SRC}/os/linux_usbfs.c" "${LIBUSB_SRC}/os/linux_netlink.c"
    "${LIBUSB_SRC}/os/events_posix.c" "${LIBUSB_SRC}/os/threads_posix.c")
  set(TERRA_LIBUSB_CONFIG_DIR "${CMAKE_CURRENT_LIST_DIR}/../compat/libusb/linux")
endif()
add_library(terra_libusb STATIC ${TERRA_LIBUSB_SOURCES})
target_include_directories(terra_libusb
  PUBLIC "${LIBUSB_SRC}"
  PRIVATE "${TERRA_LIBUSB_CONFIG_DIR}" "${LIBUSB_SRC}/os")
target_link_libraries(terra_libusb PUBLIC Threads::Threads)
if(NOT MSVC)
  target_compile_options(terra_libusb PRIVATE -w)
endif()
if(ANDROID)
  target_link_libraries(terra_libusb PUBLIC log)
elseif(APPLE)
  target_link_libraries(terra_libusb PUBLIC
    "-framework IOKit" "-framework CoreFoundation" "-framework Security")
endif()

# ---------------------------------------------------------------------------
# librtlsdr (AlexandreRouma fork: rtlsdr_open_sys_dev + Blog V4 support)
# ---------------------------------------------------------------------------
set(RTLSDR_SRC "${TP}/rtl-sdr/src")
add_library(terra_rtlsdr STATIC
  "${RTLSDR_SRC}/librtlsdr.c" "${RTLSDR_SRC}/tuner_e4k.c"
  "${RTLSDR_SRC}/tuner_fc0012.c" "${RTLSDR_SRC}/tuner_fc0013.c"
  "${RTLSDR_SRC}/tuner_fc2580.c" "${RTLSDR_SRC}/tuner_r82xx.c")
target_include_directories(terra_rtlsdr PUBLIC "${TP}/rtl-sdr/include")
target_compile_definitions(terra_rtlsdr PUBLIC rtlsdr_STATIC)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux" AND NOT ANDROID)
  # Release the DVB-T kernel driver instead of failing to claim the device.
  target_compile_definitions(terra_rtlsdr PRIVATE DETACH_KERNEL_DRIVER)
endif()
target_link_libraries(terra_rtlsdr PUBLIC terra_libusb Threads::Threads)
if(NOT MSVC)
  target_compile_options(terra_rtlsdr PRIVATE -w)
endif()

# ---------------------------------------------------------------------------
# FFTW replacement: nrsc5 only needs forward power-of-two complex DFTs.
# ---------------------------------------------------------------------------
add_library(terra_fft STATIC
  "${CMAKE_CURRENT_LIST_DIR}/../src/dsp/fft.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/../compat/fftw/fftw_shim.cpp")
target_include_directories(terra_fft
  PUBLIC "${CMAKE_CURRENT_LIST_DIR}/../compat/fftw"
         "${CMAKE_CURRENT_LIST_DIR}/../src")

# ---------------------------------------------------------------------------
# nrsc5 v3.2.0 (library only, pipe mode)
# ---------------------------------------------------------------------------
set(NRSC5_SRC "${TP}/nrsc5/src")
set(CMAKE_REQUIRED_FLAGS "-std=gnu11")
check_symbol_exists(strndup string.h HAVE_STRNDUP)
check_symbol_exists(CMPLXF complex.h HAVE_CMPLXF)
check_symbol_exists(_Imaginary_I complex.h HAVE_IMAGINARY_I)
check_symbol_exists(_Complex_I complex.h HAVE_COMPLEX_I)
unset(CMAKE_REQUIRED_FLAGS)
set(USE_FAAD2 ON)
set(LIBRARY_DEBUG_LEVEL 5)
set(TERRA_NRSC5_CONFIG_DIR "${CMAKE_CURRENT_BINARY_DIR}/nrsc5-config")
configure_file("${NRSC5_SRC}/config.h.in" "${TERRA_NRSC5_CONFIG_DIR}/config.h")

add_library(terra_nrsc5 STATIC
  "${NRSC5_SRC}/acquire.c" "${NRSC5_SRC}/decode.c" "${NRSC5_SRC}/frame.c"
  "${NRSC5_SRC}/here_images.c" "${NRSC5_SRC}/input.c" "${NRSC5_SRC}/nrsc5.c"
  "${NRSC5_SRC}/output.c" "${NRSC5_SRC}/pids.c" "${NRSC5_SRC}/rtltcp.c"
  "${NRSC5_SRC}/sync.c" "${NRSC5_SRC}/firdecim_q15.c" "${NRSC5_SRC}/conv_dec.c"
  "${NRSC5_SRC}/rs_init.c" "${NRSC5_SRC}/rs_decode.c" "${NRSC5_SRC}/unicode.c"
  "${NRSC5_SRC}/strndup.c")
target_include_directories(terra_nrsc5
  PUBLIC "${TP}/nrsc5/include"
  PRIVATE "${NRSC5_SRC}" "${TERRA_NRSC5_CONFIG_DIR}")
target_compile_definitions(terra_nrsc5 PRIVATE
  _GNU_SOURCE HAVE_FAAD2 GIT_COMMIT_HASH="v3.2.0")
target_link_libraries(terra_nrsc5 PUBLIC terra_faad2 terra_rtlsdr terra_fft Threads::Threads)
if(NOT MSVC)
  target_compile_options(terra_nrsc5 PRIVATE -O3 -w)
endif()
if(TERRA_ARCH_ARM)
  target_compile_definitions(terra_nrsc5 PRIVATE HAVE_NEON)
  if(ANDROID_ABI STREQUAL "armeabi-v7a")
    target_compile_options(terra_nrsc5 PRIVATE -mfpu=neon)
  endif()
elseif(TERRA_ARCH_X86 AND NOT MSVC)
  target_compile_definitions(terra_nrsc5 PRIVATE HAVE_SSE2 HAVE_SSE3)
  target_compile_options(terra_nrsc5 PRIVATE -msse2 -msse3 -mssse3)
endif()
if(WIN32)
  target_link_libraries(terra_nrsc5 PUBLIC ws2_32)
endif()
if(NOT WIN32)
  target_link_libraries(terra_nrsc5 PUBLIC m)
endif()

# ---------------------------------------------------------------------------
# miniaudio 0.11.25 (playback only)
# ---------------------------------------------------------------------------
add_library(terra_miniaudio STATIC "${CMAKE_CURRENT_LIST_DIR}/../src/audio/miniaudio_impl.c")
target_include_directories(terra_miniaudio PUBLIC "${TP}/miniaudio")
target_compile_definitions(terra_miniaudio PUBLIC
  MA_NO_DECODING MA_NO_ENCODING MA_NO_GENERATION MA_NO_RESOURCE_MANAGER
  MA_NO_NODE_GRAPH MA_NO_ENGINE)
if(NOT MSVC)
  target_compile_options(terra_miniaudio PRIVATE -O2 -w)
endif()
if(APPLE)
  target_link_libraries(terra_miniaudio PUBLIC
    "-framework CoreFoundation" "-framework CoreAudio" "-framework AudioToolbox")
elseif(UNIX)
  target_link_libraries(terra_miniaudio PUBLIC ${CMAKE_DL_LIBS} Threads::Threads m)
endif()
