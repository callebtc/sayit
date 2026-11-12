import Foundation
import SayItCore

/// Collects a silent synthesis job without configuring an audio output graph.
final class SpeechAudioCollector {
    private let requestID: UUID
    private let directory: URL
    private var store: PCMStore?

    init(requestID: UUID, directory: URL) {
        self.requestID = requestID
        self.directory = directory
    }

    func append(_ chunk: AudioChunk) throws {
        guard chunk.requestID == requestID else { return }
        guard !chunk.samples.isEmpty else { throw PlaybackError.emptyAudio }
        guard chunk.sampleRate.isFinite, chunk.sampleRate > 0 else {
            throw PlaybackError.invalidSampleRate
        }
        if let store, abs(store.sampleRate - chunk.sampleRate) > 0.5 {
            throw PlaybackError.inconsistentSampleRate
        }
        if store == nil {
            store = try PCMStore(sampleRate: chunk.sampleRate, directory: directory)
        }
        try store?.append(chunk.samples)
    }

    func snapshot() throws -> PCMStoreSnapshot {
        guard let store, store.frameCount > 0 else {
            throw SynthesisError.generatedNoAudio
        }
        return try store.snapshot()
    }
}
