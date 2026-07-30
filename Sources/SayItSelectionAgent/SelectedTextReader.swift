import AppKit
import ApplicationServices
import Foundation
import SayItProtocol

struct SelectedTextReader {
    static let maximumCharacters = 1_000_000

    var isAuthorized: Bool {
        AXIsProcessTrustedWithOptions(nil)
    }

    func requestAuthorization() -> Bool {
        let options = [
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func selectedText() -> SelectionServiceResponse {
        guard isAuthorized else {
            return .authorizationRequired
        }

        guard let application = frontmostApplicationElement() else {
            return .unavailable
        }
        AXUIElementSetMessagingTimeout(application, 1.5)

        guard let focusedElement = elementAttribute(
            kAXFocusedUIElementAttribute,
            from: application
        ) else {
            return .noSelection
        }

        var currentElement: AXUIElement? = focusedElement
        for _ in 0..<8 {
            guard let element = currentElement else { break }
            if let response = selectedText(in: element) {
                return response
            }
            currentElement = elementAttribute(
                kAXParentAttribute,
                from: element
            )
        }
        return .noSelection
    }

    private func frontmostApplicationElement() -> AXUIElement? {
        if let processIdentifier = NSWorkspace.shared.frontmostApplication?
            .processIdentifier {
            return AXUIElementCreateApplication(processIdentifier)
        }

        return elementAttribute(
            kAXFocusedApplicationAttribute,
            from: AXUIElementCreateSystemWide()
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
