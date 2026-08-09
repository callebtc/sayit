import AppKit
import Observation
import SayItCore
import SayItProtocol
import SayItXPC

@MainActor
@Observable
final class SelectionServiceController {
    private static let authorizationPollInterval = Duration.milliseconds(250)
    private static let authorizationPollAttempts = 480

    private let client = SelectionXPCClient()
    private var hasPreparedHelper = false

    private(set) var accessibilityIsTrusted: Bool?
    private(set) var isWorking = false
    private(set) var errorMessage: String?

    func refreshAuthorization() async {
        await perform {
            _ = try await authorizationStatus()
        }
    }

    func requestAuthorization() async {
        await perform {
            guard try await requestAuthorizationAndWait() else {
                throw SelectionServiceError.accessibilityRequired
            }
        }
    }

    func requestAuthorizationAndWait() async throws -> Bool {
        if try await authorizationStatus(prompt: true) {
            return true
        }

        for _ in 0..<Self.authorizationPollAttempts {
            try await Task.sleep(for: Self.authorizationPollInterval)
            if try await authorizationStatus() {
                return true
            }
        }
        return false
    }

    func selectedPayload() async throws -> TextSourcePayload {
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
        hasPreparedHelper = false
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
        let shouldRestartExistingJob = !hasPreparedHelper
        do {
            try await SelectionServiceLauncher.ensureRunning(
                agentURL: agentURL,
                restartingExistingJob: shouldRestartExistingJob
            )
            hasPreparedHelper = true
        } catch {
            if shouldRestartExistingJob {
                hasPreparedHelper = false
            }
            throw SelectionServiceError.helperRegistrationFailed
        }
    }

    private func authorizationStatus(prompt: Bool = false) async throws -> Bool {
        try await ensureRunning()
        let response = try await client.send(
            prompt ? .requestAuthorization : .authorizationStatus
        )
        guard case .authorizationStatus(let isTrusted) = response else {
            throw SelectionServiceError.helperUnavailable
        }
        accessibilityIsTrusted = isTrusted
        return isTrusted
    }

    private var agentURL: URL {
        Bundle.main.bundleURL.appending(
            path: "Contents/Helpers/SayItSelectionAgent"
        )
    }
}
