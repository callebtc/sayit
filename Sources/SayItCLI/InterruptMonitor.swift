import Darwin
import Dispatch

final class InterruptMonitor: @unchecked Sendable {
    private let state = InterruptState()
    private let source: DispatchSourceSignal

    init() {
        signal(SIGINT, SIG_IGN)
        source = DispatchSource.makeSignalSource(
            signal: SIGINT,
            queue: .global(qos: .userInitiated)
        )
        let state = state
        source.setEventHandler {
            Task {
                await state.markInterrupted()
            }
        }
        source.resume()
    }

    deinit {
        source.cancel()
        signal(SIGINT, SIG_DFL)
    }

    func consume() async -> Bool {
        await state.consume()
    }
}
