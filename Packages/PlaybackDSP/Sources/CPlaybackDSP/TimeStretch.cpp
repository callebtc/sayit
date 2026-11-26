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
    std::vector<float> bounded, pending, output;
    size_t pendingOffset = 0;

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
            if (!sonicWriteFloatToStream(sonic, bounded.data(), count)) throw std::bad_alloc();
            if (final) {
                // Supply lookahead before flushing and crop to the cumulative
                // target, avoiding per-chunk rounding and a clipped final phoneme.
                std::vector<float> padding(int(std::ceil(sampleRate * 0.2)), 0);
                if (!sonicWriteFloatToStream(sonic, padding.data(), int(padding.size()))
                    || !sonicFlushStream(sonic)) throw std::bad_alloc();
            }
            int available = sonicSamplesAvailable(sonic);
            if (available > 0) {
                if (pendingOffset > 0 && pendingOffset == pending.size()) {
                    pending.clear();
                    pendingOffset = 0;
                }
                auto offset = pending.size();
                pending.resize(offset + available);
                if (sonicReadFloatFromStream(sonic, pending.data() + offset, available) != available)
                    throw std::runtime_error("Incomplete read");
            }
            auto livePending = int64_t(pending.size() - pendingOffset);
            auto keep = std::min<int64_t>(livePending, expected - deliveredFrames);
            if (keep > 0) {
                auto begin = pending.begin() + ptrdiff_t(pendingOffset);
                output.assign(begin, begin + ptrdiff_t(keep));
                pendingOffset += size_t(keep);
                if (pendingOffset == pending.size()) {
                    pending.clear();
                    pendingOffset = 0;
                } else if (pendingOffset >= 16384 && pendingOffset * 2 >= pending.size()) {
                    pending.erase(pending.begin(), pending.begin() + ptrdiff_t(pendingOffset));
                    pendingOffset = 0;
                }
                deliveredFrames += keep;
            }
            if (final && deliveredFrames != expected) throw std::runtime_error("Incomplete tail");
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
