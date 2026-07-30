import Foundation

public enum VoiceRecordingError: LocalizedError, Equatable, Sendable {
    case unreadable
    case noAudioDevice
    case silent
    case clipped
    case nonFinite
    case outOfRange
    case tooShort(minimum: TimeInterval)
    case tooLong(maximum: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .unreadable:
            "The recording could not be read. Record the passage again."
        case .noAudioDevice:
            "No microphone is available. Connect or enable an input device, then try again."
        case .silent:
            "The recording is too quiet. Move closer to the microphone and speak at a comfortable volume."
        case .clipped:
            "The recording is distorted. Move farther from the microphone or lower its input level."
        case .nonFinite:
            "The recording contains invalid audio. Reconnect the microphone and record again."
        case .outOfRange:
            "The recording format is outside the supported range. Choose a standard microphone input and record again."
        case .tooShort(let minimum):
            "Keep speaking for at least \(minimum.formatted(.number.precision(.fractionLength(0)))) seconds."
        case .tooLong(let maximum):
            "Keep the recording under \(maximum.formatted(.number.precision(.fractionLength(0)))) seconds."
        }
    }
}
