import Foundation
import SayItCore
import SayItProtocol

@MainActor
protocol BackendPlaybackControlling: PlaybackControlling {
    var onFailure: (@MainActor (String) -> Void)? { get set }
    var state: PlaybackState { get }
    var elapsed: TimeInterval { get }
    var generatedDuration: TimeInterval { get }
    var estimatedDuration: TimeInterval { get }
    var amplitudes: [Float] { get }
    var currentTitle: String { get }
    var spokenText: String { get }
    var spokenChunks: [PlaybackTextChunk] { get }
    var shouldStartWhenBuffered: Bool { get }
    var showTitleInNowPlaying: Bool { get set }
    var rate: Double { get set }
    var backwardSkipInterval: TimeInterval { get set }
    var forwardSkipInterval: TimeInterval { get set }

    func prepare(
        requestID: UUID,
        title: String,
        estimatedDuration: TimeInterval
    )
    func setSpokenText(_ text: String)
    func appendSpokenChunk(_ chunk: PlaybackTextChunk)
    func stopForModelSwitch() async
    func finishBuffering()
    func archive(using archive: AudioArchive) async throws -> AudioArchiveResult
    func playFile(at url: URL, title: String) throws
}
