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
    var volume: Double = 1 {
        didSet {
            guard volume != oldValue else { return }
            commandHandler?(.setVolume(volume))
        }
    }
    var showTitleInNowPlaying = false
    var backwardSkipInterval: TimeInterval = 15
    var forwardSkipInterval: TimeInterval = 30

    @ObservationIgnored
    var commandHandler: ((ServiceCommand) -> Void)?

    func apply(_ snapshot: PlaybackSnapshot) {
        let nextState = PlaybackState(rawValue: snapshot.state) ?? .idle
        if state != nextState {
            state = nextState
        }
        if elapsed != snapshot.elapsed {
            elapsed = snapshot.elapsed
        }
        if generatedDuration != snapshot.generatedDuration {
            generatedDuration = snapshot.generatedDuration
        }
        if estimatedDuration != snapshot.estimatedDuration {
            estimatedDuration = snapshot.estimatedDuration
        }
        if snapshot.includesContent {
            if amplitudes != snapshot.amplitudes {
                amplitudes = snapshot.amplitudes
            }
            if currentTitle != snapshot.currentTitle {
                currentTitle = snapshot.currentTitle
            }
            let nextModelID = snapshot.modelID.map { ModelID($0) }
            if modelID != nextModelID {
                modelID = nextModelID
            }
            if spokenText != snapshot.spokenText {
                spokenText = snapshot.spokenText
            }
            if spokenChunks != snapshot.spokenChunks {
                spokenChunks = snapshot.spokenChunks
            }
        }
        if rate != snapshot.rate {
            let handler = commandHandler
            commandHandler = nil
            rate = snapshot.rate
            commandHandler = handler
        }
        if volume != snapshot.volume {
            let handler = commandHandler
            commandHandler = nil
            volume = snapshot.volume
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
