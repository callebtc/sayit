import AudioToolbox
import CoreAudio
import Testing
@testable import SayItBackend

@Suite("Other audio render state")
struct DuckingRenderStateTests {
    @Test("Hardware input never authorizes a silent tap")
    func hardwareInputCannotAuthorizeMuting() throws {
        let state = try makeState(
            inputChannels: [1, 2], outputChannels: [2], hardwareInputChannels: [1]
        )
        let input = AudioBuffers([(1, [0.4, 0.3]), (2, [0, 0, 0, 0])])
        let output = AudioBuffers([(2, [1, 1, 1, 1])])

        state.render(input: input.pointer, output: output.pointer)

        #expect(!state.hasReceivedSignal)
        #expect(output.samples(at: 0) == [0, 0, 0, 0])
    }

    @Test("Only real tap samples authorize replay, while originals stay audible")
    func tapSignalAuthorizesMuting() throws {
        let state = try makeState(
            inputChannels: [1, 2], outputChannels: [2], hardwareInputChannels: [1]
        )
        let input = AudioBuffers([(1, [0, 0]), (2, [0.25, 0.5, -0.25, -0.5])])
        let output = AudioBuffers([(2, [1, 1, 1, 1])])

        state.render(input: input.pointer, output: output.pointer)

        #expect(state.hasReceivedSignal)
        #expect(output.samples(at: 0) == [0, 0, 0, 0])
    }

    @Test("Missing or unavailable tap buffers do not fall back to hardware inputs")
    func missingTapDoesNotAuthorizeMuting() throws {
        let state = try makeState(
            inputChannels: [2, 2], outputChannels: [2], hardwareInputChannels: [2]
        )
        let input = AudioBuffers([(2, [0.4, 0.3]), (2, [0, 0])])
        let output = AudioBuffers([(2, [0, 0])])
        let buffers = UnsafeMutableAudioBufferListPointer(input.pointer)
        buffers[1].mData = nil

        state.render(input: input.pointer, output: output.pointer)
        #expect(!state.hasReceivedSignal)

        input.pointer.pointee.mNumberBuffers = 1
        state.render(input: input.pointer, output: output.pointer)
        #expect(!state.hasReceivedSignal)
    }

    @Test("A route cannot mute originals without a usable output buffer")
    func unavailableOutputDoesNotAuthorizeMuting() throws {
        let state = try makeState(inputChannels: [2], outputChannels: [2])
        let input = AudioBuffers([(2, [0.25, 0.5])])
        let output = AudioBuffers([(2, [0, 0])])
        UnsafeMutableAudioBufferListPointer(output.pointer)[0].mData = nil

        state.render(input: input.pointer, output: output.pointer)

        #expect(!state.hasReceivedSignal)
    }

    @Test("A partial tap cannot authorize muting the complete output")
    func shortTapDoesNotAuthorizeMuting() throws {
        let state = try makeState(inputChannels: [2], outputChannels: [2])
        let input = AudioBuffers([(2, [0.25, 0.5])])
        let output = AudioBuffers([(2, [1, 1, 1, 1])])

        state.render(input: input.pointer, output: output.pointer)

        #expect(!state.hasReceivedSignal)
        #expect(output.samples(at: 0) == [0, 0, 0, 0])
    }

    @Test("All planar tap channels must supply complete frames")
    func shortPlanarChannelDoesNotAuthorizeMuting() throws {
        let state = try makeState(inputChannels: [1, 1], outputChannels: [2])
        let input = AudioBuffers([(1, [0.25, -0.25]), (1, [0.5])])
        let output = AudioBuffers([(2, [1, 1, 1, 1])])

        state.render(input: input.pointer, output: output.pointer)

        #expect(!state.hasReceivedSignal)
        #expect(output.samples(at: 0) == [0, 0, 0, 0])
    }

    @Test("Replay excludes hardware input and preserves stereo order")
    func replayUsesOnlyTapChannels() throws {
        let state = try makeState(
            inputChannels: [1, 2], outputChannels: [2], hardwareInputChannels: [1]
        )
        let input = AudioBuffers([(1, [1, 1]), (2, [0.25, 0.5, -0.25, -0.5])])
        let output = AudioBuffers([(2, [0, 0, 0, 0])])
        state.setTarget(0.2, rampDuration: 0)
        state.startReplaying()

        state.render(input: input.pointer, output: output.pointer)

        #expect(output.samples(at: 0) == [0.05, 0.1, -0.05, -0.1])
    }

    @Test("Every surround channel retains its own samples")
    func preservesSurroundChannels() throws {
        let state = try makeState(inputChannels: [6], outputChannels: [6])
        let input = AudioBuffers([(6, [0.1, 0.2, 0.3, 0.4, 0.5, 0.6])])
        let output = AudioBuffers([(6, [0, 0, 0, 0, 0, 0])])
        state.setTarget(0.5, rampDuration: 0)
        state.startReplaying()

        state.render(input: input.pointer, output: output.pointer)

        #expect(output.samples(at: 0) == [0.05, 0.1, 0.15, 0.2, 0.25, 0.3])
    }

