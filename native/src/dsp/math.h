#pragma once

#include <cmath>

namespace terra {

constexpr double kPi = 3.14159265358979323846;
constexpr float kPiF = 3.14159265358979323846f;
constexpr float kTwoPiF = 6.28318530717958647692f;

inline float db_from_power(double power) {
  return power > 1e-20 ? static_cast<float>(10.0 * std::log10(power)) : -200.0f;
}

inline float wrap_phase(float phase) {
  while (phase > kPiF) phase -= kTwoPiF;
  while (phase < -kPiF) phase += kTwoPiF;
  return phase;
}

template <typename T>
inline T clamp(T v, T lo, T hi) {
  return v < lo ? lo : (v > hi ? hi : v);
}

}  // namespace terra
