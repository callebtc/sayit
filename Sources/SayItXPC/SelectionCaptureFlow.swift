import Foundation
import SayItProtocol

public enum SelectionCaptureFlow {
    public static func perform(
        retryDelays: [Duration],
        accessibilitySelection: () -> SelectionServiceResponse,
        copiedSelection: () async -> SelectionServiceResponse?
    ) async -> SelectionServiceResponse {
        var attemptedCopy = false

        for delay in retryDelays {
            if delay != .zero {
                try? await Task.sleep(for: delay)
            }

            let response = accessibilitySelection()
            switch response {
            case .selectedText:
                if !attemptedCopy {
                    attemptedCopy = true
                    return await copiedSelection() ?? response
                }
                return response
            case .noSelection:
                if !attemptedCopy {
                    attemptedCopy = true
                    if let copiedResponse = await copiedSelection() {
                        return copiedResponse
                    }
                }
            default:
                return response
            }
        }

        return .noSelection
    }
}
