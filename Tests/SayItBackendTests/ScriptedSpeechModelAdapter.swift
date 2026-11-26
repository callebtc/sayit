import Foundation
import SayItCore
import Synchronization
@testable import SayItBackend

/// Errors a scripted speech-model adapter can be told to raise. The
/// `inputTooLong` case is the underlying error wrapped in the
/// `SpeechModelInputTooLongError` marker, matching the live adapter.
enum ScriptedSpeechModelError: Error, Equatable, Sendable {
    case inputTooLong
    case genericGeneration
    case loadFailed
    case prepareDependenciesFailed
}

/// Which generation failure a scripted call should raise.
enum ScriptedGenerationFailure: Sendable {
    case inputTooLong
    case generic

    func makeError() -> Error {
        switch self {
        case .inputTooLong:
            return SpeechModelInputTooLongError(
                underlyingError: ScriptedSpeechModelError.inputTooLong
            )
        case .generic:
            return ScriptedSpeechModelError.genericGeneration
        }
    }
}

/// One generation call made through the speech-model port, as recorded by
/// the scripted session. Tuning is flattened because
/// `VoiceSynthesisTuning` is not `Equatable`.
struct RecordedGenerationCall: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case oneShot
        case stream
    }

    let kind: Kind
    let text: String
    let voice: String?
    let referenceSamples: [Float]?
    let referenceTranscript: String?
    let language: String?
    let tuningPreset: String?
    let tuningParameters: [String: Double]?
    let seed: UInt64?
    /// Only set for one-shot calls; streams have no such argument.
    let allowTuningSelectedGeneration: Bool?

    var hasReference: Bool {
        referenceSamples != nil
    }

    init(
        kind: Kind,
        text: String,
        voice: String?,
        reference: SpeechModelReference?,
        language: String?,
        tuning: VoiceSynthesisTuning?,
        seed: UInt64?,
        allowTuningSelectedGeneration: Bool?
    ) {
        self.kind = kind
        self.text = text
        self.voice = voice
        referenceSamples = reference?.samples
        referenceTranscript = reference?.transcript
        self.language = language
        tuningPreset = tuning?.preset
        tuningParameters = tuning?.parameters
        self.seed = seed
        self.allowTuningSelectedGeneration =
            allowTuningSelectedGeneration
    }
}

/// Scripted `SpeechModelLoading` adapter: returns its scripted session for
/// every load, records loads and dependency preparations, and can be told
/// to fail them.
final class ScriptedSpeechModelLoader: SpeechModelLoading,
    @unchecked Sendable {
    private struct State {
        var loadedModelIDs: [ModelID] = []
        var loadedDirectories: [URL] = []
        var preparedModelIDs: [ModelID] = []
        var failsPrepareDependencies = false
    }

    private let session: ScriptedSpeechModelSession?
    private let state = Mutex(State())

    init(session: ScriptedSpeechModelSession?) {
        self.session = session
    }

    var loadCount: Int {
        state.withLock { $0.loadedModelIDs.count }
    }

    var loadedModelIDs: [ModelID] {
        state.withLock { $0.loadedModelIDs }
    }

    var loadedDirectories: [URL] {
        state.withLock { $0.loadedDirectories }
    }

    var preparedModelIDs: [ModelID] {
        state.withLock { $0.preparedModelIDs }
    }

    func failPrepareDependencies() {
        state.withLock { $0.failsPrepareDependencies = true }
    }

    func load(
        model: ModelDescriptor,
        directory: URL
    ) async throws -> any SpeechModelSession {
        state.withLock { state in
            state.loadedModelIDs.append(model.id)
            state.loadedDirectories.append(directory)
        }
        guard let session else {
            throw ScriptedSpeechModelError.loadFailed
        }
        return session
    }

    func prepareDependencies(for model: ModelDescriptor) async throws {
        let shouldFail = state.withLock { state -> Bool in
            state.preparedModelIDs.append(model.id)
            return state.failsPrepareDependencies
        }
        if shouldFail {
            throw ScriptedSpeechModelError.prepareDependenciesFailed
        }
    }
}

