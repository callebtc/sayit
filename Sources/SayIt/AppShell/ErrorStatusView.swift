import SwiftUI

struct ErrorStatusView: View {
    @Environment(AppState.self) private var state
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.standardSpacing) {
            Label("Couldn’t continue", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .bold()
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Dismiss", action: state.clearError)
                Spacer()
                if state.installedModelIDs.isEmpty {
                    Button("Choose a model", action: state.showOnboarding)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}
