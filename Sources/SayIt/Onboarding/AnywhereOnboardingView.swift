import SwiftUI

struct AnywhereOnboardingView: View {
    @Environment(AppState.self) private var state
    @State private var launchAtLogin = false
    @State private var launchError: String?

    var body: some View {
        OnboardingPage(
            symbol: "cursorarrow.click.2",
            title: "Use Say It anywhere",
            subtitle: "Select text and choose Services → Say It, or copy text and use your global shortcut."
        ) {
            VStack(spacing: DesignTokens.standardSpacing) {
                VStack(alignment: .leading, spacing: DesignTokens.standardSpacing) {
                    LabeledContent("Selected text") {
                        Text("Services → Say It")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Clipboard") {
                        ShortcutRecorderView(
                            shortcut: state.settings.globalShortcut,
                            onRecord: state.updateGlobalShortcut
                        )
                    }
                    Divider()
                    Toggle("Launch Say It at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, enabled in
                            updateLaunchAtLogin(enabled)
                        }
                    if let launchError {
                        Label(
                            launchError,
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.callout)
                        .foregroundStyle(.red)
                    }
                }
                .padding(DesignTokens.generousSpacing)
                .frame(maxWidth: 400)
                .background(
                    .quaternary.opacity(0.55),
                    in: .rect(cornerRadius: DesignTokens.cardCornerRadius)
                )

                Text(
                    "Some applications place Say It in a Services submenu. Clipboard text is read only when you invoke it."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            }
        }
        .task {
            state.launchAtLogin.refresh()
            launchAtLogin = state.launchAtLogin.isEnabled
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            try state.launchAtLogin.setEnabled(enabled)
            launchError = nil
        } catch {
            launchError = error.localizedDescription
            launchAtLogin = state.launchAtLogin.isEnabled
        }
    }
}
