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
            let parentPID = monitoredParentPID(
                in: directories.applicationSupport
            )

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

            await waitForTermination(parentPID: parentPID)

            listener.invalidate()
            httpSupervisor.stop()
            await backend.shutdown()
            withExtendedLifetime(delegate) {}
        } catch {
            FileHandle.standardError.write(
                Data("Say It service failed to start.\n".utf8)
            )
        }
    }

    private static func monitoredParentPID(in directory: URL) -> pid_t? {
        guard let parentPID = ParentProcessFile.readPID(from: directory),
              parentPID > 1,
              parentPID != getpid(),
              ParentProcessFile.isAlive(parentPID) else {
            return nil
        }
        return parentPID
    }

    private static func waitForTermination(parentPID: pid_t?) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            if let parentPID,
               !ParentProcessFile.isAlive(parentPID) {
                return
            }
        }
    }
}
