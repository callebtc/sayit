import SwiftUI

struct SelectionAccessSettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading) {
            LabeledContent("Accessibility") {
                HStack {
                    if state.selectionService.isWorking {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Label(
                        accessDescription,
                        systemImage: accessSymbol
                    )
                    .foregroundStyle(.secondary)

                    if state.selectionService.accessibilityIsTrusted != true {
                        if state.selectionService.accessibilityIsTrusted == false {
                            Button(
                                "Open Settings…",
                                action: state
                                    .openSelectionAccessibilitySettings
                            )
                        } else {
                            Button(
                                "Allow…",
                                action: state
                                    .requestSelectionAccessibilityAccess
                            )
                            .disabled(state.selectionService.isWorking)
                        }
                    }
                    if state.selectionService.requiresLoginItemApproval {
                        Button(
                            "Open Login Items",
                            action: state.selectionService
                                .openLoginItemsSettings
                        )
                    }
                }
            }

            if let message = state.selectionService.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    private var accessDescription: String {
        switch state.selectionService.accessibilityIsTrusted {
        case true:
            "Allowed"
        case false:
            "Not allowed"
        case nil:
            "Not checked"
        }
    }

    private var accessSymbol: String {
        switch state.selectionService.accessibilityIsTrusted {
        case true:
            "checkmark.circle.fill"
        case false:
            "exclamationmark.circle"
        case nil:
            "questionmark.circle"
        }
    }
}
