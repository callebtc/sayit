import SayItCore
import SwiftUI

struct DiagnosticsSettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if state.diagnosticEvents.isEmpty {
                    ContentUnavailableView(
                        "No diagnostic events",
                        systemImage: "checkmark.circle",
                        description: Text(
                            "Say It records timings and stable error codes, never source text."
                        )
                    )
                } else {
                    List(state.diagnosticEvents.reversed()) { event in
                        HStack(spacing: DesignTokens.compactSpacing) {
                            Image(systemName: symbol(for: event.severity))
                                .foregroundStyle(color(for: event.severity))
                                .frame(width: 20)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.code)
                                    .font(.callout.monospaced())
                                Text(event.timestamp, format: .dateTime)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                if let milliseconds = event.durationMilliseconds {
                                    Text("\(Double(milliseconds) / 1_000, format: .number.precision(.fractionLength(2))) s")
                                        .monospacedDigit()
                                        .accessibilityLabel("Duration: \(Double(milliseconds) / 1_000, format: .number.precision(.fractionLength(2))) seconds")
                                }
                                Text(event.category.rawValue)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Text("Text, tokens, filenames, and local paths are excluded.")
                    .font(.caption)
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
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private func color(for severity: DiagnosticSeverity) -> Color {
        switch severity {
        case .debug: .secondary
        case .info: .accentColor
        case .warning: .orange
        case .error: .red
        }
    }
}
