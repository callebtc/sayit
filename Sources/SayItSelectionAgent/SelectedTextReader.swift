import AppKit
import ApplicationServices
import Foundation
import SayItProtocol
import SayItXPC

struct SelectedTextReader {
    static let maximumCharacters = 1_000_000

    private static let retryDelays: [Duration] = [
        .zero,
        .milliseconds(80),
        .milliseconds(160)
    ]

    var isAuthorized: Bool {
        AXIsProcessTrustedWithOptions(nil)
    }

    func requestAuthorization() -> Bool {
        let options = [
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func selectedText() async -> SelectionServiceResponse {
        guard isAuthorized else {
            return .authorizationRequired
        }

        guard let processIdentifier = NSWorkspace.shared.frontmostApplication?
            .processIdentifier else {
            return .unavailable
        }

        for delay in Self.retryDelays {
            if delay != .zero {
                try? await Task.sleep(for: delay)
            }
            guard NSWorkspace.shared.frontmostApplication?
                .processIdentifier == processIdentifier else {
                return .unavailable
            }

            let response = selectedText(
                inApplication: AXUIElementCreateApplication(processIdentifier)
            )
            if response != .noSelection {
                return response
            }
        }
        return .noSelection
    }

    private func selectedText(
        inApplication application: AXUIElement
    ) -> SelectionServiceResponse {
        AXUIElementSetMessagingTimeout(application, 1.5)
        activateAccessibility(for: application)

        let focusedElement = elementAttribute(
            kAXFocusedUIElementAttribute,
            from: application
        ) ?? application

        return firstValueAlongAncestorChain(
            from: focusedElement,
            value: selectedText(in:),
            parent: {
                elementAttribute(kAXParentAttribute, from: $0)
            }
        ) ?? .noSelection
    }

    private func activateAccessibility(for application: AXUIElement) {
        // Electron intentionally keeps its web accessibility tree disabled
        // until assistive software opts in through this custom attribute.
        AXUIElementSetAttributeValue(
            application,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )

        // Chromium enables its native accessibility APIs when an assistive
        // client asks for the application role.
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(
            application,
            kAXRoleAttribute as CFString,
            &role
        )
    }

    private func selectedText(
        in element: AXUIElement
    ) -> SelectionServiceResponse? {
        if let text = stringAttribute(kAXSelectedTextAttribute, from: element),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return validated(text)
        }

        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        ) == .success,
        let rangeValue,
        CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeDowncast(rangeValue, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range),
              range.length > 0 else {
            return nil
        }
        guard range.length <= Self.maximumCharacters else {
            return .selectionTooLong(
                maximumCharacters: Self.maximumCharacters
            )
        }

        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            axValue,
            &value
        ) == .success,
        let value,
        let text = value as? String,
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return validated(text)
    }

    private func validated(_ text: String) -> SelectionServiceResponse {
        guard text.count <= Self.maximumCharacters else {
            return .selectionTooLong(
                maximumCharacters: Self.maximumCharacters
            )
        }
        return .selectedText(text)
    }

    private func stringAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
        let value else {
            return nil
        }
        return value as? String
    }

    private func elementAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
}
