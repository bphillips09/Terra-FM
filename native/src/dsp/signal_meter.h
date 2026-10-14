#pragma once

#include <complex>
#include <cstdint>
#include <vector>

#include "dsp/fft.h"

namespace terra {

struct SignalReport {
  float rms_dbfs = -100.0f;
  float peak_dbfs = -100.0f;
  float clip_ratio = 0.0f;
  float channel_dbfs = -100.0f;
  float noise_dbfs = -100.0f;
  float snr_db = 0.0f;
};

// Raw IQ statistics plus an averaged power spectrum, reported every
// `report_interval` seconds of samples.
class SignalMeter {
 public:
  static constexpr double kSampleRate = 1488375.0;
  static constexpr size_t kFftSize = 1024;
  static constexpr size_t kSpectrumBins = 256;

  SignalMeter();
  void reset();

  void process_cu8(const uint8_t* iq, size_t bytes);

  // True when a new report is ready (then cleared).
  bool take_report(SignalReport& report);
  // Latest averaged spectrum in dBFS (kSpectrumBins, low to high frequency).
  bool take_spectrum(std::vector<float>& bins_db);

  void set_spectrum_enabled(bool enabled) { spectrum_enabled_ = enabled; }

 private:
  void run_fft(const uint8_t* iq);
  void finish_report();

  Fft fft_;
  std::vector<float> window_;
  float window_power_ = 1.0f;
  std::vector<std::complex<float>> fft_in_, fft_out_;
  std::vector<double> power_acc_;
  int fft_count_ = 0;

  size_t samples_until_fft_ = 0;
  size_t fft_spacing_ = 18604;  // ~12.5 ms between snapshots
  std::vector<uint8_t> fft_buffer_;

  double sum_sq_ = 0.0;
  double peak_ = 0.0;
  uint64_t clips_ = 0;
  uint64_t samples_ = 0;
  size_t report_samples_ = 148838;  // 100 ms

  SignalReport report_;
  bool report_ready_ = false;
  std::vector<float> spectrum_;
  bool spectrum_ready_ = false;
  bool spectrum_enabled_ = false;
};

}  // namespace terra
