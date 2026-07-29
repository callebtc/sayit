import Foundation
import SayItBackend
import SayItHTTP
import SayItProtocol

@MainActor
final class HTTPServerSupervisor {
    private let backend: SayItBackendService
    private var monitorTask: Task<Void, Never>?
    private var serverTask: Task<Void, Never>?
    private var activePort: Int?

    init(backend: SayItBackendService) {
        self.backend = backend
    }

    func start() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.synchronize()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        serverTask?.cancel()
        serverTask = nil
        activePort = nil
    }

    private func synchronize() async {
        let response = await backend.handle(
            ServiceRequest(command: .snapshot)
        )
        guard case .snapshot(let snapshot) = response else { return }

        guard snapshot.settings.httpEnabled else {
            serverTask?.cancel()
            serverTask = nil
            activePort = nil
            return
        }
        guard activePort != snapshot.settings.httpPort || serverTask == nil else {
            return
        }

        serverTask?.cancel()
        activePort = snapshot.settings.httpPort
        do {
            let server = try SayItHTTPServer(
                backend: backend,
                port: snapshot.settings.httpPort
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
            await backend.reportHTTPServiceError(
                "HTTP API could not start: \(error.localizedDescription)"
            )
        }
    }
}
