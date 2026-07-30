import Foundation
import SayItCore
import SayItProtocol
import Testing
@testable import SayItBackend

@MainActor
struct SpeechQueuePolicyTests {
    @Test
    func httpServiceFailuresDoNotReplacePlayerWithAGlobalError() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let service = try SayItBackendService(
            directories: AppDirectories.testing(root: root),
            playback: MockPlaybackController()
        )
        await service.start()

        var settings = try snapshot(
            await service.handle(ServiceRequest(command: .snapshot))
        ).settings
        settings.httpEnabled = true
        _ = await service.handle(
            ServiceRequest(command: .updateSettings(settings))
        )

        let message = "HTTP API could not start because the port is in use."
        await service.reportHTTPServiceError(message)

        let failedSnapshot = try snapshot(
            await service.handle(ServiceRequest(command: .snapshot))
        )
        #expect(failedSnapshot.lastError == nil)
        #expect(failedSnapshot.statusText == "Ready to speak")
        #expect(failedSnapshot.httpServiceError == message)
        #expect(!failedSnapshot.settings.httpEnabled)
    }

    @Test
    func queuePoliciesPreserveFIFOAndCancelReplacedWork() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let service = try SayItBackendService(
            directories: AppDirectories.testing(root: root),
            playback: MockPlaybackController()
        )
        await service.start()

        let active = try submittedJob(
            await service.handle(
                ServiceRequest(
                    command: .submit(
                        SpeechSubmission(
                            text: String(repeating: "Long speech. ", count: 5_000),
                            source: .frontend
                        )
                    )
                )
            )
        )
        try await waitForState(
            .awaitingConfirmation,
            jobID: active.id,
            service: service
        )

        let firstQueued = try submittedJob(
            await service.handle(
                ServiceRequest(
                    command: .submit(
                        SpeechSubmission(
                            text: "First queued speech",
                            source: .frontend
                        )
                    )
                )
            )
        )
        let secondQueued = try submittedJob(
            await service.handle(
                ServiceRequest(
                    command: .submit(
                        SpeechSubmission(
                            text: "Second queued speech",
                            source: .frontend
                        )
                    )
                )
            )
        )

        let queuedSnapshot = try snapshot(
            await service.handle(ServiceRequest(command: .snapshot))
        )
        #expect(
            queuedSnapshot.queuedJobs.map(\.id)
                == [firstQueued.id, secondQueued.id]
        )

        let replacement = try submittedJob(
            await service.handle(
                ServiceRequest(
                    command: .submit(
                        SpeechSubmission(
                            text: String(
                                repeating: "Replacement speech. ",
                                count: 3_000
                            ),
                            source: .frontend,
                            queuePolicy: .replaceAll
                        )
                    )
                )
            )
        )
        let replacementSnapshot = try snapshot(
            await service.handle(ServiceRequest(command: .snapshot))
        )
        #expect(replacementSnapshot.activeJob?.id == replacement.id)
        #expect(replacementSnapshot.queuedJobs.isEmpty)

        let jobs = try jobList(
            await service.handle(ServiceRequest(command: .jobs))
        )
        #expect(
            jobs.first(where: { $0.id == active.id })?.state == .canceled
        )
        #expect(
            jobs.first(where: { $0.id == firstQueued.id })?.state == .canceled
        )
        #expect(
            jobs.first(where: { $0.id == secondQueued.id })?.state == .canceled
        )
    }

    @Test
    func unfinishedJobsDoNotStartAfterServiceRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let original = try SayItBackendService(
            directories: AppDirectories.testing(root: root),
            playback: MockPlaybackController()
        )
        await original.start()
        let active = try submittedJob(
            await original.handle(
                ServiceRequest(
                    command: .submit(
                        SpeechSubmission(
                            text: String(
                                repeating: "Persistent speech. ",
                                count: 5_000
                            ),
                            source: .service
                        )
                    )
                )
            )
        )
        try await waitForState(
            .awaitingConfirmation,
            jobID: active.id,
            service: original
        )
        let queued = try submittedJob(
            await original.handle(
                ServiceRequest(
                    command: .submit(
                        SpeechSubmission(
                            text: "Queued after the persistent job.",
                            source: .frontend
                        )
                    )
                )
            )
        )

        let restored = try SayItBackendService(
            directories: AppDirectories.testing(root: root),
            playback: MockPlaybackController()
        )
        await restored.start()
        let restoredSnapshot = try snapshot(
            await restored.handle(ServiceRequest(command: .snapshot))
        )
        #expect(restoredSnapshot.activeJob == nil)
        #expect(restoredSnapshot.queuedJobs.isEmpty)
        #expect(restoredSnapshot.playback.state == PlaybackState.idle.rawValue)

        let restoredJobs = try jobList(
            await restored.handle(ServiceRequest(command: .jobs))
        )
        #expect(
            restoredJobs.first(where: { $0.id == active.id })?.state
                == .canceled
        )
        #expect(
            restoredJobs.first(where: { $0.id == queued.id })?.state
                == .canceled
        )

        let freshServiceJob = try submittedJob(
            await restored.handle(
                ServiceRequest(
                    command: .submit(
                        SpeechSubmission(
                            text: String(
                                repeating: "Fresh service speech. ",
                                count: 5_000
                            ),
                            source: .service
                        )
                    )
                )
            )
        )
        try await waitForState(
            .awaitingConfirmation,
            jobID: freshServiceJob.id,
            service: restored
        )
        let serviceSnapshot = try snapshot(
            await restored.handle(ServiceRequest(command: .snapshot))
        )
        #expect(serviceSnapshot.activeJob?.id == freshServiceJob.id)
    }

    private func waitForState(
        _ state: SpeechJobState,
        jobID: UUID,
        service: SayItBackendService
    ) async throws {
        for _ in 0..<200 {
            let jobs = try jobList(
                await service.handle(ServiceRequest(command: .jobs))
            )
            if jobs.first(where: { $0.id == jobID })?.state == state {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The job did not reach \(state.rawValue).")
    }

    private func submittedJob(_ response: ServiceResponse) throws -> SpeechJob {
        guard case .job(let job) = response else {
            Issue.record("Expected a submitted job.")
            throw ServiceFailure(
                code: "test.invalid_response",
                message: "Expected a submitted job."
            )
        }
        return job
    }

    private func snapshot(
        _ response: ServiceResponse
    ) throws -> ServiceSnapshot {
        guard case .snapshot(let snapshot) = response else {
            Issue.record("Expected a service snapshot.")
            throw ServiceFailure(
                code: "test.invalid_response",
                message: "Expected a service snapshot."
            )
        }
        return snapshot
    }

    private func jobList(
        _ response: ServiceResponse
    ) throws -> [SpeechJob] {
        guard case .jobs(let jobs) = response else {
            Issue.record("Expected a job list.")
            throw ServiceFailure(
                code: "test.invalid_response",
                message: "Expected a job list."
            )
        }
        return jobs
    }
}

@MainActor
private final class MockPlaybackController: BackendPlaybackControlling {
    var onFailure: (@MainActor (String) -> Void)?
    private(set) var state: PlaybackState = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var generatedDuration: TimeInterval = 0
    private(set) var estimatedDuration: TimeInterval = 0
    private(set) var amplitudes: [Float] = []
    private(set) var currentTitle = ""
    private(set) var spokenText = ""
    private(set) var spokenChunks: [PlaybackTextChunk] = []
    var shouldStartWhenBuffered = false
    var showTitleInNowPlaying = false
    var rate: Double = 1
    var backwardSkipInterval: TimeInterval = 15
    var forwardSkipInterval: TimeInterval = 30

    func prepare(
        requestID: UUID,
        title: String,
        estimatedDuration: TimeInterval
    ) {
        currentTitle = title
        self.estimatedDuration = estimatedDuration
        state = .preparing
    }

    func enqueue(_ chunk: AudioChunk) throws {
        generatedDuration += Double(chunk.samples.count) / chunk.sampleRate
        state = .buffering
    }

    func setSpokenText(_ text: String) {
        spokenText = text
        spokenChunks = []
    }

    func appendSpokenChunk(_ chunk: PlaybackTextChunk) {
        spokenChunks.append(chunk)
    }

    func play() {
        state = .playing
    }

    func pause() {
        state = .paused
    }

    func stop() {
        state = .idle
        elapsed = 0
        generatedDuration = 0
        estimatedDuration = 0
        currentTitle = ""
    }

    func seek(to seconds: TimeInterval) {
        elapsed = seconds
    }

    func skip(by seconds: TimeInterval) {
        elapsed += seconds
    }

    func finishBuffering() {
        state = .playing
    }

    func archive(
        using archive: AudioArchive
    ) async throws -> AudioArchiveResult {
        throw ServiceFailure(
            code: "test.archive_unavailable",
            message: "Archiving is not used by queue tests."
        )
    }

    func playFile(at url: URL, title: String) throws {
        currentTitle = title
        state = .playing
    }
}
