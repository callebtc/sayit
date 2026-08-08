import AppKit
import Observation
import SayItCore
import SayItProtocol
import SayItXPC

@MainActor
@Observable
final class SelectionServiceController {
    private let client = SelectionXPCClient()

    private(set) var accessibilityIsTrusted: Bool?
    private(set) var isWorking = false
    private(set) var errorMessage: String?

    func refreshAuthorization() async {
        await perform {
            try await ensureRunning()
            let response = try await client.send(.authorizationStatus)
            guard case .authorizationStatus(let isTrusted) = response else {
                throw SelectionServiceError.helperUnavailable
            }
            accessibilityIsTrusted = isTrusted
        }
    }

    func requestAuthorization() async {
        await perform {
            try await ensureRunning()
            let response = try await client.send(.requestAuthorization)
            guard case .authorizationStatus(let isTrusted) = response else {
                throw SelectionServiceError.helperUnavailable
            }
            accessibilityIsTrusted = isTrusted
        }
    }

    func selectedPayload(
        promptIfNeeded: Bool
    ) async throws -> TextSourcePayload {
        try await ensureRunning()
        let response = try await client.send(.selectedText)
        switch response {
        case .selectedContent(let content):
            accessibilityIsTrusted = true
            return TextSourcePayload(
                source: .selection,
                content: content
            )
        case .selectedText(let text):
            accessibilityIsTrusted = true
            return TextSourcePayload(
                source: .selection,
                plainText: text
            )
        case .authorizationRequired:
            accessibilityIsTrusted = false
            if promptIfNeeded {
                let promptResponse = try await client.send(
                    .requestAuthorization
                )
                if case .authorizationStatus(let isTrusted) = promptResponse {
                    accessibilityIsTrusted = isTrusted
                }
            }
            throw SelectionServiceError.accessibilityRequired
        case .noSelection:
            accessibilityIsTrusted = true
            throw SelectionServiceError.noSelection
        case .selectionTooLong(let maximumCharacters):
            accessibilityIsTrusted = true
            throw SelectionServiceError.selectionTooLong(
                maximumCharacters: maximumCharacters
            )
        case .unavailable:
            throw SelectionServiceError.frontmostApplicationUnavailable
        case .authorizationStatus:
            throw SelectionServiceError.helperUnavailable
        }
    }

    func verifyXPCConnection() async throws {
        try await ensureRunning()
        let response = try await client.send(.authorizationStatus)
        guard case .authorizationStatus = response else {
            throw SelectionServiceError.helperUnavailable
        }
    }

    func terminateForQuit() async {
        await client.invalidate()
        try? SelectionServiceLauncher.unregister()
    }

    func openAccessibilitySettings() -> Bool {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    private func perform(_ work: () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        do {
            try await work()
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }

    private func ensureRunning() async throws {
        do {
            try await SelectionServiceLauncher.ensureRunning(
                agentURL: agentURL
            )
        } catch {
            throw SelectionServiceError.helperRegistrationFailed
        }
    }

    private var agentURL: URL {
        Bundle.main.bundleURL.appending(
            path: "Contents/Helpers/SayItSelectionAgent"
        )
    }
}
