#include "TimeStretch.h"
#include "vendor/rubberband/RubberBandStretcher.h"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <stdexcept>
#include <vector>

namespace {
using Stretcher = RubberBand::RubberBandStretcher;
struct Stream {
    Stretcher stretch;
    double rate;
    int64_t inputFrames = 0, deliveredFrames = 0;
    size_t skip = 0;
    bool finished = false;
    std::vector<float> pending, output;
    static constexpr int blockSize = 4096;

    Stream(double sampleRate, double rate)
        : stretch(size_t(sampleRate), 1,
                  Stretcher::OptionProcessRealTime | Stretcher::OptionEngineFiner
                  | Stretcher::OptionChannelsTogether | Stretcher::OptionThreadingNever,
                  1.0 / rate, 1.0), rate(rate) {
        if (stretch.getEngineVersion() != 3) throw std::runtime_error("R3 engine unavailable");
        stretch.setMaxProcessSize(blockSize);
        if (rate != 1) {
            skip = stretch.getStartDelay();
            std::vector<float> padding(stretch.getPreferredStartPad(), 0);
            write(padding.data(), int(padding.size()), false);
        }
    }

    void drain() {
        int available;
        while ((available = stretch.available()) > 0) {
            std::vector<float> block(available);
            float *channels[] = {block.data()};
            auto count = stretch.retrieve(channels, available);
            if (count == 0) throw std::runtime_error("Incomplete read");
            auto drop = std::min(skip, count);
            skip -= drop;
            pending.insert(pending.end(), block.begin() + drop, block.begin() + count);
        }
    }

    void write(const float *input, int count, bool final) {
        for (int start = 0; start < count; start += blockSize) {
            int size = std::min(blockSize, count - start);
            const float *channels[] = {input + start};
            stretch.process(channels, size, final && start + size == count);
            drain();
        }
        if (count == 0 && final) {
            const float zero = 0;
            const float *channels[] = {&zero};
            stretch.process(channels, 0, true);
            drain();
        }
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
            write(input, count, final);
            // Rubber Band's local ratio is adaptive: buffer extra output rather
            // than assuming a fixed input/output count for each processing call.
            auto keep = std::min<int64_t>(pending.size(), expected - deliveredFrames);
            output.assign(pending.begin(), pending.begin() + keep);
            pending.erase(pending.begin(), pending.begin() + keep);
            deliveredFrames += keep;
            if (final && deliveredFrames != expected) throw std::runtime_error("Incomplete tail");
        }
        finished = final;
    }
};
}
extern "C" void *sayit_stretch_create(double sampleRate, double rate) {
    if (!std::isfinite(sampleRate) || sampleRate < 8000 || sampleRate > 192000
        || !std::isfinite(rate) || rate < 0.5 || rate > 2) return nullptr;
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
