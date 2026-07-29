import AppKit
import SayItCore
import SwiftUI

struct HistorySettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @Bindable var settings: AppSettings
    @State private var isConfirmingClear = false

    var body: some View {
        Form {
            Section {
                Picker("Keep history", selection: $settings.retentionPeriod) {
                    Text("7 days").tag(RetentionPeriod.sevenDays)
                    Text("30 days").tag(RetentionPeriod.thirtyDays)
                    Text("90 days").tag(RetentionPeriod.ninetyDays)
                    Text("Forever").tag(RetentionPeriod.forever)
                }
                LabeledContent("Audio storage limit") {
                    Text(
                        settings.historyQuotaBytes,
                        format: .byteCount(style: .file)
                    )
                    .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Open History", action: showHistory)
                Button(
                    "Clear History…",
                    role: .destructive,
                    action: confirmClearHistory
                )
            } footer: {
                Text(
                    "Clearing permanently deletes saved text and generated audio."
                )
            }
        }
        .confirmationDialog(
            "Clear all history?",
            isPresented: $isConfirmingClear
        ) {
            Button(
                "Clear History",
                role: .destructive,
                action: state.clearHistory
            )
        } message: {
            Text("This permanently deletes saved text and generated audio.")
        }
    }

    private func showHistory() {
        openWindow(id: AppWindowID.history)
        NSApp.activate()
    }

    private func confirmClearHistory() {
        isConfirmingClear = true
    }
}
