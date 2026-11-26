#include "TimeStretch.h"
#include "vendor/sonic.h"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <stdexcept>
#include <vector>

namespace {
struct Stream {
    sonicStream sonic = nullptr;
    double rate, sampleRate;
    int64_t inputFrames = 0, deliveredFrames = 0;
    bool finished = false;
    std::vector<float> bounded, output;

    Stream(double sampleRate, double rate) : rate(rate), sampleRate(sampleRate) {
        if (rate != 1) {
            sonic = sonicCreateStream(int(sampleRate), 1);
            if (!sonic) throw std::bad_alloc();
            sonicSetSpeed(sonic, float(rate));
            sonicSetPitch(sonic, 1);
            sonicSetRate(sonic, 1);
            sonicSetVolume(sonic, 1);
            sonicSetQuality(sonic, 1);
        }
    }
    ~Stream() {
        if (sonic) sonicDestroyStream(sonic);
    }

    void process(const float *input, int count, bool final) {
        if (finished) throw std::runtime_error("Stream already finalized");
        output.clear();
        inputFrames += count;
        auto expected = std::llround(inputFrames / rate);
        if (rate == 1) {
            if (count) output.assign(input, input + count);
            deliveredFrames += count;
        } else {
            // Sonic's upstream Float API converts internally to signed 16-bit.
            // Clamp before that conversion to prevent overflow for hot PCM.
            bounded.resize(count);
            for (int i = 0; i < count; ++i) bounded[i] = std::clamp(input[i], -1.0f, 1.0f);
            if (count > 0 && !sonicWriteFloatToStream(sonic, bounded.data(), count)) {
                throw std::bad_alloc();
            }
            // Always drain all real stretched samples Sonic has produced so
            // slow speeds where Sonic drifts slightly long (e.g. 0.5x over
            // multi-minute clips) never accumulate a backlog that truncates
            // the end of the recording.
            int preFlushAvailable = sonicSamplesAvailable(sonic);
            if (preFlushAvailable > 0) {
                output.resize(preFlushAvailable);
                if (sonicReadFloatFromStream(sonic, output.data(), preFlushAvailable) != preFlushAvailable) {
                    throw std::runtime_error("Incomplete read");
                }
                deliveredFrames += preFlushAvailable;
            }
            if (final) {
                // Supply lookahead silence before flushing so Sonic drains its
                // final pitch-period lookahead without clipping the last phoneme,
                // then trim only the synthetic silence padding.
                int padFrames = int(std::ceil(sampleRate * 0.2));
                std::vector<float> padding(padFrames, 0);
                if (!sonicWriteFloatToStream(sonic, padding.data(), padFrames)
                    || !sonicFlushStream(sonic)) {
                    throw std::bad_alloc();
                }
                int flushedAvailable = sonicSamplesAvailable(sonic);
                if (flushedAvailable > 0) {
                    std::vector<float> flushed(flushedAvailable);
                    if (sonicReadFloatFromStream(sonic, flushed.data(), flushedAvailable) != flushedAvailable) {
                        throw std::runtime_error("Incomplete read");
                    }
                    int64_t keep;
                    if (expected > deliveredFrames) {
                        keep = std::min<int64_t>(flushedAvailable, expected - deliveredFrames);
                    } else {
                        // Sonic has already emitted >= expected frames (cumulative
                        // positive drift on long slow-rate clips). Strip only the
                        // stretched lookahead padding so the real final lookahead
                        // tail is preserved.
                        auto padOutput = std::llround(double(padFrames) / rate);
                        keep = std::max<int64_t>(0, int64_t(flushedAvailable) - padOutput);
                    }
                    if (keep > 0) {
                        output.insert(output.end(), flushed.begin(), flushed.begin() + ptrdiff_t(keep));
                        deliveredFrames += keep;
                    }
                }
            }
            if (final && expected > 0 && deliveredFrames == 0) {
                throw std::runtime_error("Incomplete tail");
            }
        }
        finished = final;
    }
};
}
extern "C" void *sayit_stretch_create(double sampleRate, double rate) {
    if (!std::isfinite(sampleRate) || sampleRate < 8000 || sampleRate > 192000
        || !std::isfinite(rate) || rate < 0.5 || rate > 3) return nullptr;
    try { return new Stream(sampleRate, rate); } catch (...) { return nullptr; }
}
extern "C" void sayit_stretch_destroy(void *handle) { delete static_cast<Stream *>(handle); }
extern "C" const float *sayit_stretch_process(void *handle, const float *input, int count,
                                             int final, int *outputCount) {
    *outputCount = -1;
    if (!handle || count < 0 || (count && !input)) return nullptr;
    try {
        auto &stream = *static_cast<Stream *>(handle);
        stream.process(input, count, final != 0);
        *outputCount = int(stream.output.size());
        return stream.output.data();
    } catch (...) { return nullptr; }
}
