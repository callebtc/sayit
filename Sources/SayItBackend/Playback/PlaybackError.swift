import Foundation


enum PlaybackError: LocalizedError {
    case emptyAudio
    case invalidSampleRate
    case inconsistentSampleRate
    case invalidSamples
    case audioTooLarge
    case audioFormatMismatch
    case noOutputDevice
    case couldNotStartEngine
    case unsupportedAudioFile

    var errorDescription: String? {
        switch self {
        case .emptyAudio:
            "The speech model produced no playable audio."
        case .invalidSampleRate, .inconsistentSampleRate:
            "The speech model produced audio at an unsupported sample rate."
        case .invalidSamples:
            "The speech model produced invalid audio samples."
        case .audioTooLarge:
            "This audio is too large to play as one segment."
        case .audioFormatMismatch:
            "Say It could not match the speech audio to the current output device."
        case .noOutputDevice:
            "No audio output device is available. Connect one and try again."
        case .couldNotStartEngine:
            "Say It could not start audio playback. Check the current output device and try again."
        case .unsupportedAudioFile:
            "This history audio file could not be read."
        }
    }
}
