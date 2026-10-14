#include "sources/rtltcp_source.h"

#include <cstring>
#include <vector>

#if defined(_WIN32)
#include <winsock2.h>
#include <ws2tcpip.h>
using socket_t = SOCKET;
#define TERRA_INVALID_SOCKET INVALID_SOCKET
#define terra_close_socket closesocket
#else
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
using socket_t = int;
#define TERRA_INVALID_SOCKET (-1)
#define terra_close_socket ::close
#endif

namespace terra {

namespace {

constexpr int kConnectTimeoutMs = 4000;

// rtl_tcp tuner type codes (enum rtlsdr_tuner).
const char* tuner_name(uint32_t t) {
  switch (t) {
    case 1: return "Elonics E4000";
    case 2: return "Fitipower FC0012";
    case 3: return "Fitipower FC0013";
    case 4: return "FCI FC2580";
    case 5: return "Rafael Micro R820T/R820T2";
    case 6: return "Rafael Micro R828D";
    default: return "Unknown";
  }
}

// Gain tables from librtlsdr (rtl_tcp only reports the count).
std::vector<int> tuner_gains(uint32_t t) {
  switch (t) {
    case 1: return {-10, 15, 40, 65, 90, 115, 140, 165, 190, 215, 240, 290, 340, 420};
    case 2: return {-99, -40, 71, 179, 192};
    case 3:
      return {-99, -73, -65, -63, -60, -58, -54, 58,  61,  63,  65,  67,
              68,  70,  71,  179, 181, 182, 184, 186, 188, 191, 197};
    case 5:
    case 6:
      return {0,   9,   14,  27,  37,  77,  87,  125, 144, 157, 166, 197, 207, 229, 254,
              280, 297, 328, 338, 364, 372, 386, 402, 421, 434, 439, 445, 480, 496};
    default: return {0};
  }
}

uint32_t read_be32(const uint8_t* p) {
  return (uint32_t{p[0]} << 24) | (uint32_t{p[1]} << 16) | (uint32_t{p[2]} << 8) | p[3];
}

bool set_blocking(socket_t s, bool blocking) {
#if defined(_WIN32)
  u_long mode = blocking ? 0 : 1;
  return ioctlsocket(s, FIONBIO, &mode) == 0;
#else
  const int flags = fcntl(s, F_GETFL, 0);
  if (flags < 0) return false;
  return fcntl(s, F_SETFL, blocking ? (flags & ~O_NONBLOCK) : (flags | O_NONBLOCK)) == 0;
#endif
}

bool wait_writable(socket_t s, int timeout_ms) {
#if defined(_WIN32)
  fd_set wfds;
  FD_ZERO(&wfds);
  FD_SET(s, &wfds);
  timeval tv{timeout_ms / 1000, (timeout_ms % 1000) * 1000};
  if (select(0, nullptr, &wfds, nullptr, &tv) <= 0) return false;
#else
  pollfd pfd{s, POLLOUT, 0};
  if (poll(&pfd, 1, timeout_ms) <= 0) return false;
#endif
  int err = 0;
  socklen_t len = sizeof(err);
  getsockopt(s, SOL_SOCKET, SO_ERROR, reinterpret_cast<char*>(&err), &len);
  return err == 0;
}

bool recv_exact(socket_t s, uint8_t* buf, size_t n) {
  size_t got = 0;
  while (got < n) {
    const auto r = recv(s, reinterpret_cast<char*>(buf + got), static_cast<int>(n - got), 0);
    if (r <= 0) return false;
    got += static_cast<size_t>(r);
  }
  return true;
}

#if defined(_WIN32)
struct WinsockInit {
  WinsockInit() {
    WSADATA data;
    WSAStartup(MAKEWORD(2, 2), &data);
  }
  ~WinsockInit() { WSACleanup(); }
};
#endif

}  // namespace

RtlTcpSource::RtlTcpSource(EventSink& events, std::string host, int port)
    : events_(events), host_(std::move(host)), port_(port > 0 ? port : 1234) {}

RtlTcpSource::~RtlTcpSource() {
  stop();
  close_socket();
}

void RtlTcpSource::close_socket() {
  if (socket_ != -1) {
    terra_close_socket(static_cast<socket_t>(socket_));
    socket_ = -1;
  }
}

bool RtlTcpSource::open(std::string& error) {
#if defined(_WIN32)
  static WinsockInit winsock;
#endif
  addrinfo hints{};
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  addrinfo* result = nullptr;
  const std::string port = std::to_string(port_);
  if (getaddrinfo(host_.c_str(), port.c_str(), &hints, &result) != 0 || !result) {
    error = "cannot resolve " + host_;
    return false;
  }

  socket_t s = TERRA_INVALID_SOCKET;
  for (addrinfo* ai = result; ai; ai = ai->ai_next) {
    s = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
    if (s == TERRA_INVALID_SOCKET) continue;
    set_blocking(s, false);
    const int r = connect(s, ai->ai_addr, static_cast<int>(ai->ai_addrlen));
    bool ok = r == 0;
    if (!ok) ok = wait_writable(s, kConnectTimeoutMs);
    if (ok) {
      set_blocking(s, true);
      break;
    }
    terra_close_socket(s);
    s = TERRA_INVALID_SOCKET;
  }
  freeaddrinfo(result);
  if (s == TERRA_INVALID_SOCKET) {
    error = "Unable to connect to " + host_ + ":" + port;
    return false;
  }

  int one = 1;
  setsockopt(s, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&one), sizeof(one));
  int rcvbuf = 1 << 20;
  setsockopt(s, SOL_SOCKET, SO_RCVBUF, reinterpret_cast<const char*>(&rcvbuf), sizeof(rcvbuf));
  socket_ = static_cast<intptr_t>(s);

