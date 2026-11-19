import Foundation

@MainActor
protocol PlaybackMediaSession: AnyObject, Sendable {
    func publishNowPlaying(_ info: PlaybackNowPlayingInfo)
    func clearNowPlaying()
    func configureRemoteCommands(
        supportedPlaybackRates: [Double],
        backwardSkipInterval: TimeInterval,
        forwardSkipInterval: TimeInterval,
        handler: @escaping @MainActor @Sendable (PlaybackRemoteCommand) -> Void
    )
    func setBackwardSkipInterval(_ interval: TimeInterval)
    func setForwardSkipInterval(_ interval: TimeInterval)
}
