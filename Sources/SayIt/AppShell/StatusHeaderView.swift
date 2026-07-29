import SwiftUI

struct StatusHeaderView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Say It")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(state.statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
