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
                if state.backgroundService.isWorking || state.serviceConnection == .recovering {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Working")
                } else if state.backgroundService.requiresApproval {
                    Button("Open Login Items", action: state.backgroundService.openLoginItemsSettings)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(actionTitle, action: performRepair)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var title: String {
        if state.backgroundService.requiresApproval { return "Allow background service" }
        return switch state.serviceConnection {
        case .disabled:
            "Background service is off"
        case .recovering:
            "Reconnecting background service"
        case .updateRequired:
            "Service update needs attention"
        default:
            "Can’t reach the background service"
        }
    }

    private var detail: String {
        if state.backgroundService.requiresApproval {
            return "Allow Say It in Login Items & Extensions to continue."
        }
        if state.serviceConnection != .recovering,
           let message = state.backgroundService.errorMessage {
            return message
        }
        return switch state.serviceConnection {
        case .disabled:
            "Speech and playback are unavailable until the service is turned on."
        case .recovering:
            "Say It is restoring its connection automatically. This should only take a moment."
        case .updateRequired:
            "The service still doesn’t match this app. Quit other copies of Say It, then try again."
        default:
            "Say It can’t connect to its speech service. Restart it to continue."
        }
    }

    private var actionTitle: String {
        state.serviceConnection == .disabled ? "Turn On" : "Restart Service"
    }

    private var symbol: String {
        switch state.serviceConnection {
        case .disabled: "power"
        case .recovering: "arrow.clockwise"
        default: "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        state.serviceConnection == .disabled || state.serviceConnection == .recovering
            ? .secondary : .orange
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
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            openSettings()
            NSApp.activate()
        }
    }
}
