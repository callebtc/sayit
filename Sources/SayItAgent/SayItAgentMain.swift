import Darwin
import Foundation
import SayItBackend
import SayItCore
import SayItProtocol

@main
struct SayItAgentMain {
    @MainActor
    static func main() async {
        // Set before MLX's first operation; its TF32 preference is cached once.
        // Full float32 keeps the incremental DAC waveform consistent with a
        // whole decode on hardware supporting reduced-precision float32 GEMM.
        setenv("MLX_ENABLE_TF32", "0", 1)
        let termination = AgentTerminationMonitor()
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
            if let requirement = delegate.codeSigningRequirement {
                listener.setConnectionCodeSigningRequirement(requirement)
            }
            listener.delegate = delegate
            listener.resume()

            let httpSupervisor = HTTPServerSupervisor(backend: backend)
            httpSupervisor.start()

            await termination.wait(parentPID: parentPID)

            listener.invalidate()
            async let httpShutdown: Void = httpSupervisor.stopAndWait()
            await backend.shutdown()
            await httpShutdown
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
}