/// Scripted `SpeechModelSession` adapter. Calls are recorded in order;
/// one-shot and streamed results come from per-call queues, falling back
/// to a default batch of samples when a queue is empty.
final class ScriptedSpeechModelSession: SpeechModelSession,
    @unchecked Sendable {
    let sampleRate: Double

    private enum OneShotScript {
        case samples([Float])
        case failure(ScriptedGenerationFailure)
    }

    private enum StreamScript {
        case batches([[Float]])
        case failure(ScriptedGenerationFailure)
        case batchesThenFailure(
            [[Float]],
            ScriptedGenerationFailure
        )
        case gated(batchesBeforeGate: [[Float]])
    }

    private struct State {
        var generationCalls: [RecordedGenerationCall] = []
        var fittingCallTexts: [String] = []
        var appliedSpeakingPaces: [SpeakingPace] = []
        var quiesceCount = 0
        var shutdownCount = 0
        var oneShotScripts: [OneShotScript] = []
        var streamScripts: [StreamScript] = []
        var fittingCharacterLimit: Int?
        var isWaitingAtGate = false
    }

    private let state = Mutex(State())

    init(sampleRate: Double = 24_000) {
        self.sampleRate = sampleRate
    }

    // MARK: - Recorded outcomes

    var generationCalls: [RecordedGenerationCall] {
        state.withLock { $0.generationCalls }
    }

    var oneShotCalls: [RecordedGenerationCall] {
        generationCalls.filter { $0.kind == .oneShot }
    }

    var streamCalls: [RecordedGenerationCall] {
        generationCalls.filter { $0.kind == .stream }
    }

    var fittingCallTexts: [String] {
        state.withLock { $0.fittingCallTexts }
    }

    var appliedSpeakingPaces: [SpeakingPace] {
        state.withLock { $0.appliedSpeakingPaces }
    }

    var quiesceCount: Int {
        state.withLock { $0.quiesceCount }
    }

    var shutdownCount: Int {
        state.withLock { $0.shutdownCount }
    }

    var isWaitingAtGate: Bool {
        state.withLock { $0.isWaitingAtGate }
    }

    // MARK: - Scripting

    func enqueueOneShotSamples(_ samples: [Float]) {
        state.withLock { $0.oneShotScripts.append(.samples(samples)) }
    }

    func enqueueOneShotFailure(_ failure: ScriptedGenerationFailure) {
        state.withLock { $0.oneShotScripts.append(.failure(failure)) }
    }

    func enqueueStreamBatches(_ batches: [[Float]]) {
        state.withLock { $0.streamScripts.append(.batches(batches)) }
    }

    func enqueueStreamFailure(_ failure: ScriptedGenerationFailure) {
        state.withLock { $0.streamScripts.append(.failure(failure)) }
    }

    func enqueueStream(
        batches: [[Float]],
        thenFailure failure: ScriptedGenerationFailure
    ) {
        state.withLock {
            $0.streamScripts.append(.batchesThenFailure(batches, failure))
        }
    }

    /// The next streamed call yields `batchesBeforeGate`, then parks
    /// until its task is cancelled. This is how tests hold an operation
    /// active while they supersede or unload it.
    func enqueueGatedStream(batchesBeforeGate: [[Float]]) {
        state.withLock {
            $0.streamScripts.append(
                .gated(batchesBeforeGate: batchesBeforeGate)
            )
        }
    }

    /// Split chunks with the caller's chunker so no piece sent to
    /// generation exceeds this many characters, like the live adapter's
    /// processed-text budget.
    func scriptFittingCharacterLimit(_ limit: Int) {
        state.withLock { $0.fittingCharacterLimit = limit }
    }

    /// One default batch: a tenth of a second of constant samples.
    var defaultBatch: [Float] {
        [Float](repeating: 0.1, count: max(Int(sampleRate / 10), 1))
    }

    // MARK: - SpeechModelSession

    func generateSamples(
        text: String,
        voice: String?,
        reference: SpeechModelReference?,
        language: String?,
        tuning: VoiceSynthesisTuning?,
        seed: UInt64?,
        allowTuningSelectedGeneration: Bool
    ) async throws -> [Float] {
        let script = state.withLock { state -> OneShotScript? in
            state.generationCalls.append(
                RecordedGenerationCall(
                    kind: .oneShot,
                    text: text,
                    voice: voice,
                    reference: reference,
                    language: language,
                    tuning: tuning,
                    seed: seed,
                    allowTuningSelectedGeneration:
                        allowTuningSelectedGeneration
                )
            )
            return state.oneShotScripts.isEmpty
                ? nil
                : state.oneShotScripts.removeFirst()
        }
        switch script {
        case .samples(let samples):
            return samples
        case .failure(let failure):
            throw failure.makeError()
        case nil:
            return defaultBatch
        }
    }

    func generateSamplesStream(
        text: String,
        voice: String?,
        reference: SpeechModelReference?,
        language: String?,
        tuning: VoiceSynthesisTuning?,
        seed: UInt64?
    ) -> AsyncThrowingStream<[Float], Error> {
        let script = state.withLock { state -> StreamScript? in
            state.generationCalls.append(
                RecordedGenerationCall(
                    kind: .stream,
                    text: text,
                    voice: voice,
                    reference: reference,
                    language: language,
                    tuning: tuning,
                    seed: seed,
                    allowTuningSelectedGeneration: nil
                )
            )
            return state.streamScripts.isEmpty
                ? nil
                : state.streamScripts.removeFirst()
        }
        switch script {
        case .batches(let batches):
            return Self.stream(yielding: batches)
        case .failure(let failure):
            return Self.stream(yielding: [], thenThrowing: failure)
        case .batchesThenFailure(let batches, let failure):
            return Self.stream(yielding: batches, thenThrowing: failure)
        case .gated(let before):
            return gatedStream(before: before)
        case nil:
            return Self.stream(yielding: [defaultBatch])
        }
    }

    func fittingPieces(
        for chunk: SpeechChunk,
        language: String?,
        voice: String?,
        chunker: TextChunker
    ) async throws -> [SpeechChunk] {
        let limit = state.withLock { state -> Int? in
            state.fittingCallTexts.append(chunk.text)
            return state.fittingCharacterLimit
        }
        guard let limit else {
            return [chunk]
        }
        return chunker.fittingPieces(for: chunk) { $0.count <= limit }
    }

    func applySpeakingPace(_ pace: SpeakingPace) throws {
        state.withLock { $0.appliedSpeakingPaces.append(pace) }
    }

    func quiesce() {
        state.withLock { $0.quiesceCount += 1 }
    }

    func shutdown() {
        state.withLock { $0.shutdownCount += 1 }
    }

    private static func stream(
        yielding batches: [[Float]],
        thenThrowing failure: ScriptedGenerationFailure? = nil
    ) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { continuation in
            for batch in batches {
                continuation.yield(batch)
            }
            if let failure {
                continuation.finish(throwing: failure.makeError())
            } else {
                continuation.finish()
            }
        }
    }

    private func gatedStream(
        before: [[Float]]
    ) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for batch in before {
                        continuation.yield(batch)
                    }
                    self.state.withLock { $0.isWaitingAtGate = true }
                    while true {
                        try Task.checkCancellation()
                        await Task.yield()
                    }
                } catch {
                    self.state.withLock { $0.isWaitingAtGate = false }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}