    @Test("Planar input and output buffers preserve channel order")
    func preservesPlanarChannels() throws {
        let state = try makeState(
            inputChannels: [1, 1, 1], outputChannels: [1, 1], hardwareInputChannels: [1]
        )
        let input = AudioBuffers([(1, [1, 1]), (1, [0.25, -0.25]), (1, [0.5, -0.5])])
        let output = AudioBuffers([(1, [0, 0]), (1, [0, 0])])
        state.setTarget(0.2, rampDuration: 0)
        state.startReplaying()

        state.render(input: input.pointer, output: output.pointer)

        #expect(output.samples(at: 0) == [0.05, -0.05])
        #expect(output.samples(at: 1) == [0.1, -0.1])
    }

    @Test("Stereo taps cannot replace surround output layouts")
    func mismatchedChannelCountsAreRejected() {
        #expect(throws: DuckingError.unsupportedFormat) {
            try makeState(inputChannels: [2], outputChannels: [6], tapChannels: 2)
        }
    }

    @Test("A tap cannot begin partway through a hardware input buffer")
    func partialTapBufferIsRejected() {
        #expect(throws: DuckingError.unsupportedFormat) {
            try makeState(inputChannels: [3], outputChannels: [2])
        }
    }

    @Test("Hardware buffers alone cannot be mistaken for an attached tap")
    func absentTapLayoutIsRejected() {
        #expect(throws: DuckingError.unsupportedFormat) {
            try makeState(
                inputChannels: [2], outputChannels: [2], hardwareInputChannels: [2]
            )
        }
    }

    @Test("Unexpected output layout changes cannot authorize muting")
    func unexpectedOutputLayoutIsSilent() throws {
        let state = try makeState(inputChannels: [2], outputChannels: [2])
        let input = AudioBuffers([(2, [0.25, 0.5])])
        let output = AudioBuffers([(6, [1, 1, 1, 1, 1, 1])])

        state.render(input: input.pointer, output: output.pointer)

        #expect(!state.hasReceivedSignal)
        #expect(output.samples(at: 0) == [0, 0, 0, 0, 0, 0])
    }

    @Test("Invalid layouts clear previously received signal before muting")
    func invalidLayoutClearsReadiness() throws {
        let state = try makeState(
            inputChannels: [1, 2], outputChannels: [2], hardwareInputChannels: [1]
        )
        let input = AudioBuffers([(1, [1]), (2, [0.25, 0.5])])
        let output = AudioBuffers([(2, [0, 0])])
        state.render(input: input.pointer, output: output.pointer)
        #expect(state.hasReceivedSignal)
        state.startReplaying()

        input.pointer.pointee.mNumberBuffers = 1
        state.render(input: input.pointer, output: output.pointer)

        #expect(!state.hasReceivedSignal)
    }

    @Test("Gain ramps continue across render calls")
    func gainRampProgresses() throws {
        let state = try makeState(inputChannels: [1], outputChannels: [1], sampleRate: 4)
        let input = AudioBuffers([(1, [1, 1])])
        let output = AudioBuffers([(1, [0, 0])])
        state.setTarget(0, rampDuration: 1)
        state.startReplaying()

        state.render(input: input.pointer, output: output.pointer)
        #expect(output.samples(at: 0) == [0.75, 0.5])
        state.render(input: input.pointer, output: output.pointer)
        #expect(output.samples(at: 0) == [0.25, 0])

        state.setTarget(1, rampDuration: 1)
        state.render(input: input.pointer, output: output.pointer)
        #expect(output.samples(at: 0) == [0.25, 0.5])
    }

    private func makeState(
        inputChannels: [Int],
        outputChannels: [Int],
        sampleRate: Double = 48_000,
        tapChannels: Int? = nil,
        hardwareInputChannels: [Int] = []
    ) throws -> DuckingRenderState {
        let state = DuckingRenderState()
        try state.configure(
            tapChannels: tapChannels ?? outputChannels.reduce(0, +),
            sampleRate: sampleRate,
            inputChannels: inputChannels,
            outputChannels: outputChannels,
            hardwareInputChannels: hardwareInputChannels
        )
        return state
    }
}

private final class AudioBuffers {
    let pointer: UnsafeMutablePointer<AudioBufferList>
    private let storage: UnsafeMutableRawPointer
    private let data: [UnsafeMutablePointer<Float>]
    private let counts: [Int]

    init(_ layouts: [(UInt32, [Float])]) {
        let bytes = MemoryLayout<AudioBufferList>.size
            + max(layouts.count - 1, 0) * MemoryLayout<AudioBuffer>.stride
        storage = .allocate(byteCount: bytes, alignment: MemoryLayout<AudioBufferList>.alignment)
        pointer = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        pointer.initialize(to: AudioBufferList(
            mNumberBuffers: UInt32(layouts.count),
            mBuffers: AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil)
        ))
        counts = layouts.map { $0.1.count }
        data = layouts.map { _, samples in
            let result = UnsafeMutablePointer<Float>.allocate(capacity: samples.count)
            result.initialize(from: samples, count: samples.count)
            return result
        }
        let buffers = UnsafeMutableAudioBufferListPointer(pointer)
        for index in layouts.indices {
            buffers[index] = AudioBuffer(
                mNumberChannels: layouts[index].0,
                mDataByteSize: UInt32(counts[index] * MemoryLayout<Float>.size),
                mData: data[index]
            )
        }
    }

    func samples(at index: Int) -> [Float] {
        Array(UnsafeBufferPointer(start: data[index], count: counts[index]))
    }

    deinit {
        for index in data.indices {
            data[index].deinitialize(count: counts[index])
            data[index].deallocate()
        }
        pointer.deinitialize(count: 1)
        storage.deallocate()
    }
}
