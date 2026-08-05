import Darwin
import Foundation

@MainActor
enum SelectionXPCSmokeTest {
    private static let argument = "--smoke-test-selection-xpc"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(argument)
    }

    static func run() async -> Never {
        let controller = SelectionServiceController()
        await controller.terminateForQuit()

        let succeeded: Bool
        do {
            try await controller.verifyXPCConnection()
            succeeded = true
        } catch {
            succeeded = false
        }

        await controller.terminateForQuit()

        if succeeded {
            FileHandle.standardOutput.write(
                Data("Selection helper XPC smoke test passed.\n".utf8)
            )
            exit(EXIT_SUCCESS)
        }

        FileHandle.standardError.write(
            Data("Selection helper XPC smoke test failed.\n".utf8)
        )
        exit(EXIT_FAILURE)
    }
}
