import AppKit
import Observation
import SayItCore
import SayItProtocol
import SayItXPC
import ServiceManagement

@MainActor
@Observable
final class SelectionServiceController {
    private let service = SMAppService.agent(
        plistName: SayItServiceIdentifiers.selectionLaunchAgentPlist
    )
    private let client = SelectionXPCClient()

    private(set) var accessibilityIsTrusted: Bool?
    private(set) var isWorking = false
    private(set) var errorMessage: String?

    var requiresLoginItemApproval: Bool {
        #if DEBUG || SAYIT_LOCAL_BUILD
        false
        #else
        service.status == .requiresApproval
        #endif
    }

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
        #if DEBUG || SAYIT_LOCAL_BUILD
        try? DevelopmentSelectionServiceLauncher.unregister()
        #else
        if service.status == .enabled || service.status == .requiresApproval {
            try? await service.unregister()
        }
        #endif
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
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
        #if DEBUG || SAYIT_LOCAL_BUILD
        try await DevelopmentSelectionServiceLauncher.ensureRunning(
            agentURL: agentURL
        )
        #else
        if service.status == .requiresApproval {
            throw SelectionServiceError.helperApprovalRequired
        }
        if service.status != .enabled {
            try service.register()
        }
        for _ in 0..<50 {
            if service.status == .enabled {
                return
            }
            if service.status == .requiresApproval {
                throw SelectionServiceError.helperApprovalRequired
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard service.status == .enabled else {
            throw SelectionServiceError.helperUnavailable
        }
        #endif
    }

    #if DEBUG || SAYIT_LOCAL_BUILD
    private var agentURL: URL {
        Bundle.main.bundleURL.appending(
            path: "Contents/Library/LaunchServices/SayItSelectionAgent"
        )
    }
    #endif
}
