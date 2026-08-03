import Testing
@testable import SayIt

@Suite("App error recovery")
struct AppErrorRecoveryActionTests {
    @Test("Accessibility denial offers a settings recovery action")
    func accessibilityDenialRecovery() {
        let error = SelectionServiceError.accessibilityRequired

        #expect(error.recoveryAction == .openAccessibilitySettings)
        #expect(
            error.recoveryAction?.buttonTitle
                == "Open Accessibility Settings…"
        )
    }

    @Test("Other selection failures do not offer accessibility recovery")
    func unrelatedSelectionFailureRecovery() {
        #expect(SelectionServiceError.noSelection.recoveryAction == nil)
        #expect(
            SelectionServiceError.helperUnavailable.recoveryAction == nil
        )
    }
}
