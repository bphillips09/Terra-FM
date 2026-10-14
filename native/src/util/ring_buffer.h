#pragma once

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstring>
#include <vector>

namespace terra {

// Lock-free single-producer / single-consumer ring buffer of trivially
// copyable elements. Capacity is rounded up to a power of two.
template <typename T>
class SpscRing {
 public:
  explicit SpscRing(size_t min_capacity) {
    size_t cap = 1;
    while (cap < min_capacity) cap <<= 1;
    buffer_.resize(cap);
    mask_ = cap - 1;
  }

  size_t capacity() const { return buffer_.size(); }

  size_t size() const {
    return write_.load(std::memory_order_acquire) - read_.load(std::memory_order_acquire);
  }

  size_t free_space() const { return capacity() - size(); }

  // Producer side. Writes up to n elements, returns the number written.
  size_t write(const T* data, size_t n) {
    const size_t w = write_.load(std::memory_order_relaxed);
    const size_t r = read_.load(std::memory_order_acquire);
    const size_t space = capacity() - (w - r);
    n = std::min(n, space);
    copy_in(w, data, n);
    write_.store(w + n, std::memory_order_release);
    return n;
  }

  // Consumer side. Reads up to n elements, returns the number read.
  size_t read(T* out, size_t n) {
    const size_t r = read_.load(std::memory_order_relaxed);
    const size_t w = write_.load(std::memory_order_acquire);
    n = std::min(n, w - r);
    copy_out(r, out, n);
    read_.store(r + n, std::memory_order_release);
    return n;
  }

  // Consumer side. Peeks without consuming.
  size_t peek(T* out, size_t n, size_t offset = 0) const {
    const size_t r = read_.load(std::memory_order_relaxed);
    const size_t w = write_.load(std::memory_order_acquire);
    if (offset >= w - r) return 0;
    n = std::min(n, w - r - offset);
    copy_out(r + offset, out, n);
    return n;
  }

  // Consumer side. Drops up to n elements.
  size_t skip(size_t n) {
    const size_t r = read_.load(std::memory_order_relaxed);
    const size_t w = write_.load(std::memory_order_acquire);
    n = std::min(n, w - r);
    read_.store(r + n, std::memory_order_release);
    return n;
  }

  // Consumer side. Drops everything currently buffered.
  void clear() { read_.store(write_.load(std::memory_order_acquire), std::memory_order_release); }

 private:
  void copy_in(size_t pos, const T* data, size_t n) {
    const size_t start = pos & mask_;
    const size_t first = std::min(n, capacity() - start);
    std::memcpy(&buffer_[start], data, first * sizeof(T));
    if (n > first) std::memcpy(&buffer_[0], data + first, (n - first) * sizeof(T));
  }

  void copy_out(size_t pos, T* out, size_t n) const {
    const size_t start = pos & mask_;
    const size_t first = std::min(n, capacity() - start);
    std::memcpy(out, &buffer_[start], first * sizeof(T));
    if (n > first) std::memcpy(out + first, &buffer_[0], (n - first) * sizeof(T));
  }

  std::vector<T> buffer_;
  size_t mask_ = 0;
  alignas(64) std::atomic<size_t> write_{0};
  alignas(64) std::atomic<size_t> read_{0};
};

}  // namespace terra
