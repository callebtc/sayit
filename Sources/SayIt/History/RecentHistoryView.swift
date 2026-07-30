import AppKit
import SwiftUI

struct RecentHistoryView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.compactSpacing) {
            Text("Recent")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, DesignTokens.compactSpacing)
                .accessibilityAddTraits(.isHeader)

            if state.history.items.isEmpty {
                Text("Spoken items appear here.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, DesignTokens.compactSpacing)
                    .frame(minHeight: DesignTokens.minimumControlSize)
            } else {
                ForEach(state.history.items.prefix(3)) { item in
                    RecentHistoryRowView(item: item)
                }
            }

            Button("View All History…", action: openHistory)
                .buttonStyle(.sayItInline)
                .font(.callout)
                .foregroundStyle(Color.accentColor)
        }
    }

    private func openHistory() {
        dismiss()
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            WindowActivator.prepareForWindowPresentation()
            openWindow(id: AppWindowID.history)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
