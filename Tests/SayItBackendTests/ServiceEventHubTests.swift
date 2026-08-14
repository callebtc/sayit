import Foundation
import Testing
@testable import SayItBackend

@Suite("Service event hub")
@MainActor
struct ServiceEventHubTests {
    @Test("Publishing one revision resumes every registered waiter")
    func publicationResumesEveryWaiter() async throws {
        let hub = ServiceEventHub()
        let first = Task { @MainActor in
            try await hub.wait(
                after: 7,
                currentRevision: 7,
                timeout: .seconds(30)
            )
        }
        let second = Task { @MainActor in
            try await hub.wait(
                after: 7,
                currentRevision: 7,
                timeout: .seconds(30)
            )
        }
        while hub.waiterCount < 2 {
            await Task.yield()
        }

        hub.publish(8)

        try await first.value
        try await second.value
        #expect(hub.waiterCount == 0)
    }

    @Test("Cancellation unregisters a waiter")
    func cancellationUnregistersWaiter() async {
        let hub = ServiceEventHub()
        let waiting = Task { @MainActor in
            try await hub.wait(
                after: 9,
                currentRevision: 9,
                timeout: .seconds(30)
            )
        }
        while hub.waiterCount == 0 {
            await Task.yield()
        }

        waiting.cancel()

        await #expect(throws: CancellationError.self) {
            try await waiting.value
        }
        #expect(hub.waiterCount == 0)
    }

    @Test("A timeout resumes its waiter and records the requested heartbeat")
    func timeoutResumesWaiter() async throws {
        let recorder = EventSleepRecorder()
        let hub = ServiceEventHub { duration in
            await recorder.record(duration)
        }

        try await hub.wait(
            after: 11,
            currentRevision: 11,
            timeout: .seconds(30)
        )

        #expect(await recorder.recordedDurations() == [.seconds(30)])
        #expect(hub.waiterCount == 0)
    }
}

private actor EventSleepRecorder {
    private var durations: [Duration] = []

    func record(_ duration: Duration) {
        durations.append(duration)
    }

    func recordedDurations() -> [Duration] {
        durations
    }
}
