#include "TimeStretch.h"
#include "vendor/signalsmith-stretch.h"
#include <cmath>
#include <cstdint>
#include <vector>
#include <stdexcept>

namespace {
struct Stream {
    signalsmith::stretch::SignalsmithStretch<float> stretch{0};
    double rate;
    int64_t inputFrames = 0, rawFrames = 0, deliveredFrames = 0;
    int64_t skip;
    bool finished = false;
    std::vector<float> output;

    Stream(double sampleRate, double playbackRate) : rate(playbackRate) {
        stretch.presetDefault(1, sampleRate);
        skip = std::llround(stretch.inputLatency() / rate) + stretch.outputLatency();
    }

    void render(const float *input, int count, int outputCount) {
        std::vector<float> block(outputCount);
        const float *inputs[] = {input};
        float *outputs[] = {block.data()};
        stretch.process(inputs, count, outputs, outputCount);
        auto drop = std::min<int64_t>(skip, outputCount);
        skip -= drop;
        auto remaining = std::llround(inputFrames / rate) - deliveredFrames;
        auto keep = std::min<int64_t>(outputCount - drop, remaining);
        output.insert(output.end(), block.begin() + drop, block.begin() + drop + keep);
        deliveredFrames += keep;
    }

    void process(const float *input, int count, bool final) {
        if (finished) throw std::runtime_error("Stream already finalized");
        output.clear();
        inputFrames += count;
        if (rate == 1) {
            if (count) output.assign(input, input + count);
            deliveredFrames += count;
        } else {
            auto nextRawFrames = std::llround(inputFrames / rate);
            if (count) render(input, count, int(nextRawFrames - rawFrames));
            rawFrames = nextRawFrames;
            if (final) {
                // Feed silence through the same continuous engine to drain its lookahead.
                auto missing = nextRawFrames - deliveredFrames;
                int padding = int(std::ceil((missing + skip + stretch.outputLatency()) * rate))
                    + stretch.blockSamples();
                std::vector<float> silence(padding, 0);
                render(silence.data(), padding, int(std::ceil(padding / rate)));
                if (deliveredFrames != nextRawFrames) throw std::runtime_error("Incomplete tail");
            }
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
