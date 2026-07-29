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
                Button(
                    "Play",
                    systemImage: "play.fill",
                    action: replay
                )
                .buttonStyle(.borderedProminent)
                .disabled(item.state != .completed)

                Menu("Export", systemImage: "square.and.arrow.up") {
                    Button("Export M4A", action: exportM4A)
                    .disabled(item.state != .completed)
                    Button("Export WAV", action: exportWAV)
                    .disabled(item.state != .completed)
                    Button("Export Text", action: exportText)
                }
                Button(
                    "Regenerate",
                    systemImage: "arrow.clockwise",
                    action: regenerate
                )
                Button(
                    item.isPinned ? "Unpin" : "Pin",
                    systemImage: item.isPinned ? "pin.slash" : "pin",
                    action: togglePinned
                )
                Spacer()
                Button(
                    "Delete",
                    systemImage: "trash",
                    role: .destructive,
                    action: confirmDelete
                )
                .confirmationDialog(
                    "Delete this history item?",
                    isPresented: $isConfirmingDelete
                ) {
                    Button(
                        "Delete",
                        role: .destructive,
                        action: deleteItem
                    )
                } message: {
                    Text("Saved text and generated audio will be deleted.")
                }
            }
        }
        .padding(24)
    }

    private func replay() {
        state.replay(item)
    }

    private func exportM4A() {
        state.export(item, kind: .m4a)
    }

    private func exportWAV() {
        state.export(item, kind: .wav)
    }

    private func exportText() {
        state.export(item, kind: .text)
    }

    private func regenerate() {
        state.regenerate(item)
    }

    private func togglePinned() {
        state.togglePinned(item)
    }

    private func confirmDelete() {
        isConfirmingDelete = true
    }

    private func deleteItem() {
        state.deleteHistoryItem(item)
    }
}
