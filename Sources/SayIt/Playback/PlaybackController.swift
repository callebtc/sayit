import Foundation
import Observation
import SayItCore
import SayItProtocol

@MainActor
@Observable
final class PlaybackController {
    private(set) var state: PlaybackState = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var generatedDuration: TimeInterval = 0
    private(set) var estimatedDuration: TimeInterval = 0
    private(set) var amplitudes: [Float] = []
    private(set) var currentTitle = ""
    private(set) var modelID: ModelID?
    private(set) var spokenText = ""
    private(set) var spokenChunks: [PlaybackTextChunk] = []
    var rate: Double = 1 {
        didSet {
            guard rate != oldValue else { return }
            commandHandler?(.setPlaybackRate(rate))
        }
    }
    var showTitleInNowPlaying = false
    var backwardSkipInterval: TimeInterval = 15
    var forwardSkipInterval: TimeInterval = 30

    @ObservationIgnored
    var commandHandler: ((ServiceCommand) -> Void)?

    func apply(_ snapshot: PlaybackSnapshot) {
        state = PlaybackState(rawValue: snapshot.state) ?? .idle
        elapsed = snapshot.elapsed
        generatedDuration = snapshot.generatedDuration
        estimatedDuration = snapshot.estimatedDuration
        if snapshot.includesContent {
            amplitudes = snapshot.amplitudes
            currentTitle = snapshot.currentTitle
            modelID = snapshot.modelID.map { ModelID($0) }
            spokenText = snapshot.spokenText
            spokenChunks = snapshot.spokenChunks
        }
        if rate != snapshot.rate {
            let handler = commandHandler
            commandHandler = nil
            rate = snapshot.rate
            commandHandler = handler
        }
    }

    func play() {
        commandHandler?(.play)
    }

    func pause() {
        commandHandler?(.pause)
    }

    func stop() {
        commandHandler?(.clear)
    }

    func seek(to seconds: TimeInterval) {
        commandHandler?(.seek(seconds))
    }

    func skip(by seconds: TimeInterval) {
        commandHandler?(.skip(seconds))
    }
}
