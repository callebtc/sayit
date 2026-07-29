import SayItCore
import SwiftUI

struct DiagnosticsSettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            if state.diagnosticEvents.isEmpty {
                ContentUnavailableView(
                    "No diagnostic events",
                    systemImage: "checkmark.circle",
                    description: Text("Say It records timings and stable error codes, never source text.")
                )
            } else {
                List(state.diagnosticEvents.reversed()) { event in
                    HStack {
                        Image(systemName: symbol(for: event.severity))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading) {
                            Text(event.code)
                                .font(.body.monospaced())
                            Text(event.timestamp, format: .dateTime)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(event.category.rawValue)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            HStack {
                Text("Text, tokens, filenames, and local paths are excluded.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Export…", action: state.exportDiagnostics)
                Button("Clear", action: state.clearDiagnostics)
            }
            .padding(DesignTokens.standardSpacing)
        }
        .task {
            state.refreshDiagnostics()
        }
    }

    private func symbol(for severity: DiagnosticSeverity) -> String {
        switch severity {
        case .debug: "ladybug"
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }
}
