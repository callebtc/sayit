import Foundation

struct PlaybackNowPlayingInfo: Equatable, Sendable {
    let title: String
    let duration: TimeInterval
    let elapsed: TimeInterval
    let playbackRate: Double
}
