import Foundation
import SayItCore
import Testing
@testable import SayItBackend

@Suite("Synthesis operation lifecycle")
struct SynthesisOperationLifecycleTests {
    @Test("The MLX operation gate never overlaps work")
    func gateSerializesOperations() async throws {
        let gate = SynthesisOperationGate()
        let probe = OperationOverlapProbe()

        async let first: Int = gate.perform {
            await probe.begin()
            try await Task.sleep(for: .milliseconds(40))
            await probe.end()
            return 1
        }
        async let second: Int = gate.perform {
            await probe.begin()
            try await Task.sleep(for: .milliseconds(10))
            await probe.end()
            return 2
        }

        let values = try await [first, second]
        #expect(Set(values) == [1, 2])
        #expect(await probe.maximumConcurrentOperations == 1)
    }

    @Test("A follower waits for canceled operation cleanup")
    func gateAwaitsCancellationCleanup() async throws {
        let gate = SynthesisOperationGate()
        let probe = GateCancellationProbe()
        let first = Task {
            try await gate.perform {
                try await probe.runFirstOperation()
            }
        }

        await probe.waitUntilFirstStarted()
        first.cancel()
        await probe.waitUntilCleanupStarted()
        let second = Task {
            try await gate.perform {
                await probe.markSecondStarted()
                return 2
            }
        }
        try await Task.sleep(for: .milliseconds(10))
        #expect(!(await probe.secondStarted))

        await probe.releaseCleanup()
        _ = try? await first.value
        #expect(try await second.value == 2)
        #expect(await probe.secondStarted)
    }

    @Test("Voice sample cancellation is registered and awaited")
    func voiceSampleCancellationQuiescesProvider() async throws {
        let provider = CancellableModelURLProvider()
        let synthesizer = SynthesisActor { modelID in
            await provider.url(for: modelID)
        }
        let model = try #require(
            ModelCatalogLoader().bundledCatalog().models.first
        )

        let sampleTask = Task {
            try await synthesizer.generateVoiceSample(
                model: model,
                text: "Cancellation test",
                language: model.defaultLanguage,
                tuning: VoiceSynthesisTuning(
                    preset: "natural",
                    parameters: [:]
                ),
                seed: 1
            )
        }

        await provider.waitUntilStarted()
        await synthesizer.cancelCurrentRequest()

        do {
            _ = try await sampleTask.value
            Issue.record("Expected voice sample generation to be cancelled")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await provider.observedCancellation)
    }
}

private actor OperationOverlapProbe {
    private var activeOperations = 0
    private(set) var maximumConcurrentOperations = 0

    func begin() {
        activeOperations += 1
        maximumConcurrentOperations = max(
            maximumConcurrentOperations,
            activeOperations
        )
    }

    func end() {
        activeOperations -= 1
    }
}

private actor CancellableModelURLProvider {
    private var started = false
    private(set) var observedCancellation = false

    func url(for _: ModelID) async -> URL? {
        started = true
        do {
            try await Task.sleep(for: .seconds(30))
        } catch is CancellationError {
            observedCancellation = true
        } catch {
            Issue.record("Unexpected provider error: \(error)")
        }
        return nil
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }
}

private actor GateCancellationProbe {
    private var firstStarted = false
    private var cleanupStarted = false
    private var cleanupContinuation: CheckedContinuation<Void, Never>?
    private(set) var secondStarted = false

    func runFirstOperation() async throws -> Int {
        firstStarted = true
        do {
            try await Task.sleep(for: .seconds(30))
            return 1
        } catch is CancellationError {
            cleanupStarted = true
            await withCheckedContinuation { continuation in
                cleanupContinuation = continuation
            }
            throw CancellationError()
        }
    }

    func waitUntilFirstStarted() async {
        while !firstStarted {
            await Task.yield()
        }
    }

    func waitUntilCleanupStarted() async {
        while !cleanupStarted {
            await Task.yield()
        }
    }

    func releaseCleanup() {
        cleanupContinuation?.resume()
        cleanupContinuation = nil
    }

    func markSecondStarted() {
        secondStarted = true
    }
}
