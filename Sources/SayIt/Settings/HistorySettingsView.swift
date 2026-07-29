import SayItCore
import SwiftUI

struct HistorySettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @Bindable var settings: AppSettings
    @State private var isConfirmingClear = false

    var body: some View {
        SettingsPage(
            title: "History",
            subtitle: "Control how long cleaned text and generated audio stay on this Mac."
        ) {
            Form {
                Picker("Keep history", selection: $settings.retentionPeriod) {
                    Text("7 days").tag(RetentionPeriod.sevenDays)
                    Text("30 days").tag(RetentionPeriod.thirtyDays)
                    Text("90 days").tag(RetentionPeriod.ninetyDays)
                    Text("Forever").tag(RetentionPeriod.forever)
                }
                LabeledContent("Audio storage limit") {
                    Text(settings.historyQuotaBytes, format: .byteCount(style: .file))
                }
                Button("Open History") {
                    openWindow(id: "history")
                }
                Button("Clear History…", role: .destructive) {
                    isConfirmingClear = true
                }
                .confirmationDialog(
                    "Clear all history?",
                    isPresented: $isConfirmingClear
                ) {
                    Button("Clear History", role: .destructive) {
                        state.clearHistory()
                    }
                } message: {
                    Text("This permanently deletes saved text and generated audio.")
                }
            }
        }
    }
}
