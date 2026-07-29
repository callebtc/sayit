import SwiftUI

struct LongTextConfirmationView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.standardSpacing) {
            Label("This is a long read", systemImage: "text.page")
                .bold()
            Text("Generating it may take a while and use additional storage.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancel", action: state.cancelLongText)
                Spacer()
                Button("Read It", action: state.confirmLongText)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
