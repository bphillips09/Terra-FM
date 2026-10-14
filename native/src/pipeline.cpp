#include "pipeline.h"

namespace terra {

DspPipeline::DspPipeline(EventSink& events) : hd_(events) {
  hd_.set_audio_handler([this](int program, const int16_t* frames, size_t count, bool valid) {
    hd_frames_[static_cast<size_t>(program & 7)] += count;
    if (program == mixer_.program()) mixer_.push_hd(frames, count, valid);
  });
  analog_.reserve(8192);
  output_.reserve(8192);
}

void DspPipeline::reset(uint32_t frequency_hz) {
  meter_.reset();
  hd_.reset(frequency_hz);
  fm_.reset();
  mixer_.reset();
  samples_ = 0;
  hd_frames_.fill(0);
}

void DspPipeline::process(const uint8_t* iq, size_t bytes) {
  bytes &= ~size_t{1};
  analog_.clear();
  output_.clear();
  if (bytes == 0) return;

  meter_.process_cu8(iq, bytes);
  hd_.process_cu8(iq, bytes);
  fm_.process_cu8(iq, bytes, analog_);
  mixer_.mix(analog_.data(), analog_.size() / 2, fm_.status().squelched, output_);
  samples_ += bytes / 2;
}

}  // namespace terra