/// Controllable `SynthesisClock`. In the default auto-advance mode a sleep
/// records its duration, advances `now` by it, and returns after a yield.
/// In manual mode a sleep records its duration and then parks until the
/// test advances `now` past its deadline with `advance(by:)`, which is
/// how idle-unload timing is driven on demand without real-time waits.
final class ControllableSynthesisClock: SynthesisClock,
    @unchecked Sendable {
    private struct State {
        var instant: ContinuousClock.Instant
        var sleeps: [Duration] = []
        let autoAdvance: Bool
    }

    private let state: Mutex<State>

    init(autoAdvance: Bool = true) {
        state = Mutex(
            State(instant: ContinuousClock.now, autoAdvance: autoAdvance)
        )
    }

    var now: ContinuousClock.Instant {
        state.withLock { $0.instant }
    }

    var recordedSleeps: [Duration] {
        state.withLock { $0.sleeps }
    }

    func advance(by duration: Duration) {
        state.withLock {
            $0.instant = $0.instant.advanced(by: duration)
        }
    }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        let deadline = state.withLock { state -> ContinuousClock.Instant in
            state.sleeps.append(duration)
            if state.autoAdvance {
                state.instant = state.instant.advanced(by: duration)
            }
            return state.instant.advanced(
                by: state.autoAdvance ? .zero : duration
            )
        }
        await Task.yield()
        while now < deadline {
            try Task.checkCancellation()
            await Task.yield()
        }
        try Task.checkCancellation()
    }
}
