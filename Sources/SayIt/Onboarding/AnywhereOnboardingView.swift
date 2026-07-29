import SwiftUI

struct AnywhereOnboardingView: View {
    @Environment(AppState.self) private var state
    @State private var launchAtLogin = false
    @State private var launchError: String?

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "cursorarrow.click.2")
                .font(.system(size: 48))
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            VStack(spacing: DesignTokens.compactSpacing) {
                Text("Use Say It anywhere")
                    .font(.largeTitle)
                    .fontDesign(.rounded)
                    .bold()
                    .accessibilityAddTraits(.isHeader)
                Text(
                    "Select text and choose Services → Say It, or copy text and use your global shortcut."
                )
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 430)
            }
            VStack(alignment: .leading, spacing: DesignTokens.standardSpacing) {
                LabeledContent("Selected text") {
                    Text("Services → Say It")
                }
                LabeledContent("Clipboard") {
                    ShortcutRecorderView(
                        shortcut: state.settings.globalShortcut,
                        onRecord: state.updateGlobalShortcut
                    )
                }
                Text(
                    "Some applications place Say It in a Services submenu. Clipboard text is read only when you invoke it."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                Toggle("Launch Say It at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            try state.launchAtLogin.setEnabled(enabled)
                            launchError = nil
                        } catch {
                            launchError = error.localizedDescription
                            launchAtLogin = state.launchAtLogin.isEnabled
                        }
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
            .frame(maxWidth: 410)
        }
        .padding(32)
        .task {
            state.launchAtLogin.refresh()
            launchAtLogin = state.launchAtLogin.isEnabled
        }
    }
}
