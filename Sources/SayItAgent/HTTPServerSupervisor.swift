import Foundation
import SayItBackend
import SayItHTTP

@MainActor
final class HTTPServerSupervisor {
    private let backend: SayItBackendService
    private var serverTask: Task<Void, Never>?
    private var activePort: Int?
    private var isStarted = false

    init(backend: SayItBackendService) {
        self.backend = backend
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        backend.setHTTPServiceConfigurationHandler { [weak self] configuration in
            self?.synchronize(configuration)
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        backend.setHTTPServiceConfigurationHandler(nil)
        serverTask?.cancel()
        serverTask = nil
        activePort = nil
    }

    private func synchronize(_ configuration: HTTPServiceConfiguration) {
        guard configuration.isEnabled else {
            serverTask?.cancel()
            serverTask = nil
            activePort = nil
            return
        }
        guard activePort != configuration.port || serverTask == nil else {
            return
        }

        serverTask?.cancel()
        activePort = configuration.port
        do {
            let server = try SayItHTTPServer(
                backend: backend,
                port: configuration.port
            )
            serverTask = Task {
                do {
                    try await server.run()
                } catch is CancellationError {
                    return
                } catch {
                    await backend.reportHTTPServiceError(
                        "HTTP API could not start: \(error.localizedDescription)"
                    )
                }
            }
        } catch {
            activePort = nil
            let message = "HTTP API could not start: \(error.localizedDescription)"
            Task {
                await backend.reportHTTPServiceError(message)
            }
        }
    }
}
