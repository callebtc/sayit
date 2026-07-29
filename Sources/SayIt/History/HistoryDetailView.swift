import SwiftUI

struct HistoryDetailView: View {
    @Environment(AppState.self) private var state
    let item: HistoryItemSnapshot
    @Binding var isConfirmingDelete: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.generousSpacing) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.title2)
                    .fontDesign(.rounded)
                    .bold()
                    .accessibilityAddTraits(.isHeader)
                Text(item.createdAt, format: .dateTime)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                Text(item.cleanedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            Divider()
            HStack {
                Button("Play", systemImage: "play.fill") {
                    state.replay(item)
                }
                .buttonStyle(.borderedProminent)
                .disabled(item.state != .completed)

                Menu("Export", systemImage: "square.and.arrow.up") {
                    Button("Export M4A") {
                        state.export(item, kind: .m4a)
                    }
                    .disabled(item.state != .completed)
                    Button("Export WAV") {
                        state.export(item, kind: .wav)
                    }
                    .disabled(item.state != .completed)
                    Button("Export Text") {
                        state.export(item, kind: .text)
                    }
                }
                Button("Regenerate", systemImage: "arrow.clockwise") {
                    state.regenerate(item)
                }
                Button(
                    item.isPinned ? "Unpin" : "Pin",
                    systemImage: item.isPinned ? "pin.slash" : "pin"
                ) {
                    state.togglePinned(item)
                }
                Spacer()
                Button("Delete", systemImage: "trash", role: .destructive) {
                    isConfirmingDelete = true
                }
                .confirmationDialog(
                    "Delete this history item?",
                    isPresented: $isConfirmingDelete
                ) {
                    Button("Delete", role: .destructive) {
                        state.deleteHistoryItem(item)
                    }
                } message: {
                    Text("Saved text and generated audio will be deleted.")
                }
            }
        }
        .padding(24)
    }
}