  uint8_t header[12];
  if (!recv_exact(s, header, sizeof(header)) || std::memcmp(header, "RTL0", 4) != 0) {
    error = "not an rtl_tcp server";
    close_socket();
    return false;
  }
  const uint32_t tuner = read_be32(header + 4);
  info_.tuner = tuner_name(tuner);
  info_.gains = tuner_gains(tuner);
  info_.description = "rtl_tcp " + host_ + ":" + port;
  info_.supports_bias_tee = tuner == 5 || tuner == 6;

  send_command(0x02, TERRA_IQ_SAMPLE_RATE);
  send_command(0x08, 0);  // RTL2832 digital AGC off
  send_command(0x03, 1);  // manual tuner gain
  events_.log(TERRA_LOG_INFO, "rtltcp", "connected to %s (%s)", info_.description.c_str(),
              info_.tuner.c_str());
  return true;
}

bool RtlTcpSource::send_command(uint8_t cmd, uint32_t param) {
  if (socket_ == -1) return false;
  uint8_t buf[5] = {cmd, static_cast<uint8_t>(param >> 24), static_cast<uint8_t>(param >> 16),
                    static_cast<uint8_t>(param >> 8), static_cast<uint8_t>(param)};
  std::lock_guard<std::mutex> lock(send_mutex_);
  return send(static_cast<socket_t>(socket_), reinterpret_cast<const char*>(buf), 5, 0) == 5;
}

bool RtlTcpSource::start(DataHandler on_data, StateHandler on_state) {
  if (socket_ == -1 || thread_.joinable()) return false;
  on_data_ = std::move(on_data);
  on_state_ = std::move(on_state);
  stopping_ = false;
  thread_ = std::thread([this] { read_loop(); });
  return true;
}

void RtlTcpSource::read_loop() {
  std::vector<uint8_t> buf(65536 + 1);
  size_t carry = 0;  // keep I/Q pairs aligned across reads
  const auto s = static_cast<socket_t>(socket_);
  while (!stopping_) {
    const auto r = recv(s, reinterpret_cast<char*>(buf.data() + carry),
                        static_cast<int>(buf.size() - 1 - carry), 0);
    if (r <= 0) break;
    const size_t total = carry + static_cast<size_t>(r);
    const size_t even = total & ~size_t{1};
    if (even > 0) on_data_(buf.data(), even);
    carry = total - even;
    if (carry) buf[0] = buf[even];
  }
  if (!stopping_) {
    events_.log(TERRA_LOG_WARN, "rtltcp", "connection closed");
    if (on_state_) on_state_(TERRA_SOURCE_STATE_LOST, 0, "rtl_tcp connection closed");
  }
}

void RtlTcpSource::stop() {
  if (!thread_.joinable()) return;
  stopping_ = true;
  if (socket_ != -1) {
#if defined(_WIN32)
    shutdown(static_cast<socket_t>(socket_), SD_BOTH);
#else
    shutdown(static_cast<socket_t>(socket_), SHUT_RDWR);
#endif
  }
  thread_.join();
}

bool RtlTcpSource::set_frequency(uint32_t hz) { return send_command(0x01, hz); }

bool RtlTcpSource::set_gain(int tenth_db) {
  return send_command(0x03, 1) && send_command(0x04, static_cast<uint32_t>(tenth_db));
}

bool RtlTcpSource::set_hardware_agc() { return send_command(0x03, 0); }

bool RtlTcpSource::set_ppm(int ppm) { return send_command(0x05, static_cast<uint32_t>(ppm)); }

bool RtlTcpSource::set_bias_tee(bool enabled) { return send_command(0x0e, enabled ? 1 : 0); }

}  // namespace terra
