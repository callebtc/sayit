import Foundation
import SayItCore

@MainActor
protocol OtherAudioRouting: AnyObject {
    var onOutputDeviceChange: (@MainActor () -> Void)? { get set }
    func setGain(_ gain: Float, rampDuration: TimeInterval)
    func stop()
}

/// Lowers other apps' audio while Say It is speaking and restores it shortly
/// after speech stops. The short hold bridges gaps between queued items.
@MainActor
final class OtherAudioDucker {
    static let duckRampDuration: TimeInterval = 0.25
    static let restoreRampDuration: TimeInterval = 0.5
    static let restoreDelay: Duration = .milliseconds(800)

    static func shouldDuck(during state: PlaybackState) -> Bool {
        switch state {
        case .playing, .buffering:
            true
        case .idle, .preparing, .paused, .finished, .failed:
            false
        }
    }

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            reconcile()
        }
    }
    var level: Double = 0.2 {
        didSet {
            guard level != oldValue, let router, restoreTask == nil else {
                return
            }
            router.setGain(gain, rampDuration: Self.duckRampDuration)
        }
    }
    var onFailure: (@MainActor (any Error) -> Void)?

    private let makeRouter: @MainActor () throws -> any OtherAudioRouting
    private let sleep: @Sendable (Duration) async throws -> Void
    private var router: (any OtherAudioRouting)?
    private var restoreTask: Task<Void, Never>?
    private var isSpeaking = false
    private var hasReportedFailure = false

    init(
        makeRouter: @escaping @MainActor () throws -> any OtherAudioRouting = {
            try SystemAudioDuckingRouter()
        },
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.makeRouter = makeRouter
        self.sleep = sleep
    }

    var isDucking: Bool { router != nil && restoreTask == nil }

    func playbackStateDidChange(_ state: PlaybackState) {
        isSpeaking = Self.shouldDuck(during: state)
        reconcile()
    }

    /// Rebuilds the route, for example after the default output device changes.
    func outputDeviceDidChange() {
        guard router != nil else { return }
        tearDown()
        reconcile()
    }

    private var gain: Float { Float(min(max(level, 0), 1)) }

    private func reconcile() {
        if isEnabled && isSpeaking {
            duck()
        } else if !isEnabled {
            tearDown()
        } else {
            scheduleRestore()
        }
    }

    private func duck() {
        restoreTask?.cancel()
        restoreTask = nil
        if router == nil {
            do {
                let router = try makeRouter()
                router.onOutputDeviceChange = { [weak self] in
                    self?.outputDeviceDidChange()
                }
                self.router = router
                hasReportedFailure = false
            } catch {
                reportFailure(error)
                return
            }
        }
        router?.setGain(gain, rampDuration: Self.duckRampDuration)
    }

    private func scheduleRestore() {
        guard router != nil, restoreTask == nil else { return }
        let sleep = sleep
        restoreTask = Task { [weak self] in
            do {
                try await sleep(Self.restoreDelay)
                self?.router?.setGain(1, rampDuration: Self.restoreRampDuration)
                try await sleep(.seconds(Self.restoreRampDuration))
            } catch {
                return
            }
            self?.tearDown()
        }
    }

    private func tearDown() {
        restoreTask?.cancel()
        restoreTask = nil
        router?.stop()
        router = nil
    }

    private func reportFailure(_ error: any Error) {
        // Report once until a route starts again, not for every queued item.
        guard !hasReportedFailure else { return }
        hasReportedFailure = true
        onFailure?(error)
    }
}
