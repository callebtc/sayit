import CoreAudio
import Testing
@testable import SayItBackend

@Suite("System audio ducking route")
struct SystemAudioDuckingRouterTests {
    @Test("Taps are confined to their selected output device")
    func deviceScopedTap() throws {
        let first = try SystemAudioDuckingRouter.makeTapDescription(
            excluding: [11, 22],
            outputDeviceUID: "test-output-a",
            outputStreamCount: 1
        )
        let second = try SystemAudioDuckingRouter.makeTapDescription(
            excluding: [11, 22],
            outputDeviceUID: "test-output-b",
            outputStreamCount: 1
        )

        #expect(first.deviceUID == "test-output-a")
        #expect(second.deviceUID == "test-output-b")
        #expect(first.stream == 0)
        #expect(first.isExclusive)
        #expect(first.processes == [11, 22])
    }

    @Test("Native output channels are not downmixed to stereo")
    func nativeChannelTap() throws {
        let description = try SystemAudioDuckingRouter.makeTapDescription(
            excluding: [],
            outputDeviceUID: "test-surround-output",
            outputStreamCount: 1
        )

        #expect(!description.isMixdown)
        #expect(!description.isMono)
    }

    @Test("Unsupported stream layouts are rejected before a tap is created", arguments: [0, 2, 4])
    func unsupportedStreams(count: Int) {
        #expect(throws: DuckingError.unsupportedFormat) {
            try SystemAudioDuckingRouter.makeTapDescription(
                excluding: [],
                outputDeviceUID: "test-output",
                outputStreamCount: count
            )
        }
    }
}
