import Foundation

enum PlaybackRemoteCommand: Equatable, Sendable {
    case play
    case pause
    case togglePlayPause
    case stop
    case nextTrack
    case previousTrack
    case skipBackward
    case skipForward
    case seek(TimeInterval)
    case changePlaybackRate(Double)
}
