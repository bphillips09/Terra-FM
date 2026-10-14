/* libusb configuration for Linux desktop builds (glibc or musl). */
#define DEFAULT_VISIBILITY __attribute__((visibility("default")))
#define ENABLE_LOGGING 1
#define HAVE_ASM_TYPES_H 1
#define HAVE_CLOCK_GETTIME 1
#define HAVE_EVENTFD 1
#define HAVE_NFDS_T 1
#define HAVE_PIPE2 1
#define HAVE_PTHREAD_SETNAME_NP 1
#define HAVE_SYS_TIME_H 1
#define HAVE_TIMERFD 1
#define PLATFORM_POSIX 1
#define PRINTF_FORMAT(a, b) __attribute__((__format__(__printf__, a, b)))
#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif
