import Darwin
import Foundation
import SayItBackend
import SayItCore
import SayItProtocol

@main
struct SayItAgentMain {
    @MainActor
    static func main() async {
        do {
            let directories = try AppDirectories.shared(
                appGroupIdentifier: SayItServiceIdentifiers.appGroup
            )
            armParentWatchdog(in: directories.applicationSupport)

            let version = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "0.1.0"
            let backend = try SayItBackendService(
                directories: directories,
                serviceVersion: version
            )
            await backend.start()

            let delegate = SayItAgentListenerDelegate(backend: backend)
            let listener = NSXPCListener(
                machServiceName: SayItServiceIdentifiers.machService
            )
            listener.delegate = delegate
            listener.resume()

            let httpSupervisor = HTTPServerSupervisor(backend: backend)
            httpSupervisor.start()

            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(3_600))
            }

            httpSupervisor.stop()
            listener.invalidate()
            withExtendedLifetime(delegate) {}
        } catch {
            FileHandle.standardError.write(
                Data("Say It service failed to start.\n".utf8)
            )
        }
    }

    private static func armParentWatchdog(in directory: URL) {
        guard let parentPID = ParentProcessFile.readPID(from: directory),
              parentPID > 1,
              parentPID != getpid(),
              ParentProcessFile.isAlive(parentPID) else {
            return
        }
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard ParentProcessFile.isAlive(parentPID) else {
                    exit(EXIT_SUCCESS)
                }
            }
        }
    }
}
