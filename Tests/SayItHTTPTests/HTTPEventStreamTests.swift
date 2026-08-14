import Hummingbird
import SayItProtocol
import Testing
@testable import SayItHTTP

@Suite("HTTP event stream")
struct HTTPEventStreamTests {
    @Test("A written event advances the stream revision")
    func writtenEventAdvancesRevision() async throws {
        let recorder = SSEWriteRecorder()
        var writer: any ResponseBodyWriter = RecordingSSEWriter(
            recorder: recorder
        )
        var revision: UInt64 = 7
        let event = serviceEvent(revision: 8)

        try await ServiceEventSSEWriter.write(
            .events([event]),
            lastRevision: &revision,
            to: &writer
        )

        #expect(revision == 8)
        let payloads = await recorder.payloads()
        #expect(payloads.count == 1)
        #expect(payloads[0].hasPrefix("id: 8\nevent: snapshot\ndata: "))
        #expect(payloads[0].hasSuffix("\n\n"))
    }

    @Test("A failed event write leaves the stream revision unchanged")
    func failedEventDoesNotAdvanceRevision() async {
        let recorder = SSEWriteRecorder()
        var writer: any ResponseBodyWriter = RecordingSSEWriter(
            recorder: recorder,
            writeError: SSETestError.writeFailed
        )
        var revision: UInt64 = 7

        await #expect(throws: SSETestError.self) {
            try await ServiceEventSSEWriter.write(
                .events([serviceEvent(revision: 8)]),
                lastRevision: &revision,
                to: &writer
            )
        }

        #expect(revision == 7)
        #expect(await recorder.payloads().isEmpty)
    }

    @Test("An empty long-poll response writes an SSE heartbeat")
    func emptyResponseWritesHeartbeat() async throws {
        let recorder = SSEWriteRecorder()
        var writer: any ResponseBodyWriter = RecordingSSEWriter(
            recorder: recorder
        )
        var revision: UInt64 = 7

        try await ServiceEventSSEWriter.write(
            .events([]),
            lastRevision: &revision,
            to: &writer
        )

        #expect(revision == 7)
        #expect(await recorder.payloads() == [": heartbeat\n\n"])
    }
}

private actor SSEWriteRecorder {
    private var recordedPayloads: [String] = []

    func record(_ buffer: ByteBuffer) {
        recordedPayloads.append(
            String(decoding: buffer.readableBytesView, as: UTF8.self)
        )
    }

    func payloads() -> [String] {
        recordedPayloads
    }
}

private struct RecordingSSEWriter: ResponseBodyWriter {
    let recorder: SSEWriteRecorder
    var writeError: (any Error)?

    init(
        recorder: SSEWriteRecorder,
        writeError: (any Error)? = nil
    ) {
        self.recorder = recorder
        self.writeError = writeError
    }

    mutating func write(_ buffer: ByteBuffer) async throws {
        if let writeError {
            throw writeError
        }
        await recorder.record(buffer)
    }

    consuming func finish(_ trailingHeaders: HTTPFields?) async throws {}
}

private enum SSETestError: Error {
    case writeFailed
}

private func serviceEvent(revision: UInt64) -> ServiceEvent {
    ServiceEvent(
        id: revision,
        snapshot: ServiceSnapshot(
            serviceVersion: "test",
            revision: revision,
            statusText: "Ready to speak",
            lastError: nil,
            activeJob: nil,
            queuedJobs: [],
            playback: PlaybackSnapshot(),
            download: nil,
            installedModelIDs: [],
            settings: BackendSettingsSnapshot(),
            modelsRevision: 0,
            historyRevision: 0,
            diagnosticsRevision: 0
        )
    )
}
