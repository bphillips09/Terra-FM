#include "dsp/signal_meter.h"

#include <algorithm>
#include <cmath>

#include "dsp/math.h"

namespace terra {

namespace {
constexpr double kChannelHalfWidthHz = 100000.0;
// Noise floor = low percentile of bins, ignoring the band edges where the
// tuner's IF filter rolls off.
constexpr double kNoisePercentile = 0.15;
constexpr double kUsableFraction = 0.85;
}  // namespace

SignalMeter::SignalMeter() : fft_(kFftSize) {
  window_.resize(kFftSize);
  double wp = 0.0;
  for (size_t n = 0; n < kFftSize; ++n) {
    window_[n] = static_cast<float>(0.5 - 0.5 * std::cos(2.0 * kPi * n / (kFftSize - 1)));
    wp += static_cast<double>(window_[n]) * window_[n];
  }
  window_power_ = static_cast<float>(wp);
  fft_in_.resize(kFftSize);
  fft_out_.resize(kFftSize);
  power_acc_.assign(kFftSize, 0.0);
  spectrum_.assign(kSpectrumBins, -120.0f);
  fft_buffer_.reserve(kFftSize * 2);
  reset();
}

void SignalMeter::reset() {
  std::fill(power_acc_.begin(), power_acc_.end(), 0.0);
  fft_count_ = 0;
  samples_until_fft_ = 0;
  fft_buffer_.clear();
  sum_sq_ = 0.0;
  peak_ = 0.0;
  clips_ = 0;
  samples_ = 0;
  report_ready_ = false;
  spectrum_ready_ = false;
}

void SignalMeter::process_cu8(const uint8_t* iq, size_t bytes) {
  size_t pos = 0;
  while (pos + 1 < bytes) {
    const size_t until_report = report_samples_ - samples_;
    const size_t chunk = std::min((bytes - pos) / 2, until_report);

    for (size_t k = 0; k < chunk; ++k) {
      const uint8_t ib = iq[pos + 2 * k];
      const uint8_t qb = iq[pos + 2 * k + 1];
      const double i = (ib - 127.5) / 127.5;
      const double q = (qb - 127.5) / 127.5;
      const double p = i * i + q * q;
      sum_sq_ += p;
      if (p > peak_) peak_ = p;
      if (ib == 0 || ib == 255 || qb == 0 || qb == 255) ++clips_;
    }

    // FFT snapshots.
    size_t k = 0;
    while (k < chunk) {
      if (!fft_buffer_.empty() || samples_until_fft_ == 0) {
        const size_t need = kFftSize - fft_buffer_.size() / 2;
        const size_t take = std::min(need, chunk - k);
        fft_buffer_.insert(fft_buffer_.end(), iq + pos + 2 * k, iq + pos + 2 * (k + take));
        k += take;
        if (fft_buffer_.size() / 2 == kFftSize) {
          run_fft(fft_buffer_.data());
          fft_buffer_.clear();
          samples_until_fft_ = fft_spacing_;
        }
      } else {
        const size_t skip = std::min(samples_until_fft_, chunk - k);
        samples_until_fft_ -= skip;
        k += skip;
      }
    }

    samples_ += chunk;
    pos += chunk * 2;
    if (samples_ >= report_samples_) finish_report();
  }
}

void SignalMeter::run_fft(const uint8_t* iq) {
  for (size_t n = 0; n < kFftSize; ++n) {
    const float i = (iq[2 * n] - 127.5f) / 127.5f;
    const float q = (iq[2 * n + 1] - 127.5f) / 127.5f;
    fft_in_[n] = {i * window_[n], q * window_[n]};
  }
  fft_.forward(fft_in_.data(), fft_out_.data());
  for (size_t n = 0; n < kFftSize; ++n) power_acc_[n] += std::norm(fft_out_[n]);
  ++fft_count_;
}

void SignalMeter::finish_report() {
  SignalReport r;
  const double mean = samples_ > 0 ? sum_sq_ / static_cast<double>(samples_) : 0.0;
  r.rms_dbfs = db_from_power(mean);
  r.peak_dbfs = db_from_power(peak_);
  r.clip_ratio = samples_ > 0 ? static_cast<float>(clips_) / static_cast<float>(samples_) : 0.0f;

  if (fft_count_ > 0) {
    // Per-bin power normalized so that summing bins gives mean |x|^2.
    std::vector<double> bins(kFftSize);
    const double norm = 1.0 / (static_cast<double>(fft_count_) * kFftSize * window_power_);
    for (size_t n = 0; n < kFftSize; ++n) {
      const size_t shifted = (n + kFftSize / 2) % kFftSize;  // DC to the middle
      bins[n] = power_acc_[shifted] * norm;
    }

    const double bin_hz = kSampleRate / kFftSize;
    const auto half_bins = static_cast<int>(kChannelHalfWidthHz / bin_hz);
    const int center = static_cast<int>(kFftSize / 2);
    double channel = 0.0;
    for (int b = center - half_bins; b <= center + half_bins; ++b) channel += bins[static_cast<size_t>(b)];

    const auto usable = static_cast<int>(kFftSize * kUsableFraction / 2);
    std::vector<double> sorted(bins.begin() + (center - usable), bins.begin() + (center + usable));
    const auto idx = static_cast<size_t>(sorted.size() * kNoisePercentile);
    std::nth_element(sorted.begin(), sorted.begin() + static_cast<std::ptrdiff_t>(idx), sorted.end());
    const double noise_per_bin = sorted[idx];
    const double noise = noise_per_bin * (2 * half_bins + 1);

    r.channel_dbfs = db_from_power(channel);
    r.noise_dbfs = db_from_power(noise);
    r.snr_db = r.channel_dbfs - r.noise_dbfs;

    if (spectrum_enabled_) {
      const size_t group = kFftSize / kSpectrumBins;
      for (size_t s = 0; s < kSpectrumBins; ++s) {
        double acc = 0.0;
        for (size_t g = 0; g < group; ++g) acc += bins[s * group + g];
        spectrum_[s] = db_from_power(acc / static_cast<double>(group));
      }
      spectrum_ready_ = true;
    }
  }

  report_ = r;
  report_ready_ = true;
  std::fill(power_acc_.begin(), power_acc_.end(), 0.0);
  fft_count_ = 0;
  sum_sq_ = 0.0;
  peak_ = 0.0;
  clips_ = 0;
  samples_ = 0;
}

bool SignalMeter::take_report(SignalReport& report) {
  if (!report_ready_) return false;
  report = report_;
  report_ready_ = false;
  return true;
}

bool SignalMeter::take_spectrum(std::vector<float>& bins_db) {
  if (!spectrum_ready_) return false;
  bins_db = spectrum_;
  spectrum_ready_ = false;
  return true;
}

}  // namespace terra
