#if DEBUG || SAYIT_LOCAL_BUILD
import Foundation
import SayItProtocol
import SayItXPC

enum DevelopmentServiceLauncher {
    private static let label = "sh.sayit.mac.agent.debug"

    static func ensureRunning(agentURL: URL) async throws {
        try await jobManager(agentURL: agentURL).ensureRunning()
    }

    static func unregister() throws {
        try jobManager(
            agentURL: URL(filePath: "/dev/null")
        ).shutdown()
    }

    static var isLoaded: Bool {
        ServiceJobManager.printJob(label: label)?.status == 0
    }

    static func removeLegacyJobIfNeeded() {
        let legacyLabel = "com.sayit.mac.agent"
        let legacyMachService = "com.sayit.mac.agent.debug"
        guard let existing = ServiceJobManager.printJob(label: legacyLabel),
              existing.status == 0 else {
            return
        }
        let isLegacyDevelopmentJob =
            existing.output.contains(legacyMachService)
                || existing.output.contains("\(legacyLabel).debug.log")
        guard isLegacyDevelopmentJob else { return }
        try? ServiceJobManager.shutdown(label: legacyLabel)
    }

    private static func jobManager(agentURL: URL) -> ServiceJobManager {
        ServiceJobManager(
            label: label,
            machServiceName: SayItServiceIdentifiers.machService,
            agentURL: agentURL,
            logURL: FileManager.default.temporaryDirectory
                .appending(path: "\(label).log"),
            propertyListURL: FileManager.default.temporaryDirectory
                .appending(path: "\(label).plist")
        )
    }
}
#endif
