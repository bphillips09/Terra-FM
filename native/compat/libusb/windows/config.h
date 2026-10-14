/* libusb configuration for Windows builds with MinGW-w64 (GCC or Clang). */
#define DEFAULT_VISIBILITY
#define ENABLE_LOGGING 1
#define HAVE_STRUCT_TIMESPEC 1
#define PLATFORM_WINDOWS 1
#define PRINTF_FORMAT(a, b) __attribute__((__format__(__printf__, a, b)))
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0601
#endif
