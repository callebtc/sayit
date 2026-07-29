import AppKit
import SwiftUI

struct ServiceRepairView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.standardSpacing) {
            Label(title, systemImage: symbol)
                .foregroundStyle(tint)
                .bold()
            Text(detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Service Settings…", action: openServiceSettings)
                Spacer()
                if state.backgroundService.isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Working")
                } else {
                    Button(actionTitle, action: performRepair)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var title: String {
        switch state.serviceConnection {
        case .disabled:
            "Background service is off"
        case .updateRequired:
            "Service update required"
        default:
            "Can’t reach the background service"
        }
    }

    private var detail: String {
        switch state.serviceConnection {
        case .disabled:
            "Speech and playback are unavailable until the service is turned on."
        case .updateRequired:
            "The running service is out of date. Restart it to continue."
        default:
            "Say It can’t connect to its speech service. Restart it to continue."
        }
    }

    private var actionTitle: String {
        state.serviceConnection == .disabled ? "Turn On" : "Restart Service"
    }

    private var symbol: String {
        state.serviceConnection == .disabled
            ? "power"
            : "exclamationmark.triangle"
    }

    private var tint: Color {
        state.serviceConnection == .disabled ? .secondary : .orange
    }

    private func performRepair() {
        if state.serviceConnection == .disabled {
            state.enableBackgroundService()
        } else {
            state.restartBackgroundService()
        }
    }

    private func openServiceSettings() {
        state.settings.selectedSettingsPane = .service
        dismiss()
        openSettings()
        NSApp.activate()
    }
}
