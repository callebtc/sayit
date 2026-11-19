import Foundation
@preconcurrency import MediaPlayer
import SayItCore

@MainActor
final class LivePlaybackMediaSession: PlaybackMediaSession {
    private final class TargetRegistry: @unchecked Sendable {
        private struct Entry {
            let command: MPRemoteCommand
            let target: Any
        }

        private let lock = NSLock()
        private var entries: [Entry] = []

        func register(_ target: Any, on command: MPRemoteCommand) {
            lock.withLock {
                entries.append(Entry(command: command, target: target))
            }
        }

        func removeAll() {
            let current = lock.withLock { () -> [Entry] in
                let existing = entries
                entries.removeAll(keepingCapacity: false)
                return existing
            }
            for entry in current {
                entry.command.removeTarget(entry.target)
            }
        }
    }

    private let registry = TargetRegistry()

    deinit {
        registry.removeAll()
    }

    func publishNowPlaying(_ info: PlaybackNowPlayingInfo) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: info.title,
            MPMediaItemPropertyPlaybackDuration: info.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: info.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: info.playbackRate
        ]
    }

    func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func configureRemoteCommands(
        supportedPlaybackRates: [Double],
        backwardSkipInterval: TimeInterval,
        forwardSkipInterval: TimeInterval,
        handler: @escaping @MainActor @Sendable (PlaybackRemoteCommand) -> Void
    ) {
        clearRemoteCommands()
        let commands = MPRemoteCommandCenter.shared()
        registerSimple(commands.playCommand, command: .play, handler: handler)
        registerSimple(commands.pauseCommand, command: .pause, handler: handler)
        registerSimple(
            commands.togglePlayPauseCommand,
            command: .togglePlayPause,
            handler: handler
        )
        registerSimple(commands.stopCommand, command: .stop, handler: handler)
        registerSimple(
            commands.nextTrackCommand,
            command: .nextTrack,
            handler: handler
        )
        registerSimple(
            commands.previousTrackCommand,
            command: .previousTrack,
            handler: handler
        )

        commands.skipBackwardCommand.preferredIntervals = [
            NSNumber(value: backwardSkipInterval)
        ]
        registerSimple(
            commands.skipBackwardCommand,
            command: .skipBackward,
            handler: handler
        )

        commands.skipForwardCommand.preferredIntervals = [
            NSNumber(value: forwardSkipInterval)
        ]
        registerSimple(
            commands.skipForwardCommand,
            command: .skipForward,
            handler: handler
        )

        let positionToken = commands.changePlaybackPositionCommand.addTarget { event in
            guard let position = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let positionTime = position.positionTime
            Task { @MainActor in
                handler(.seek(positionTime))
            }
            return .success
        }
        registry.register(
            positionToken,
            on: commands.changePlaybackPositionCommand
        )

        commands.changePlaybackRateCommand.supportedPlaybackRates =
            supportedPlaybackRates.map { NSNumber(value: $0) }
        let rateToken = commands.changePlaybackRateCommand.addTarget { event in
            guard let rateEvent = event as? MPChangePlaybackRateCommandEvent,
                  PlaybackRate.isSupported(Double(rateEvent.playbackRate)) else {
                return .commandFailed
            }
            let playbackRate = Double(rateEvent.playbackRate)
            Task { @MainActor in
                handler(.changePlaybackRate(playbackRate))
            }
            return .success
        }
        registry.register(
            rateToken,
            on: commands.changePlaybackRateCommand
        )
    }

    func setBackwardSkipInterval(_ interval: TimeInterval) {
        MPRemoteCommandCenter.shared()
            .skipBackwardCommand.preferredIntervals = [
                NSNumber(value: interval)
            ]
    }

    func setForwardSkipInterval(_ interval: TimeInterval) {
        MPRemoteCommandCenter.shared()
            .skipForwardCommand.preferredIntervals = [
                NSNumber(value: interval)
            ]
    }

    func clearRemoteCommands() {
        registry.removeAll()
    }

    private func registerSimple(
        _ remoteCommand: MPRemoteCommand,
        command: PlaybackRemoteCommand,
        handler: @escaping @MainActor @Sendable (PlaybackRemoteCommand) -> Void
    ) {
        let token = remoteCommand.addTarget { _ in
            Task { @MainActor in
                handler(command)
            }
            return .success
        }
        registry.register(token, on: remoteCommand)
    }
}
